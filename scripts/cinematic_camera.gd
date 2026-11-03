extends Node
## Cinematic camera (Space): directs the orbit camera by itself, like a spectator camera.
## Shots, highest priority first:
##   attack  - on an "action": attacker, then a two-shot of attacker + targets held through the hit,
##             then back to the attacker
##   moving  - frames every token that's moving (plus whoever's turn it is in combat)
##   turn    - in combat: a low hero shot on the active token with the tokens around it, slowly orbiting
##   idle    - ~20 s shots that blend into each other: all tokens, then a wide environment shot, ...
## Every shot only sets a desired pose (pivot, distance, yaw, pitch). Critically damped springs move the
## live pose toward it, so position and velocity stay continuous: the camera never cuts or snaps.
## Mouse / keys take over (orbit_camera.gd user_input); the director glides back after RESUME_AFTER seconds.

const RESUME_AFTER := 8.0
const IDLE_SHOT := 20.0
const CONTEXT_RADIUS := 9.0     ## meters around the active token that count as "nearby" (about 6 squares)
const MIN_DISTANCE := 4.0
const TOKEN_HEIGHT := 1.6       ## framing allowance above a token's base
const MOVE_EPSILON := 0.12      ## meters between a token's shown and target position that counts as moving
const MOVE_LINGER := 3.0        ## seconds the moving shot holds after the last move (settled overhead)
const ATTACK_HOLD := 1.0        ## on the attacker before the two-shot
const ATTACK_IMPACT_LATEST := 3.5
const ATTACK_RETURN_HOLD := 2.5   ## back on the attacker after the hit, before anything else
const ATTACK_TARGET_HOLD := 3.0   ## covers the hit landing up to ~0.8 s after its number (projectile flight)
const SWAY := 1.0               ## handheld sway strength (0 = off)
const IDLE_ZOOM := 0.8          ## idle orbit / drift shots: < 1 is closer
const IDLE_MARGIN := 1.4        ## idle shots fit close around all the visible tokens (x IDLE_ZOOM: just over a snug fit)
const IDLE_PITCHES := [-45.0, -32.0, -58.0]  ## idle shots cycle these angles (degrees), one per IDLE_SHOT
const COMBAT_ZOOM := 1.3        ## turn, attack and in-combat movement shots: > 1 is wider
const TWO_SHOT_ZOOM := 1.15     ## extra room for attacker + target together
const ATTACK_ZOOM := 1.0        ## attack shots (attacker, two-shot, return): > 1 is wider
const MOVE_ZOOM := 1.5          ## moving shots 1.5x as far: the whole path, start to arrival, with room around it
const MOVE_PITCH := -60.0       ## moving shots look down from above (degrees), over the tokens and where they're going
const MOVE_SMOOTH := 0.9        ## moving shots drift over loosely (the pitch rises faster: MOVE_PITCH_SMOOTH)
const MOVE_PITCH_SMOOTH := 0.5  ## overhead within about half a second of a move starting
const MOVE_LEAD := 0.35         ## how far the moving shot leans from the middle of the path toward the arrival point
## Speed follows the subject: a long move eases in slower, a small re-frame is quicker, moving tokens are
## kept up with (their speed, capped here, so the camera never whips around).
const TRACK_SPEED_CAP := 12.0   ## m/s of token movement the camera will match (a fast run)
const MIN_SMOOTH := 0.35
const SceneInfo = preload("res://scripts/scene_info.gd")

var orbit: Node3D               ## orbit_camera.gd
var tokens: Node                ## token_manager.gd (reads its _tokens: node / target)
var info: SceneInfo
var active := false             ## cinematic mode on
var shot := ""                  ## current shot, e.g. "turn:abc", "idle:group" (for the HUD and tests)

var _t := 0.0
var _paused_until := -1.0
var _combat := {"active": false}
var _action := {}               ## {from, targets, t0, impact}
var _last_target := {}          ## token id -> last target position seen
var _last_move := {}            ## token id -> time it last moved
var _last_pos := {}             ## token id -> shown position last frame
var _speed := {}                ## token id -> how fast it's moving (m/s, smoothed)
var _move_from := {}            ## token id -> where its current move started (world)
var _idle_start := 0.0
var _idle_index := 0
var _base_yaw := 0.0            ## the slowly drifting yaw shots orbit with
var _focus: Array = []          ## what the current shot looks at (world points), for the see-through effect

# Live pose and spring velocities
var _pivot := Vector3.ZERO
var _distance := 30.0
var _yaw := 0.0
var _pitch := -1.0
var _v_pivot := Vector3.ZERO
var _v_distance := 0.0             ## of log(distance)
var _v_yaw := 0.0
var _v_pitch := 0.0


func _ready() -> void:
	process_priority = -10  # before orbit_camera.gd applies the pose this frame


func setup(orbit_camera: Node3D, token_manager: Node) -> void:
	orbit = orbit_camera
	tokens = token_manager
	orbit.user_input.connect(_on_user_input)


func set_active(on: bool) -> void:
	if on == active:
		return
	active = on
	_paused_until = -1.0
	if on:
		_sync_from_orbit()
		_restart_idle()
	orbit.driven = on
	shot = ""


## Every snapshot rebuilds the tokens; only a different scene restarts the idle cycle (no jump either way).
func on_scene_loaded(scene: SceneInfo, new_scene := true) -> void:
	info = scene
	_last_target.clear()
	_last_move.clear()
	_last_pos.clear()
	_speed.clear()
	if new_scene:
		_action = {}
		_restart_idle()


func on_combat_state(state: Dictionary) -> void:
	_combat = state if state.get("active", false) else {"active": false}


func on_action(msg: Dictionary) -> void:
	var targets: Array = msg.get("targets", [])
	if str(msg.get("from", "")) == "" and targets.is_empty():
		return
	_action = {"from": str(msg.get("from", "")), "targets": targets, "t0": _t, "impact": -1.0}


## A damage / healing number on a token: the hit of the current attack has landed.
func on_float(token_id: String) -> void:
	if not _action.is_empty() and _action.impact < 0.0 and (_action.targets.has(token_id) or _action.from == token_id):
		_action.impact = _t


## The points the camera is looking at right now (the framed tokens, or the middle of the shot).
func focus_points() -> Array:
	return _focus


func is_paused() -> bool:
	return active and _paused_until >= 0.0


func _on_user_input() -> void:
	if not active:
		return
	_paused_until = _t + RESUME_AFTER
	orbit.driven = false


func _process(delta: float) -> void:
	_t += delta
	_track_movement(delta)
	if not active or orbit == null:
		return
	if _paused_until >= 0.0:
		if _t < _paused_until:
			return
		_paused_until = -1.0
		_sync_from_orbit()  # carry on from wherever the user left it
		orbit.driven = true
	var want := _direct()
	_step(want, delta)
	_apply()


# ---------------------------------------------------------------------------
# Director
# ---------------------------------------------------------------------------

func _direct() -> Dictionary:
	var want := _attack_shot()
	if want.is_empty():
		want = _moving_shot()
	if want.is_empty() and _combat.get("active", false):
		want = _turn_shot()
	if want.is_empty():
		want = _idle_shot()
	return want


func _attack_shot() -> Dictionary:
	if _action.is_empty():
		return {}
	var elapsed := _t - float(_action.t0)
	var impact := float(_action.impact)
	var landed := impact >= 0.0 or elapsed >= ATTACK_IMPACT_LATEST
	var landed_at := impact if impact >= 0.0 else float(_action.t0) + ATTACK_IMPACT_LATEST
	var attacker := _positions([_action.from])
	var targets := _positions(_action.targets)
	if attacker.is_empty() and targets.is_empty():
		_action = {}
		return {}
	var after := _t - landed_at if landed else -1.0
	if after > ATTACK_TARGET_HOLD:
		# The attack is over: back to whoever made it, then on to the turn / idle shots
		if after > ATTACK_TARGET_HOLD + ATTACK_RETURN_HOLD or attacker.is_empty():
			_action = {}
			return {}
		_start_shot("attack:return", _yaw)
		return _framed(attacker, deg_to_rad(-28.0), _base_yaw, 1.6 * COMBAT_ZOOM * ATTACK_ZOOM, 1.4)
	if elapsed < ATTACK_HOLD and not attacker.is_empty() and not landed:
		_start_shot("attack:attacker", _yaw)
		return _framed(attacker, deg_to_rad(-25.0), _base_yaw, 2.0 * COMBAT_ZOOM * ATTACK_ZOOM, 1.2)
	var both := attacker + targets
	# Side-on two-shot: look across the line between attacker and targets, on the side nearer the camera
	var line := _centroid(targets) - (_centroid(attacker) if not attacker.is_empty() else _centroid(targets))
	var side := _yaw
	if Vector2(line.x, line.z).length() > 0.5:
		var across := _yaw_looking(Vector3(-line.z, 0.0, line.x))  # view direction perpendicular to the line
		side = _nearest_angle(across, _yaw)
		var flipped := _nearest_angle(across + PI, _yaw)
		if absf(flipped - _yaw) < absf(side - _yaw):
			side = flipped
	_start_shot("attack:both", side)
	return _framed(both, deg_to_rad(-35.0), _base_yaw, 1.35 * COMBAT_ZOOM * TWO_SHOT_ZOOM * ATTACK_ZOOM, 1.4)


func _moving_shot() -> Dictionary:
	var ids := []
	for id in _last_move:
		if _t - float(_last_move[id]) <= MOVE_LINGER:
			ids.append(id)
	var points := []
	var ends := []
	var fastest := 0.0
	for id in ids:
		var now := _positions([id])
		if now.is_empty():
			continue
		var end: Vector3 = _destinations([id])[0]
		# The whole path, start to arrival, stays put while the token walks it: the camera doesn't chase it
		points += [now[0], end]
		if _move_from.has(id):
			points.append(_move_from[id])
		ends.append(end)
		# Only a token with no known arrival point (it's where it's headed) pulls the camera along, loosely
		if now[0].distance_to(end) < 0.3:
			fastest = maxf(fastest, float(_speed.get(id, 0.0)))
	if points.is_empty():
		return {}
	if _combat.get("active", false):
		points += _positions([_combat.get("turnTokenId", "")])
	_start_shot("moving", _yaw)
	_base_yaw += deg_to_rad(1.5) * get_process_delta_time()
	var want := _framed(points, deg_to_rad(MOVE_PITCH), _base_yaw,
		1.5 * (COMBAT_ZOOM if _combat.get("active", false) else IDLE_ZOOM) * MOVE_ZOOM, MOVE_SMOOTH)
	# Lean toward where they're going (and widen by as much, so where they started stays in view)
	var arrival := _centroid(ends)
	arrival.y = want.pivot.y
	var shift: Vector3 = (arrival - want.pivot) * MOVE_LEAD
	want.pivot += shift
	want.distance = clampf(want.distance + shift.length() * 2.0, MIN_DISTANCE, _max_distance())
	want.pitch_smooth = MOVE_PITCH_SMOOTH
	want.track = minf(fastest * 0.5, TRACK_SPEED_CAP)
	return want


func _turn_shot() -> Dictionary:
	var id := str(_combat.get("turnTokenId", ""))
	var hero := _positions([id])
	if hero.is_empty():
		return {}
	var center: Vector3 = hero[0]
	var context := []
	for entry in _visible_tokens():
		if entry.id != id and entry.pos.distance_to(center) <= CONTEXT_RADIUS:
			context.append(entry.pos)
	var key := "turn:" + id
	if shot != key:
		# Over the shoulder: look from the hero toward the tokens around them, within 70 degrees of the current view
		var look := _yaw
		if not context.is_empty():
			var d := _centroid(context) - center
			if Vector2(d.x, d.z).length() > 0.3:
				look = _yaw + clampf(_nearest_angle(_yaw_looking(d), _yaw) - _yaw, deg_to_rad(-70.0), deg_to_rad(70.0))
		_start_shot(key, look)
	_base_yaw += deg_to_rad(2.0) * get_process_delta_time()
	var want := _framed(hero + context, deg_to_rad(-28.0), _base_yaw, 1.3 * COMBAT_ZOOM, 1.6)
	want.pivot = want.pivot.lerp(center + Vector3.UP * TOKEN_HEIGHT * 0.5, 0.4)  # the hero nearer the middle
	return want


func _idle_shot() -> Dictionary:
	if _t - _idle_start >= IDLE_SHOT:
		_idle_start = _t
		_idle_index += 1
	var everyone := []
	for entry in _visible_tokens():
		everyone.append(entry.pos)
	# Tokens on the map: always centered on all of them, close, from a different angle every shot.
	# The map-wide environment shots are only for an empty map.
	var kind := "group%d" % (_idle_index % IDLE_PITCHES.size()) if not everyone.is_empty() else "env%d" % (_idle_index % 3)
	var key := "idle:%s:%d" % [kind, _idle_index]
	var size := info.size_m() if info else Vector2(30, 30)
	var center := Vector3(size.x / 2.0, 0.0, size.y / 2.0)
	var diagonal := size.length()
	var progress := clampf((_t - _idle_start) / IDLE_SHOT, 0.0, 1.0)
	if not everyone.is_empty():
		_start_shot(key, _yaw)
		_base_yaw += deg_to_rad(1.5) * get_process_delta_time()
		return _framed(everyone, deg_to_rad(IDLE_PITCHES[_idle_index % IDLE_PITCHES.size()]), _base_yaw, IDLE_MARGIN * IDLE_ZOOM, 3.0)
	match kind:
		"env0":  # high slow orbit around the middle of the map
			_start_shot(key, _yaw)
			_base_yaw += deg_to_rad(3.0) * get_process_delta_time()
			return _want(center, diagonal * 0.55 * IDLE_ZOOM, _base_yaw, deg_to_rad(-38.0), 3.0)
		"env1":  # low dolly along the long side
			var along := Vector3(1, 0, 0) if size.x >= size.y else Vector3(0, 0, 1)
			var length := maxf(size.x, size.y)
			var across := _yaw_looking(Vector3(-along.z, 0.0, along.x))  # looking across the dolly path
			var other := _nearest_angle(across + PI, _yaw)
			across = _nearest_angle(across, _yaw)
			_start_shot(key, across if absf(across - _yaw) <= absf(other - _yaw) else other)
			var pivot := center + along * length * lerpf(-0.3, 0.3, progress)
			return _want(pivot, (minf(size.x, size.y) * 0.6 + 4.0) * IDLE_ZOOM, _base_yaw, deg_to_rad(-22.0), 3.0)
		_:  # three-quarter view drifting over one quarter of the map
			_start_shot(key, _yaw)
			_base_yaw += deg_to_rad(2.0) * get_process_delta_time()
			var q := (_idle_index / 2) % 4
			var quarter := Vector3(size.x * (0.25 if q % 2 == 0 else 0.75), 0.0, size.y * (0.25 if q < 2 else 0.75))
			return _want(center.lerp(quarter, 0.3 + 0.4 * progress), (diagonal * 0.35 + 4.0) * IDLE_ZOOM, _base_yaw, deg_to_rad(-30.0), 3.0)


## A new shot starts: its slow orbit begins at `yaw` (for shots that pick a direction) without jumping.
func _start_shot(key: String, yaw: float) -> void:
	if shot == key:
		return
	shot = key
	_base_yaw = yaw


func _restart_idle() -> void:
	_idle_start = _t
	_idle_index = 0


# ---------------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------------

func _want(pivot: Vector3, distance: float, yaw: float, pitch: float, smooth: float) -> Dictionary:
	_focus = [pivot + Vector3.UP * 0.8]
	return {"pivot": pivot, "distance": clampf(distance, MIN_DISTANCE, _max_distance()), "yaw": yaw, "pitch": pitch, "smooth": smooth}


## Pivot and distance that fit the points (and their height) in the view, with `margin` room around them.
func _framed(points: Array, pitch: float, yaw: float, margin: float, smooth: float) -> Dictionary:
	var focus := points.map(func(p): return p + Vector3.UP * 0.8)  # chest height
	var lo: Vector3 = points[0]
	var hi: Vector3 = points[0]
	for p in points:
		lo = lo.min(p)
		hi = hi.max(p + Vector3.UP * TOKEN_HEIGHT)
	var center := (lo + hi) * 0.5
	var radius := maxf((hi - lo).length() * 0.5, 1.2)
	var camera: Camera3D = orbit.camera
	var view := camera.get_viewport().get_visible_rect().size if camera.is_inside_tree() else Vector2(16, 9)
	var half_v := deg_to_rad(camera.fov) * 0.5
	var half_h := atan(tan(half_v) * view.x / maxf(view.y, 1.0))
	var distance := radius * margin / sin(minf(half_v, half_h))
	var want := _want(center, distance, yaw, pitch, smooth)
	_focus = focus
	return want


func _max_distance() -> float:
	var size := info.size_m() if info else Vector2(30, 30)
	return maxf(size.x, size.y) * 1.3 + 10.0


func _visible_tokens() -> Array:
	var out := []
	if tokens == null:
		return out
	for id in tokens._tokens:
		var node: Node3D = tokens._tokens[id].node
		if is_instance_valid(node) and node.is_visible_in_tree():
			out.append({"id": id, "pos": node.global_position})
	return out


func _positions(ids: Array) -> Array:
	var out := []
	if tokens == null:
		return out
	for id in ids:
		var entry: Dictionary = tokens._tokens.get(str(id), {})
		if not entry.is_empty() and is_instance_valid(entry.node) and entry.node.is_visible_in_tree():
			out.append(entry.node.global_position)
	return out


## Where the tokens are headed: the end of a streamed Foundry move (token_manager.gd entry.destination),
## else the position they're gliding to (entry.target).
func _destinations(ids: Array) -> Array:
	var out := []
	if tokens == null:
		return out
	for id in ids:
		var entry: Dictionary = tokens._tokens.get(str(id), {})
		if not entry.is_empty() and is_instance_valid(entry.node) and entry.node.is_visible_in_tree():
			var to: Vector3 = entry.get("destination", entry.target)
			var parent: Node3D = entry.node.get_parent_node_3d()
			out.append(parent.to_global(to) if parent else to)
	return out


func _centroid(points: Array) -> Vector3:
	var sum := Vector3.ZERO
	for p in points:
		sum += p
	return sum / maxf(points.size(), 1)


## The yaw at which the camera looks along `direction` (orbit_camera.gd: view = (-sin yaw, -cos yaw)).
func _yaw_looking(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


## `angle` shifted by whole turns to be as close as possible to `reference`.
func _nearest_angle(angle: float, reference: float) -> float:
	return reference + wrapf(angle - reference, -PI, PI)


func _track_movement(delta: float) -> void:
	if tokens == null:
		return
	for id in tokens._tokens:
		var entry: Dictionary = tokens._tokens[id]
		if not is_instance_valid(entry.node):
			continue
		var pos: Vector3 = entry.node.position
		if _last_pos.has(id) and delta > 0.0:
			var now := minf(pos.distance_to(_last_pos[id]) / delta, TRACK_SPEED_CAP * 3.0)
			_speed[id] = lerpf(float(_speed.get(id, 0.0)), now, 1.0 - exp(-6.0 * delta))
		_last_pos[id] = pos
		var target: Vector3 = entry.target
		var moving: bool = entry.node.position.distance_to(target) > MOVE_EPSILON
		if _last_target.has(id) and _last_target[id].distance_to(target) > 0.01:
			moving = true
		_last_target[id] = target
		if moving:
			if _t - float(_last_move.get(id, -INF)) > MOVE_LINGER:  # a new move: remember where it started
				_move_from[id] = entry.node.global_position
			_last_move[id] = _t
		elif _move_from.has(id) and _t - float(_last_move.get(id, -INF)) > MOVE_LINGER:
			_move_from.erase(id)


# ---------------------------------------------------------------------------
# Motion: critically damped springs, then the handheld sway on top
# ---------------------------------------------------------------------------

func _sync_from_orbit() -> void:
	_pivot = orbit.position
	_distance = orbit.distance
	_yaw = orbit.yaw
	_pitch = orbit.pitch
	_base_yaw = _yaw
	_v_pivot = Vector3.ZERO
	_v_distance = 0.0
	_v_yaw = 0.0
	_v_pitch = 0.0


## How quickly to get there, from the shot's base pace, scaled to what's needed right now.
func _pace(want: Dictionary) -> Array:
	var base: float = want.smooth
	var view := maxf(_distance, MIN_DISTANCE)
	# Farther to go (relative to the view): ease in slower; a small re-frame: quicker
	var travel: float = (want.pivot - _pivot).length() / view
	var smooth := base * clampf(0.7 + 0.45 * sqrt(travel), 0.6, 1.8)
	var max_speed := view * 1.2  # meters per second for the pivot, relative to the zoom
	# Moving subjects: keep up with them (and no faster than needed)
	var track: float = want.get("track", 0.0)
	if track > 0.05:
		smooth = minf(smooth, maxf(MIN_SMOOTH, base * 2.0 / (1.0 + track / maxf(view * 0.25, 0.5))))
		max_speed = maxf(max_speed, track * 1.6)
	return [smooth, max_speed]


func _step(want: Dictionary, delta: float) -> void:
	var pace := _pace(want)
	var smooth: float = pace[0]
	var max_speed: float = pace[1]
	var turn := absf(_nearest_angle(want.yaw, _yaw) - _yaw)  # a big swing of the view goes slower
	var p := _damp_vec(_pivot, want.pivot, _v_pivot, smooth, delta, max_speed)
	_pivot = p[0]
	_v_pivot = p[1]
	# Zoom eases in log space (an even pace however far it goes) and isn't hurried by tracking: a big
	# zoom-out, like attack -> moving shot, never whips
	var d := _damp(log(maxf(_distance, 0.1)), log(maxf(want.distance, 0.1)), _v_distance, maxf(smooth, want.smooth) * 1.15, delta)
	_distance = exp(d[0])
	_v_distance = d[1]
	var y := _damp(_yaw, _nearest_angle(want.yaw, _yaw), _v_yaw, smooth * 1.3 * clampf(0.75 + 0.35 * turn, 0.75, 1.6), delta)
	_yaw = y[0]
	_v_yaw = y[1]
	var pt := _damp(_pitch, want.pitch, _v_pitch, want.get("pitch_smooth", smooth * 1.3), delta)
	_pitch = pt[0]
	_v_pitch = pt[1]


func _apply() -> void:
	var sway_yaw := 0.0
	var sway_pitch := 0.0
	var sway_pivot := Vector3.ZERO
	if SWAY > 0.0:
		sway_yaw = (sin(_t * 0.31) * 0.6 + sin(_t * 0.73 + 1.0) * 0.4) * deg_to_rad(0.3) * SWAY
		sway_pitch = (sin(_t * 0.27 + 2.0) * 0.6 + sin(_t * 0.61 + 0.5) * 0.4) * deg_to_rad(0.25) * SWAY
		sway_pivot = Vector3(sin(_t * 0.21), 0.0, cos(_t * 0.17)) * 0.004 * _distance * SWAY
	orbit.position = _pivot + sway_pivot
	orbit.distance = _distance
	orbit.yaw = _yaw + sway_yaw
	orbit.pitch = clampf(_pitch + sway_pitch, deg_to_rad(-89.0), deg_to_rad(-5.0))


## Unity-style SmoothDamp: [new value, new velocity].
static func _damp(current: float, target: float, velocity: float, smooth: float, delta: float) -> Array:
	var omega := 2.0 / maxf(smooth, 0.0001)
	var x := omega * delta
	var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change := current - target
	var temp := (velocity + omega * change) * delta
	return [target + (change + temp) * e, (velocity - omega * temp) * e]


static func _damp_vec(current: Vector3, target: Vector3, velocity: Vector3, smooth: float, delta: float, max_speed: float) -> Array:
	var omega := 2.0 / maxf(smooth, 0.0001)
	var x := omega * delta
	var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change := current - target
	var max_change := max_speed * smooth
	if change.length() > max_change:
		change = change.normalized() * max_change
	var goal := current - change
	var temp := (velocity + omega * change) * delta
	return [goal + (change + temp) * e, (velocity - omega * temp) * e]
