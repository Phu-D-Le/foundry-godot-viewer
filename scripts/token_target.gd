extends RefCounted
## Foundry's target markers on a token (Token#_drawTargetArrows / _drawTargetPips, client/canvas/placeables/token.mjs),
## laid on the floor around its footprint:
##   arrows: you target it. Four filled right triangles just outside the footprint's corners (legs 0.15 of a grid
##           cell, along the edges), in Foundry's border color for this client (token.borderColor: orange when it's
##           yours, else its disposition color), outlined in black; a slow pulse so they read in 3D.
##   pips:   one disc per other user targeting it, in their color, outlined in black, along the footprint's top
##           (north) edge in Foundry's alternating order.
## Data: token.targets [{id, color, self}] and token.borderColor (serialize.js serializeTargets).

const SceneInfo = preload("res://scripts/scene_info.gd")
const HOLDER := "Target"
const ARROW := 0.15      ## leg length, x a grid cell (CONFIG.Canvas.targeting.size)
const BORDER := 0.025    ## outline width, x a grid cell (Foundry: 2 px at grid 100)
const PIP := 0.06        ## pip radius, x a grid cell (6 px at grid 100)
const PIP_STEP := 0.16   ## pip spacing, x a grid cell (16 px)
const HEIGHT := 0.06     ## above the token's base, over the floor and the ring
## Foundry's disposition colors (CONFIG.Canvas.dispositionColors), for data without a borderColor
const CONTROLLED := Color("ff9829")
const DISPOSITION := {-2: Color("a612d4"), -1: Color("e72124"), 0: Color("f1d836"), 1: Color("43dfdf")}


## Show the markers `t` asks for on the token `node` (rebuilt only when they change; none: removed).
static func apply(node: Node3D, t: Dictionary, info: SceneInfo) -> void:
	var targets: Array = t.get("targets", []) if t.get("targets") is Array else []
	var mine := targets.any(func(u): return u is Dictionary and u.get("self", false))
	var others := targets.filter(func(u): return u is Dictionary and not u.get("self", false))
	var cell := info.grid_m if info else 1.5
	var w := info.px_to_m(float(t.get("widthPx", 100))) if info else cell
	var h := info.px_to_m(float(t.get("heightPx", 100))) if info else cell
	var color := border_color(t)
	var key := JSON.stringify([mine, others.map(func(u): return str(u.get("color", ""))), color.to_html(), w, h, cell])
	var existing := node.get_node_or_null(HOLDER)
	if existing and existing.get_meta("key", "") == key:
		return
	if existing:
		node.remove_child(existing)
		existing.queue_free()
	if not mine and others.is_empty():
		return
	var holder := Node3D.new()
	holder.name = HOLDER
	holder.set_meta("key", key)
	holder.position.y = HEIGHT
	node.add_child(holder)
	if mine:
		var arrows := Node3D.new()
		arrows.name = "Arrows"
		holder.add_child(arrows)
		var l := ARROW * cell
		var b := BORDER * cell
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var a := Vector2(corner.x * w / 2.0, corner.y * h / 2.0)
			var u := Vector2(corner.x, 0.0)
			var v := Vector2(0.0, corner.y)
			# The black outline: the same triangle grown by `b` on every side, drawn first
			var a_out := a - (u + v) * b
			var grown := l + b * (2.0 + sqrt(2.0))
			arrows.add_child(_triangle([a_out, a_out + u * grown, a_out + v * grown], Color.BLACK, 10))
			arrows.add_child(_triangle([a, a + u * l, a + v * l], color, 11))
		var tween := arrows.create_tween().set_loops()
		tween.tween_property(arrows, "scale", Vector3(1.08, 1.0, 1.08), 0.6).set_trans(Tween.TRANS_SINE)
		tween.tween_property(arrows, "scale", Vector3.ONE, 0.6).set_trans(Tween.TRANS_SINE)
	var even := others.size() % 2 == 0
	for i in others.size():
		var sign := 1.0 if i % 2 == 0 else -1.0
		var x := (0.5 * PIP_STEP if even else 0.0) + sign * floorf((i + 1) / 2.0) * PIP_STEP
		var pip := Node3D.new()
		pip.name = "Pip%d" % i
		pip.position = Vector3(x * cell, 0.0, -h / 2.0)
		holder.add_child(pip)
		pip.add_child(_disc((PIP + BORDER) * cell, Color.BLACK, 10))
		pip.add_child(_disc(PIP * cell, Color.from_string(str(others[i].get("color", "#ffffff")), Color.WHITE), 11))


## Foundry's border color for this client: token.borderColor, else orange for your own token, else the
## disposition color.
static func border_color(t: Dictionary) -> Color:
	var given = t.get("borderColor")
	if given is String and given != "":
		return Color.from_string(given, CONTROLLED)
	if t.get("owner", false):
		return CONTROLLED
	return DISPOSITION.get(int(t.get("disposition", 0)), Color.WHITE)


## A flat triangle on the floor (points are x, z), drawn on top of everything.
static func _triangle(points: Array, color: Color, priority: int) -> MeshInstance3D:
	var verts := PackedVector3Array()
	for p in points:
		verts.append(Vector3(p.x, 0.0, p.y))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = _flat(color, priority)
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return inst


static func _disc(radius: float, color: Color, priority: int) -> MeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.005
	cyl.radial_segments = 24
	cyl.rings = 1
	var inst := MeshInstance3D.new()
	inst.mesh = cyl
	inst.material_override = _flat(color, priority)
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return inst


static func _flat(color: Color, priority: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = priority
	return mat
