extends Node3D
## Foundry -> Godot 3D viewer. Receives scene data from the foundry-godot-bridge module
## and keeps a 3D mirror of the GM's current scene.
##
## Settings come from res://viewer.cfg; command-line args (after `--`) override them:
##   --bind=0.0.0.0 --port=8765 --insecure-tls

const SceneInfo = preload("res://scripts/scene_info.gd")
const LevelBuilder = preload("res://scripts/level_builder.gd")
const BridgeServer = preload("res://scripts/bridge_server.gd")
const AssetLoader = preload("res://scripts/asset_loader.gd")
const TokenManager = preload("res://scripts/token_manager.gd")
const LightManager = preload("res://scripts/light_manager.gd")
const TileManager = preload("res://scripts/tile_manager.gd")
const SceneEnvironment = preload("res://scripts/environment.gd")
const OrbitCamera = preload("res://scripts/orbit_camera.gd")
const PostProcess = preload("res://scripts/post_process.gd")
const Weather = preload("res://scripts/weather.gd")
const PlayMode = preload("res://scripts/play_mode.gd")
const FogOfWar = preload("res://scripts/fog_of_war.gd")
const PostPanel = preload("res://scripts/post_panel.gd")
const CinematicCamera = preload("res://scripts/cinematic_camera.gd")
const OcclusionCutter = preload("res://scripts/occlusion_cutter.gd")
const STATE_FILE := "user://viewer_state.cfg"  ## remembered between runs (camera mode)
var state_file := STATE_FILE  ## tests point this elsewhere so they never change the real one

const HELP := "Left-drag orbit · Right-drag / WASD pan · Wheel zoom · Q/E rotate · T top-down\n" \
	+ "Space cinematic camera · F follow selected token · PgUp/PgDn show floors · V token style · Tab hide UI\n" \
	+ "P post-process · Ctrl+S save level · Ctrl+P publish level"

var server := BridgeServer.new()
var loader := AssetLoader.new()
var tokens := TokenManager.new()
var lights := LightManager.new()
var tiles := TileManager.new()
var orbit := OrbitCamera.new()
var sun := DirectionalLight3D.new()
var env := Environment.new()
var environment := SceneEnvironment.new()  # darkness, ambience, global illumination
var post := PostProcess.new()  # HD-2D look
var weather := Weather.new()  # Scene Config → Weather
var fog := FogOfWar.new()  # play mode: Foundry's vision and fog of war
var play := PlayMode.new()  # play mode: the player's Foundry client over the 3D view (the default)
var post_panel := PostPanel.new()
var cinematic := CinematicCamera.new()  # Space: the camera directs itself
var _actions: Array = []  # recent actions for the see-through path: [{from, targets, t0, impact}]
var _action_clock := 0.0
const PATH_HOLD := 2.5  # seconds the path stays clear after the hit lands
const PATH_MAX := 8.0   # ... or after the action, if no hit ever shows
var cutter := OcclusionCutter.new()  # holes through walls / doors / tiles / upper floors around the tokens in view
var _post_save_timer := Timer.new()  # auto-saves panel edits to the Foundry scene

var info: SceneInfo
var level_root: Node3D
var walls_by_id := {}  # wall id -> Node3D (generated or found in a manual level)
var _wall_data := {}  # wall id -> latest Foundry wall data (door states for any level source)
var _server_level := {"scene_id": "", "bytes": PackedByteArray()}  # last .glb downloaded from Foundry
var _generation := 0  # bumps on every snapshot so stale async work can bail out
var _follow_enabled := false
var _focused_token_id := ""
var _visible_floor_count := -1  # -1 = all floors visible
var _scene_started_ms := 0

var _hud: CanvasLayer
var _image_view: CanvasLayer  # full-screen 2D picture for scenes set to "2D image"
var _image_rect: TextureRect
var _view_note := ""  # appended to the status line, e.g. " · 2D image view"
var _status: Label
var _scene_label: Label


func _ready() -> void:
	_setup_world()
	_setup_hud()
	for node in [loader, tokens, lights, tiles, orbit, weather, fog]:
		add_child(node)
	weather.name = "Weather"
	weather.loader = loader
	weather.post = post
	tokens.name = "Tokens"
	lights.name = "Lights"
	tiles.name = "Tiles"
	tokens.loader = loader
	tiles.loader = loader
	tokens.level_filter = _level_visible
	tokens.token_hit.connect(func(severity: float) -> void:
		if not cinematic.active or cinematic.is_paused():  # the cinematic camera never jerks
			orbit.shake(0.015 * severity, 0.25 + 0.2 * severity))
	tiles.level_filter = func(level_ids: Array) -> bool: return level_ids.is_empty() or level_ids.any(_level_visible)
	cinematic.name = "Cinematic"
	add_child(cinematic)
	cinematic.setup(orbit, tokens)
	cutter.name = "SeeThrough"
	cutter.level_root_of = func() -> Node: return level_root
	cutter.tiles_root_of = func() -> Node: return tiles
	add_child(cutter)
	if _load_state().get_value("camera", "cinematic", false):
		set_cinematic(true, false)

	_load_config()
	add_child(server)
	server.message_received.connect(_on_message)
	server.clients_changed.connect(_on_clients_changed)
	if server.start() == OK:
		_set_status("Waiting for Foundry on ws://%s:%d ..." % [server.bind_address, server.port])
	else:
		# Another viewer already owns the port; one window is enough, so close this copy.
		_set_status("Another viewer is already running on port %d. Closing this one ..." % server.port)
		get_tree().create_timer(3.0).timeout.connect(get_tree().quit)
		return
	play.name = "PlayMode"
	play.main = self
	add_child(play)
	play.start()


func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://viewer.cfg") == OK:
		server.bind_address = str(cfg.get_value("network", "bind", server.bind_address))
		server.port = int(cfg.get_value("network", "port", server.port))
		loader.insecure_tls = bool(cfg.get_value("network", "insecure_tls", false))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bind="):
			server.bind_address = arg.trim_prefix("--bind=")
		elif arg.begins_with("--port="):
			server.port = int(arg.trim_prefix("--port="))
		elif arg == "--insecure-tls":
			loader.insecure_tls = true


func _setup_world() -> void:
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ssao_enabled = true
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	sun.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 300.0
	add_child(sun)
	environment.name = "SceneEnvironment"
	environment.env = env
	environment.sun = sun
	environment.darkness_changed.connect(func(d: float) -> void:
		lights.set_darkness(d)
		tokens.set_darkness(d))
	add_child(environment)
	post.name = "HD2D"
	post.env = env
	post.camera = orbit.camera
	post.sun = sun
	post.lights_changed.connect(func() -> void:
		lights.set_darkness(lights.darkness)
		tokens.set_darkness(tokens.darkness))
	post.pixel_art_changed.connect(func() -> void:
		tokens.rebuild_all()
		tiles.rebuild_all())
	add_child(post)


func _setup_hud() -> void:
	_image_view = CanvasLayer.new()
	_image_view.name = "ImageView"
	_image_view.layer = 0
	_image_view.visible = false
	add_child(_image_view)
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	_image_view.add_child(black)
	_image_rect = TextureRect.new()
	_image_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_image_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image_view.add_child(_image_rect)

	_hud = CanvasLayer.new()
	_hud.layer = 1  # above the 2D image view
	add_child(_hud)
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.modulate = Color(1, 1, 1, 0.9)
	_hud.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	_scene_label = Label.new()
	_scene_label.text = "No scene"
	box.add_child(_scene_label)
	_status = Label.new()
	box.add_child(_status)
	var help := Label.new()
	help.text = HELP
	help.add_theme_font_size_override("font_size", 12)
	help.modulate = Color(1, 1, 1, 0.7)
	box.add_child(help)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	var save := Button.new()
	save.text = "Save level for manual editing"
	save.focus_mode = Control.FOCUS_NONE  # keep Tab / Space for the viewer's own shortcuts
	save.pressed.connect(save_level)
	buttons.add_child(save)
	var publish := Button.new()
	publish.text = "Publish level to Foundry"
	publish.focus_mode = Control.FOCUS_NONE
	publish.pressed.connect(publish_level)
	buttons.add_child(publish)
	var post_button := Button.new()
	post_button.text = "Post-Process"
	post_button.focus_mode = Control.FOCUS_NONE
	post_button.pressed.connect(toggle_post_panel)
	buttons.add_child(post_button)

	# Post-Process panel, top right; edits apply at once and save to the scene a second later.
	post_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	post_panel.position = Vector2(-12, 12)
	post_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	post_panel.modulate = Color(1, 1, 1, 0.92)
	_hud.add_child(post_panel)
	post_panel.edited.connect(_on_post_edited)
	post_panel.reset_requested.connect(_on_post_reset)
	post_panel.preset_save_requested.connect(func(name: String, settings: Dictionary) -> void:
		if server.send({"type": "post.preset.save", "name": name, "settings": settings}):
			_set_status("Saved post-process preset \"%s\"" % name))
	post_panel.preset_delete_requested.connect(func(name: String) -> void:
		server.send({"type": "post.preset.delete", "name": name}))
	_post_save_timer.one_shot = true
	_post_save_timer.wait_time = 1.0
	_post_save_timer.timeout.connect(_save_post)
	add_child(_post_save_timer)


func _set_status(text: String) -> void:
	_status.text = text
	print("Viewer: ", text)


func _on_clients_changed(count: int) -> void:
	_set_status("Foundry connected" if count > 0 else "Foundry disconnected, waiting ...")


# ---------------------------------------------------------------------------
# Messages from Foundry
# ---------------------------------------------------------------------------

func _on_message(msg: Dictionary) -> void:
	match msg.type:
		"hello":
			_set_status("Foundry connected (world: %s, v%s)" % [msg.get("world", "?"), msg.get("foundry", "?")])
			return
		"scene.snapshot":
			load_scene(msg.scene)
			return
		"vision.update":  # play mode: the player's vision and explored fog (play-client.js)
			fog.apply(msg, info)
			return
		"scene.post":
			_apply_post(msg)
			return
		"post.presets":
			post_panel.set_presets(msg)
			return
		"level.uploaded":
			if msg.get("ok", false):
				_set_status("Published to Foundry: %s" % msg.get("path", ""))
			else:
				_set_status("Publishing failed: %s" % msg.get("error", "unknown error"))
			return
	if info == null:
		return  # deltas before the first snapshot can't be placed
	match msg.type:
		"scene.env":
			environment.apply(msg.get("environment", {"darkness": msg.get("darkness", 0)}), float(msg.get("duration", 0)) / 1000.0)
			_apply_weather(msg.get("environment", {}))
		"token.upsert":
			tokens.upsert(msg.token, true, msg.get("livePosition", false))
		"token.move":
			tokens.move(msg.token)
		"combat.state":
			cinematic.on_combat_state(msg)
		"action":
			cinematic.on_action(msg)
			_note_action(msg)
		"token.float":
			cinematic.on_float(str(msg.id))
			_note_impact(str(msg.id))
			var id := str(msg.id)
			var kind := str(msg.get("kind", "damage"))
			var text := str(msg.get("text", ""))
			# Hit reaction (damage, or temp HP lost), and the 0 HP look; older modules send no HP fields.
			var reaction := str(msg.get("reaction", "full"))
			var downs: bool = msg.has("hp") and float(msg.hp) <= 0.0
			if kind == "damage" or msg.has("amount"):
				var amount := float(msg.get("amount", absf(text.to_float())))
				var hit_info = msg.get("hit", {})  # damage type, delivery, attacker (module hit-info.js)
				tokens.hit(id, amount, float(msg.get("hpMax", 0)), downs, reaction,
					hit_info if hit_info is Dictionary else {})
			elif kind == "hit":  # an attack that hit, on its roll: it plays now, the damage number comes later (misses.js)
				var strike_info = msg.get("hit", {})
				tokens.attack_hit(id, strike_info if strike_info is Dictionary else {}, reaction, float(msg.get("hpMax", 0)))
			elif kind == "miss":  # a missed attack: the attack plays, the target doesn't react (misses.js)
				var miss_info = msg.get("hit", {})
				tokens.attack_missed(id, miss_info if miss_info is Dictionary else {}, reaction)
			# The number and the 0 HP look land with the blow (after the attacker's lunge or the arrow's flight).
			if text != "":  # a "hit" has no number yet
				tokens.after_impact(id, func() -> void: tokens.float_text(id, text, kind))
			if msg.has("hp") and reaction != "off":
				tokens.after_impact(id, func() -> void: tokens.set_downed(id, downs))
		"token.delete":
			tokens.remove(msg.id)
		"token.focus":
			_focused_token_id = msg.id
			if _follow_enabled and not play.active:
				orbit.follow = tokens.get_token(msg.id)
		"wall.upsert":
			_upsert_wall(msg.wall)
		"wall.delete":
			_wall_data.erase(msg.id)
			if info.mode != "manual" and walls_by_id.has(msg.id):
				_discard(walls_by_id[msg.id])
				walls_by_id.erase(msg.id)
		"light.upsert":
			lights.upsert(msg.light)
		"light.delete":
			lights.remove(msg.id)
		"tile.upsert":
			tiles.upsert(msg.tile)
		"tile.delete":
			tiles.remove(msg.id)


func load_scene(data: Dictionary) -> void:
	var same_scene: bool = info != null and info.id == data.id
	_scene_started_ms = Time.get_ticks_msec()
	info = SceneInfo.new(data)
	_generation += 1
	tokens.info = info
	lights.info = info
	tiles.info = info
	_scene_label.text = "Scene: %s  [%s]" % [info.name, "2D image" if data.get("view") == "image" else info.mode]
	_apply_view(data)
	_wall_data.clear()
	for w in data.walls:
		_wall_data[w.id] = w

	tokens.clear()
	lights.clear()
	tiles.clear()
	fog.clear()
	_visible_floor_count = -1

	# Level source, in order: a local hand-edited .scn, the .glb published on the Foundry server,
	# or a level generated from the walls. The server copy downloads in the background.
	var local_level: Node3D = _load_local_level(info.id) if info.mode == "manual" else null
	_install_level(local_level if local_level else LevelBuilder.build_level(info, data.walls))
	if info.mode == "manual" and local_level == null:
		var url = data.get("manualLevelUrl")
		if url is String:
			_load_server_level(url, same_scene, _generation)

	for t in data.tokens:
		tokens.upsert(t, false)
	for l in data.lights:
		lights.upsert(l)
	for tile in data.get("tiles", []):
		tiles.upsert(tile)
	environment.apply(data.get("environment", {"darkness": data.get("darkness", 0)}), 0.0)
	_apply_weather(data.get("environment", {}))
	post.mpu = info.mpu
	post.set_scene(info.size_m(), info.id)
	cinematic.on_scene_loaded(info, not same_scene)
	cutter.prepare(level_root)
	_post_save_timer.stop()  # a different scene: don't save pending edits onto it
	_apply_post(data)
	_apply_floor_visibility()

	if not same_scene:
		var size := info.size_m()
		if not cinematic.active:  # the cinematic camera glides to the new scene instead of jumping
			orbit.frame(Vector3(size.x / 2.0, 0.0, size.y / 2.0), size)


## Replace the static level (floors + walls) and re-apply everything that comes from Foundry.
func _install_level(root: Node3D) -> void:
	if level_root:
		_discard(level_root)
	level_root = root
	level_root.name = "Level"
	add_child(level_root)
	LevelBuilder.rehydrate(level_root)
	_index_walls()
	cutter.prepare(level_root)  # see-through holes on this level's walls / doors (also hand-made levels)
	# Door states always come from Foundry, also for hand-edited levels.
	for id in _wall_data:
		var w: Dictionary = _wall_data[id]
		var wall: Node3D = walls_by_id.get(id)
		if wall and int(w.door) != LevelBuilder.DOOR_NONE:
			wall.set_meta("foundry_door", int(w.door))
			LevelBuilder.set_door_state(wall, int(w.ds), false, LevelBuilder.door_animation(w))
			_load_door_texture(wall, w, _generation)
	_apply_floor_visibility()
	_load_floor_textures(_generation)


func _load_server_level(url: String, same_scene: bool, generation: int) -> void:
	var body: PackedByteArray
	if same_scene and _server_level.scene_id == info.id:
		body = _server_level.bytes  # a resync of the same scene: don't download again
	else:
		_set_status("Downloading manual level from Foundry ...")
		body = await loader.fetch_bytes(url)
	if generation != _generation:
		return  # another snapshot arrived meanwhile
	if body.is_empty():
		_set_status("Manual mode, but this scene has no saved level yet. Showing the generated level; press Ctrl+S to save it.")
		return
	var root := _level_from_glb(body)
	if root == null:
		_set_status("The manual level on the Foundry server couldn't be read; showing the generated level.")
		return
	_server_level = {"scene_id": info.id, "bytes": body}
	_install_level(root)
	_set_status("Loaded manual level from Foundry")


func _upsert_wall(w: Dictionary) -> void:
	_wall_data[w.id] = w
	var wall: Node3D = walls_by_id.get(w.id)
	var unchanged: bool = wall != null and wall.get_meta("foundry_signature", "") == LevelBuilder.geometry_signature(w)
	# In manual mode the GM's hand-edited geometry wins; only door states are synced.
	if info.mode == "manual" or unchanged:
		if wall and wall.has_meta("foundry_door"):
			LevelBuilder.set_door_state(wall, int(w.ds), true, LevelBuilder.door_animation(w))
		return
	if wall:
		_discard(wall)
		walls_by_id.erase(w.id)
	var rebuilt := LevelBuilder.build_wall(info, w)
	if rebuilt:
		var parent := level_root.get_node_or_null("Walls")
		(parent if parent else level_root).add_child(rebuilt)
		walls_by_id[w.id] = rebuilt
		_load_door_texture(rebuilt, w, _generation)
		_apply_floor_visibility()


## Foundry's Door Texture on a generated door (manual levels keep their own look).
func _load_door_texture(wall: Node3D, w: Dictionary, generation: int) -> void:
	var anim := LevelBuilder.door_animation(w)
	if not anim.texture is String or LevelBuilder.get_swing(wall).get_node_or_null("Panel0") == null:
		return
	var texture: Texture2D = await loader.fetch_texture(anim.texture)
	if texture and generation == _generation and is_instance_valid(wall) and walls_by_id.get(w.id) == wall:
		LevelBuilder.apply_door_texture(wall, texture, anim, info)


func _index_walls() -> void:
	walls_by_id.clear()
	for node in level_root.find_children("*", "Node3D", true, false):
		if node.has_meta("foundry_wall_id"):
			walls_by_id[node.get_meta("foundry_wall_id")] = node


## Detach before freeing so a replacement node can take the same name in the same frame.
static func _discard(node: Node) -> void:
	if node.get_parent():
		node.get_parent().remove_child(node)
	node.queue_free()


func _load_floor_textures(generation: int) -> void:
	var map_notes := []
	for floor_mesh in _floor_nodes():
		var lv := info.level_by_id(floor_mesh.get_meta("foundry_level_id"))
		var url = lv.get("background")
		if not url is String:
			continue
		var texture: Texture2D = await loader.fetch_texture(url)
		if generation != _generation or not is_instance_valid(floor_mesh):
			return  # a newer snapshot replaced this level while downloading
		if texture:
			LevelBuilder.set_floor_texture(floor_mesh, texture)
		var fetch: Dictionary = loader.last_fetch.get(url, {})
		map_notes.append("%s %d ms" % [fetch.get("source", "?"), fetch.get("ms", 0)])
	_set_status("Scene loaded in %d ms (map: %s)%s" % [Time.get_ticks_msec() - _scene_started_ms,
		", ".join(map_notes) if map_notes else "none", _view_note])


## "2D image" scenes show one picture full-screen instead of the 3D view (black if none is set).
## The 3D scene is still built underneath, so switching back is instant; it just isn't rendered.
func _apply_view(data: Dictionary) -> void:
	var image_mode: bool = data.get("view", "3d") == "image"
	_image_view.visible = image_mode
	get_viewport().disable_3d = image_mode
	_image_rect.texture = null
	_view_note = ""
	if not image_mode:
		return
	var url = data.get("viewImage")
	if not url is String:
		_view_note = " · 2D image view (no image set: black)"
		return
	_view_note = " · 2D image view"
	var generation := _generation
	var texture: Texture2D = await loader.fetch_texture(url)
	if generation != _generation:
		return  # another scene arrived meanwhile
	if texture:
		_image_rect.texture = texture
	else:
		_view_note = " · 2D image view (image failed to load: black)"


func _floor_nodes() -> Array:
	var floors := level_root.find_children("Floor_*", "MeshInstance3D", true, false)
	return floors.filter(func(n): return n.has_meta("foundry_level_id"))


# ---------------------------------------------------------------------------
# Floors (Foundry Levels) visibility: PgDn hides upper floors so you can look inside
# ---------------------------------------------------------------------------

func _visible_level_ids() -> Array:
	var count := info.levels.size() if _visible_floor_count < 0 else _visible_floor_count
	return info.levels.slice(0, count).map(func(l): return l.id)


func _apply_floor_visibility() -> void:
	if info == null or level_root == null:
		return
	var visible_ids := _visible_level_ids()
	for node in level_root.find_children("*", "Node3D", true, false):
		if node.has_meta("foundry_level_id"):
			var level_id = node.get_meta("foundry_level_id")
			node.visible = level_id == "default" or visible_ids.has(level_id)
	tokens.refresh_visibility()
	tiles.refresh_visibility()


## Whether things on a Foundry Level are shown under the current PgUp/PgDn floor filter.
func _level_visible(level_id: String) -> bool:
	if info == null or level_id == "" or info.level_by_id(level_id).is_empty():
		return true
	return _visible_level_ids().has(level_id)


## Tab is handled here because focused controls would otherwise consume it.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_hud.visible = not _hud.visible
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_SPACE:
			set_cinematic(not cinematic.active)
		KEY_F:
			if cinematic.active:
				set_cinematic(false)
			_follow_enabled = not _follow_enabled
			orbit.follow = tokens.get_token(_focused_token_id) if _follow_enabled else null
			_set_status("Following selected token" if _follow_enabled else "Free camera")
		KEY_PAGEDOWN, KEY_PAGEUP:
			if info == null:
				return
			var total := info.levels.size()
			var current := total if _visible_floor_count < 0 else _visible_floor_count
			current = clampi(current + (1 if event.keycode == KEY_PAGEUP else -1), 1, total)
			_visible_floor_count = current
			_apply_floor_visibility()
			_set_status("Showing floors 1-%d of %d" % [current, total])
		KEY_S:
			if event.ctrl_pressed:
				save_level()
		KEY_P:
			if event.ctrl_pressed:
				publish_level()
			else:
				toggle_post_panel()
		KEY_V:
			# Viewer-only preview of every style; the last step returns to the styles set in Foundry.
			var cycle := [""] + TokenManager.STYLES
			tokens.style_override = cycle[(cycle.find(tokens.style_override) + 1) % cycle.size()]
			tokens.rebuild_all()
			_set_status("Token style: %s (V to cycle)" % (tokens.style_override if tokens.style_override else "as set in Foundry"))


## Cinematic camera on / off. On: follow is off, the HUD hides (Tab still shows it). Off: the camera stays
## where it is and the HUD comes back. The mode is remembered for the next run.
func set_cinematic(on: bool, remember := true) -> void:
	if on and play.active:  # the player view never steers the camera by itself
		return
	if on:
		_follow_enabled = false
		orbit.follow = null
	cinematic.set_active(on)
	_hud.visible = not on
	if remember:
		var state := _load_state()
		state.set_value("camera", "cinematic", on)
		state.save(state_file)
	_set_status("Cinematic camera (Space for free camera)" if on else "Free camera (Space for cinematic)")


func _load_state() -> ConfigFile:
	var state := ConfigFile.new()
	state.load(state_file)  # missing on the first run: empty
	return state


# ---------------------------------------------------------------------------
# HD-2D post-process: settings from Foundry (world defaults or the scene's own), panel edits auto-saved
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	post.update(orbit.distance, orbit.global_position)
	_action_clock += delta
	cutter.update(_see_through_focus(), delta, _attack_paths())
	weather.focus = orbit.global_position


## An attack / spell / save: the see-through also clears the way between the actor and each target (the
## projectile's path), from the action until a moment after the hit lands.
func _note_action(msg: Dictionary) -> void:
	var from := str(msg.get("from", ""))
	var targets: Array = msg.get("targets", []).map(func(t): return str(t)).filter(func(t): return t != "" and t != from)
	if from == "" or targets.is_empty():
		return
	_actions = _actions.filter(func(a): return a.from != from)  # a new action from the same token replaces its last
	_actions.append({"from": from, "targets": targets, "t0": _action_clock, "impact": -1.0})


func _note_impact(token_id: String) -> void:
	for a in _actions:
		if a.impact < 0.0 and (a.targets.has(token_id) or a.from == token_id):
			a.impact = _action_clock


## [{key, a, b}] for the actions still showing (chest height, live token positions).
func _attack_paths() -> Array:
	_actions = _actions.filter(func(a): return _action_clock < (a.impact + PATH_HOLD if a.impact >= 0.0 else a.t0 + PATH_MAX))
	var paths: Array = []
	for a in _actions:
		var from_node: Node3D = tokens.get_token(a.from)
		for target in a.targets:
			var to_node: Node3D = tokens.get_token(target)
			if from_node and to_node and from_node.is_visible_in_tree() and to_node.is_visible_in_tree():
				paths.append({"key": "%s|%s" % [a.from, target], "a": from_node.global_position + Vector3.UP * 0.8,
					"b": to_node.global_position + Vector3.UP * 0.8})
	return paths


## See-through holes: what the cinematic shot frames first, then the other tokens on screen (nearest the middle
## first), or, with no token in view, the point the camera orbits.
func _see_through_focus() -> Array:
	if play.active:
		return _play_see_through_focus()
	var focus: Array = cinematic.focus_points().duplicate() if cinematic.active and not cinematic.is_paused() else []
	var cam := get_viewport().get_camera_3d()
	if cam:
		var middle := get_viewport().get_visible_rect().size / 2.0
		var on_screen: Array = []  # [distance from the middle px, point]
		for p in tokens.visible_points():
			if cam.is_position_in_frustum(p):
				on_screen.append([cam.unproject_position(p).distance_to(middle), p])
		on_screen.sort_custom(func(a, b): return a[0] < b[0])
		for entry in on_screen:
			var p: Vector3 = entry[1]
			if focus.size() >= OcclusionCutter.SLOTS:
				break
			if not focus.any(func(f): return f.distance_to(p) < 0.5):
				focus.append(p)
	if focus.is_empty():
		focus = [orbit.global_position + Vector3.UP * 0.8]
	return focus


## Player view: holes for every friendly token (yours first) and whatever this player targets, never picked by
## where they are on screen, so they stay put while the camera turns. Then nearest the camera's pivot.
func _play_see_through_focus() -> Array:
	var picked: Array = []  # [rank, ground distance to the pivot, point]
	for e in tokens.see_through_entries():
		var t: Dictionary = e.data
		var targeted: bool = t.get("targets", []) is Array and t.get("targets", []).any(func(u): return u is Dictionary and u.get("self", false))
		if int(t.get("disposition", 0)) != 1 and not targeted:
			continue
		var rank := 0 if t.get("owner", false) else (1 if targeted else 2)
		var p: Vector3 = e.pos
		picked.append([rank, Vector2(p.x - orbit.global_position.x, p.z - orbit.global_position.z).length(), p])
	picked.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var focus: Array = picked.slice(0, OcclusionCutter.SLOTS).map(func(x): return x[2])
	return focus if not focus.is_empty() else [orbit.global_position + Vector3.UP * 0.8]


## Scene Config → Weather (the module sends it with the environment).
func _apply_weather(environment_data: Dictionary) -> void:
	if info == null:
		return
	weather.mpp = info.mpp
	weather.apply(environment_data.get("weather"), info.size_m())


func toggle_post_panel() -> void:
	post_panel.visible = not post_panel.visible


## Settings from a snapshot or a scene.post delta: {postProcess, postProcessScene}.
func _apply_post(data: Dictionary) -> void:
	var settings: Dictionary = data.get("postProcess", PostProcess.DEFAULTS)
	post.apply(settings)
	if _post_save_timer.is_stopped():  # don't fight edits that are still being saved
		post_panel.show_settings(settings, bool(data.get("postProcessScene", false)))


func _on_post_edited(settings: Dictionary) -> void:
	post.apply(settings)
	_post_save_timer.start()  # restarts on every edit; saves 1 s after the last one


func _save_post() -> void:
	if info == null:
		return
	if server.send({"type": "post.save", "sceneId": info.id, "settings": post.settings}):
		_set_status("Post-process settings saved with this scene")
	else:
		_set_status("Not connected to Foundry; post-process settings not saved")


func _on_post_reset() -> void:
	_post_save_timer.stop()
	if info and server.send({"type": "post.reset", "sceneId": info.id}):
		_set_status("This scene now uses the Foundry post-process defaults")

# ---------------------------------------------------------------------------
# Manual levels
#   Local copy:  res://levels/<sceneId>.scn  - what you open and edit in the Godot editor
#   Server copy: Data/godot-levels/<sceneId>.glb on the Foundry server - what other PCs load
# ---------------------------------------------------------------------------

## res://levels when running from the project folder (so the Godot editor sees the file),
## user://levels when running an exported build.
func _level_dir() -> String:
	return "user://levels" if OS.has_feature("template") else "res://levels"


func _level_path(scene_id: String) -> String:
	return "%s/%s.scn" % [_level_dir(), scene_id]


## Save the current level locally for editing and publish it to the Foundry server.
func save_level() -> void:
	if level_root == null or info == null:
		_set_status("Nothing to save yet; open a scene in Foundry first.")
		return
	var path := _level_path(info.id)
	var result := [ERR_CANT_CREATE]  # lambdas capture locals by value; an Array is shared
	_while_exportable(func():
		for node in level_root.find_children("*", "Node", true, false):
			node.owner = level_root  # PackedScene only stores nodes owned by the root
		var packed := PackedScene.new()
		result[0] = packed.pack(level_root)
		if result[0] == OK:
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			result[0] = ResourceSaver.save(packed, path, ResourceSaver.FLAG_COMPRESS))
	var err: Error = result[0]
	if err != OK:
		_set_status("Saving failed: %s" % error_string(err))
		return
	_set_status("Saved %s" % ProjectSettings.globalize_path(path))
	publish_level()


## Upload the current level to the Foundry server (through the module) so every PC's viewer can load it.
func publish_level() -> void:
	if level_root == null or info == null:
		_set_status("Nothing to publish yet; open a scene in Foundry first.")
		return
	var result := [PackedByteArray()]
	_while_exportable(func(): result[0] = _level_to_glb(level_root))
	var body: PackedByteArray = result[0]
	if body.is_empty():
		_set_status("Publishing failed: could not export the level as .glb")
		return
	var sent := server.send({"type": "level.upload", "sceneId": info.id,
		"data": Marshalls.raw_to_base64(body)})
	if sent:
		_server_level = {"scene_id": info.id, "bytes": body}
		_set_status("Publishing level to Foundry (%.1f MB) ..." % (body.size() / 1048576.0))
	else:
		_set_status("Not connected to Foundry; the level was only saved on this PC.")


## Temporarily show every node and close every door, so saved files hold the complete level.
func _while_exportable(action: Callable) -> void:
	var hidden := []
	for node in level_root.find_children("*", "Node3D", true, false):
		if not node.visible:
			hidden.append(node)
			node.visible = true
	var doors := []
	for id in walls_by_id:
		var wall: Node3D = walls_by_id[id]
		if wall.has_meta("foundry_door") and _wall_data.has(id):
			doors.append(wall)
			LevelBuilder.set_door_state(wall, 0, false, LevelBuilder.door_animation(_wall_data[id]))
	cutter.restore_materials(level_root)  # exported / saved levels keep their standard materials
	action.call()
	cutter.prepare(level_root)
	for node in hidden:
		node.visible = false
	for wall in doors:
		var w: Dictionary = _wall_data[wall.get_meta("foundry_wall_id")]
		LevelBuilder.set_door_state(wall, int(w.ds), false, LevelBuilder.door_animation(w))


static func _level_to_glb(root: Node3D) -> PackedByteArray:
	var doc := GLTFDocument.new()
	if "image_format" in doc:
		doc.image_format = "Lossy WebP"  # map images dominate the file size
		doc.lossy_quality = 0.85
	var state := GLTFState.new()
	if doc.append_from_scene(root, state) != OK:
		return PackedByteArray()
	return doc.generate_buffer(state)


static func _level_from_glb(body: PackedByteArray) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_buffer(body, "", state) != OK:
		return null
	return doc.generate_scene(state) as Node3D


func _load_local_level(scene_id: String) -> Node3D:
	for dir in ["res://levels", "user://levels"]:
		var path := "%s/%s.scn" % [dir, scene_id]
		if not FileAccess.file_exists(path):
			continue
		var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed:
			_set_status("Loaded manual level %s" % path)
			return packed.instantiate() as Node3D
	return null
