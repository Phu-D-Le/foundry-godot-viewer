extends Node3D
## Mirrors Foundry tiles as flat textured planes lying at the tile's elevation, or, with the tile's
## "Custom Appearance" ticked, in one of the token styles (visual_builder.gd).

const SceneInfo = preload("res://scripts/scene_info.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const CUSTOM_RIM_COLOR := Color("8a8a8a")  # coin rim for tiles (they have no disposition)

const BASE_OFFSET := 0.004  # meters above the floor
const SORT_STEP := 0.0005  # keeps overlapping tiles in Foundry's sort order without flicker
const MAX_SORT_OFFSET := 0.004

var info: SceneInfo
var loader: Node  # asset_loader.gd
## Returns whether something on the given Foundry Level ids should be shown (PgUp/PgDn floor filter).
var level_filter := func(_level_ids: Array) -> bool: return true

var _tiles := {}  # id -> {"node": MeshInstance3D, "data": Dictionary, "holder": Node3D (custom appearance)}


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_tiles.clear()


func upsert(t: Dictionary) -> void:
	var entry: Dictionary = _tiles.get(t.id, {})
	if entry.is_empty():
		var mesh := MeshInstance3D.new()
		mesh.name = "Tile_" + t.id
		mesh.mesh = PlaneMesh.new()
		add_child(mesh)
		entry = {"node": mesh}
		_tiles[t.id] = entry
	entry.data = t
	var node: MeshInstance3D = entry.node
	var url = _look(t)[0]
	if entry.get("src_img") != t.get("img"):
		entry.src_img = t.get("img")
		entry.erase("texture_size")  # new image: its size is known once it loads (a cut-out keeps the size)
	_place(entry)

	# Image material for the tile's look (blend mode, tint and opacity). A new image's material goes on
	# once that image has loaded (_load_texture), so the old look stays meanwhile.
	var material_key := "%s|%s|%s|%.3f|%.1f|%s" % [url, _look(t)[1], _tint(t).to_html(), _tolerance(t), _hue(t),
		VisualBuilder.pixel_art]
	if node.get_meta("material_key", "") != material_key:
		node.set_meta("material_key", material_key)
		if node.material_override == null or node.get_meta("img", "") == str(url):
			_set_material(node, t, _current_texture(node))
	_set_cull(node)
	_apply_visibility(entry)
	_load_texture(node, t)
	_update_custom(entry)


## The tile's image and how it's blended: Foundry's finished cut-out ("baked", with the edge refinements
## from Tile Config) once the GM's browser has uploaded it, otherwise the image itself, with white cut out
## here ("cutout") or drawn as is ("normal").
static func _look(t: Dictionary) -> Array:
	var blend := str(t.get("blendMode", "normal"))
	if blend == "cutout" and t.get("cutoutImg") is String:
		return [t.cutoutImg, "baked"]
	return [t.get("img"), blend]


static func _tint(t: Dictionary) -> Color:
	return Color(Color.from_string(str(t.get("tint", "#ffffff")), Color.WHITE), float(t.get("alpha", 1.0)))


static func _tolerance(t: Dictionary) -> float:
	return float(t.get("whiteTolerance", 0.1))


## Hue Shift (degrees) from Tile Config.
static func _hue(t: Dictionary) -> float:
	return float(t.get("hueShift", 0.0))


static func _current_texture(node: MeshInstance3D) -> Texture2D:
	var material := node.material_override
	if material is StandardMaterial3D:
		return (material as StandardMaterial3D).albedo_texture
	if material is ShaderMaterial:
		return (material as ShaderMaterial).get_shader_parameter("tex")
	return null


## `blend` overrides the tile's own, e.g. "cutout" when its uploaded cut-out couldn't be loaded.
func _set_material(node: MeshInstance3D, t: Dictionary, texture: Texture2D, blend := "") -> void:
	if blend:
		node.set_meta("blend_override", blend)
	blend = node.get_meta("blend_override", _look(t)[1])
	node.material_override = VisualBuilder.image_material(texture, blend, _tint(t), false, false, _tolerance(t), false,
		_hue(t))
	_set_cull(node)


## A mirrored tile (negative scale) turns the plane inside out: draw both sides.
func _set_cull(node: MeshInstance3D) -> void:
	var mat := node.material_override
	if mat is StandardMaterial3D:
		(mat as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED if node.scale.x * node.scale.z < 0 			else BaseMaterial3D.CULL_BACK


## Size, position and rotation exactly as Foundry draws the tile (client/canvas/placeables/tile.mjs):
## the image is fitted into width x height (texture.fit), scaled by |scaleX|, |scaleY|, and
## (x, y) is the point at (anchorX, anchorY) of that image, which the tile rotates around.
func _place(entry: Dictionary) -> void:
	var t: Dictionary = entry.data
	var node: MeshInstance3D = entry.node
	var box := Vector2(float(t.width), float(t.height))
	var size := box
	var tex: Vector2 = entry.get("texture_size", Vector2.ZERO)
	if tex.x > 0.0 and tex.y > 0.0:
		match str(t.get("fit", "fill")):
			"contain":
				size = tex * minf(box.x / tex.x, box.y / tex.y)
			"cover":
				size = tex * maxf(box.x / tex.x, box.y / tex.y)
			"width":
				size = tex * (box.x / tex.x)
			"height":
				size = tex * (box.y / tex.y)
	var scale_x := float(t.get("scaleX", 1))
	var scale_y := float(t.get("scaleY", 1))
	size *= Vector2(absf(scale_x), absf(scale_y))

	# Center of the image in Foundry pixels: the anchor point plus the rotated offset to the center.
	var angle := deg_to_rad(float(t.get("rotation", 0)))
	var offset := Vector2((0.5 - float(t.get("anchorX", 0.5))) * size.x, (0.5 - float(t.get("anchorY", 0.5))) * size.y)
	var center := Vector2(float(t.x), float(t.y)) + offset.rotated(angle)

	(node.mesh as PlaneMesh).size = Vector2(maxf(info.px_to_m(size.x), 0.001), maxf(info.px_to_m(size.y), 0.001))
	var sort_offset := clampf(float(t.get("sort", 0)) * SORT_STEP, 0.0, MAX_SORT_OFFSET)
	node.position = info.to_3d(center.x, center.y, float(t.get("elevation", 0))) + Vector3.UP * (BASE_OFFSET + sort_offset)
	node.rotation.y = -angle  # Foundry rotates clockwise on screen
	# Negative texture scale mirrors the image in Foundry.
	node.scale = Vector3(-1.0 if scale_x < 0.0 else 1.0, 1.0, -1.0 if scale_y < 0.0 else 1.0)
	# Where a custom-appearance visual goes: the image's center at the tile's elevation.
	entry.center = info.to_3d(center.x, center.y, float(t.get("elevation", 0)))
	entry.angle = -angle
	entry.size_m = Vector2(info.px_to_m(size.x), info.px_to_m(size.y))
	var holder: Node3D = entry.get("holder")
	if holder:
		holder.position = entry.center
		holder.rotation.y = entry.angle


## "Custom Appearance": build the tile in a token style; the flat plane is hidden meanwhile.
func _update_custom(entry: Dictionary) -> void:
	var t: Dictionary = entry.data
	var holder: Node3D = entry.get("holder")
	if not t.get("custom", false) or not t.get("appearance") is Dictionary:
		if holder:
			holder.set_meta("visual_key", "")
			for child in holder.get_children():
				holder.remove_child(child)
				child.queue_free()
		_apply_visibility(entry)
		return
	if holder == null:
		holder = Node3D.new()
		holder.name = "TileVisual_" + t.id
		add_child(holder)
		entry.holder = holder
	holder.position = entry.center
	holder.rotation.y = entry.angle
	var d: Dictionary = t.appearance.duplicate()
	d.img = _look(t)[0]
	var style := str(d.get("style", "flat"))
	var size: Vector2 = entry.size_m
	var blend: String = _look(t)[1]
	var tolerance := _tolerance(t)
	# Offset (grid units) inside the holder, so it turns with the tile; moving it needs no rebuild.
	var offset_node: Node3D = holder.get_node_or_null("Offset")
	if offset_node == null:
		offset_node = Node3D.new()
		offset_node.name = "Offset"
		holder.add_child(offset_node)
	offset_node.position = Vector3(float(d.get("offsetX", 0)), float(d.get("offsetY", 0)), float(d.get("offsetZ", 0))) * info.mpu
	var key := VisualBuilder.cache_key(style, d, size.x, size.y, CUSTOM_RIM_COLOR, blend, tolerance, _hue(t))
	_apply_visibility(entry)
	if holder.get_meta("visual_key", "") == key:
		return
	holder.set_meta("visual_key", key)
	for child in offset_node.get_children():
		offset_node.remove_child(child)
		child.queue_free()
	var visual := await VisualBuilder.build(style, d, size.x, size.y, loader, CUSTOM_RIM_COLOR, blend, tolerance, _hue(t))
	if visual == null and blend == "baked" and is_instance_valid(holder) and holder.get_meta("visual_key", "") == key:
		d.img = t.get("img")  # cut-out missing on the server: cut out white here
		visual = await VisualBuilder.build(style, d, size.x, size.y, loader, CUSTOM_RIM_COLOR, "cutout", tolerance, _hue(t))
	if visual == null or not is_instance_valid(offset_node) or holder.get_meta("visual_key", "") != key:
		if visual:
			visual.free()
		return
	offset_node.add_child(visual)


func remove(id: String) -> void:
	if _tiles.has(id):
		for key in ["node", "holder"]:
			var node: Node3D = _tiles[id].get(key)
			if node:
				remove_child(node)
				node.queue_free()
		_tiles.erase(id)


## Rebuild every tile's look, e.g. after HD-2D pixel-art filtering was turned on or off.
func rebuild_all() -> void:
	for entry in _tiles.values():
		entry.node.set_meta("material_key", "")
		var holder: Node3D = entry.get("holder")
		if holder:
			holder.set_meta("visual_key", "")
		upsert(entry.data)


func refresh_visibility() -> void:
	for entry in _tiles.values():
		_apply_visibility(entry)


func _apply_visibility(entry: Dictionary) -> void:
	var t: Dictionary = entry.data
	var shown: bool = not t.get("hidden", false) and level_filter.call(t.get("levels", []))
	var custom: bool = t.get("custom", false) and t.get("appearance") is Dictionary
	entry.node.visible = shown and not custom
	var holder: Node3D = entry.get("holder")
	if holder:
		holder.visible = shown and custom


func _load_texture(node: MeshInstance3D, t: Dictionary) -> void:
	var url = _look(t)[0]
	if node.get_meta("img", "") == str(url):
		return
	node.set_meta("img", str(url))
	node.remove_meta("blend_override")
	if not url is String:
		return
	var texture: Texture2D = await loader.fetch_texture(url)
	var blend := ""
	if texture == null and _look(t)[1] == "baked" and t.get("img") is String:
		texture = await loader.fetch_texture(t.img)  # cut-out missing on the server: cut out white here
		blend = "cutout"
	if is_instance_valid(node) and node.get_meta("img", "") == url and texture:
		var entry: Dictionary = _tiles.get(t.id, {})
		if entry.is_empty() or entry.node != node:
			return
		_set_material(node, entry.data, texture, blend)
		entry.texture_size = Vector2(texture.get_size())  # "fit" depends on the image's aspect ratio
		_place(entry)
		_update_custom(entry)  # its size depends on the fitted image too
