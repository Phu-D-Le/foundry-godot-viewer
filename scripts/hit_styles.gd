extends RefCounted
## Hit effects by how a hit was delivered and its damage type (token_manager.gd hit()), on the attacker and on
## the target, in the spirit of Octopath Traveler / Triangle Strategy (step in, swing, flash) and Limbus Company
## (dash, big weapon arcs, heavy impacts). The module sends `hit = {type, delivery, from}` (hit-info.js):
##   type     - dnd5e damage type, the biggest part of the hit (slashing, fire, ...)
##   delivery - melee / ranged / firearm / spell-ranged / spell-melee / area
##   from     - the attacking token's id
## A hit plays in three steps: wind_up() (the attacker lunges, draws a bow, aims, gathers a spell), launch() (an
## arrow, tracer or orb flies) and impact() (the target's cut, puncture, crack, burst and damage-type layer).
## Without an attacker, only the impact plays.

const HitReaction = preload("res://scripts/hit_reaction.gd")
const VFX = preload("res://scripts/vfx.gd")

const SPARK_WARM := Color(1.0, 0.95, 0.75)
## flash: the token's flash color, spark: effect color, extra: the damage type's own layer (_extra)
const TYPES := {
	"slashing": {"flash": Color.WHITE, "spark": Color(1.0, 0.42, 0.18)},  # red-orange blade arcs
	"piercing": {"flash": Color.WHITE, "spark": Color(0.45, 0.85, 1.0)},  # cold cyan thrusts
	"bludgeoning": {"flash": Color.WHITE, "spark": Color(1.0, 0.78, 0.3)},  # golden impact
	"fire": {"flash": Color("ff7a1a"), "spark": Color("ffb040"), "extra": "fire"},
	"cold": {"flash": Color("9fe3ff"), "spark": Color("bfefff"), "extra": "cold"},
	"lightning": {"flash": Color("d6ecff"), "spark": Color("9fd0ff"), "extra": "lightning"},
	"thunder": {"flash": Color("e8e4ff"), "spark": Color("c8c0ff"), "extra": "thunder"},
	"acid": {"flash": Color("c4ff3a"), "spark": Color("9be22a"), "extra": "acid"},
	"poison": {"flash": Color("8bd13a"), "spark": Color("7ac24c"), "extra": "poison"},
	"necrotic": {"flash": Color("2a0f3a"), "spark": Color("9b4dff"), "extra": "necrotic"},
	"radiant": {"flash": Color("ffe27a"), "spark": Color("fff2b0"), "extra": "radiant"},
	"psychic": {"flash": Color("ff5ad7"), "spark": Color("ff9be8"), "extra": "psychic"},
	"force": {"flash": Color("8a7bff"), "spark": Color("b8adff"), "extra": "force"},
}
const LUNGE := 0.35  # meters the attacker steps in
const ARROW_SPEED := 25.0  # m/s


## How the hit moves the target: multipliers on token_manager.gd's plain reaction, plus colors (null = plain).
static func motion(info: Dictionary) -> Dictionary:
	var m := {"flash": null, "spark": null, "squash": 1.0, "hitstop": 1.0, "push": 1.0, "shake": 1.0,
		"shake_rate": 15.0, "recover": 1.0, "sideways": 0.0, "flicker": false, "camera": 1.0, "camera_from": 0.25}
	var type := str(info.get("type", ""))
	var delivery := str(info.get("delivery", ""))
	if TYPES.has(type):
		m.flash = TYPES[type].flash
		m.spark = TYPES[type].spark
	match melee_kind(type, delivery):
		"slash":
			m.sideways = 0.8
			m.shake = 0.7
		"stab":
			m.push = 0.7
			m.shake = 0.3
			m.hitstop = 0.8
		"blunt":
			m.squash = 1.6
			m.hitstop = 1.5
			m.camera_from = 0.1
	if delivery == "firearm":
		m.hitstop = 0.5
		m.push = 0.8
		m.shake = 0.5
		m.camera_from = 0.0
		m.camera = 0.6
	match type:
		"cold":
			m.recover = 1.5
		"lightning":
			m.flicker = true
			m.shake_rate = 30.0
		"thunder":
			m.camera = 1.5
			m.camera_from = 0.0
	return m


## Physical melee look: slash, stab or blunt; "" for anything else.
static func melee_kind(type: String, delivery: String) -> String:
	if delivery != "melee" and not (delivery == "" and type in ["slashing", "piercing", "bludgeoning"]):
		return ""
	match type:
		"slashing":
			return "slash"
		"piercing":
			return "stab"
		"bludgeoning", "":
			return "blunt"
	return ""


static func _color(info: Dictionary) -> Color:
	return TYPES.get(str(info.get("type", "")), {}).get("spark", SPARK_WARM)


static func _chest(token: Node3D) -> Vector3:
	return token.global_position + Vector3(0.0, _chest_height(token), 0.0)


static func _chest_height(token: Node3D) -> float:
	var acc := [null]
	for child in token.get_node("Visual").get_children():
		_accumulate_aabb(child, Transform3D.IDENTITY, acc)
	return maxf((acc[0] as AABB).end.y * 0.6, 0.3) if acc[0] != null else 0.6


static func _accumulate_aabb(node: Node, parent_xform: Transform3D, acc: Array) -> void:
	if node.has_meta("vfx"):
		return
	var xform := parent_xform
	if node is Node3D:
		xform = parent_xform * (node as Node3D).transform
	if node is VisualInstance3D:
		var box: AABB = xform * (node as VisualInstance3D).get_aabb()
		acc[0] = box if acc[0] == null else (acc[0] as AABB).merge(box)
	for child in node.get_children():
		_accumulate_aabb(child, xform, acc)


## The attacker's part before the hit lands. Returns the time until the blow connects or the shot leaves.
static func wind_up(attacker: Node3D, target: Node3D, info: Dictionary) -> float:
	if attacker == null:
		return 0.0
	var type := str(info.get("type", ""))
	var delivery := str(info.get("delivery", ""))
	var dir := target.global_position - attacker.global_position
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.001 else Vector3.FORWARD
	var visual: Node3D = attacker.get_node("Visual")
	var previous: Tween = attacker.get_meta("attack_tween") if attacker.has_meta("attack_tween") else null
	if previous and previous.is_valid():
		previous.kill()
	visual.position = Vector3.ZERO
	visual.scale = Vector3.ONE
	var tween := attacker.create_tween()
	attacker.set_meta("attack_tween", tween)
	var chest := _chest(attacker)
	var side := VFX.screen_side(attacker, dir)
	var color := _color(info)
	match delivery:
		"melee":
			var kind := melee_kind(type, delivery)
			if kind == "blunt":  # raise it back and up, then smash down into the target
				tween.tween_property(visual, "position", -dir * 0.12 + Vector3.UP * 0.12, 0.15).set_ease(Tween.EASE_OUT)
				tween.parallel().tween_property(visual, "scale", Vector3(0.95, 1.08, 0.95), 0.15)
				tween.tween_property(visual, "position", dir * LUNGE, 0.08).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
				tween.parallel().tween_property(visual, "scale", Vector3(1.08, 0.92, 1.08), 0.08)
				_arc_at(attacker, "SmashArc", chest + dir * 0.45 + Vector3.UP * 0.2, 1.5, -side * PI / 2.0, side < 0.0,
					color, 0.14, 0.09, 0.24)
				_return(tween, visual, 0.23)
				return 0.23
			# slash / stab / any other melee: a quick step in
			tween.tween_property(visual, "position", dir * LUNGE, 0.12).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
			tween.parallel().tween_property(visual, "scale", Vector3(1.05, 0.96, 1.05), 0.12)
			if kind == "stab":
				var length := minf(target.global_position.distance_to(attacker.global_position) * 0.8, 1.6)
				var thrust := VFX.quad(attacker, "Thrust", "thrust", Vector2(1.0, 0.22), chest + dir * (0.25 + length / 2.0),
					{"color": color, "progress": 0.0})
				thrust.set_meta("vfx", true)
				VFX.orient_along(thrust, dir)
				thrust.scale = Vector3(length, 1.0, 1.0)
				VFX.animate(thrust, "progress", 0.0, 1.0, 0.08, 0.05)
				VFX.animate(thrust, "fade", 1.0, 0.0, 0.15, 0.15)
				VFX.free_after(thrust, 0.4)
			elif kind == "slash":
				_arc_at(attacker, "SlashArc", chest + dir * 0.5, 1.7, 0.0, side < 0.0, color, 0.03, 0.12, 0.2)
			_return(tween, visual, 0.12)
			return 0.12
		"ranged":  # draw the bow (lean away), loose: snap forward, the string twangs
			tween.tween_property(visual, "position", -dir * 0.15, 0.25).set_ease(Tween.EASE_OUT)
			tween.parallel().tween_property(visual, "scale", Vector3(0.96, 1.04, 0.96), 0.25)
			tween.tween_property(visual, "position", dir * 0.06, 0.05)
			tween.parallel().tween_property(visual, "scale", Vector3.ONE, 0.05)
			_return(tween, visual, 0.0)
			var string := VFX.quad(attacker, "BowString", "slash", Vector2(0.9, 0.9), chest + dir * 0.2,
				{"color": Color(1, 1, 1), "progress": 0.0, "thickness": 0.05})
			string.set_meta("vfx", true)
			VFX.face_camera(string, -side * PI / 2.0, side < 0.0)
			VFX.animate(string, "progress", 0.0, 1.4, 0.06, 0.25)
			VFX.animate(string, "fade", 1.0, 0.0, 0.15, 0.31)
			VFX.free_after(string, 0.6)
			return 0.25
		"firearm":  # aim, fire: recoil, muzzle flash, smoke
			tween.tween_interval(0.05)
			tween.tween_property(visual, "position", -dir * 0.15, 0.04).set_ease(Tween.EASE_OUT)
			tween.parallel().tween_property(visual, "scale", Vector3(1.04, 0.97, 1.04), 0.04)
			_return(tween, visual, 0.0)
			var barrel := chest + dir * 0.45
			attacker.get_tree().create_timer(0.05).timeout.connect(func() -> void:
				if not is_instance_valid(attacker):
					return
				var muzzle := VFX.quad(attacker, "MuzzleStar", "star", Vector2(0.7, 0.7), barrel,
					{"color": Color(1.0, 0.75, 0.3), "spikes": 5.0, "sharp": 10.0, "size": 1.0, "seed": randf() * 6.0})
				muzzle.set_meta("vfx", true)
				VFX.face_camera(muzzle, randf() * TAU)
				VFX.animate(muzzle, "fade", 1.0, 0.0, 0.08)
				VFX.free_after(muzzle, 0.2)
				var smoke := VFX.quad(attacker, "GunSmoke", "smoke", Vector2(0.5, 0.5), barrel,
					{"color": Color(0.7, 0.7, 0.68), "seed": randf() * 10.0})
				smoke.set_meta("vfx", true)
				var drift := smoke.create_tween().set_parallel()
				drift.tween_property(smoke, "scale", Vector3.ONE * 2.0, 1.0).set_ease(Tween.EASE_OUT)
				drift.tween_property(smoke, "global_position", barrel + Vector3.UP * 0.4 + dir * 0.2, 1.0)
				VFX.animate(smoke, "fade", 1.0, 0.0, 1.0)
				VFX.free_after(smoke, 1.1))
			return 0.05
		_:  # spells: motes of the damage color gather into the caster as it glows
			var fx := HitReaction.surfaces(attacker)
			tween.tween_method(func(v: float) -> void: HitReaction.set_flash(fx, v, color), 0.0, 0.5, 0.25)
			tween.tween_method(func(v: float) -> void: HitReaction.set_flash(fx, v, color), 0.5, 0.0, 0.2)
			for i in 6:
				var angle := TAU * i / 6.0
				var start := chest + Vector3(cos(angle), sin(angle * 2.0) * 0.4, sin(angle)) * 0.7
				var mote := VFX.quad(attacker, "Gather", "star", Vector2(0.18, 0.18), start,
					{"color": color, "spikes": 4.0, "sharp": 8.0})
				mote.set_meta("vfx", true)
				VFX.face_camera(mote, 0.0)
				var pull := mote.create_tween()
				pull.tween_property(mote, "global_position", chest, 0.25).set_ease(Tween.EASE_IN)
				pull.tween_callback(mote.queue_free)
			return 0.25


## Ease the attacker back to its spot after `wait`.
static func _return(tween: Tween, visual: Node3D, wait: float) -> void:
	if wait > 0.0:
		tween.tween_interval(0.05)
	tween.tween_property(visual, "position", Vector3.ZERO, 0.25).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.parallel().tween_property(visual, "scale", Vector3.ONE, 0.25)


## A crescent swing (VFX slash) at `at`, turned `roll` in the view, its head sweeping over `time` after `delay`.
static func _arc_at(parent: Node3D, name: String, at: Vector3, size: float, roll: float, mirror: bool, color: Color,
		delay: float, time: float, thickness := 0.14) -> MeshInstance3D:
	var arc := VFX.quad(parent, name, "slash", Vector2(size, size), VFX.in_front(parent, at),
		{"color": color, "progress": 0.0, "thickness": thickness})
	arc.set_meta("vfx", true)
	VFX.face_camera(arc, roll, mirror)
	VFX.animate(arc, "progress", 0.0, 1.4, time, delay, Tween.TRANS_QUAD)
	VFX.animate(arc, "fade", 1.0, 0.0, 0.2, delay + time)
	VFX.free_after(arc, delay + time + 0.3)
	return arc


## What flies after the wind-up. Returns the flight time: the impact plays then.
static func launch(manager: Node3D, info: Dictionary, attacker: Node3D, target: Node3D) -> float:
	var delivery := str(info.get("delivery", ""))
	if attacker == null or not delivery in ["ranged", "firearm", "spell-ranged"]:
		return 0.0
	var from := _chest(attacker)
	var to := _chest(target)
	var dir := (to - from).normalized()
	match delivery:
		"firearm":  # a bullet is instant: a hot, thin, straight tracer
			var start := from + dir * 0.45
			var tracer := VFX.quad(manager, "Tracer", "thrust", Vector2(1.0, 0.05), (start + to) / 2.0,
				{"color": Color(1.0, 0.85, 0.5), "progress": 1.0})
			VFX.orient_along(tracer, to - start)
			tracer.scale = Vector3(start.distance_to(to), 1.0, 1.0)
			VFX.animate(tracer, "fade", 1.0, 0.0, 0.08)
			VFX.free_after(tracer, 0.2)
			return 0.0
		"spell-ranged":  # a glowing orb of the damage color
			var orb := VFX.quad(manager, "Orb", "star", Vector2(0.55, 0.55), from,
				{"color": _color(info), "spikes": 8.0, "sharp": 4.0})
			VFX.face_camera(orb, 0.0)
			var time := clampf(from.distance_to(to) / 20.0, 0.1, 0.4)
			var fly := orb.create_tween()
			fly.tween_property(orb, "global_position", to, time)
			fly.tween_callback(orb.queue_free)
			return time
		_:  # an arrow on a gentle arc, sticking into the target
			return _arrow(manager, from + dir * 0.3, to, target)


## Arrow: a wooden shaft, a steel head and white fletching, nose along its flight, faint streak behind.
static func _arrow(manager: Node3D, from: Vector3, to: Vector3, target: Node3D) -> float:
	var arrow := Node3D.new()
	arrow.name = "Arrow"
	arrow.set_meta("vfx", true)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.45, 0.3, 0.16)
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.75, 0.77, 0.8)
	steel.metallic = 0.8
	steel.roughness = 0.3
	var feather := StandardMaterial3D.new()
	feather.albedo_color = Color(0.95, 0.93, 0.88)
	feather.cull_mode = BaseMaterial3D.CULL_DISABLED
	var shaft := MeshInstance3D.new()
	shaft.name = "Shaft"
	var rod := CylinderMesh.new()
	rod.top_radius = 0.012
	rod.bottom_radius = 0.012
	rod.height = 0.75
	rod.radial_segments = 6
	shaft.mesh = rod
	shaft.material_override = wood
	shaft.rotation.x = -PI / 2.0  # along -Z, the way look_at points
	arrow.add_child(shaft)
	var head := MeshInstance3D.new()
	head.name = "Head"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.03
	cone.height = 0.1
	cone.radial_segments = 6
	head.mesh = cone
	head.material_override = steel
	head.rotation.x = -PI / 2.0
	head.position.z = -0.42
	arrow.add_child(head)
	for i in 2:
		var vane := MeshInstance3D.new()
		vane.name = "Fletching%d" % i
		var plane := QuadMesh.new()
		plane.size = Vector2(0.14, 0.05)
		vane.mesh = plane
		vane.material_override = feather
		vane.rotation = Vector3(0.0, PI / 2.0, PI / 2.0 * i)
		vane.position.z = 0.3
		arrow.add_child(vane)
	var streak := MeshInstance3D.new()
	streak.name = "Streak"
	var trail := QuadMesh.new()
	trail.size = Vector2(0.03, 0.9)
	streak.mesh = trail
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	glow.cull_mode = BaseMaterial3D.CULL_DISABLED
	glow.albedo_texture = VFX.texture_named("dot")
	glow.albedo_color = Color(1, 1, 1, 0.35)
	streak.material_override = glow
	streak.rotation.x = -PI / 2.0
	streak.position.z = 0.75
	arrow.add_child(streak)
	manager.add_child(arrow)
	arrow.global_position = from

	var distance := from.distance_to(to)
	var time := clampf(distance / ARROW_SPEED, 0.12, 0.6)
	var apex := distance * 0.08
	var at := func(t: float) -> Vector3:
		return from.lerp(to, t) + Vector3.UP * apex * 4.0 * t * (1.0 - t)
	var fly := func(t: float) -> void:
		var here: Vector3 = at.call(t)
		var ahead: Vector3 = at.call(minf(t + 0.02, 1.0)) if t < 0.98 else here + (to - from).normalized()
		arrow.global_position = here
		if not here.is_equal_approx(ahead):
			arrow.look_at(ahead, Vector3.UP if absf((ahead - here).normalized().y) < 0.99 else Vector3.FORWARD)
	fly.call(0.0)
	var tween := arrow.create_tween()
	tween.tween_method(fly, 0.0, 1.0, time)
	tween.tween_callback(func() -> void: _stick(arrow, target))
	return time


## The arrow stays in the target (riding its knockback), then fades away.
static func _stick(arrow: Node3D, target: Node3D) -> void:
	if not is_instance_valid(target):
		arrow.queue_free()
		return
	arrow.get_node("Streak").queue_free()
	var keep := arrow.global_transform
	arrow.get_parent().remove_child(arrow)
	target.get_node("Visual").add_child(arrow)
	arrow.global_transform = keep
	arrow.global_position += -arrow.global_basis.z * 0.12  # sinks in
	VFX.particles(target, "Splinters", arrow.global_position, "shard", Color(0.55, 0.4, 0.25),
		{"amount": 6, "lifetime": 0.4, "speed": Vector2(1.0, 2.5), "gravity": -9.0, "scale": Vector2(0.03, 0.06)})
	var vanish := func(v: float) -> void:
		for part in arrow.get_children():
			if part is GeometryInstance3D:
				(part as GeometryInstance3D).transparency = v
	var fade := arrow.create_tween()
	fade.tween_interval(0.8)
	fade.tween_method(vanish, 0.0, 1.0, 0.3)
	fade.tween_callback(arrow.queue_free)


## The target's part as the hit lands. `away`: the knockback direction, `chest`: local height of its chest.
static func impact(target: Node3D, info: Dictionary, s: float, away: Vector3, chest: float) -> void:
	var type := str(info.get("type", ""))
	var delivery := str(info.get("delivery", ""))
	var style: Dictionary = TYPES.get(type, {})
	var color: Color = style.get("spark", SPARK_WARM)
	var at := target.global_position + Vector3(0.0, chest, 0.0)
	var side := VFX.screen_side(target, away)
	match melee_kind(type, delivery):
		"slash":  # a diagonal cut across the body; a crossing second cut on heavy hits
			_arc_at(target, "SlashArc", at, 1.6 + 0.5 * s, -0.6 * side, side < 0.0, color, 0.0, 0.1, 0.22)
			if s >= 0.5:
				_arc_at(target, "SlashArc", at, 1.5 + 0.5 * s, 0.6 * side, side > 0.0, color, 0.06, 0.1, 0.18)
			VFX.particles(target, "CutSparks", at, "dot", color, {"amount": int(8 + 10 * s), "lifetime": 0.35,
				"speed": Vector2(2.0, 4.0), "gravity": -6.0, "scale": Vector2(0.03, 0.06), "additive": true})
		"stab":  # a puncture star, spray out the back
			_star(target, "Puncture", at, 1.2 + 0.4 * s, color, 7.0, 30.0, 0.0, 0.25)
			VFX.particles(target, "ExitSpray", at + away * 0.15, "dot", color, {"amount": int(8 + 8 * s),
				"lifetime": 0.3, "direction": away, "spread": 18.0, "speed": Vector2(3.0, 6.0), "gravity": -4.0,
				"scale": Vector2(0.03, 0.05), "additive": true})
		"blunt":  # a jagged starburst, the floor cracks, dust
			_star(target, "ImpactBurst", at, 1.4 + 0.5 * s, color, 11.0, 8.0, 0.75, 0.25)
			var crack := VFX.quad(target, "GroundCrack", "crack", Vector2.ONE * (1.6 + 0.8 * s),
				target.global_position + Vector3(0.0, 0.03, 0.0), {"grow": 0.0, "seed": randf() * 10.0})
			crack.set_meta("vfx", true)
			crack.global_basis = Basis(Vector3.RIGHT, -PI / 2.0)
			VFX.animate(crack, "grow", 0.0, 1.0, 0.1)
			VFX.animate(crack, "heat", 1.0, 0.0, 0.6, 0.1)  # glowing hot, cooling to dark scorch lines
			VFX.animate(crack, "fade", 1.0, 0.0, 0.8, 0.6)
			VFX.free_after(crack, 1.5)
			VFX.particles(target, "Dust", target.global_position + Vector3.UP * 0.1, "dot", Color(0.62, 0.57, 0.5, 0.7),
				{"amount": 10, "lifetime": 0.8, "spread": 80.0, "speed": Vector2(0.6, 1.4), "gravity": 0.4,
				"damping": 1.5, "scale": Vector2(0.15, 0.3), "radius": 0.3})
	match delivery:
		"firearm":
			_star(target, "Puncture", at, 0.5, Color(1.0, 0.8, 0.5), 5.0, 30.0, 0.0, 0.15)
			var puff := VFX.quad(target, "BulletDust", "smoke", Vector2(0.4, 0.4), at + away * 0.35,
				{"color": Color(0.7, 0.65, 0.58), "seed": randf() * 10.0})
			puff.set_meta("vfx", true)
			puff.create_tween().tween_property(puff, "scale", Vector3.ONE * 2.0, 0.6)
			VFX.animate(puff, "fade", 1.0, 0.0, 0.6)
			VFX.free_after(puff, 0.7)
		"spell-ranged", "spell-melee", "area":
			_star(target, "Burst", at, 1.3 + 0.5 * s, color, 9.0, 5.0, 0.7, 0.3)
		"melee":
			if melee_kind(type, delivery) == "":  # a magic weapon's elemental hit
				_star(target, "Burst", at, 1.2, color, 9.0, 5.0, 0.7, 0.3)
	_extra(target, str(style.get("extra", "")), color, s, at)


## Spiked starburst growing in 0.06 s, fading over `time`.
static func _star(parent: Node3D, name: String, at: Vector3, size: float, color: Color, spikes: float, sharp: float,
		ring: float, time: float) -> MeshInstance3D:
	var star := VFX.quad(parent, name, "star", Vector2(size, size), VFX.in_front(parent, at),
		{"color": color, "spikes": spikes, "sharp": sharp, "ring": ring, "size": 0.0, "seed": randf() * 6.0})
	star.set_meta("vfx", true)
	VFX.face_camera(star, randf() * TAU)
	VFX.animate(star, "size", 0.0, 1.0, 0.06, 0.0, Tween.TRANS_QUAD)
	VFX.animate(star, "fade", 1.0, 0.0, time, 0.06)
	VFX.free_after(star, time + 0.2)
	return star


## The damage type's own layer.
static func _extra(target: Node3D, extra: String, color: Color, s: float, at: Vector3) -> void:
	var base := target.global_position
	match extra:
		"fire":  # flame tongues flare up around the target and die down
			for i in 3:
				var offset := Vector3(cos(TAU * i / 3.0), 0.0, sin(TAU * i / 3.0)) * 0.25
				var height := (0.8 + 0.4 * s) * (1.0 if i == 0 else 0.75)
				var flame := VFX.quad(target, "FireFlare", "flame", Vector2(height * 0.6, height),
					base + offset + Vector3.UP * height / 2.0, {"seed": randf() * 10.0, "intensity": 0.0, "speed": 2.5})
				flame.set_meta("vfx", true)
				VFX.animate(flame, "intensity", 0.0, 1.0, 0.08)
				VFX.animate(flame, "intensity", 1.0, 0.0, 0.6, 0.25)
				VFX.free_after(flame, 1.0)
		"cold":
			VFX.particles(target, "Frost", at, "shard", color, {"amount": int(8 + 8 * s), "lifetime": 0.7,
				"speed": Vector2(1.5, 3.0), "spread": 120.0, "gravity": -9.0, "scale": Vector2(0.06, 0.12)})
			_star(target, "FrostRing", at, 1.6, color, 6.0, 60.0, 0.85, 0.35)
		"lightning":  # jagged bolts crackling around the target
			for i in 3:
				var dir := Vector3(randf_range(-1.0, 1.0), randf_range(0.2, 1.0), randf_range(-1.0, 1.0)).normalized()
				var bolt := VFX.quad(target, "Bolt", "thrust", Vector2(1.0, 0.4), at + dir * 0.45,
					{"color": color, "progress": 1.0, "jag": 0.25, "seed": randf() * 50.0})
				bolt.set_meta("vfx", true)
				VFX.orient_along(bolt, dir)
				bolt.scale = Vector3(1.0 + 0.3 * s, 1.0, 1.0)
				VFX.animate(bolt, "fade", 1.0, 0.0, 0.2, 0.05 * i)
				VFX.free_after(bolt, 0.4)
		"thunder":
			_star(target, "Thunderclap", at, 2.0 + s, color, 16.0, 80.0, 0.85, 0.4)
		"acid":
			VFX.particles(target, "AcidDrops", at, "drop", color, {"amount": int(6 + 6 * s), "lifetime": 0.8,
				"speed": Vector2(0.8, 2.0), "spread": 70.0, "gravity": -9.0, "scale": Vector2(0.06, 0.1), "fixed_y": true})
		"poison":
			VFX.particles(target, "PoisonBurst", at, "bubble", color, {"amount": int(5 + 5 * s), "lifetime": 1.0,
				"speed": Vector2(0.3, 0.8), "gravity": 1.0, "scale": Vector2(0.06, 0.12), "radius": 0.25})
		"necrotic":
			var wisps := VFX.quad(target, "NecroticWisps", "haze", Vector2.ONE * 1.6, at,
				{"color": Color(0.25, 0.05, 0.35), "strength": 0.0, "speed": 1.2, "seed": randf() * 10.0})
			wisps.set_meta("vfx", true)
			VFX.animate(wisps, "strength", 0.0, 0.8, 0.1)
			VFX.animate(wisps, "strength", 0.8, 0.0, 0.7, 0.2)
			VFX.free_after(wisps, 1.0)
		"radiant":
			_star(target, "Rays", at, 1.8 + 0.6 * s, color, 14.0, 40.0, 0.0, 0.35)
		"psychic":
			for i in 2:
				_star(target, "Ripple", at + Vector3.UP * 0.3, 1.4 + 0.5 * i, color, 1.0, 500.0, 0.8, 0.45)
		"force":
			_star(target, "RingBurst", at, 1.7 + 0.5 * s, color, 1.0, 500.0, 0.8, 0.25)
