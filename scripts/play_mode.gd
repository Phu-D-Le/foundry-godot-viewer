extends Node
## Play mode (the default at launch): the player's own Foundry client runs in a see-through web layer over the
## full-screen 3D view (Godot WRY / WebView2). Foundry's UI works as usual; its 2D board is hidden and the 3D view
## takes its place. The module's play client (play-client.js) streams that player's scene to this viewer and
## sends clicks on empty map space, wheel and a few keys here (ipc). They become 3D picks and Foundry actions
## (its `godotPlay` API, called with eval).
##   Ctrl+`  play <-> dev mode (dev: the web layer hides; the viewer as before, fed by a GM browser)
##   F11     window (the default) <-> full screen (a borderless full window)          F3  performance overlay
##   F2      change the Foundry address (while the page isn't showing)
## In the 3D view: left-click a token = select, drag your token = move (Shift: no grid snap), drag elsewhere =
## orbit, right/middle-drag = pan, wheel = zoom, right-click = token HUD (yours), double
## right-click = target (config on yours, as in Foundry), T = target
## under the cursor, double-click = sheet, Ctrl-drag = ruler, hold still = ping, Esc = release.
## Not started headless, from test scripts (--script) or with --dev.

const DragGrid = preload("res://scripts/drag_grid.gd")
const CONFIG_PATH := "user://play.cfg"
const DEFAULT_URL := "http://localhost:30000"
const DRAG_START_PX := 6.0
const PING_HOLD := 0.6  # seconds held still for a ping
const RIGHT_DOUBLE := 0.4  # seconds between two right-clicks on a token for a double right-click
const LOAD_WAIT := 10.0  # seconds for Foundry's page to start loading before the viewer says something is wrong
const WEBVIEW2_URL := "https://go.microsoft.com/fwlink/p/?LinkId=2124703"  # Microsoft's Evergreen installer
const WEBVIEW2_ID := "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

var main: Node  # main.gd
## Play mode on (web layer shown, the play client feeds the viewer).
var active := false
## Play mode can run here: a window and the WebView add-on.
var available := false

var web: Control
var _web_layer: CanvasLayer
var _ui: CanvasLayer  # drawn by Godot under the web layer: first-run panel, performance overlay, notes
var _note: Label
var _perf: Label
var _cfg := ConfigFile.new()
var _url := ""
var _user := {}
var _web_perf := {}
var _frame_ms: Array[float] = []
var _windowed := true  # starts in a window; F11 toggles a borderless full window
var _rebuilding := false  # F11 / a resize is rebuilding the web layer
var _resize_wait: SceneTreeTimer
var _drag := {}  # a pointer drag that started on empty map space
var _pointer := Vector2.ZERO  # last pointer position, viewport px
var _css_size := Vector2.ZERO  # the page's size in CSS px (from its messages)
var _ruler: MeshInstance3D
var _ruler_label: Label3D
var _measure_wait := 0.0
var _grid: DragGrid  # Foundry's grid around the pointer while dragging a token
var _last_right := {}  # the last right-click on a token: {id, t}
var last_call := ""  # the last godotPlay call (tests read it; nothing runs without the web layer)
var _page_seen := false  # the current web layer started loading a page


func start() -> void:
	var args := OS.get_cmdline_args()
	available = DisplayServer.get_name() != "headless" and ClassDB.class_exists("WebView") \
		and not "--script" in args and not "--dev" in args and not "--dev" in OS.get_cmdline_user_args()
	if not available:
		main.server.active_role = ""  # as before play mode: any Foundry client feeds the viewer
		return
	_ui = CanvasLayer.new()
	_ui.name = "PlayUI"
	_ui.layer = 5
	add_child(_ui)
	_note = Label.new()
	_note.add_theme_font_size_override("font_size", 18)
	_note.add_theme_color_override("font_outline_color", Color.BLACK)
	_note.add_theme_constant_override("outline_size", 6)
	_note.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_note.position.y = 12
	_ui.add_child(_note)
	_perf = Label.new()
	_perf.add_theme_font_size_override("font_size", 15)
	_perf.add_theme_color_override("font_outline_color", Color.BLACK)
	_perf.add_theme_constant_override("outline_size", 5)
	_perf.position = Vector2(12, 60)
	_perf.visible = false
	_ui.add_child(_perf)
	_web_layer = CanvasLayer.new()
	_web_layer.name = "WebLayer"
	_web_layer.layer = 10
	add_child(_web_layer)
	_cfg.load(CONFIG_PATH)
	_url = str(_cfg.get_value("foundry", "url", ""))
	if _cfg.get_value("gpu", "answer", "") == "":
		await _ask_gpu()  # once, on laptops with two GPUs
	elif _cfg.get_value("gpu", "answer", "") == "yes":
		_set_gpu_preference()  # again each start: WebView2 updates move to a new folder
	if _url == "":
		_ask_address()
	else:
		_connect()


## The address is checked before the web layer opens: a wrong one (or the GM's Foundry being off) brings back the
## address panel instead of an empty view.
func _connect() -> void:
	_say("Connecting to %s ..." % _url, 8.0)
	var problem := await _probe(_url)
	if problem != "":
		print("Play: can't reach %s (%s)" % [_url, problem])
		_ask_address("Couldn't reach %s (%s).\nCheck the address, and that the GM's Foundry is running." % [_url, problem])
		return
	_open()


## "" when something answers at the address, otherwise why not.
func _probe(url: String) -> String:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	http.set_tls_options(TLSOptions.client_unsafe())  # only "is it there": a self-signed certificate is the page's business
	add_child(http)
	if http.request(url + "/join", [], HTTPClient.METHOD_HEAD) != OK:
		http.queue_free()
		return "not a web address"
	var result: Array = await http.request_completed
	http.queue_free()
	match int(result[0]):
		HTTPRequest.RESULT_SUCCESS:
			return ""
		HTTPRequest.RESULT_TIMEOUT:
			return "no answer"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "unknown name"
		_:
			return "connection refused or blocked"


## The web layer (WebView2) needs Microsoft's runtime: Windows 11 has it, some Windows 10 PCs don't.
func _webview2_installed() -> bool:
	for key in ["HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\" + WEBVIEW2_ID,
			"HKLM\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\" + WEBVIEW2_ID,
			"HKCU\\Software\\Microsoft\\EdgeUpdate\\Clients\\" + WEBVIEW2_ID]:
		var out := []
		if OS.execute("reg", ["query", key, "/v", "pv"], out) == 0 and not "0.0.0.0" in str(out):
			return true
	return false


## Laptops with two GPUs: Windows may run the web layer (WebView2) on the integrated GPU while Godot uses the
## fast one, so every frame is copied between them and Foundry's UI stutters. With the player's OK, set Windows'
## per-app GPU preference ("High performance") for the WebView2 runtime and this viewer. Per user, no admin
## rights; Windows Settings > Display > Graphics shows and undoes it.
const GPU_KEY := "HKCU\\Software\\Microsoft\\DirectX\\UserGpuPreferences"

func _ask_gpu() -> void:
	var out := []
	OS.execute("powershell", ["-NoProfile", "-Command", "(Get-CimInstance Win32_VideoController).Name"], out)
	var gpus := str(out[0] if out.size() else "").strip_edges().split("\n", false)
	if gpus.size() < 2:
		_cfg.set_value("gpu", "answer", "single")
		_cfg.save(CONFIG_PATH)
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Smoother play on this laptop"
	dialog.dialog_text = ("This PC has two graphics chips (%s).\nRun Foundry's UI on the same fast one as the 3D view?\n"
		+ "It makes the UI much smoother. Windows remembers it per app (Settings > Display > Graphics);\n"
		+ "takes effect after restarting the viewer.") % ", ".join(gpus)
	dialog.ok_button_text = "Yes, use the fast GPU"
	dialog.cancel_button_text = "No"
	_ui.add_child(dialog)
	dialog.popup_centered()
	var answer := ["no"]
	dialog.confirmed.connect(func() -> void: answer[0] = "yes")
	await dialog.visibility_changed
	dialog.queue_free()
	_cfg.set_value("gpu", "answer", answer[0])
	_cfg.save(CONFIG_PATH)
	if answer[0] == "yes":
		_set_gpu_preference()
		_say("Done: restart the viewer to use the fast GPU for Foundry's UI.", 6.0)


func _set_gpu_preference() -> void:
	var exes: Array[String] = [OS.get_executable_path().replace("/", "\\")]
	for root in ["C:/Program Files (x86)/Microsoft/EdgeWebView/Application", "C:/Program Files/Microsoft/EdgeWebView/Application"]:
		for version in DirAccess.get_directories_at(root):
			var exe := "%s/%s/msedgewebview2.exe" % [root, version]
			if FileAccess.file_exists(exe):
				exes.append(exe.replace("/", "\\"))
	for exe in exes:
		OS.execute("reg", ["add", GPU_KEY, "/v", exe, "/t", "REG_SZ", "/d", "GpuPreference=2;", "/f"])


## Where the Foundry server is (a Godot panel, no web layer meanwhile): on the first run, with F2, or with what
## went wrong (`problem`) when the address can't be reached or the page didn't open.
func _ask_address(problem := "", webview_help := false) -> void:
	if web:
		web.queue_free()
		web = null
	var old := _ui.get_node_or_null("FirstRun")
	if old:
		old.free()
	set_play(false, false)
	main._hud.visible = false
	var panel := PanelContainer.new()
	panel.name = "FirstRun"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Play in 3D: your Foundry address"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)
	var hint := Label.new()
	hint.text = "The address you open Foundry at in your browser (ask your GM)."
	box.add_child(hint)
	if problem != "":
		var trouble := Label.new()
		trouble.text = problem
		trouble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		trouble.custom_minimum_size = Vector2(520, 0)  # wraps at the panel's width, not one word a line
		trouble.add_theme_color_override("font_color", Color(1.0, 0.62, 0.4))
		box.add_child(trouble)
	if webview_help:
		var get_runtime := Button.new()
		get_runtime.text = "Get Microsoft WebView2 Runtime (free), install it, then press Play"
		get_runtime.pressed.connect(func() -> void: OS.shell_open(WEBVIEW2_URL))
		box.add_child(get_runtime)
	var field := LineEdit.new()
	field.text = _url if _url != "" else DEFAULT_URL
	field.select_all_on_focus = true
	box.add_child(field)
	var go := Button.new()
	go.text = "Play"
	box.add_child(go)
	var dev := Button.new()
	dev.text = "Dev mode (viewer fed by a GM browser)"
	box.add_child(dev)
	_ui.add_child(panel)
	panel.reset_size()
	panel.position = (get_viewport().get_visible_rect().size - panel.size) / 2.0
	_note.modulate.a = 0.0  # "Connecting ..." is over
	field.grab_focus()
	var submit := func(_t := "") -> void:
		_url = field.text.strip_edges().trim_suffix("/")
		if not _url.begins_with("http"):
			_url = "http://" + _url
		_cfg.set_value("foundry", "url", _url)
		_cfg.save(CONFIG_PATH)
		panel.queue_free()
		_connect()
	field.text_submitted.connect(submit)
	go.pressed.connect(submit)
	dev.pressed.connect(func() -> void:
		panel.queue_free()
		main._hud.visible = true
		_say("Dev mode. Ctrl+` opens play mode."))


## Window size first, then the web layer: it only stays see-through at the size it was made.
func _open() -> void:
	_rebuilding = true
	if _windowed:
		_window_mode()
	else:
		_full_window()
	await get_tree().create_timer(0.3).timeout
	await _make_web()
	_rebuilding = false
	set_play(true)
	if not get_window().size_changed.is_connected(_on_resized):
		get_window().size_changed.connect(_on_resized)


func _make_web() -> void:
	if web:
		web.queue_free()
		web = null
		await get_tree().process_frame
	web = ClassDB.instantiate("WebView")
	web.name = "Foundry"
	web.set("transparent", true)
	web.set("full_window_size", true)
	web.set("forward_input_events", false)  # the player's typing never reaches Godot; the page sends our keys
	web.set("devtools", bool(_cfg.get_value("play", "devtools", false)))
	web.set("data_directory", ProjectSettings.globalize_path("user://webview"))  # stays logged in
	web.set("url", _url + "/join")  # Foundry goes on to /game when already logged in
	web.set_anchors_preset(Control.PRESET_FULL_RECT)
	web.connect("ipc_message", _on_ipc)
	_page_seen = false
	web.connect("page_load_started", func(_a = null) -> void:
		_page_seen = true
		print("Play: page loading ", web.get("url") if web else ""))
	web.connect("page_load_finished", func(_a = null) -> void:
		_page_seen = true
		print("Play: page loaded"))
	web.visible = true
	_web_layer.add_child(web)
	print("Play: web layer opened for %s" % _url)
	_watch_page(web)


## A web layer that never starts loading a page leaves only the 3D view: say why instead.
func _watch_page(view: Control) -> void:
	await get_tree().create_timer(LOAD_WAIT).timeout
	if view != web or _page_seen:
		return
	var runtime := _webview2_installed()
	print("Play: Foundry's page didn't open in %d s (WebView2 runtime %s)" % [LOAD_WAIT, "found" if runtime else "missing"])
	if runtime:
		_ask_address("Foundry's page didn't open. Press Play to try again. If it keeps failing, reinstall Microsoft " +
			"WebView2 Runtime below and restart the viewer.", true)
	else:
		_ask_address("Foundry's page can't open: this PC is missing Microsoft WebView2 Runtime, which the viewer " +
			"uses to show Foundry. Install it, then press Play.", true)


## Play (web layer on top, the play client feeds the viewer) or dev mode (the viewer as before).
func set_play(on: bool, announce := true) -> void:
	active = on and available
	main.server.active_role = "play" if active else "gm"
	# Players steer the camera themselves (Space can't reach Godot from the page): the cinematic camera is for dev
	# mode, where its remembered on/off comes back
	main.set_cinematic(false if active else bool(main._load_state().get_value("camera", "cinematic", false)), false)
	main.orbit.manual_only = active  # no automated camera at all for players (follow, director)
	if active:
		main._follow_enabled = false
		main.orbit.follow = null
	if web:
		web.visible = active
		if active:
			web.call("focus")
		else:
			web.call("focus_parent")  # keys come back to Godot, so Ctrl+` works again
	main._hud.visible = not active
	if not active:
		main.fog.clear()  # dev mode shows everything; play mode gets the player's vision again on resend
	main.env.ssao_enabled = not active  # play: lighter, the UI gets GPU time
	Engine.max_fps = _fps_cap() if active else 0
	main.server.send({"type": "snapshot.request"})  # the now-active client resends its scene
	if announce:
		_say("Play mode (Ctrl+` for dev mode)" if active else "Dev mode (Ctrl+` for play mode)")


## Godot's frame cap in play mode: the screen's refresh rate, at most 60 (play.cfg [play] max_fps; 0 = none).
func _fps_cap() -> int:
	var cap := int(_cfg.get_value("play", "max_fps", 60))
	var refresh := int(DisplayServer.screen_get_refresh_rate())
	if cap <= 0:
		return 0
	return mini(cap, refresh) if refresh > 0 else cap


func _input(event: InputEvent) -> void:
	if not available or not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_QUOTELEFT and event.ctrl_pressed:
		if web == null and (_url == "" or _ui.get_node_or_null("FirstRun")):
			return  # on the address panel
		if web == null:
			_open()
		else:
			set_play(not active)
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_F11:
		_toggle_window()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_F3:
		_perf.visible = not _perf.visible
	elif event.keycode == KEY_F2 and _ui.get_node_or_null("FirstRun") == null:
		_ask_address()  # reaches Godot only while the page doesn't have the keyboard
		get_viewport().set_input_as_handled()


## Window <-> full screen. The web layer is rebuilt after the resize (it would lose its see-through background);
## the login survives (data_directory).
func _toggle_window() -> void:
	_windowed = not _windowed
	_rebuilding = true
	if _windowed:
		_window_mode()
	else:
		_full_window()
	if web:
		await get_tree().create_timer(0.3).timeout
		await _make_web()
		set_play(active, false)
	_rebuilding = false


## A normal window: three quarters of the screen, centered.
func _window_mode() -> void:
	var screen := DisplayServer.window_get_current_screen()
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	var size := DisplayServer.screen_get_size(screen) * 3 / 4
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(DisplayServer.screen_get_position(screen) + (DisplayServer.screen_get_size(screen) - size) / 2)


## The window was resized by hand (border drag, maximize): once it settles, rebuild the web layer so it stays
## see-through.
func _on_resized() -> void:
	if _rebuilding or web == null:
		return
	var wait := get_tree().create_timer(0.5)
	_resize_wait = wait
	await wait.timeout
	if wait != _resize_wait or _rebuilding:
		return  # a newer resize, or F11 took over
	_rebuilding = true
	await _make_web()
	set_play(active, false)
	_rebuilding = false


## "Full screen windowed": a borderless window covering the screen. Godot's own full-screen mode lets Windows skip
## desktop composition, and the see-through web layer then shows grey instead of the 3D view.
func _full_window() -> void:
	var screen := DisplayServer.window_get_current_screen()
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_position(DisplayServer.screen_get_position(screen))
	DisplayServer.window_set_size(DisplayServer.screen_get_size(screen))


func _process(delta: float) -> void:
	if not available:
		return
	_frame_ms.append(delta * 1000.0)
	if _frame_ms.size() > 240:
		_frame_ms.pop_front()
	if _perf.visible:
		_perf.text = _perf_text()
	if _drag.get("down", false) and not _drag.get("moved", false) and _drag.button == MOUSE_BUTTON_LEFT \
			and not _drag.get("pinged", false) and Time.get_ticks_msec() / 1000.0 - float(_drag.t0) > PING_HOLD \
			and str(_drag.token) == "":
		_drag.pinged = true
		_ping(_drag.pos)
	if _measure_wait > 0.0:
		_measure_wait -= delta


func _perf_text() -> String:
	var sorted := _frame_ms.duplicate()
	sorted.sort()
	var n := sorted.size()
	var hitches := sorted.filter(func(t): return t > 25.0).size()
	var lines := ["Godot %.0f FPS · frame p50 %.1f ms · p95 %.1f ms · hitches %d (last 4 s) · cap %s" % [
		Engine.get_frames_per_second(), sorted[n / 2] if n else 0.0, sorted[int(n * 0.95)] if n else 0.0, hitches,
		str(Engine.max_fps) if Engine.max_fps > 0 else "none"],
		"GPU: %s" % RenderingServer.get_video_adapter_name()]
	if not _web_perf.is_empty():
		lines.append("Foundry UI %.0f FPS · UI frame p95 %.1f ms · Foundry canvas %.0f FPS (hidden, throttled)" % [
			float(_web_perf.get("webFps", 0)), float(_web_perf.get("uiFrameP95ms", 0)), float(_web_perf.get("canvasFps", 0))])
	return "\n".join(lines)


func _say(text: String, seconds := 3.0) -> void:
	if _note == null:
		return
	_note.text = text
	_note.modulate.a = 1.0
	var tween := _note.create_tween()
	tween.tween_interval(seconds)
	tween.tween_property(_note, "modulate:a", 0.0, 0.6)


# ---------------------------------------------------------------------------
# Messages from the page (play-client.js)
# ---------------------------------------------------------------------------

func _on_ipc(message: String) -> void:
	var data = JSON.parse_string(message)
	if not data is Dictionary:
		return
	if data.has("x") and data.has("w"):
		_pointer = _to_viewport(data)
		_css_size = Vector2(float(data.w), float(data.h))
	match str(data.get("type")):
		"ready":
			_user = data.get("user", {}) if data.get("user") is Dictionary else {}
			_say("Playing as %s · Ctrl+` dev mode · F3 performance" % _user.get("name", "?"), 5.0)
		"perf":
			_web_perf = data
		"key":
			_on_key(str(data.get("key", "")))
		"wheel":
			main.orbit.zoom_step(float(data.get("dy", 0)) < 0.0)
		"pick":
			_on_pick(data)
		"result":
			_on_result(data)


func _on_key(key: String) -> void:
	match key:
		"toggle":
			set_play(not active)
		"F11":
			_toggle_window()
		"F3":
			_perf.visible = not _perf.visible
		"KeyT":
			var id := token_at(_pointer)
			if id != "":
				_call("godotPlay.target(%s, {releaseOthers: true})" % JSON.stringify(id))
		"Escape":
			_call("godotPlay.release()")


func _on_pick(data: Dictionary) -> void:
	var pos := _to_viewport(data)
	var mods: Dictionary = data.get("mods", {})
	match str(data.get("phase")):
		"down":
			var id := token_at(pos)
			_drag = {"down": true, "pos": pos, "last": pos, "button": _godot_button(int(data.get("button", 0))), "token": id,
				"moved": false, "mods": mods, "t0": Time.get_ticks_msec() / 1000.0, "kind": ""}
		"move":
			if not _drag.get("down", false):
				return
			var delta: Vector2 = pos - _drag.last
			_drag.last = pos
			if not _drag.moved and pos.distance_to(_drag.pos) > DRAG_START_PX:
				_drag.moved = true
				_drag.kind = _drag_kind()
			if _drag.moved:
				_drag_update(pos, delta)
		"up":
			if not _drag.get("down", false):
				return
			_drag.down = false
			if not _drag.moved and not _drag.get("pinged", false):
				_click(pos, int(_drag.button), mods)
			elif _drag.moved:
				_drag_end(pos)
		"dblclick":  # as in Foundry: the actor sheet (with permission)
			var id := token_at(pos)
			if id != "":
				_call("godotPlay.openSheet(%s)" % JSON.stringify(id))


## The page's MouseEvent.button (0 left, 1 middle, 2 right) as Godot's (LEFT 1, RIGHT 2, MIDDLE 3).
static func _godot_button(dom_button: int) -> MouseButton:
	match dom_button:
		1:
			return MOUSE_BUTTON_MIDDLE
		2:
			return MOUSE_BUTTON_RIGHT
		_:
			return MOUSE_BUTTON_LEFT


func _drag_kind() -> String:
	if _drag.button != MOUSE_BUTTON_LEFT:
		return "pan"
	if _drag.mods.get("ctrl", false):
		return "ruler"
	var t: Dictionary = main.tokens._tokens.get(str(_drag.token), {}).get("data", {})
	if not t.is_empty() and t.get("owner", false):
		return "token"
	return "orbit"


func _drag_update(pos: Vector2, delta: Vector2) -> void:
	match str(_drag.kind):
		# Straight to the camera: fake motion events would be swallowed by the full-window WebView control
		"orbit":
			main.orbit.orbit_by(delta)
		"pan":
			main.orbit.pan_by(delta)
		"token", "ruler":
			var from: Vector3 = _token_center(str(_drag.token)) if _drag.kind == "token" else _floor_at(_drag.pos)
			_show_ruler(from, _floor_at(pos))
			if _drag.kind == "token":
				_show_grid(str(_drag.token), _floor_at(pos))


func _drag_end(pos: Vector2) -> void:
	if _drag.kind == "token":
		var id := str(_drag.token)
		var t: Dictionary = main.tokens._tokens.get(id, {}).get("data", {})
		var center := to_foundry(_floor_at(pos))
		var dest := {"x": center.x - float(t.get("widthPx", 0)) / 2.0, "y": center.y - float(t.get("heightPx", 0)) / 2.0}
		_call("godotPlay.move(%s, [%s], {snap: %s})" % [JSON.stringify(id), JSON.stringify(dest),
			"false" if _drag.mods.get("shift", false) else "true"])
	_hide_ruler()


func _click(pos: Vector2, button: int, mods: Dictionary) -> void:
	var id := token_at(pos)
	if button == MOUSE_BUTTON_LEFT:
		if id != "":
			_call("godotPlay.control(%s, {releaseOthers: %s})" % [JSON.stringify(id), "false" if mods.get("shift", false) else "true"])
		else:
			_call("godotPlay.release()")
	elif button == MOUSE_BUTTON_RIGHT and id != "":
		# As in Foundry: right-click your token for its HUD; double right-click targets (or, on your own token, opens
		# its config: godotPlay.rightDouble = Token#_onClickRight2). The page sends no right dblclick, so time it here.
		var now := Time.get_ticks_msec() / 1000.0
		if str(_last_right.get("id", "")) == id and now - float(_last_right.get("t", -10.0)) <= RIGHT_DOUBLE:
			_last_right = {}
			_call("godotPlay.rightDouble(%s, {shift: %s})" % [JSON.stringify(id), "true" if mods.get("shift", false) else "false"])
			return
		_last_right = {"id": id, "t": now}
		var t: Dictionary = main.tokens._tokens.get(id, {}).get("data", {})
		if t.get("owner", false):
			var css := _to_css(_screen_of(_token_center(id)))
			_call("godotPlay.hud(%s, %d, %d)" % [JSON.stringify(id), css.x, css.y])


func _ping(pos: Vector2) -> void:
	var at := _floor_at(pos)
	var p := to_foundry(at)
	_call("godotPlay.ping(%f, %f)" % [p.x, p.y])
	var ring := MeshInstance3D.new()  # a quick expanding ring where the ping lands
	var torus := TorusMesh.new()
	torus.inner_radius = 0.45
	torus.outer_radius = 0.5
	ring.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.3)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring.material_override = mat
	main.add_child(ring)
	ring.global_position = at + Vector3.UP * 0.05
	var tween := ring.create_tween().set_parallel()
	tween.tween_property(ring, "scale", Vector3.ONE * 4.0, 1.0).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 1.0)
	tween.chain().tween_callback(ring.queue_free)


func _on_result(data: Dictionary) -> void:
	match str(data.get("op")):
		"measure":
			if _ruler_label and _ruler.visible:
				_ruler_label.text = "%s %s" % [str(snappedf(float(data.get("distance", 0)), 0.1)), str(data.get("units", ""))]
		"move":
			if not data.get("ok", true):
				_say("Can't move there: %s" % str(data.get("error", "not allowed")))


func _show_ruler(from: Vector3, to: Vector3) -> void:
	if _ruler == null:
		_ruler = MeshInstance3D.new()
		_ruler.mesh = ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.85, 0.3)
		mat.no_depth_test = true
		_ruler.material_override = mat
		main.add_child(_ruler)
		_ruler_label = Label3D.new()
		_ruler_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_ruler_label.no_depth_test = true
		_ruler_label.font_size = 48
		_ruler_label.outline_size = 12
		_ruler_label.pixel_size = 0.01
		_ruler.add_child(_ruler_label)
	_ruler.visible = true
	var mesh := _ruler.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_add_vertex(from + Vector3.UP * 0.06)
	mesh.surface_add_vertex(to + Vector3.UP * 0.06)
	mesh.surface_end()
	_ruler_label.global_position = to + Vector3.UP * 0.6
	if _measure_wait <= 0.0:
		_measure_wait = 0.1
		var a := to_foundry(from)
		var b := to_foundry(to)
		_call("godotPlay.measure([%s, %s])" % [JSON.stringify({"x": a.x, "y": a.y}), JSON.stringify({"x": b.x, "y": b.y})])


func _hide_ruler() -> void:
	if _ruler:
		_ruler.visible = false
	if _grid:
		_grid.hide_grid()


func _show_grid(id: String, at: Vector3) -> void:
	if _grid == null:
		_grid = DragGrid.new()
		_grid.name = "DragGrid"
		main.add_child(_grid)
	_grid.info = main.info
	var t: Dictionary = main.tokens._tokens.get(id, {}).get("data", {})
	var color := Color.from_string(str(_user.get("color", "")), Color(1.0, 0.6, 0.16))
	_grid.show_at(at, float(t.get("widthPx", 0)), float(t.get("heightPx", 0)), color)


func _call(js: String) -> void:
	last_call = js
	if web and active:
		web.call("eval", "globalThis.godotPlay && " + js)


# ---------------------------------------------------------------------------
# Picking: screen points <-> the 3D scene <-> Foundry pixels
# ---------------------------------------------------------------------------

func _to_viewport(data: Dictionary) -> Vector2:
	var size := get_viewport().get_visible_rect().size
	return Vector2(float(data.x), float(data.y)) * size / Vector2(maxf(float(data.w), 1.0), maxf(float(data.h), 1.0))


func _to_css(pos: Vector2) -> Vector2i:
	var size := get_viewport().get_visible_rect().size
	var css := _css_size if _css_size != Vector2.ZERO else size
	return Vector2i(pos * css / size)


func _screen_of(at: Vector3) -> Vector2:
	return main.orbit.camera.unproject_position(at)


## The floor point under a screen point (on the highest floor shown).
func _floor_at(pos: Vector2) -> Vector3:
	var cam: Camera3D = main.orbit.camera
	var from := cam.project_ray_origin(pos)
	var dir := cam.project_ray_normal(pos)
	var hit = Plane(Vector3.UP, _floor_y()).intersects_ray(from, dir)
	return hit if hit != null else from + dir * 10.0


func _floor_y() -> float:
	if main.info == null:
		return 0.0
	var levels: Array = main.info.levels
	var shown: int = levels.size() if main._visible_floor_count < 0 else main._visible_floor_count
	return main.info.units_to_m(float(levels[clampi(shown - 1, 0, levels.size() - 1)].get("bottom", 0)))


func to_foundry(at: Vector3) -> Vector2:
	var info = main.info
	return Vector2(info.rect.position.x + at.x / info.mpp, info.rect.position.y + at.z / info.mpp)


func _token_center(id: String) -> Vector3:
	var node: Node3D = main.tokens.get_token(id)
	return node.global_position if node else Vector3.ZERO


## The token under a screen point: the closest one whose upright column (footprint wide, as tall as wide) the
## view ray passes through; nearest to the camera wins. "" for none.
func token_at(pos: Vector2) -> String:
	if main.info == null:
		return ""
	var cam: Camera3D = main.orbit.camera
	var from := cam.project_ray_origin(pos)
	var to := from + cam.project_ray_normal(pos) * 5000.0
	var best := ""
	var best_depth := INF
	for id in main.tokens._tokens:
		var entry: Dictionary = main.tokens._tokens[id]
		var node: Node3D = entry.node
		if not node.is_visible_in_tree():
			continue
		var t: Dictionary = entry.data
		var radius: float = main.info.px_to_m(minf(float(t.get("widthPx", 100)), float(t.get("heightPx", 100)))) / 2.0
		var base := node.global_position
		var pts := Geometry3D.get_closest_points_between_segments(from, to, base, base + Vector3.UP * radius * 2.0)
		if pts[0].distance_to(pts[1]) <= radius:
			var depth := from.distance_to(pts[0])
			if depth < best_depth:
				best_depth = depth
				best = id
	return best

