extends Node
## Downloads images and models from the Foundry server.
## - Disk cache (user://cache) revalidated with ETag / Last-Modified, so a map is only
##   downloaded again when it changed, even across viewer restarts.
## - Images are decoded and mipmapped on a worker thread so the viewer never freezes.
## - Requests for the same URL in flight at the same time share one download.

signal _request_finished(url: String, body: PackedByteArray)

const CACHE_DIR := "user://cache"

var _textures := {}  # url -> Texture2D (decoded, this session)
var _pending := {}   # url -> true while a download is in flight
## url -> {"source": "cache" | "revalidated" | "download" | "failed", "ms": int} for the last fetch
var last_fetch := {}

## Accept self-signed https certificates from the Foundry server (viewer.cfg: network/insecure_tls).
var insecure_tls := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)


func fetch_bytes(url: String) -> PackedByteArray:
	while _pending.has(url):
		var finished: Array = await _request_finished
		if finished[0] == url:
			return finished[1]

	_pending[url] = true
	var started := Time.get_ticks_msec()
	var cache_path := "%s/%s" % [CACHE_DIR, url.get_slice("?", 0).md5_text()]
	var meta := _read_meta(cache_path)
	var headers := PackedStringArray()
	if meta.has("etag"):
		headers.append("If-None-Match: " + meta.etag)
	if meta.has("last_modified"):
		headers.append("If-Modified-Since: " + meta.last_modified)

	var http := HTTPRequest.new()
	http.use_threads = true
	if insecure_tls:
		http.set_tls_options(TLSOptions.client_unsafe())
	add_child(http)
	var body := PackedByteArray()
	var source := "failed"
	if http.request(url, headers) == OK:
		var res: Array = await http.request_completed  # [result, code, headers, body]
		if res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 304:
			body = FileAccess.get_file_as_bytes(cache_path)
			source = "cache"
		elif res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200:
			body = res[3]
			source = "download"
			_write_cache(cache_path, body, res[2])
		else:
			push_warning("Assets: failed to download %s (result %d, HTTP %d)" % [url, res[0], res[1]])
	else:
		push_warning("Assets: could not start download of %s" % url)
	if body.is_empty() and source == "failed" and FileAccess.file_exists(cache_path):
		body = FileAccess.get_file_as_bytes(cache_path)  # server unreachable: use the last copy
		source = "cache"
	http.queue_free()
	_pending.erase(url)
	last_fetch[url] = {"source": source, "ms": Time.get_ticks_msec() - started}
	_request_finished.emit(url, body)
	return body


func fetch_texture(url: String) -> Texture2D:
	if _textures.has(url):
		last_fetch[url] = {"source": "memory", "ms": 0}
		return _textures[url]
	var body := await fetch_bytes(url)
	if _textures.has(url):  # another caller decoded it while we waited
		return _textures[url]
	if body.is_empty():
		return null
	# Decode + mipmaps can take a second for big maps: do it off the main thread.
	var result := {"image": null}  # lambdas capture by value; a Dictionary is shared
	var task := WorkerThreadPool.add_task(func():
		var image := decode_image(body, url)
		if image:
			image.generate_mipmaps()
		result.image = image)
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if result.image == null:
		return null
	var texture := ImageTexture.create_from_image(result.image)
	_textures[url] = texture
	return texture


## The decoded image behind a texture fetched earlier (used to build meshes from token art).
func get_image(url: String) -> Image:
	var texture: Texture2D = _textures.get(url)
	return texture.get_image() if texture else null


func _read_meta(cache_path: String) -> Dictionary:
	if not FileAccess.file_exists(cache_path) or not FileAccess.file_exists(cache_path + ".json"):
		return {}
	var meta = JSON.parse_string(FileAccess.get_file_as_string(cache_path + ".json"))
	return meta if meta is Dictionary else {}


func _write_cache(cache_path: String, body: PackedByteArray, headers: PackedStringArray) -> void:
	var meta := {}
	for header in headers:
		var name := header.get_slice(":", 0).strip_edges().to_lower()
		var value := header.substr(header.find(":") + 1).strip_edges()
		if name == "etag":
			meta.etag = value
		elif name == "last-modified":
			meta.last_modified = value
	if meta.is_empty():
		return  # can't revalidate later, so don't cache
	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if file:
		file.store_buffer(body)
		file.close()
		FileAccess.open(cache_path + ".json", FileAccess.WRITE).store_string(JSON.stringify(meta))


static func decode_image(body: PackedByteArray, url: String) -> Image:
	if body.size() < 12:
		return null
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if body[0] == 0x89 and body[1] == 0x50:
		err = image.load_png_from_buffer(body)
	elif body[0] == 0xFF and body[1] == 0xD8:
		err = image.load_jpg_from_buffer(body)
	elif body.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = image.load_webp_from_buffer(body)
	elif body[0] == 0x42 and body[1] == 0x4D:
		err = image.load_bmp_from_buffer(body)
	elif url.get_slice("?", 0).get_extension().to_lower() == "svg" or body[0] == 0x3C:
		err = image.load_svg_from_buffer(body, 2.0)
	if err != OK:
		push_warning("Assets: unsupported or corrupt image %s (videos/GIFs aren't supported)" % url)
		return null
	return image
