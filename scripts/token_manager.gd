extends Node3D
## Mirrors Foundry tokens. Each token is a disposition-colored ring, a visual in one of the styles below,
## and the token's own light. Positions ease toward the latest live position from Foundry.
##   billboard - upright image that always turns to the camera
##   flat      - image lying on the floor, like Foundry's top-down view
##   standee   - image cut out along its outline and extruded (token_mesh.gd)
##   coin      - thick disc with the image on top (token_mesh.gd)
##   model     - .glb model from the token flag foundry-godot-bridge.model

const SceneInfo = preload("res://scripts/scene_info.gd")
const LightManager = preload("res://scripts/light_manager.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const HitReaction = preload("res://scripts/hit_reaction.gd")
const HitStyles = preload("res://scripts/hit_styles.gd")
const TokenStatus = preload("res://scripts/token_status.gd")
const TokenTarget = preload("res://scripts/token_target.gd")

## A token took a heavy hit (severity 0..1, "full" hit reactions only): main.gd shakes the camera.
signal token_hit(severity: float)

const STYLES := ["billboard", "cross", "flat", "standee", "coin", "model"]
const FOLLOW_RATE := 25.0  # higher = snappier; 25 reaches the live position in ~0.15 s
const CLEARANCE := VisualBuilder.CLEARANCE  # every token style starts this far above the floor
const RING_TUBE := 0.035  # radius of the disposition ring's tube, meters
const TOKEN_LIGHT_HEIGHT := 1.5  # meters above the token
# CONST.TOKEN_DISPOSITIONS: secret, hostile, neutral, friendly
const DISPOSITION_COLORS := {-2: Color("a612d4"), -1: Color("e72124"), 0: Color("f1d836"), 1: Color("3ad14a")}

var info: SceneInfo
var loader: Node  # asset_loader.gd
## Returns whether a token on the given Foundry Level id should be shown (PgUp/PgDn floor filter).
var level_filter := func(_level_id: String) -> bool: return true
## Viewer-only style for every token ("" = use each token's style from Foundry). Cycled with V.
var style_override := ""
## Current scene darkness (for token lights).
var darkness := 0.0

var _tokens := {}  # id -> {"node": Node3D, "data": Dictionary, "target": Vector3, "rotation": float}


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_tokens.clear()


func get_token(id: String) -> Node3D:
	return _tokens[id].node if _tokens.has(id) else null


## Chest-height points (0.8 m up, like the cinematic camera's focus) of the tokens shown right now.
func visible_points() -> Array:
	var points: Array = []
	for entry in _tokens.values():
		var node: Node3D = entry.node
		if is_instance_valid(node) and node.is_visible_in_tree():
			points.append(node.global_position + Vector3.UP * 0.8)
	return points


## Visible tokens for the see-through: [{id, pos (chest height, as visible_points), data}].
func see_through_entries() -> Array:
	var out: Array = []
	for id in _tokens:
		var entry: Dictionary = _tokens[id]
		var node: Node3D = entry.node
		if is_instance_valid(node) and node.is_visible_in_tree():
			out.append({"id": id, "pos": node.global_position + Vector3.UP * 0.8, "data": entry.data})
	return out


## `live_position`: Foundry is animating this move and streams the positions (token.move), so the
## final position in `t` must not be applied yet.
func upsert(t: Dictionary, animate := true, live_position := false) -> Node3D:
	var entry: Dictionary = _tokens.get(t.id, {})
	var is_new := entry.is_empty()
	if is_new:
		entry = {"node": _create(t.id)}
		add_child(entry.node)
		_tokens[t.id] = entry
	entry.data = t
	var node: Node3D = entry.node
	if is_new or not live_position:
		_set_target(entry, t)
	elif not is_new:
		# Where the streamed move will end (the cinematic camera frames it while the token is on the way)
		entry.destination = info.to_3d(t.x, t.y, float(t.get("elevation", 0)))
	if is_new or not animate:
		_snap(entry)

	var style := _effective_style(t)
	var footprint := info.px_to_m(minf(t.widthPx, t.heightPx))
	var ring: MeshInstance3D = node.get_node("Ring")
	ring.visible = style != "coin"  # the coin's rim already shows the disposition
	var torus := ring.mesh as TorusMesh
	torus.inner_radius = maxf(footprint * 0.48 - RING_TUBE, 0.01)
	torus.outer_radius = footprint * 0.48 + RING_TUBE
	_color_ring(node)

	_load_visual(node, t, style)
	_update_light(entry)
	_apply_visibility(entry)
	if t.has("downed"):
		set_downed(t.id, bool(t.downed), not is_new)
	TokenStatus.apply(node, t.get("statuses", []), t.get("effects", []), loader, style)
	TokenTarget.apply(node, t, info)  # Foundry's target arrows (yours) and pips (other users')
	entry.status_gray = "unconscious" in t.get("statuses", [])
	_refresh_gray(entry, not is_new)
	return node


## Live position from Foundry (mid-animation or while dragging): only moves the target.
func move(m: Dictionary) -> void:
	var entry: Dictionary = _tokens.get(m.id, {})
	if entry.is_empty():
		return
	for key in ["x", "y", "elevation", "rotation"]:
		if m.has(key):
			entry.data[key] = m[key]
	_set_target(entry, entry.data)
	if float(entry.data.get("light", {}).get("angle", 360)) < 360.0:
		_update_light(entry)  # a cone light turns with the token


## Damage / healing number rising above a token and fading out (HP changes in Foundry).
const FLOAT_COLORS := {"damage": Color("ff4a3d"), "healing": Color("4ade5a"), "temp": Color("5aa8ff"),
	"miss": Color("c8c8c8")}
var _float_count := 0

func float_text(id: String, text: String, kind: String) -> Label3D:
	var node := get_token(id)
	if node == null:
		return null
	var label := Label3D.new()
	_float_count += 1
	label.name = "Float%d" % _float_count  # unique, so numbers that arrive together stack instead of colliding
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true  # readable even behind walls
	label.fixed_size = false
	label.pixel_size = 0.012
	label.font_size = 64
	label.outline_size = 14
	label.modulate = FLOAT_COLORS.get(kind, Color.WHITE)
	label.outline_modulate = Color(0, 0, 0, 0.85)
	# Stack numbers that arrive together so they don't overlap
	var stacked := node.find_children("Float*", "Label3D", false, false).size()
	label.position = Vector3(0, 2.0 + stacked * 0.45, 0)
	node.add_child(label)
	var tween := label.create_tween().set_parallel()
	tween.tween_property(label, "position:y", label.position.y + 1.2, 1.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.6).set_delay(1.0)
	tween.chain().tween_callback(label.queue_free)
	return label


## Hit reaction when the token takes damage, scaled by the hit's share of max HP (severity 0..1):
## small hits react like Octopath Traveler / Triangle Strategy (white flash, short shake, small hop back),
## big ones like Limbus Company (hitstop, red flash, long knockback, squash and stretch, camera shake).
## `hit_info` ({type, delivery, from}, hit_styles.gd) shapes it by weapon and damage type: slash, stab, blunt,
## arrows and bullets from the attacker, elemental colors and particles. Knockback is away from the attacker,
## or from the camera. `reaction`: the module's "hitReactions" setting (off / subtle / full).
const HIT_RED := Color("ff3030")
const SPARK_WHITE := Color(1.0, 0.95, 0.75)
const SPARK_RED := Color(1.0, 0.45, 0.2)

func hit(id: String, amount: float, hp_max: float, downs := false, reaction := "full", hit_info := {}) -> void:
	var entry: Dictionary = _tokens.get(id, {})
	if entry.is_empty() or reaction == "off":
		return
	# The attack already played on its roll (attack_hit): the damage only gets a beat, no second attack
	var struck: Dictionary = entry.get("struck", {})
	if not struck.is_empty() and Time.get_ticks_msec() - int(struck.at) < STRUCK_MEMORY_MS:
		entry.erase("struck")
		_pulse(entry.node, HIT_RED if downs or (hp_max > 0.0 and amount / hp_max >= 0.25) else Color.WHITE)
		return
	var full := reaction != "subtle"
	var s := clampf(amount / hp_max / 0.5, 0.0, 1.0) if hp_max > 0.0 else 0.3  # half of max HP = full severity
	if downs:
		s = maxf(s, 0.7)
	if not full:
		s = minf(s, 0.35)
	var node: Node3D = entry.node
	var style := HitStyles.motion(hit_info)
	var arrived := await _attack_arrives(id, entry, hit_info)
	if arrived.is_empty():
		return
	var ticket: Array[Callable] = arrived.ticket
	var attacker: Node3D = arrived.attacker
	var away: Vector3 = arrived.away
	var chest: float = arrived.chest

	var visual: Node3D = node.get_node("Visual")
	var previous: Tween = entry.get("hit_tween")
	if previous and previous.is_valid():
		previous.kill()
	visual.position = Vector3.ZERO
	visual.scale = Vector3.ONE

	var fx := HitReaction.surfaces(node)
	var side := away.cross(Vector3.UP)
	var push := (away + side * float(style.sideways)).normalized() * lerpf(0.08, 0.45, s) * float(style.push)
	var hop := 0.05 + 0.1 * s
	var hitstop := lerpf(0.0, 0.12, s) * float(style.hitstop) if full else 0.0
	var shake := lerpf(0.03, 0.09, s) * float(style.shake)
	var shake_time := 0.2 + 0.15 * s
	var shake_rate: float = style.shake_rate
	var squash := 0.15 * s * float(style.squash)
	var color: Color = style.flash if style.flash != null else (HIT_RED if s >= 0.5 else Color.WHITE)
	var spark: Color = style.spark if style.spark != null else (SPARK_RED if s >= 0.5 else SPARK_WHITE)
	var hurt: Texture2D = node.get_meta("hurt_tex") if node.has_meta("hurt_tex") else null

	# Impact: flash, hurt image, sparks and the hit's own effects, and a squash held through the hitstop.
	if hit_info.get("type", "") == "" and hit_info.get("delivery", "") == "":  # typed hits bring their own shapes
		HitReaction.spawn_sparks(node, Vector3(0.0, chest, 0.0) - away * 0.1, s, spark)
	_land(entry, ticket)  # the damage number pops with the flash
	HitStyles.impact(node, hit_info, s, away, chest)
	HitReaction.set_flash(fx, 1.0, color)
	if hurt:
		HitReaction.set_texture(fx, hurt)
	visual.scale = Vector3(1.0 + squash, 1.0 - squash, 1.0 + squash)
	if full and s > float(style.camera_from):
		token_hit.emit(minf(s * float(style.camera), 1.5))

	var tween := node.create_tween()
	entry.hit_tween = tween
	if hitstop > 0.0:
		tween.tween_interval(hitstop)
	# Knockback: snap away with a little hop, stretching as it flies; a red flash turns white.
	tween.tween_property(visual, "position", push + Vector3.UP * hop, 0.06) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(visual, "scale", Vector3(1.0 - squash / 2.0, 1.0 + squash * 0.66, 1.0 - squash / 2.0), 0.06)
	var settle: Color = Color.WHITE if style.flash == null else color
	tween.parallel().tween_method(func(c: Color) -> void: HitReaction.set_flash(fx, 1.0, c), color, settle, 0.06)
	# Shake: decaying side-to-side jitter while the hop lands.
	var jitter := func(k: float) -> void:
		visual.position = push + Vector3.UP * hop * k + side * shake * k * sin((1.0 - k) * shake_time * TAU * shake_rate)
	tween.tween_method(jitter, 1.0, 0.0, shake_time)
	tween.parallel().tween_property(visual, "scale", Vector3.ONE, shake_time) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	var flicker: bool = style.flicker
	var fade := func(a: float) -> void:
		if flicker:  # lightning: the flash strobes as it fades
			a *= float(int(a * 8.0) % 2 == 0)
		HitReaction.set_flash(fx, a, settle)
	tween.parallel().tween_method(fade, 1.0, 0.0, 0.3 if flicker else 0.15)
	# Recover: ease back to the token's spot, then show its own image again.
	tween.tween_property(visual, "position", Vector3.ZERO, (0.25 + 0.2 * s) * float(style.recover)) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(func() -> void: HitReaction.set_flash(fx, 0.0))
	if hurt:
		tween.tween_callback(func() -> void: HitReaction.set_texture(fx, null))


## An attack that hit, as soon as its roll is resolved (module misses.js "hit" float, before the damage is rolled
## and applied): the attacker's motion and the target's reaction play now, at a medium severity; the damage float
## that follows within STRUCK_MEMORY_MS only flashes and shows its number (hit()).
const HIT_ON_ROLL_SEVERITY := 0.4
const STRUCK_MEMORY_MS := 30000

func attack_hit(id: String, hit_info := {}, reaction := "full", hp_max := 0.0) -> void:
	var entry: Dictionary = _tokens.get(id, {})
	if entry.is_empty() or reaction == "off":
		return
	entry.erase("struck")
	var max_hp := hp_max if hp_max > 0.0 else 1.0
	hit(id, HIT_ON_ROLL_SEVERITY * 0.5 * max_hp, max_hp, false, reaction, hit_info)  # severity = amount / max / 0.5
	entry.struck = {"at": Time.get_ticks_msec(), "from": str(hit_info.get("from", ""))}


## A quick flash on the token (the damage of an attack that already played).
func _pulse(node: Node3D, color: Color) -> void:
	var fx := HitReaction.surfaces(node)
	var tween := node.create_tween()
	tween.tween_method(func(a: float) -> void: HitReaction.set_flash(fx, a, color), 1.0, 0.0, 0.18)


## A missed attack: the attacker swings or shoots and the attack's effects play on the target as on a hit
## (HitStyles.impact, at a light severity), but the target doesn't react: no flash, hurt image, knockback or
## camera shake. main.gd floats "Miss" when it lands (after_impact). `reaction` "off": nothing plays.
const MISS_SEVERITY := 0.3

func attack_missed(id: String, hit_info := {}, reaction := "full") -> void:
	var entry: Dictionary = _tokens.get(id, {})
	if entry.is_empty() or reaction == "off":
		return
	var arrived := await _attack_arrives(id, entry, hit_info)
	if arrived.is_empty():
		return
	_land(entry, arrived.ticket)
	HitStyles.impact(entry.node, hit_info, MISS_SEVERITY, arrived.away, arrived.chest)


## The attack's approach, shared by hits and misses. Queues this attack's ticket right away (damage numbers,
## "Miss" and the 0 HP look wait on it: after_impact), then plays the attacker's lunge / draw / aim / gather and
## the arrow's or orb's flight. Returns {ticket, attacker, away, chest} on contact, or {} (ticket landed) when the
## target went away meanwhile.
func _attack_arrives(id: String, entry: Dictionary, hit_info: Dictionary) -> Dictionary:
	var node: Node3D = entry.node
	var ticket: Array[Callable] = []
	if not entry.has("impact_queue"):
		entry.impact_queue = []
	entry.impact_queue.append(ticket)
	var attacker := get_token(str(hit_info.get("from", "")))
	if attacker == node:
		attacker = null
	var away := _away_from(attacker, node)
	var chest := _chest_height(node)
	var wind_up := HitStyles.wind_up(attacker, node, hit_info)
	if wind_up > 0.0:
		await get_tree().create_timer(wind_up).timeout
		if not is_instance_valid(node) or _tokens.get(id, {}).get("node") != node:
			_land(entry, ticket)
			return {}
		if not is_instance_valid(attacker):
			attacker = null
	var travel := HitStyles.launch(self, hit_info, attacker, node)
	if travel > 0.0:
		await get_tree().create_timer(travel).timeout
		if not is_instance_valid(node) or _tokens.get(id, {}).get("node") != node:
			_land(entry, ticket)
			return {}
	return {"ticket": ticket, "attacker": attacker, "away": away, "chest": chest}


## Run `action` when the token's latest hit lands (its attacker's lunge or arrow connects), or now if no hit is
## on its way: damage numbers and the 0 HP look stay in step with the hit reaction.
func after_impact(id: String, action: Callable) -> void:
	var queue: Array = _tokens.get(id, {}).get("impact_queue", [])
	if queue.is_empty():
		action.call()
	else:
		queue[-1].append(action)


## A hit landed (or was cut short): run what waited on its ticket.
func _land(entry: Dictionary, ticket: Array[Callable]) -> void:
	var queue: Array = entry.get("impact_queue", [])
	for i in queue.size():
		if is_same(queue[i], ticket):  # by identity: two empty tickets are equal by value
			queue.remove_at(i)
			break
	for action in ticket:
		action.call()


## Height of the token's chest (60% of its visual), for sparks and projectiles.
func _chest_height(node: Node3D) -> float:
	return HitStyles._chest_height(node)  # ignores effects riding the token (stuck arrows)


## At 0 HP the token loses 80% of its color until it's healed.
const DOWNED_SATURATION := 0.2

func set_downed(id: String, downed: bool, animate := true) -> void:
	var entry: Dictionary = _tokens.get(id, {})
	if entry.is_empty() or entry.get("downed", false) == downed:
		return
	entry.downed = downed
	_refresh_gray(entry, animate, 0.15 if downed else 0.0)  # after the hit's flash


## Gray at 0 HP or while Unconscious (token_status.gd), in color otherwise.
func _refresh_gray(entry: Dictionary, animate: bool, delay := 0.0) -> void:
	var target := DOWNED_SATURATION if entry.get("downed", false) or entry.get("status_gray", false) else 1.0
	if is_equal_approx(float(entry.get("gray_target", 1.0)), target):
		return
	entry.gray_target = target
	var node: Node3D = entry.node
	var previous: Tween = entry.get("downed_tween")
	if previous and previous.is_valid():
		previous.kill()
	if not animate:
		_set_saturation(node, target)
		return
	var tween := node.create_tween()
	entry.downed_tween = tween
	tween.tween_method(func(v: float) -> void: _set_saturation(node, v), float(node.get_meta("saturation", 1.0)),
		target, 0.4).set_delay(delay)


func _set_saturation(node: Node3D, value: float) -> void:
	node.set_meta("saturation", value)
	HitReaction.set_saturation(HitReaction.surfaces(node), value)
	_color_ring(node)


## The disposition ring, losing color with the token at 0 HP.
func _color_ring(node: Node3D) -> void:
	var entry: Dictionary = _tokens.get(str(node.name).trim_prefix("Token_"), {})
	if entry.is_empty():
		return
	var color := _disposition_color(entry.data)
	var grey := Color(color.get_luminance(), color.get_luminance(), color.get_luminance())
	var ring: MeshInstance3D = node.get_node("Ring")
	(ring.material_override as StandardMaterial3D).albedo_color = grey.lerp(color, node.get_meta("saturation", 1.0))


## Horizontal direction from the attacker (or the camera) to the token.
func _away_from(attacker: Node3D, node: Node3D) -> Vector3:
	if attacker:
		var from_attacker := node.global_position - attacker.global_position
		from_attacker.y = 0.0
		if from_attacker.length() > 0.001:
			return from_attacker.normalized()
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector3.FORWARD
	var dir := node.global_position - camera.global_position
	dir.y = 0.0
	if dir.length() < 0.001:  # camera right above the token
		dir = -camera.global_basis.z
		dir.y = 0.0
	return dir.normalized() if dir.length() > 0.001 else Vector3.FORWARD


func remove(id: String) -> void:
	if _tokens.has(id):
		var node: Node3D = _tokens[id].node
		remove_child(node)
		node.queue_free()
		_tokens.erase(id)


## Scene darkness changed: token lights have darkness ranges too.
func set_darkness(value: float) -> void:
	darkness = value
	for entry in _tokens.values():
		_update_light(entry)


func _update_light(entry: Dictionary) -> void:
	var t: Dictionary = entry.data
	LightManager.apply_light_data(entry.node.get_node("Light"), t.get("light", {}), info, darkness,
		-TOKEN_LIGHT_HEIGHT, float(t.get("rotation", 0)))


func refresh_visibility() -> void:
	for entry in _tokens.values():
		_apply_visibility(entry)


## Rebuild every token's visual, e.g. after the V hotkey changed style_override.
func rebuild_all() -> void:
	for entry in _tokens.values():
		entry.node.set_meta("visual_key", "")
		upsert(entry.data, false)


func _process(delta: float) -> void:
	var weight := 1.0 - exp(-FOLLOW_RATE * delta)
	for entry in _tokens.values():
		var node: Node3D = entry.node
		node.position = node.position.lerp(entry.target, weight)
		if entry.has("destination") and node.position.distance_to(entry.destination) < 0.05:
			entry.erase("destination")  # arrived
		var visual: Node3D = node.get_node("Visual")
		visual.rotation.y = lerp_angle(visual.rotation.y, entry.rotation, weight)


func _set_target(entry: Dictionary, t: Dictionary) -> void:
	entry.target = info.to_3d(t.x, t.y, float(t.get("elevation", 0)))
	entry.rotation = -deg_to_rad(float(t.get("rotation", 0)))  # Foundry rotates clockwise


func _snap(entry: Dictionary) -> void:
	entry.node.position = entry.target
	entry.node.get_node("Visual").rotation.y = entry.rotation


func _apply_visibility(entry: Dictionary) -> void:
	var t: Dictionary = entry.data
	entry.node.visible = not t.get("hidden", false) and level_filter.call(str(t.get("level", "")))


func _effective_style(t: Dictionary) -> String:
	var style: String = style_override if style_override != "" else str(t.get("style", "billboard"))
	if style == "model" and not t.get("model") is String:
		return "billboard"  # nothing to load
	return style if style in STYLES else "billboard"


func _disposition_color(t: Dictionary) -> Color:
	return DISPOSITION_COLORS.get(int(t.get("disposition", 0)), Color.WHITE)


func _create(id: String) -> Node3D:
	var node := Node3D.new()
	node.name = "Token_" + id

	# Disposition ring around the token, unshaded so it stays readable at night (like Foundry's border).
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	var torus := TorusMesh.new()
	torus.rings = 48
	torus.ring_segments = 8
	ring.mesh = torus
	ring.position.y = RING_TUBE
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat
	node.add_child(ring)

	var visual := Node3D.new()
	visual.name = "Visual"
	node.add_child(visual)

	var light := OmniLight3D.new()
	light.name = "Light"
	light.position.y = TOKEN_LIGHT_HEIGHT
	node.add_child(light)
	return node


## (Re)builds the visual, only when the style, image, model, size or appearance settings changed.
## Token images use the "plain" image shader, so every style can flash and desaturate (hit reactions).
func _load_visual(node: Node3D, t: Dictionary, style: String) -> void:
	var width_m := info.px_to_m(t.widthPx)
	var height_m := info.px_to_m(t.heightPx)
	var rim := _disposition_color(t)
	var key := VisualBuilder.cache_key(style, t, width_m, height_m, rim, "plain") + "|%s" % t.get("hurtImg")
	if node.get_meta("visual_key", "") == key:
		return
	node.set_meta("visual_key", key)
	node.remove_meta("hit_surfaces")
	node.remove_meta("hurt_tex")
	var holder: Node3D = node.get_node("Visual")
	for child in holder.get_children():
		holder.remove_child(child)
		child.queue_free()
	var visual := await VisualBuilder.build(style, t, width_m, height_m, loader, rim, "plain")
	# The token may have been deleted or changed again while we were downloading.
	if visual == null or not is_instance_valid(node) or node.get_meta("visual_key", "") != key:
		if visual:
			visual.free()
		return
	holder.add_child(visual)
	var saturation: float = node.get_meta("saturation", 1.0)
	if saturation < 1.0:  # still downed
		HitReaction.set_saturation(HitReaction.surfaces(node), saturation)
	TokenStatus.reapply(node)  # condition tints and fades on the new surfaces
	# Hurt image: fetched now, so a hit can show it at once.
	if t.get("hurtImg") is String and style != "model":
		var hurt: Texture2D = await loader.fetch_texture(t.hurtImg)
		if hurt and is_instance_valid(node) and node.get_meta("visual_key", "") == key:
			node.set_meta("hurt_tex", hurt)