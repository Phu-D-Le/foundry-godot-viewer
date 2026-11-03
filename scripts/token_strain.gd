extends RefCounted
## The Strain bar above a token (the Overwhelmed module in Foundry): one segment per point of the threshold, filled
## orange (hot orange when one firearm hit would break it), all red while Overwhelmed. A boss shows its stage (I / II).
## The bar pulses while it's close to breaking, and flashes white while the double-damage hit is pending.
## Reaching a boss's first threshold, or being Overwhelmed, plays a stagger: a shake, a burst of shards and a shout.
## token_manager.gd calls apply() with the token's `strain` ({value, max, stage, boss, overwhelmed, pending, nearBreak},
## or null) on every token update, and reapply() after a visual rebuild.

const HitStyles = preload("res://scripts/hit_styles.gd")
const VFX = preload("res://scripts/vfx.gd")

const SEG := 24  # pixels per segment in the composed bar texture
const GAP := 4
const BAR_H := 20
const BORDER := 3
const ABOVE := 0.12  # meters above the top of the token (the status icon row sits above this)
const MIN_TOP := 0.3  # flat tokens and coins: still clear of the token art on the floor
const FILL := Color("e8a33c")
const HOT := Color("ff5a2a")
const OVERWHELMED := Color("d11f1f")
const STAGE2 := Color("b07cff")


static func apply(node: Node3D, strain: Variant) -> void:
	var bar := node.get_node_or_null("StrainBar") as Sprite3D
	if not (strain is Dictionary):
		if bar:
			node.remove_child(bar)
			bar.queue_free()
		node.remove_meta("strain_last")
		return
	var s: Dictionary = strain
	var value := int(s.get("value", 0))
	var max_value := maxi(1, int(s.get("max", 1)))
	var stage := int(s.get("stage", 1))
	var overwhelmed := bool(s.get("overwhelmed", false))
	var pending := bool(s.get("pending", false))
	var near := bool(s.get("nearBreak", false))
	var boss := bool(s.get("boss", false))

	# The stagger: a boss reaching its first threshold, or Overwhelmed starting
	var last: Dictionary = node.get_meta("strain_last", {})
	if not last.is_empty():
		if overwhelmed and not bool(last.get("overwhelmed", false)):
			stagger(node, "OVERWHELMED!", OVERWHELMED)
		elif boss and stage == 2 and int(last.get("stage", 1)) == 1 and not overwhelmed:
			stagger(node, "STAGGERED!", STAGE2)
	node.set_meta("strain_last", s.duplicate())

	if bar == null:
		bar = Sprite3D.new()
		bar.name = "StrainBar"
		bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		bar.no_depth_test = true
		bar.shaded = false
		bar.render_priority = 10
		node.add_child(bar)
		var badge := Label3D.new()
		badge.name = "Stage"
		badge.font_size = 64
		badge.pixel_size = 0.004
		badge.outline_size = 14
		badge.outline_modulate = Color(0, 0, 0, 0.9)
		badge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		badge.no_depth_test = true
		badge.render_priority = 11
		bar.add_child(badge)
	var key := "%d/%d/%d/%s/%s/%s" % [value, max_value, stage, overwhelmed, pending, near]
	if bar.get_meta("key", "") != key:
		bar.set_meta("key", key)
		bar.texture = ImageTexture.create_from_image(_draw(value, max_value, overwhelmed, pending, near))
	bar.set_meta("segments", max_value)
	bar.set_meta("value", value)
	var width_m := clampf(_footprint(node) * 1.8, 0.6, 2.4)
	bar.pixel_size = width_m / float(bar.texture.get_width())
	bar.position.y = maxf(_top(node), MIN_TOP) + ABOVE

	var badge: Label3D = bar.get_node("Stage")
	badge.visible = boss
	badge.text = "II" if stage == 2 else "I"
	badge.modulate = STAGE2 if stage == 2 else Color.WHITE
	badge.position = Vector3(-width_m / 2.0 - 0.1, 0.0, 0.0)

	_pulse(bar, near or pending, Color(1.6, 1.6, 1.6) if pending else Color(1.35, 1.0, 0.85))


## After the token's visual was rebuilt: the bar back on top of it.
static func reapply(node: Node3D) -> void:
	var bar := node.get_node_or_null("StrainBar") as Node3D
	if bar:
		bar.position.y = maxf(_top(node), MIN_TOP) + ABOVE


static func _draw(value: int, max_value: int, overwhelmed: bool, pending: bool, near: bool) -> Image:
	var w := max_value * SEG + (max_value - 1) * GAP + 2 * BORDER
	var h := BAR_H + 2 * BORDER
	var image := Image.create(w, h, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 0.95) if pending else Color(0, 0, 0, 0.8))
	image.fill_rect(Rect2i(BORDER - 1, BORDER - 1, w - 2 * BORDER + 2, h - 2 * BORDER + 2), Color(0, 0, 0, 0.8))
	var color := OVERWHELMED if overwhelmed else (HOT if near else FILL)
	for i in max_value:
		var filled := overwhelmed or i < value
		var x := BORDER + i * (SEG + GAP)
		image.fill_rect(Rect2i(x, BORDER, SEG, BAR_H), color if filled else Color(0.25, 0.25, 0.25, 0.6))
		if filled:  # a lighter top edge, so the segments read as little blocks
			image.fill_rect(Rect2i(x, BORDER, SEG, 4), color.lightened(0.35))
	return image


## A slow glow (close to breaking) or a white flash (the double-damage hit is pending).
static func _pulse(bar: Sprite3D, on: bool, bright: Color) -> void:
	var tween: Tween = bar.get_meta("pulse") if bar.has_meta("pulse") else null
	if on and bar.get_meta("pulse_color", Color.BLACK) == bright and tween and tween.is_valid():
		return
	if tween and tween.is_valid():
		tween.kill()
	bar.remove_meta("pulse")
	bar.modulate = Color.WHITE
	if not on:
		return
	tween = bar.create_tween().set_loops()
	tween.tween_property(bar, "modulate", bright, 0.45).set_trans(Tween.TRANS_SINE)
	tween.tween_property(bar, "modulate", Color.WHITE, 0.45).set_trans(Tween.TRANS_SINE)
	bar.set_meta("pulse", tween)
	bar.set_meta("pulse_color", bright)


## The token reels: a quick side-to-side shake, shards bursting from it, and a shout above its head.
static func stagger(node: Node3D, text: String, color: Color) -> void:
	var visual := node.get_node_or_null("Visual") as Node3D
	if visual and not node.has_meta("strain_shaking"):
		node.set_meta("strain_shaking", true)
		var home := visual.position
		var shake := visual.create_tween()
		for i in 6:
			var side := 0.07 * (1.0 - i / 6.0) * (1.0 if i % 2 == 0 else -1.0)
			shake.tween_property(visual, "position", home + Vector3(side, 0.0, 0.0), 0.05)
		shake.tween_property(visual, "position", home, 0.05)
		shake.finished.connect(func():
			if is_instance_valid(node):
				node.remove_meta("strain_shaking"))
	var top := maxf(_top(node), MIN_TOP)
	VFX.particles(node, "StrainBurst", node.global_position + Vector3.UP * top * 0.6, "shard", color.lightened(0.3),
		{"amount": 16, "lifetime": 0.7, "speed": Vector2(1.5, 3.5), "gravity": -6.0, "scale": Vector2(0.05, 0.1),
		"additive": true, "radius": 0.15})
	var old := node.get_node_or_null("StrainShout")
	if old:
		node.remove_child(old)
		old.queue_free()
	var shout := Label3D.new()
	shout.name = "StrainShout"
	shout.text = text
	shout.font_size = 90
	shout.pixel_size = 0.004
	shout.outline_size = 22
	shout.modulate = color.lightened(0.2)
	shout.outline_modulate = Color(0, 0, 0, 0.9)
	shout.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shout.no_depth_test = true
	shout.render_priority = 12
	shout.position.y = top + 0.6
	shout.scale = Vector3.ZERO
	node.add_child(shout)
	var tween := shout.create_tween()
	tween.tween_property(shout, "scale", Vector3.ONE * 1.2, 0.12).set_ease(Tween.EASE_OUT)
	tween.tween_property(shout, "scale", Vector3.ONE, 0.1)
	tween.tween_interval(1.1)
	tween.parallel().tween_property(shout, "position:y", top + 0.9, 1.1)
	tween.tween_property(shout, "modulate:a", 0.0, 0.35)
	tween.tween_callback(shout.queue_free)


## Top of the token's visual (meters above its base), 1 m while it's still loading. Stuck arrows don't count.
static func _top(node: Node3D) -> float:
	var visual := node.get_node_or_null("Visual")
	if visual == null:
		return 1.0
	var acc := [null]
	for child in visual.get_children():
		HitStyles._accumulate_aabb(child, Transform3D.IDENTITY, acc)
	return (acc[0] as AABB).end.y if acc[0] != null else 1.0


static func _footprint(node: Node3D) -> float:
	var ring := node.get_node_or_null("Ring") as MeshInstance3D
	return (ring.mesh as TorusMesh).outer_radius if ring and ring.mesh is TorusMesh else 0.5
