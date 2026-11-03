extends RefCounted
## Generates the static 3D level (floors + walls + doors) from a Foundry scene snapshot.
##
## Node layout (also what a hand-edited manual level must keep for doors to keep working):
##   Level
##     Floors/Floor_<levelId>        MeshInstance3D, meta foundry_level_id
##     Walls/Wall_<wallId>           Node3D at the wall's first endpoint, meta foundry_wall_id
##       Swing_<wallId>              what opens and closes (a door), or just holds the wall
##         Segment_<levelId>_<wallId> MeshInstance3D box, meta foundry_level_id (walls)
##         Panel0 / Panel1           doors: one pivot per door leaf (two for a double door), at its hinge
##           Segment_<levelId>_<wallId>[_B]   (or middle), holding the leaf's segments
## A manual level may only have Swing_<wallId>; then that whole node opens (see set_door_state).
## Names are unique because glTF (.glb, used to publish levels) renames duplicate node names.

const SceneInfo = preload("res://scripts/scene_info.gd")
const LightManager = preload("res://scripts/light_manager.gd")
const OcclusionCutter = preload("res://scripts/occlusion_cutter.gd")

const WALL_THICKNESS := 0.15  # meters

# CONST.WALL_SENSE_TYPES / WALL_DOOR_TYPES / WALL_DOOR_STATES in Foundry
const SENSE_NONE := 0
const SENSE_NORMAL := 20
const DOOR_NONE := 0
const DOOR_SECRET := 2
const DOOR_STATE_OPEN := 1
const DOOR_TYPES := ["ascend", "descend", "slide", "swing", "swivel"]  # CONFIG.Wall.animationTypes
const MIDPOINT_TYPES := ["ascend", "descend", "swivel"]  # pivot at the leaf's middle (midpoint: true)

static var _wall_material: StandardMaterial3D
static var _door_material: StandardMaterial3D
static var _window_material: StandardMaterial3D


static func build_level(info: SceneInfo, walls: Array) -> Node3D:
	var root := Node3D.new()
	root.name = "Level"
	var floors := Node3D.new()
	floors.name = "Floors"
	root.add_child(floors)
	var wall_root := Node3D.new()
	wall_root.name = "Walls"
	root.add_child(wall_root)

	for lv in info.levels:
		floors.add_child(build_floor(info, lv))
	for w in walls:
		var node := build_wall(info, w)
		if node:
			wall_root.add_child(node)
	return root


static func build_floor(info: SceneInfo, lv: Dictionary) -> MeshInstance3D:
	var size := info.size_m()
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.name = "Floor_" + lv.id
	floor_mesh.set_meta("foundry_level_id", lv.id)
	var mesh := PlaneMesh.new()
	mesh.size = size
	floor_mesh.mesh = mesh
	floor_mesh.position = Vector3(
		size.x / 2.0 + info.px_to_m(float(lv.get("offsetX", 0))),
		info.units_to_m(float(lv.bottom)),
		size.y / 2.0 + info.px_to_m(float(lv.get("offsetY", 0))))
	var mat := _new_floor_material()
	mat.set_shader_parameter("floor_color", Color.from_string(str(lv.get("color", "#999999")), Color.GRAY))
	floor_mesh.material_override = mat
	return floor_mesh


## The map: lit evenly under a light like Foundry (LightManager.FLAT_LIGHT), not dimmer toward its edge.
## Upper floors usually have transparent areas (e.g. open air over the ground floor): alpha scissor.
const FLOOR_SHADER := """
shader_type spatial;
render_mode cull_back;
uniform sampler2D map_tex : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 floor_color : source_color = vec4(1.0);
uniform bool has_map = false;
// occlusion_cutter.gd: holes around tokens under an upper floor
//SEE_CUT_GLSL
void fragment() {
	vec4 c = has_map ? texture(map_tex, UV) : floor_color;
	ALBEDO = c.rgb;
	ROUGHNESS = 0.95;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
//SEE_CUT_APPLY
}
%s
"""

static var _floor_shader: Shader


static func _new_floor_material() -> ShaderMaterial:
	if _floor_shader == null:
		_floor_shader = Shader.new()
		_floor_shader.code = (FLOOR_SHADER % LightManager.FLAT_LIGHT).replace("//SEE_CUT_GLSL", OcclusionCutter.CUT_GLSL) 			.replace("//SEE_CUT_APPLY", OcclusionCutter.CUT_APPLY)
	var mat := ShaderMaterial.new()
	mat.shader = _floor_shader
	return mat


## Applies a downloaded map image to a floor created by build_floor (or kept in a manual level).
static func set_floor_texture(floor_mesh: MeshInstance3D, texture: Texture2D) -> void:
	var mat := floor_mesh.material_override as ShaderMaterial
	if mat == null or mat.shader != _floor_shader:
		mat = _new_floor_material()
		floor_mesh.material_override = mat
	mat.set_shader_parameter("map_tex", texture)
	mat.set_shader_parameter("has_map", true)


## Levels loaded from a .glb lose node metadata; recover it from the node naming convention above.
static func rehydrate(root: Node) -> void:
	for node in root.find_children("*", "Node3D", true, false):
		var node_name := String(node.name)
		if node_name.begins_with("Wall_"):
			node.set_meta("foundry_wall_id", node_name.trim_prefix("Wall_"))
		elif node_name.begins_with("Floor_"):
			node.set_meta("foundry_level_id", node_name.trim_prefix("Floor_"))
		elif node_name.begins_with("Panel") and node_name.trim_prefix("Panel").is_valid_int():
			node.set_meta("leaf", int(node_name.trim_prefix("Panel")))  # second half of a double door
		elif node_name.begins_with("Segment_"):
			node.set_meta("foundry_level_id", node_name.trim_prefix("Segment_").get_slice("_", 0))


## Everything about a wall except its door state; if this changes the wall must be rebuilt.
static func geometry_signature(w: Dictionary) -> String:
	var anim := door_animation(w) if int(w.get("door", 0)) != DOOR_NONE else {}
	return JSON.stringify([w.c, w.get("levels", []), w.sight, w.get("light"), w.door, anim.get("double"), anim.get("type"),
		anim.get("texture"), anim.get("flip")])


static func build_wall(info: SceneInfo, w: Dictionary) -> Node3D:
	var sight := int(w.sight)
	if sight == SENSE_NONE:
		return null  # invisible walls only block movement; nothing to draw
	var c: Array = w.c
	var p0 := info.to_3d(c[0], c[1])
	var p1 := info.to_3d(c[2], c[3])
	var flat := Vector2(p1.x - p0.x, p1.z - p0.z)
	var length := flat.length()
	if length < 0.01:
		return null

	var node := Node3D.new()
	node.name = "Wall_" + w.id
	node.set_meta("foundry_wall_id", w.id)
	node.set_meta("foundry_signature", geometry_signature(w))
	node.position = p0
	node.rotation.y = atan2(-flat.y, flat.x)  # local +X points from p0 to p1
	var swing := Node3D.new()
	swing.name = "Swing_" + w.id
	node.add_child(swing)

	var door := int(w.door)
	var material := _material_for(sight, door)
	var spans := info.wall_spans(w.get("levels", []))
	if door == DOOR_NONE:
		for span in spans:
			var segment := MeshInstance3D.new()
			segment.name = "Segment_%s_%s" % [span[2], w.id]
			segment.set_meta("foundry_level_id", span[2])
			var box := BoxMesh.new()
			box.size = Vector3(length, span[1], WALL_THICKNESS)
			segment.mesh = box
			segment.position = Vector3(length / 2.0, span[0] + span[1] / 2.0, 0.0)
			segment.material_override = material
			swing.add_child(segment)
		return node

	# Door leaves: one, or two halves for a double door, each on a pivot where Foundry pivots it
	# (door-mesh.mjs #getClosedPosition): the hinge end for swing / slide, the middle otherwise.
	var anim := door_animation(w)
	var leaves := 2 if anim.double else 1
	var leaf_length := length / leaves
	var midpoint: bool = anim.type in MIDPOINT_TYPES
	var bottom := INF
	var top := -INF
	for i in leaves:
		var start := leaf_length * i
		var pivot := start + leaf_length / 2.0 if midpoint else (start if i == 0 else length)
		var panel := Node3D.new()
		panel.name = "Panel%d" % i
		panel.position = Vector3(pivot, 0.0, 0.0)
		panel.set_meta("leaf", i)
		swing.add_child(panel)
		for span in spans:
			var segment := MeshInstance3D.new()
			segment.name = "Segment_%s_%s%s" % [span[2], w.id, "_B" if i == 1 else ""]
			segment.set_meta("foundry_level_id", span[2])
			segment.mesh = _leaf_mesh(leaf_length, span[1], WALL_THICKNESS, i == 1)
			segment.position = Vector3(start + leaf_length / 2.0 - pivot, span[0] + span[1] / 2.0, 0.0)
			segment.material_override = material
			panel.add_child(segment)
			bottom = minf(bottom, span[0])
			top = maxf(top, span[0] + span[1])
	node.set_meta("foundry_door", door)
	node.set_meta("door_length", length)
	node.set_meta("door_height", maxf(top - bottom, 0.1))
	set_door_state(node, int(w.ds), false, anim)
	return node


## The node that rotates when a door opens (named "Swing" in levels saved by older versions).
static func get_swing(wall: Node) -> Node3D:
	for child in wall.get_children():
		if child is Node3D and String(child.name).begins_with("Swing"):
			return child
	return null


## Foundry's door animation settings (Wall Config → Door Animation) with its defaults, as the module sends them.
static func door_animation(w: Dictionary) -> Dictionary:
	var a: Dictionary = w.get("animation") if w.get("animation") is Dictionary else {}
	var type := str(a.get("type", "swing"))
	return {
		"type": type if type in DOOR_TYPES else "swing",
		"direction": -1.0 if float(a.get("direction", 1)) < 0.0 else 1.0,
		"strength": clampf(float(a.get("strength", 1.0)), 0.0, 2.0),
		"duration": maxf(float(a.get("duration", 750)), 1.0) / 1000.0,
		"double": bool(a.get("double", false)),
		"flip": bool(a.get("flip", false)),
		"texture": a.get("texture") if a.get("texture") is String else null,
		"textureGridSize": maxf(float(a.get("textureGridSize", 100)), 1.0)}


## Open (ds = DOOR_STATE_OPEN) or close a door like Foundry's animation `anim` (door_animation), over its
## duration when `animate`. Each leaf goes from its closed pose (t = 0) to its open pose (t = 1).
static func set_door_state(wall: Node3D, ds: int, animate: bool, anim := {}) -> void:
	var swing := get_swing(wall)
	if swing == null:
		return
	if anim.is_empty():
		anim = door_animation({})
	var leaves: Array = swing.get_children().filter(func(c): return c is Node3D and String(c.name).begins_with("Panel"))
	if leaves.is_empty():
		leaves = [swing]  # a manual level: the whole door node opens
	if not wall.has_meta("door_length"):  # a loaded level: measure the closed door once
		var size := _extent(swing).size
		wall.set_meta("door_length", size.x)
		wall.set_meta("door_height", size.y)
	for leaf: Node3D in leaves:
		if not leaf.has_meta("closed"):
			leaf.set_meta("closed", leaf.transform)
	var target := 1.0 if ds == DOOR_STATE_OPEN else 0.0
	var pose := func(t: float) -> void:
		wall.set_meta("door_t", t)
		for leaf: Node3D in leaves:
			leaf.transform = door_pose(wall, leaf, anim, t)
	var running = wall.get_meta("door_tween") if wall.has_meta("door_tween") else null
	if running is Tween and (running as Tween).is_valid():
		(running as Tween).kill()
	var from: float = wall.get_meta("door_t", 0.0)
	if animate and wall.is_inside_tree() and not is_equal_approx(from, target):
		var tween := wall.create_tween()
		tween.tween_method(pose, from, target, anim.duration * absf(target - from)) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		wall.set_meta("door_tween", tween)
	else:
		pose.call(target)


## Where a door leaf is at `t` (0 = closed, 1 = open), in the wall's frame (+X along the wall from A).
##   swing / swivel: turn around the pivot by direction x strength x 90 degrees (Foundry: clockwise on the map)
##   slide: toward A by the wall's length x strength (a double door's halves: half that, apart)
##   ascend / descend: up into the ceiling / down into the floor by the door's height x strength
## The second half of a double door mirrors the first (Foundry's DOUBLE_RIGHT turns the other way).
static func door_pose(wall: Node3D, leaf: Node3D, anim: Dictionary, t: float) -> Transform3D:
	var closed: Transform3D = leaf.get_meta("closed", leaf.transform)
	var direction: float = anim.direction * (-1.0 if int(leaf.get_meta("leaf", 0)) == 1 else 1.0)
	var strength: float = anim.strength
	var length: float = wall.get_meta("door_length", 1.0)
	var height: float = wall.get_meta("door_height", 1.0)
	match anim.type:
		"slide":
			var share := 0.5 if anim.double else 1.0
			return closed.translated(Vector3(-length * direction * strength * share * t, 0.0, 0.0))
		"ascend":
			return closed.translated(Vector3(0.0, height * strength * t, 0.0))
		"descend":
			return closed.translated(Vector3(0.0, -height * strength * t, 0.0))
	# swing / swivel: a panel already sits at its pivot; a whole manual door node turns around its hinge
	# (A), or its middle for swivel.
	var pivot := closed.origin
	if not String(leaf.name).begins_with("Panel") and anim.type in MIDPOINT_TYPES:
		pivot = closed.origin + Vector3(length / 2.0, 0.0, 0.0)
	var turn := Transform3D(Basis(Vector3.UP, -direction * strength * PI / 2.0 * t), Vector3.ZERO)
	return Transform3D(Basis.IDENTITY, pivot) * turn * Transform3D(Basis.IDENTITY, -pivot) * closed


## Size of a node's meshes in its own frame (doors of manual levels have no length / height meta).
static func _extent(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		var mesh_box: AABB = mesh.get_aabb()
		var parent := mesh.get_parent()
		var xform := mesh.transform
		while parent != node and parent is Node3D:
			xform = (parent as Node3D).transform * xform
			parent = parent.get_parent()
		mesh_box = xform * mesh_box
		box = mesh_box if first else box.merge(mesh_box)
		first = false
	return box


## A door leaf: a box like the walls', with UVs for Foundry's top-down door textures. The top shows the
## sprite across the door's thickness (v around 0.5); the faces and ends show that same band stretched up
## the door, so they carry its wood or metal look. apply_door_texture scales v to the texture's real size.
## `mirrored`: the second half of a double door, which Foundry draws turned around.
static func _leaf_mesh(length: float, height: float, thickness: float, mirrored: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hx := length / 2.0
	var hy := height / 2.0
	var hz := thickness / 2.0
	var u := func(x: float) -> float: return 0.5 - x / length if mirrored else 0.5 + x / length
	var v := func(f: float) -> float: return -f if mirrored else f  # -0.5..0.5 across the plank
	var quad := func(normal: Vector3, corners: Array, uvs: Array) -> void:
		st.set_normal(normal)
		for i in [0, 2, 1, 0, 3, 2]:
			st.set_uv(uvs[i])
			st.add_vertex(corners[i])
	for side in [1.0, -1.0]:
		# top (seen from above: like Foundry's sprite) and bottom
		var y: float = hy * side
		var c: Array = [Vector3(-hx, y, -hz), Vector3(hx, y, -hz), Vector3(hx, y, hz), Vector3(-hx, y, hz)]
		if side < 0.0:
			c.reverse()
		quad.call(Vector3(0, side, 0), c, c.map(func(p): return Vector2(u.call(p.x), v.call(p.z / thickness))))
		# front / back (+Z / -Z) and ends (+X / -X): the band stretched over the height
		var z: float = hz * side
		var f: Array = [Vector3(-hx, -hy, z), Vector3(hx, -hy, z), Vector3(hx, hy, z), Vector3(-hx, hy, z)]
		if side < 0.0:
			f.reverse()
		quad.call(Vector3(0, 0, side), f, f.map(func(p): return Vector2(u.call(p.x), v.call(p.y / height))))
		var x: float = hx * side
		var e: Array = [Vector3(x, -hy, hz), Vector3(x, -hy, -hz), Vector3(x, hy, -hz), Vector3(x, hy, hz)]
		if side < 0.0:
			e.reverse()
		quad.call(Vector3(side, 0, 0), e, e.map(func(p): return Vector2(u.call(p.x), v.call(p.y / height))))
	return st.commit()


## Put a Foundry door texture on a door built by build_wall (`anim` from door_animation). The sprite is as
## tall, across the wall, as Foundry draws it: texture px x gridSize / textureGridSize.
static func apply_door_texture(wall: Node3D, texture: Texture2D, anim: Dictionary, info: SceneInfo) -> void:
	var swing := get_swing(wall)
	if swing == null or texture == null:
		return
	var texture_m: float = texture.get_height() * info.grid_m / float(anim.textureGridSize)
	var mat := StandardMaterial3D.new()
	mat.resource_name = "DoorTexture"
	mat.albedo_texture = texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 0.8
	var span_v := WALL_THICKNESS / maxf(texture_m, 0.001)
	mat.uv1_scale = Vector3(1.0, -span_v if anim.flip else span_v, 1.0)
	mat.uv1_offset = Vector3(0.0, 0.5, 0.0)
	for segment in swing.find_children("Segment_*", "MeshInstance3D", true, false):
		(segment as MeshInstance3D).material_override = mat


static func _material_for(sight: int, door: int) -> StandardMaterial3D:
	if door != DOOR_NONE and door != DOOR_SECRET:
		if _door_material == null:
			_door_material = StandardMaterial3D.new()
			_door_material.resource_name = "Door"
			_door_material.albedo_color = Color("7a4a22")
			_door_material.roughness = 0.8
		return _door_material
	if sight != SENSE_NORMAL:
		# Limited / proximity / distance walls: windows, curtains, terrain walls.
		if _window_material == null:
			_window_material = StandardMaterial3D.new()
			_window_material.resource_name = "Window"
			_window_material.albedo_color = Color(0.6, 0.8, 1.0, 0.35)
			_window_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_window_material.roughness = 0.1
		return _window_material
	if _wall_material == null:
		_wall_material = StandardMaterial3D.new()
		_wall_material.resource_name = "Wall"
		_wall_material.albedo_color = Color("6b6660")
		_wall_material.roughness = 0.95
	return _wall_material
