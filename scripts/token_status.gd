extends RefCounted
## Status effects on a token (Foundry conditions and effects): a row of their icons above it, and looks for the
## big conditions. token_manager.gd calls apply() on every token update and reapply() after a visual rebuild.
##   prone, unconscious - lies down, smoothly (billboards turn 90 degrees in the view; flat and coin tokens
##                        already lie flat). Unconscious tokens are also grayed out (token_manager.gd).
##   ethereal     - a pale, wavering, see-through ghost (hit_reaction.gd GHOST_SHADER)
##   invisible    - nearly gone: bends what's behind it like heat haze, a faint shimmering outline
##   burning      - flame tongues licking up around the body, embers
##   bleeding, bloodied - drops of blood run down and fall, splatting on the floor (bloodied: fewer)
##   poisoned, diseased - bubbles rise and pop in a thin green fume (diseased: sickly yellow-green)
##   cursed       - a swirling purple haze around the token
##   surprised    - a red "!?" above the head
##   poisoned, diseased, paralyzed, petrified - tinted (green, sickly, ice blue, stone)
##   frightened   - trembles
##   stunned      - stars circling above the head
##   concentrating - a thin pulsing second ring at the feet

const HitReaction = preload("res://scripts/hit_reaction.gd")
const HitStyles = preload("res://scripts/hit_styles.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const VFX = preload("res://scripts/vfx.gd")

const ICON_SIZE := 0.3  # meters per icon in the row above the token
const ICON_CELL := 64  # pixels per icon in the composed row texture
const ICON_GAP := 8
const PRONE_TILT := -75.0  # degrees, lying back (non-billboard styles)
const LIE_TIME := 0.5
const SURPRISE_HEIGHT := 1.0  # the "!?" above the head, clear of the icon row
const LYING := ["prone", "unconscious"]
## Condition colors for the surfaces' status_tint (a = amount). Earlier entries win.
const TINTS := [
	["petrified", Color(0.78, 0.74, 0.68, 0.9)],
	["paralyzed", Color(0.6, 0.85, 1.0, 0.45)],
	["poisoned", Color(0.45, 1.0, 0.35, 0.3)],
	["diseased", Color(0.7, 0.85, 0.3, 0.3)],
]
const BLOOD := Color(0.5, 0.02, 0.03)
## Seconds between drops: [min, max]
const BLEED_RATES := {"bleeding": Vector2(0.45, 0.85), "bloodied": Vector2(1.2, 2.0)}


## Show the token's `statuses` (status ids, e.g. "prone") and `effects` ([{id, name, img}], the icons).
static func apply(node: Node3D, statuses: Array, effects: Array, loader: Node, style: String) -> void:
	node.set_meta("status", {"statuses": statuses, "effects": effects, "style": style})
	_looks(node)
	_icons(node, effects, loader)


## After the token's visual was rebuilt: the looks again, on the new surfaces.
static func reapply(node: Node3D) -> void:
	if node.has_meta("status"):
		_looks(node)
		for name in ["StatusIcons", "Surprised"]:
			var above := node.get_node_or_null(name) as Node3D
			if above:
				above.position.y = _top(node) + (0.35 if name == "StatusIcons" else SURPRISE_HEIGHT)


static func _looks(node: Node3D) -> void:
	var st: Dictionary = node.get_meta("status")
	var statuses: Array = st.statuses
	var fx := HitReaction.surfaces(node)
	var tint := Color(1, 1, 1, 0)
	for entry in TINTS:
		if entry[0] in statuses:
			tint = entry[1]
			break
	HitReaction.set_status_tint(fx, tint)
	HitReaction.set_ghost(fx, 2 if "invisible" in statuses else (1 if "ethereal" in statuses else 0))
	_tremble(node, "frightened" in statuses)
	_lie(node, LYING.any(func(id): return id in statuses))
	_flames(node, "burning" in statuses)
	var bleed := ""
	for id in BLEED_RATES:
		if id in statuses:
			bleed = id
			break
	_bleed(node, bleed)
	_bubbles(node, "poisoned" if "poisoned" in statuses else ("diseased" if "diseased" in statuses else ""))
	_curse(node, "cursed" in statuses)
	_surprised(node, "surprised" in statuses)
	_stars(node, "stunned" in statuses)
	_concentration(node, "concentrating" in statuses)


## Lie down (1) or stand up (0), smoothly.
static func _lie(node: Node3D, on: bool) -> void:
	var target := 1.0 if on else 0.0
	if is_equal_approx(float(node.get_meta("lie_target", 0.0)), target):
		_pose(node)
		return
	node.set_meta("lie_target", target)
	var previous: Tween = node.get_meta("lie_tween") if node.has_meta("lie_tween") else null
	if previous and previous.is_valid():
		previous.kill()
	var step := func(v: float) -> void:
		node.set_meta("lie", v)
		_pose(node)
	var tween := node.create_tween()
	tween.tween_method(step, float(node.get_meta("lie", 0.0)), target, LIE_TIME) \
		.set_trans(Tween.TRANS_BACK if on else Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	node.set_meta("lie_tween", tween)


## Lying and trembling. Billboards are turned by their shader (roll); other styles by the Visual node.
static func _pose(node: Node3D, wobble := 0.0) -> void:
	if wobble == 0.0 and node.has_meta("wobble"):
		wobble = node.get_meta("wobble")
	var st: Dictionary = node.get_meta("status", {})
	var style: String = st.get("style", "")
	var lie: float = node.get_meta("lie", 0.0)
	var visual: Node3D = node.get_node("Visual")
	var fx := HitReaction.surfaces(node)
	var billboard: MeshInstance3D = null
	for image in fx.images:
		if (image.mat as ShaderMaterial).get_shader_parameter("billboard"):
			billboard = image.nodes[0]
	if billboard and is_instance_valid(billboard):
		HitReaction.set_roll(fx, lie * PI / 2.0 + wobble)
		if not billboard.has_meta("stand_y"):
			billboard.set_meta("stand_y", billboard.position.y)
		var size: Vector2 = (billboard.mesh as QuadMesh).size
		var lying_y := VisualBuilder.CLEARANCE + size.x * absf(billboard.scale.x) / 2.0
		billboard.position.y = lerpf(float(billboard.get_meta("stand_y")), lying_y, lie)
		visual.rotation.x = 0.0
		visual.rotation.z = 0.0
	else:
		visual.rotation.x = deg_to_rad(PRONE_TILT) * lie if not style in ["flat", "coin"] else 0.0
		visual.rotation.z = wobble


static func _tremble(node: Node3D, on: bool) -> void:
	var running: Tween = node.get_meta("tremble_tween") if node.has_meta("tremble_tween") else null
	if on == (running != null and running.is_valid()):
		return
	if running:
		running.kill()
		node.remove_meta("tremble_tween")
		node.remove_meta("wobble")
		_pose(node)
		return
	var shiver := func(t: float) -> void:
		var wobble := deg_to_rad(3.0) * sin(t * TAU * 9.0) * (0.6 + 0.4 * sin(t * TAU * 2.3))
		node.set_meta("wobble", wobble)
		_pose(node, wobble)
	var tween := node.create_tween().set_loops()
	tween.tween_method(shiver, 0.0, 1.0, 1.0)
	node.set_meta("tremble_tween", tween)


## Fanning flames: tongues of fire at staggered heights and phases around the body, a few embers.
static func _flames(node: Node3D, on: bool) -> void:
	if _toggle(node, "Burning", on) == null:
		return
	var holder: Node3D = node.get_node("Burning")
	var top := _top(node)
	var radius := _footprint(node) * 0.35
	for i in 4:
		var angle := TAU * i / 4.0 + 0.4
		var height := top * (1.0 if i % 2 == 0 else 0.75) + 0.3
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * radius * (0.6 if i % 2 else 1.0)
		var flame := VFX.quad(holder, "Flame%d" % i, "flame", Vector2(height * 0.6, height),
			node.global_position + offset + Vector3.UP * height * 0.5,
			{"seed": i * 3.7, "speed": 1.4 + 0.3 * i, "intensity": 0.9})
		flame.set_meta("vfx", true)
	VFX.particles(holder, "Embers", node.global_position + Vector3.UP * top * 0.5, "dot", Color(1.0, 0.6, 0.2),
		{"amount": 8, "lifetime": 1.2, "one_shot": false, "spread": 25.0, "speed": Vector2(0.3, 0.7), "gravity": 1.2,
		"scale": Vector2(0.02, 0.04), "additive": true, "radius": radius})


## Blood: drops run down the body and fall, splatting on the floor. `kind`: "bleeding", "bloodied" or "".
static func _bleed(node: Node3D, kind: String) -> void:
	var timer := node.get_node_or_null("Bleed") as Timer
	if timer and timer.get_meta("kind") == kind:
		return
	if timer:
		timer.queue_free()
		node.remove_child(timer)
	if kind == "":
		return
	var rate: Vector2 = BLEED_RATES[kind]
	timer = Timer.new()
	timer.name = "Bleed"
	timer.set_meta("kind", kind)
	timer.wait_time = rate.x * 0.5
	timer.one_shot = false
	timer.timeout.connect(func() -> void:
		timer.wait_time = randf_range(rate.x, rate.y)
		_drop(node))
	node.add_child(timer)
	timer.start()


static func _drop(node: Node3D) -> void:
	var start := node.global_position + _front_offset(node, 0.18) + Vector3.UP * _top(node) * randf_range(0.45, 0.75)
	var drop := MeshInstance3D.new()
	drop.name = "BloodDrop"
	drop.set_meta("vfx", true)
	var quad := QuadMesh.new()
	quad.size = Vector2(0.045, 0.09)
	drop.mesh = quad
	drop.material_override = _blood_material(BaseMaterial3D.BILLBOARD_FIXED_Y)
	drop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(drop)
	drop.global_position = start
	var floor_y := node.global_position.y + 0.02
	var fall := sqrt(2.0 * maxf(start.y - 0.05 - floor_y, 0.01) / 9.8)
	var tween := drop.create_tween()
	tween.tween_property(drop, "global_position:y", start.y - 0.05, 0.4).set_ease(Tween.EASE_IN_OUT)  # runs down
	tween.tween_property(drop, "global_position:y", floor_y + 0.04, fall).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(drop, "scale", Vector3(0.8, 1.6, 1.0), fall)  # stretches as it falls
	tween.tween_callback(func() -> void:
		_splat(node, Vector3(drop.global_position.x, floor_y, drop.global_position.z))
		drop.queue_free())


static func _splat(node: Node3D, at: Vector3) -> void:
	if not is_instance_valid(node):
		return
	var splat := MeshInstance3D.new()
	splat.name = "BloodSplat"
	splat.set_meta("vfx", true)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * randf_range(0.1, 0.18)
	splat.mesh = quad
	var mat := _blood_material(BaseMaterial3D.BILLBOARD_DISABLED, "splat")
	splat.material_override = mat
	splat.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(splat)
	splat.global_position = at
	splat.global_basis = Basis(Vector3.UP, randf() * TAU) * Basis(Vector3.RIGHT, -PI / 2.0)
	splat.scale = Vector3.ONE * 0.4
	var tween := splat.create_tween()
	tween.tween_property(splat, "scale", Vector3.ONE, 0.1).set_ease(Tween.EASE_OUT)
	tween.tween_interval(1.4)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.8)
	tween.tween_callback(splat.queue_free)


static func _blood_material(billboard: BaseMaterial3D.BillboardMode, texture := "drop") -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = billboard
	mat.billboard_keep_scale = true
	mat.albedo_texture = VFX.texture_named(texture)
	mat.albedo_color = BLOOD
	return mat


## Poison: bubbles rise from the body, wobble and pop, in a thin fume. `kind`: "poisoned", "diseased" or "".
static func _bubbles(node: Node3D, kind: String) -> void:
	var timer := node.get_node_or_null("Bubbles") as Timer
	if timer and timer.get_meta("kind") == kind:
		return
	if timer:
		node.remove_child(timer)
		timer.queue_free()
	var fumes := node.get_node_or_null("PoisonFumes")
	if fumes:
		node.remove_child(fumes)
		fumes.queue_free()
	if kind == "":
		return
	var color := Color(0.45, 0.95, 0.3) if kind == "poisoned" else Color(0.75, 0.85, 0.3)
	timer = Timer.new()
	timer.name = "Bubbles"
	timer.set_meta("kind", kind)
	timer.wait_time = 0.2
	timer.timeout.connect(func() -> void:
		timer.wait_time = randf_range(0.3, 0.6)
		_bubble(node, color))
	node.add_child(timer)
	timer.start()
	var haze := VFX.quad(node, "PoisonFumes", "haze", Vector2.ONE * _footprint(node) * 1.8,
		node.global_position + Vector3.UP * _top(node) * 0.45,
		{"color": color * 0.7, "strength": 0.3, "speed": 0.2, "seed": randf() * 10.0})
	haze.set_meta("vfx", true)


static func _bubble(node: Node3D, color: Color) -> void:
	var bubble := MeshInstance3D.new()
	bubble.name = "PoisonBubble"
	bubble.set_meta("vfx", true)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * randf_range(0.06, 0.12)
	bubble.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.albedo_texture = VFX.texture_named("bubble")
	mat.albedo_color = Color(color, 0.9)
	bubble.material_override = mat
	bubble.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(bubble)
	var start := node.global_position + _front_offset(node, 0.25) + Vector3.UP * _top(node) * randf_range(0.2, 0.8)
	bubble.global_position = start
	var phase := randf() * TAU
	var rise := func(t: float) -> void:
		bubble.global_position = start + Vector3(sin(t * 9.0 + phase) * 0.03, t * 0.4, 0.0)
	var tween := bubble.create_tween()
	tween.tween_method(rise, 0.0, 1.0, randf_range(0.8, 1.2))
	tween.tween_property(bubble, "scale", Vector3.ONE * 1.8, 0.1)  # pop
	tween.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.1)
	tween.tween_callback(bubble.queue_free)


## Cursed: two swirling purple hazes turning against each other, dark motes rising.
static func _curse(node: Node3D, on: bool) -> void:
	if _toggle(node, "Curse", on) == null:
		return
	var holder: Node3D = node.get_node("Curse")
	var size := _footprint(node) * 2.2
	var chest := node.global_position + Vector3.UP * _top(node) * 0.5
	for i in 2:
		var haze := VFX.quad(holder, "CurseHaze" if i == 0 else "CurseHaze2", "haze", Vector2.ONE * size * (1.0 - 0.2 * i),
			chest + Vector3.UP * 0.1 * i, {"color": Color(0.45, 0.12, 0.65), "strength": 0.6,
			"speed": 0.35 if i == 0 else -0.25, "seed": 4.0 * i})
		haze.set_meta("vfx", true)
	VFX.particles(holder, "CurseMotes", chest, "dot", Color(0.35, 0.1, 0.5, 0.8), {"amount": 6, "lifetime": 1.6,
		"one_shot": false, "spread": 30.0, "speed": Vector2(0.1, 0.3), "gravity": 0.4, "scale": Vector2(0.04, 0.07),
		"radius": size * 0.3})


## Surprised: a red "!?" pops up above the head and bobs.
static func _surprised(node: Node3D, on: bool) -> void:
	var existing := node.get_node_or_null("Surprised")
	if on == (existing != null):
		return
	if existing:
		existing.queue_free()
		node.remove_child(existing)
		return
	var label := Label3D.new()
	label.name = "Surprised"
	label.text = "!?"
	label.font_size = 110
	label.pixel_size = 0.008
	label.outline_size = 24
	label.modulate = Color("ff2626")
	label.outline_modulate = Color(0, 0, 0, 0.9)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 11
	var y := _top(node) + SURPRISE_HEIGHT
	label.position.y = y
	label.scale = Vector3.ZERO
	node.add_child(label)
	var pop := label.create_tween()
	pop.tween_property(label, "scale", Vector3.ONE * 1.25, 0.12).set_ease(Tween.EASE_OUT)
	pop.tween_property(label, "scale", Vector3.ONE, 0.1)
	var bob := label.create_tween().set_loops()
	bob.tween_property(label, "position:y", y + 0.06, 0.6).set_trans(Tween.TRANS_SINE)
	bob.tween_property(label, "position:y", y, 0.6).set_trans(Tween.TRANS_SINE)


## Three little stars circling above the head.
static func _stars(node: Node3D, on: bool) -> void:
	if _toggle(node, "Stars", on) == null:
		return
	var stars: Node3D = node.get_node("Stars")
	stars.position.y = _top(node) + 0.1
	for i in 3:
		var star := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.16, 0.16)
		quad.material = HitReaction.spark_quad().material.duplicate()
		quad.material.albedo_color = Color(1.0, 0.9, 0.3)
		quad.material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		star.mesh = quad
		star.position = Vector3(cos(TAU * i / 3.0), 0.0, sin(TAU * i / 3.0)) * 0.3
		stars.add_child(star)
	var tween := stars.create_tween().set_loops()
	tween.tween_property(stars, "rotation:y", TAU, 1.2).from(0.0)


## A thin glowing ring just outside the disposition ring, slowly pulsing.
static func _concentration(node: Node3D, on: bool) -> void:
	var existing := node.get_node_or_null("ConcentrationRing")
	if on == (existing != null):
		return
	if existing:
		existing.queue_free()
		node.remove_child(existing)
		return
	var radius := _footprint(node) + 0.08
	var ring := MeshInstance3D.new()
	ring.name = "ConcentrationRing"
	var torus := TorusMesh.new()
	torus.inner_radius = radius - 0.015
	torus.outer_radius = radius + 0.015
	torus.rings = 48
	torus.ring_segments = 6
	ring.mesh = torus
	ring.position.y = 0.05
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.55, 0.85, 1.0)
	ring.material_override = mat
	node.add_child(ring)
	var tween := ring.create_tween().set_loops()
	tween.tween_property(ring, "scale", Vector3.ONE * 1.06, 0.8).set_trans(Tween.TRANS_SINE)
	tween.tween_property(ring, "scale", Vector3.ONE, 0.8).set_trans(Tween.TRANS_SINE)


## Add (on) or free (off) an empty holder child named `name`. Returns the new holder, or null when nothing
## needs building (it's already there, or it was removed).
static func _toggle(node: Node3D, name: String, on: bool) -> Node3D:
	var existing := node.get_node_or_null(name)
	if on == (existing != null):
		return null
	if existing:
		node.remove_child(existing)
		existing.queue_free()
		return null
	var holder := Node3D.new()
	holder.name = name
	node.add_child(holder)
	return holder


## The effect icons in one row (one billboard sprite, composed when the set of effects changes).
static func _icons(node: Node3D, effects: Array, loader: Node) -> void:
	var key := ",".join(effects.map(func(e): return "%s|%s" % [e.get("id", ""), e.get("img", "")]))
	if node.get_meta("icons_key", "") == key:
		return
	node.set_meta("icons_key", key)
	var images: Array[Image] = []
	for e in effects:
		var texture: Texture2D = await loader.fetch_texture(str(e.get("img", ""))) if e.get("img") is String else null
		if not is_instance_valid(node) or node.get_meta("icons_key", "") != key:
			return  # changed again meanwhile
		if texture:
			images.append(texture.get_image())
	var old := node.get_node_or_null("StatusIcons")
	if old:
		node.remove_child(old)
		old.queue_free()
	if images.is_empty():
		return
	var row := Image.create(images.size() * ICON_CELL + (images.size() - 1) * ICON_GAP, ICON_CELL, false,
		Image.FORMAT_RGBA8)
	for i in images.size():
		var icon := images[i].duplicate() as Image
		if icon.is_compressed():
			icon.decompress()
		icon.convert(Image.FORMAT_RGBA8)
		icon.resize(ICON_CELL - 8, ICON_CELL - 8)
		_whiten_if_monochrome(icon)
		var x := i * (ICON_CELL + ICON_GAP)
		row.fill_rect(Rect2i(x, 0, ICON_CELL, ICON_CELL), Color(0, 0, 0, 0.75))  # dark backing, readable anywhere
		row.blend_rect(icon, Rect2i(Vector2i.ZERO, icon.get_size()), Vector2i(x + 4, 4))
	var sprite := Sprite3D.new()
	sprite.name = "StatusIcons"
	sprite.texture = ImageTexture.create_from_image(row)
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.no_depth_test = true
	sprite.shaded = false
	sprite.pixel_size = ICON_SIZE / ICON_CELL
	sprite.render_priority = 10
	sprite.set_meta("count", images.size())
	sprite.position.y = _top(node) + 0.35
	node.add_child(sprite)


## Foundry's status icons are single-color SVG shapes with no fill (they load black) that Foundry tints white on
## its canvas: draw those white and fully opaque, keeping their shape. Colored icons keep their colors.
static func _whiten_if_monochrome(icon: Image) -> void:
	var colorful := 0
	var opaque := 0
	for y in icon.get_height():
		for x in icon.get_width():
			var c := icon.get_pixel(x, y)
			if c.a > 0.5:
				opaque += 1
				if c.s > 0.25 and c.v > 0.15:
					colorful += 1
	if opaque == 0 or colorful > opaque * 0.1:
		return
	for y in icon.get_height():
		for x in icon.get_width():
			var a := icon.get_pixel(x, y).a
			icon.set_pixel(x, y, Color(1, 1, 1, clampf(a * 1.4, 0.0, 1.0)))


## Top of the token's visual (meters above its base), 1 m while it's still loading. Stuck arrows don't count.
static func _top(node: Node3D) -> float:
	var acc := [null]
	for child in node.get_node("Visual").get_children():
		HitStyles._accumulate_aabb(child, Transform3D.IDENTITY, acc)
	return (acc[0] as AABB).end.y if acc[0] != null else 1.0


## Radius of the token's disposition ring.
static func _footprint(node: Node3D) -> float:
	return ((node.get_node("Ring") as MeshInstance3D).mesh as TorusMesh).outer_radius


## A random spot on the camera's side of the token (so drops and bubbles show in front), `spread` x footprint.
static func _front_offset(node: Node3D, spread: float) -> Vector3:
	var camera := node.get_viewport().get_camera_3d()
	var toward := Vector3.BACK
	if camera:
		toward = camera.global_position - node.global_position
		toward.y = 0.0
		toward = toward.normalized() if toward.length() > 0.001 else Vector3.BACK
	var across := toward.cross(Vector3.UP)
	var r := _footprint(node)
	return toward * r * spread + across * r * randf_range(-0.6, 0.6)
