extends Node
## See-through holes: a soft-edged hole with a dark rim is cut through walls, doors, tiles, props and upper floors
## right around the tokens in view, so they show through whatever stands in front of them (however many layers);
## everything else stays solid. Up to 8 holes, as the global shader parameters see_cut_0..7 = (world position,
## HOLE_RADIUS x strength), registered in project.godot. Each hole keeps to its own token, glides after it and
## fades in / out quickly (strength 0..1).
## A surface is cut only where it's nearer the camera than the token and over 0.1 m above the token's feet, so
## walls behind a token, and the floor (or floor tiles) it stands on, are never holed. Only the camera's own
## pass cuts (see_cut_cam): shadows keep their shape, so no light leaks through the holes.
## Walls / doors / windows / tile props / sprites have BaseMaterial3D (also in hand-made .glb levels and model
## tiles): prepare() swaps them for a look-alike ShaderMaterial with the cut, and restore_materials() puts the
## originals back (for saving / export). The floor shader (level_builder.gd) and the tile image shader
## (visual_builder.gd, on with the "see_cut_on" instance flag, which tokens never get) include CUT_GLSL themselves.
## Fading needs real transparency, which opaque / alpha-scissor surfaces don't have: each one gets a blended
## "fade" twin, put on only while a hole is near it (and back to the solid one after), so sorting, SSAO and the
## depth effects stay as they are everywhere else.

const SLOTS := 8
const HOLE_RADIUS := 2.2        ## meters around a token (also SEE_CUT_HOLE in CUT_GLSL)
const PATHS := 4                ## attacker -> target ways cleared at once
const PATH_RADIUS := 1.2        ## meters either side of the way (also SEE_CUT_PATH in CUT_GLSL)
const EASE := 6.0               ## per second: how fast holes glide after their token
const FADE_IN := 0.2            ## seconds for a hole to fade in
const FADE_OUT := 0.25          ## seconds for a hole to fade out
const REFRESH := 0.25           ## seconds between sweeps of the level and tiles (door textures, re-made materials)
const KEEP_SLOT := 3.0          ## meters: a focus point within this of an open hole keeps that hole
const NEAR := 1.3               ## a surface within HOLE_RADIUS x this of the camera -> token line takes its fade twin
const FADE_HOLD := 0.3          ## seconds a surface keeps its fade twin after the last hole near it

## Functions for a fragment shader. Call see_cut(world, VERTEX, VIEW_MATRIX, PROJECTION_MATRIX,
## CAMERA_POSITION_WORLD, VIEWPORT_SIZE): x = how see-through (0..1), y = how much of the dark rim to apply.
const CUT_GLSL := """
global uniform vec4 see_cut_0;
global uniform vec4 see_cut_1;
global uniform vec4 see_cut_2;
global uniform vec4 see_cut_3;
global uniform vec4 see_cut_4;
global uniform vec4 see_cut_5;
global uniform vec4 see_cut_6;
global uniform vec4 see_cut_7;
global uniform vec4 see_cut_cam;
global uniform vec4 see_cut_path_a_0;
global uniform vec4 see_cut_path_a_1;
global uniform vec4 see_cut_path_a_2;
global uniform vec4 see_cut_path_a_3;
global uniform vec4 see_cut_path_b_0;
global uniform vec4 see_cut_path_b_1;
global uniform vec4 see_cut_path_b_2;
global uniform vec4 see_cut_path_b_3;
const float SEE_CUT_HOLE = 2.2;  // occlusion_cutter.gd HOLE_RADIUS: w / this = the hole's strength
const float SEE_CUT_PATH = 1.2;  // occlusion_cutter.gd PATH_RADIUS
// Soft edge and dark rim at `dist` from the middle of a cut `radius` wide, faded by `fade`.
vec2 see_cut_edge(float dist, float radius, float fade) {
	float open = 1.0 - smoothstep(radius * 0.88, radius, dist);
	float rim = smoothstep(radius * 0.88, radius, dist) * (1.0 - smoothstep(radius, radius * 1.12, dist));
	return vec2(open, rim) * fade;
}
vec2 see_cut_one(vec4 cut, vec3 world, vec3 view_pos, mat4 view_m, mat4 proj, vec2 vp) {
	if (cut.w <= 0.0) { return vec2(0.0); }
	vec4 vs = view_m * vec4(cut.xyz, 1.0);
	float depth = -vs.z;
	if (depth <= 0.1 || -view_pos.z > depth - 0.3 || world.y < cut.y - 0.7) { return vec2(0.0); }
	float fade = smoothstep(0.0, 1.0, clamp(cut.w / SEE_CUT_HOLE, 0.0, 1.0));
	// Compare subject and fragment in the same projected space (Godot's projection may flip y; this doesn't care)
	vec4 clip = proj * vs;
	vec4 frag = proj * vec4(view_pos, 1.0);
	vec2 d = (frag.xy / frag.w - clip.xy / clip.w) * 0.5 * vec2(vp.x / max(vp.y, 1.0), 1.0);
	float r = SEE_CUT_HOLE * mix(0.7, 1.0, fade) * abs(proj[1][1]) / depth * 0.5;
	// Smooth, irregular outline, from the hole itself (not each surface): every layer in front of the token
	// gets the very same outline, so several walls / tiles read as one clean hole
	float a = atan(d.y, d.x);
	float radius = r * (1.0 + 0.07 * sin(3.0 * a + 1.3) + 0.05 * sin(5.0 * a + 0.4) + 0.03 * sin(9.0 * a + 2.1));
	return see_cut_edge(length(d), radius, fade);
}
// The way between an attacker (a.xyz, a.w = strength) and its target (b.xyz): a band along it, cut where a
// surface is nearer the camera than the path at that point (depth and height interpolated perspective-correct).
vec2 see_cut_path(vec4 a, vec4 b, vec3 world, vec3 view_pos, mat4 view_m, mat4 proj, vec2 vp) {
	if (a.w <= 0.0) { return vec2(0.0); }
	vec4 va = view_m * vec4(a.xyz, 1.0);
	vec4 vb = view_m * vec4(b.xyz, 1.0);
	float da = -va.z;
	float db = -vb.z;
	if (da <= 0.1 || db <= 0.1) { return vec2(0.0); }
	float fade = smoothstep(0.0, 1.0, clamp(a.w, 0.0, 1.0));
	vec2 aspect = 0.5 * vec2(vp.x / max(vp.y, 1.0), 1.0);
	vec4 ca = proj * va;
	vec4 cb = proj * vb;
	vec4 cf = proj * vec4(view_pos, 1.0);
	vec2 sa = ca.xy / ca.w * aspect;
	vec2 ab = cb.xy / cb.w * aspect - sa;
	vec2 sf = cf.xy / cf.w * aspect;
	float t = clamp(dot(sf - sa, ab) / max(dot(ab, ab), 1e-8), 0.0, 1.0);
	float inv = mix(1.0 / da, 1.0 / db, t);
	float depth = 1.0 / inv;
	float y = mix(a.y / da, b.y / db, t) / inv;
	if (-view_pos.z > depth - 0.3 || world.y < y - 0.7) { return vec2(0.0); }
	float r = SEE_CUT_PATH * mix(0.7, 1.0, fade) * abs(proj[1][1]) / depth * 0.5;
	return see_cut_edge(length(sf - (sa + ab * t)), r, fade);
}
vec2 see_cut(vec3 world, vec3 view_pos, mat4 view_m, mat4 proj, vec3 cam, vec2 vp) {
	// Shadow / probe passes render from elsewhere: no holes there, so shadows keep their shape
	if (see_cut_cam.w <= 0.0 || distance(cam, see_cut_cam.xyz) > 0.05) { return vec2(0.0); }
	vec2 a = max(see_cut_one(see_cut_0, world, view_pos, view_m, proj, vp), see_cut_one(see_cut_1, world, view_pos, view_m, proj, vp));
	vec2 b = max(see_cut_one(see_cut_2, world, view_pos, view_m, proj, vp), see_cut_one(see_cut_3, world, view_pos, view_m, proj, vp));
	vec2 c = max(see_cut_one(see_cut_4, world, view_pos, view_m, proj, vp), see_cut_one(see_cut_5, world, view_pos, view_m, proj, vp));
	vec2 d = max(see_cut_one(see_cut_6, world, view_pos, view_m, proj, vp), see_cut_one(see_cut_7, world, view_pos, view_m, proj, vp));
	vec2 p = max(max(see_cut_path(see_cut_path_a_0, see_cut_path_b_0, world, view_pos, view_m, proj, vp),
		see_cut_path(see_cut_path_a_1, see_cut_path_b_1, world, view_pos, view_m, proj, vp)),
		max(see_cut_path(see_cut_path_a_2, see_cut_path_b_2, world, view_pos, view_m, proj, vp),
		see_cut_path(see_cut_path_a_3, see_cut_path_b_3, world, view_pos, view_m, proj, vp)));
	return max(max(max(a, b), max(c, d)), p);
}
"""
## The lines a fragment() that writes ALPHA runs (after ALBEDO and ALPHA are set): fade the hole, darken its rim.
const CUT_APPLY := """
	vec2 see = see_cut((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, VERTEX, VIEW_MATRIX, PROJECTION_MATRIX, CAMERA_POSITION_WORLD, VIEWPORT_SIZE);
	if (see.x > 0.99) { discard; }
	ALPHA *= 1.0 - see.x;
	ALBEDO *= 1.0 - 0.55 * see.y;
"""
## The same for an opaque fragment() (no ALPHA, so it stays in the opaque pass): a hard cut.
const CUT_APPLY_OPAQUE := """
	vec2 see = see_cut((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, VERTEX, VIEW_MATRIX, PROJECTION_MATRIX, CAMERA_POSITION_WORLD, VIEWPORT_SIZE);
	if (see.x > 0.5) { discard; }
	ALBEDO *= 1.0 - 0.55 * see.y;
"""

## Look-alike of a BaseMaterial3D. %s: render modes, texture filter, CUT_GLSL, billboard vertex code,
## alpha lines, the cut lines.
const LOOK_SHADER := """
shader_type spatial;
render_mode %s;
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, %s;
uniform bool has_tex = false;
uniform bool vertex_color = false;
uniform sampler2D normal_tex : hint_normal;
uniform bool has_normal = false;
uniform float normal_scale = 1.0;
uniform float roughness = 0.9;
uniform float metallic = 0.0;
uniform vec3 emission = vec3(0.0);
uniform float scissor = 0.5;
uniform vec3 uv_scale = vec3(1.0);
uniform vec3 uv_offset = vec3(0.0);
%s
void vertex() {
	UV = UV * uv_scale.xy + uv_offset.xy;
%s
}
void fragment() {
	vec4 c = albedo * (has_tex ? texture(albedo_tex, UV) : vec4(1.0));
	if (vertex_color) { c *= COLOR; }
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	EMISSION = emission;
	if (has_normal) { NORMAL_MAP = texture(normal_tex, UV).rgb; NORMAL_MAP_DEPTH = normal_scale; }
	%s
%s
}
"""
## Upright, turning around Y to face the camera, keeping the scale (BILLBOARD_FIXED_Y + keep scale).
const BILLBOARD_VERTEX := """
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right * length(MODEL_MATRIX[0].xyz), 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))) * length(MODEL_MATRIX[2].xyz), 0.0),
		MODEL_MATRIX[3]);
"""
const IMAGE_SCISSOR := "ALPHA_SCISSOR_THRESHOLD = 0.5;"  ## how the image shader's scissor variant is told apart

## Return the roots to cut: set by main.gd (the level, and the tiles).
var level_root_of: Callable = func() -> Node: return null
var tiles_root_of: Callable = func() -> Node: return null

var _slots: Array = []          ## [{pos: Vector3, strength: float, sent: Vector4}]
var _paths: Array = []          ## [{key, a: Vector3, b: Vector3, strength: float, sent_a: Vector4, sent_b: Vector4}]
var _shaders := {}              ## variant key -> Shader
var _cut_materials := {}        ## BaseMaterial3D -> ShaderMaterial look-alike
var _fade_materials := {}       ## BaseMaterial3D -> blended twin of the look-alike
var _sprite_materials := {}     ## "texture id|variant" -> [solid, fade] for Sprite3D
## "node id|surface (-1 = override)" -> {node, surface, solid, fade, aabb, near_at}: surfaces with a fade twin
var _surfaces := {}
var _since_refresh := REFRESH
var _pending: Array = []        ## nodes added since the last flush
var _cam_sent := Vector4.ZERO
var _t := 0.0


func _init() -> void:
	for i in SLOTS:
		_slots.append({"pos": Vector3.ZERO, "strength": 0.0, "sent": Vector4.ZERO})
	for i in PATHS:
		_paths.append({"key": "", "a": Vector3.ZERO, "b": Vector3.ZERO, "strength": 0.0, "sent_a": Vector4.ZERO,
			"sent_b": Vector4.ZERO})


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


## Swap the standard materials under `root` for cut look-alikes (idempotent), and switch the cut on for
## images drawn by the image shader.
func prepare(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	_prepare_node(root)
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		_prepare_node(node)


## The original materials back (before saving / exporting a level).
func restore_materials(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		if not node.has_meta("see_cut_original"):
			continue
		var original: Dictionary = node.get_meta("see_cut_original")
		if original.has("override"):
			node.material_override = original.override
		for i in original.get("surfaces", {}):
			node.set_surface_override_material(i, original.surfaces[i])
		node.remove_meta("see_cut_original")


## Move the holes to the focus points (world, chest height): they glide after them and fade in / out. Each
## point keeps the hole that's already near it, so holes never slide from one token to another.
## `paths`: [{key, a, b}] attacker -> target ways to keep clear (chest height), each fading in / out by its key.
func update(focus: Array, delta: float, paths: Array = []) -> void:
	_t += delta
	_since_refresh += delta
	if _since_refresh >= REFRESH:
		_since_refresh = 0.0
		prepare(level_root_of.call())
		prepare(tiles_root_of.call())
		_refresh_bounds()
	_send_camera()
	var weight := 1.0 - exp(-EASE * delta)
	var targets := _assign(focus.slice(0, SLOTS))
	for i in SLOTS:
		var slot: Dictionary = _slots[i]
		if targets.has(i):
			var target: Vector3 = targets[i]
			slot.pos = target if slot.strength <= 0.0 else slot.pos.lerp(target, weight)  # fades in where it's needed
			slot.strength = move_toward(slot.strength, 1.0, delta / FADE_IN)
		else:
			slot.strength = move_toward(slot.strength, 0.0, delta / FADE_OUT)
		slot.sent = Vector4(slot.pos.x, slot.pos.y, slot.pos.z, HOLE_RADIUS * slot.strength)
		RenderingServer.global_shader_parameter_set("see_cut_%d" % i, slot.sent)
	_update_paths(paths.slice(0, PATHS), delta)
	_pick_twins()


## A hole (for tests): {pos, strength, sent = the last value given to the shaders}.
func slot(i: int) -> Dictionary:
	return _slots[i]


## An attacker -> target way (for tests): {key, a, b, strength, sent_a, sent_b}.
func path(i: int) -> Dictionary:
	return _paths[i]


## The camera position the shaders cut for (w = 1), as last sent.
func camera_sent() -> Vector4:
	return _cam_sent


## Whether `node`'s material (`surface`, -1 = material_override) is its blended fade twin right now (tests).
func is_fading(node: GeometryInstance3D, surface := -1) -> bool:
	var entry: Dictionary = _surfaces.get(_key(node, surface), {})
	return not entry.is_empty() and _material_of(node, surface) == entry.fade


## slot index -> focus point. Closest (open hole, point) pairs first; the rest take closed (or closing) slots.
func _assign(focus: Array) -> Dictionary:
	var result := {}
	var used_points := {}
	var pairs: Array = []
	for i in SLOTS:
		if _slots[i].strength > 0.0:
			for j in focus.size():
				var d: float = _slots[i].pos.distance_to(focus[j])
				if d < KEEP_SLOT:
					pairs.append([d, i, j])
	pairs.sort_custom(func(a, b): return a[0] < b[0])
	for p in pairs:
		if not result.has(p[1]) and not used_points.has(p[2]):
			result[p[1]] = focus[p[2]]
			used_points[p[2]] = true
	var free: Array = []
	for i in SLOTS:
		if not result.has(i):
			free.append(i)
	free.sort_custom(func(a, b): return _slots[a].strength < _slots[b].strength)
	for j in focus.size():
		if not used_points.has(j) and not free.is_empty():
			result[free.pop_front()] = focus[j]
	return result


func _update_paths(wanted: Array, delta: float) -> void:
	var wanted_keys: Array = wanted.map(func(w): return w.key)
	var new_ones: Array = []
	for w in wanted:
		var kept := false
		for p in _paths:  # a way still wanted keeps its slot, its ends following the tokens
			if p.key == w.key and p.strength > 0.0:
				p.a = w.a
				p.b = w.b
				kept = true
		if not kept:
			new_ones.append(w)
	for w in new_ones:  # new ones take a closed (or the weakest unwanted) slot
		var free: Array = _paths.filter(func(p): return not wanted_keys.has(p.key) or p.strength <= 0.0)
		if free.is_empty():
			break
		free.sort_custom(func(x, y): return x.strength < y.strength)
		free[0].merge({"key": w.key, "a": w.a, "b": w.b, "strength": 0.0}, true)
	for i in PATHS:
		var p: Dictionary = _paths[i]
		var on := wanted_keys.has(p.key)
		p.strength = move_toward(p.strength, 1.0 if on else 0.0, delta / (FADE_IN if on else FADE_OUT))
		p.sent_a = Vector4(p.a.x, p.a.y, p.a.z, p.strength)
		p.sent_b = Vector4(p.b.x, p.b.y, p.b.z, 0.0)
		RenderingServer.global_shader_parameter_set("see_cut_path_a_%d" % i, p.sent_a)
		RenderingServer.global_shader_parameter_set("see_cut_path_b_%d" % i, p.sent_b)


func _send_camera() -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	_cam_sent = Vector4.ZERO
	if cam:
		var p := cam.global_position
		_cam_sent = Vector4(p.x, p.y, p.z, 1.0)
	RenderingServer.global_shader_parameter_set("see_cut_cam", _cam_sent)


## Surfaces near an open hole (between the camera and its token) wear their fade twin, the rest their solid one.
func _pick_twins() -> void:
	var cam := Vector3(_cam_sent.x, _cam_sent.y, _cam_sent.z)
	var reach := HOLE_RADIUS * NEAR
	var lines: Array = []  # [point, box around the camera -> point line, reach]
	if _cam_sent.w > 0.0:
		for s in _slots:
			if s.strength > 0.0:
				var box := AABB(cam, Vector3.ZERO).expand(s.pos).grow(reach)
				lines.append([s.pos, box, reach])
		for p in _paths:  # and the ways between attackers and targets, a few points along each
			if p.strength > 0.0:
				var path_reach := PATH_RADIUS * NEAR
				for k in 5:
					var point: Vector3 = p.a.lerp(p.b, k / 4.0)
					lines.append([point, AABB(cam, Vector3.ZERO).expand(point).grow(path_reach), path_reach])
	for key in _surfaces.keys():
		var entry: Dictionary = _surfaces[key]
		var node = entry.node
		if not is_instance_valid(node):
			_surfaces.erase(key)
			continue
		for line in lines:
			if line[1].intersects(entry.aabb) and _near_line(entry.aabb, cam, line[0], line[2]):
				entry.near_at = _t
				break
		var want: Material = entry.fade if _t - entry.near_at < FADE_HOLD else entry.solid
		var current := _material_of(node, entry.surface)
		if current != want and (current == entry.solid or current == entry.fade):  # never over someone else's
			if want == entry.fade:
				_sync_twin(entry.solid, entry.fade)
			_set_material_of(node, entry.surface, want)


static func _near_line(box: AABB, from: Vector3, to: Vector3, reach: float) -> bool:
	for i in 9:
		var p := from.lerp(to, i / 8.0)
		if p.distance_to(p.clamp(box.position, box.end)) < reach:
			return true
	return false


func _refresh_bounds() -> void:
	for entry in _surfaces.values():
		if is_instance_valid(entry.node) and entry.node.is_inside_tree():
			entry.aabb = entry.node.global_transform * entry.node.get_aabb()


func _on_node_added(node: Node) -> void:
	if node is GeometryInstance3D:
		if _pending.is_empty():
			_flush_pending.call_deferred()
		_pending.append(node)


## New meshes / sprites under the level or the tiles are cut from their first frame on.
func _flush_pending() -> void:
	var roots: Array = [level_root_of.call(), tiles_root_of.call()].filter(func(r): return r and is_instance_valid(r))
	for node in _pending:
		if is_instance_valid(node) and roots.any(func(r): return r == node or r.is_ancestor_of(node)):
			_prepare_node(node)
	_pending.clear()


func _prepare_node(node: Node) -> void:
	if node is Sprite3D:
		_prepare_sprite(node)
	elif node is MeshInstance3D:
		_prepare_mesh(node)
	if node is GeometryInstance3D and _uses_image_shader(node):
		node.set_instance_shader_parameter("see_cut_on", true)
		# Floors (level_builder.gd) keep their own hard cut: a blended twin of the map would lose its depth
		# (the effects that read it) and sort behind everything
		if not node.has_meta("foundry_level_id"):
			_prepare_image_twins(node)


func _prepare_mesh(mesh: MeshInstance3D) -> void:
	var original: Dictionary = mesh.get_meta("see_cut_original", {})
	var override := mesh.material_override
	if override is BaseMaterial3D:
		original.override = override  # the latest one (doors get their texture later, tiles re-make theirs)
		mesh.material_override = _cut_material(override)
		_track(mesh, -1, mesh.material_override, _fade_material(override))
	elif override == null and mesh.mesh:
		for i in mesh.mesh.get_surface_count():
			var mat := mesh.get_active_material(i)
			if mat is BaseMaterial3D:
				if not original.has("surfaces"):
					original.surfaces = {}
				original.surfaces[i] = mesh.get_surface_override_material(i)
				mesh.set_surface_override_material(i, _cut_material(mat))
				_track(mesh, i, mesh.get_surface_override_material(i), _fade_material(mat))
	if not original.is_empty():
		mesh.set_meta("see_cut_original", original)


## A Sprite3D draws its own quad: a billboard look-alike with its texture goes over it.
func _prepare_sprite(sprite: Sprite3D) -> void:
	if sprite.texture == null:
		return
	var current := sprite.material_override
	if current is ShaderMaterial and current.get_meta("see_cut_sprite", null) == sprite.texture:
		return
	if current != null and not (current is ShaderMaterial and current.has_meta("see_cut_sprite")):
		return  # someone else's material on it
	var billboard := sprite.billboard != BaseMaterial3D.BILLBOARD_DISABLED
	var alpha := sprite.alpha_cut == SpriteBase3D.ALPHA_CUT_DISABLED
	var nearest := sprite.texture_filter in [BaseMaterial3D.TEXTURE_FILTER_NEAREST, BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS,
		BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC]
	var variant := {"transparency": "alpha" if alpha else "scissor", "cull": "disabled" if sprite.double_sided else "back",
		"billboard": billboard, "unshaded": not sprite.shaded, "nearest": nearest, "fade": false}
	var key := "%d|%s" % [sprite.texture.get_instance_id(), variant]
	if not _sprite_materials.has(key):
		var pair: Array = []
		for fade in [false, true]:
			if fade and alpha:
				pair.append(pair[0])  # already blended
				continue
			variant.fade = fade
			var mat := ShaderMaterial.new()
			mat.shader = _shader(variant)
			mat.set_shader_parameter("vertex_color", true)  # the sprite's modulate comes as its vertex colour
			mat.set_shader_parameter("has_tex", true)
			mat.set_shader_parameter("albedo_tex", sprite.texture)
			mat.set_meta("see_cut_sprite", sprite.texture)
			pair.append(mat)
		_sprite_materials[key] = pair
	if not sprite.has_meta("see_cut_original"):
		sprite.set_meta("see_cut_original", {"override": null})
	sprite.material_override = _sprite_materials[key][0]
	_track(sprite, -1, _sprite_materials[key][0], _sprite_materials[key][1])


## Image-shader tiles drawn with alpha scissor (upright cut-outs, trees...) get the blended variant as fade twin.
func _prepare_image_twins(node: GeometryInstance3D) -> void:
	var surfaces: Array = [-1]
	if node is MeshInstance3D and node.mesh:
		surfaces.append_array(range(node.mesh.get_surface_count()))
	for surface in surfaces:
		var mat := _material_of(node, surface)
		if not (mat is ShaderMaterial and mat.shader and mat.shader.code.contains("see_cut_on")):
			continue
		var entry: Dictionary = _surfaces.get(_key(node, surface), {})
		if not entry.is_empty() and (mat == entry.solid or mat == entry.fade):
			continue
		if mat.shader.code.contains(IMAGE_SCISSOR):
			_track(node, surface, mat, _image_twin(mat))


func _image_twin(solid: ShaderMaterial) -> ShaderMaterial:
	var key := "image|%d" % solid.shader.get_instance_id()
	if not _shaders.has(key):
		var shader := Shader.new()
		shader.code = solid.shader.code.replace(IMAGE_SCISSOR, "")
		_shaders[key] = shader
	var twin := ShaderMaterial.new()
	twin.shader = _shaders[key]
	for u in solid.shader.get_shader_uniform_list():
		twin.set_shader_parameter(u.name, solid.get_shader_parameter(u.name))
	return twin


func _track(node: GeometryInstance3D, surface: int, solid: Material, fade: Material) -> void:
	if fade == null or fade == solid:
		return
	var key := _key(node, surface)
	var entry: Dictionary = _surfaces.get(key, {"near_at": -INF})
	entry.merge({"node": node, "surface": surface, "solid": solid, "fade": fade}, true)
	entry.aabb = node.global_transform * node.get_aabb() if node.is_inside_tree() else AABB()
	_surfaces[key] = entry


## The twin takes the solid one's current parameters (textures arrive after the twin was made, e.g. a map
## or a re-loaded tile image), so swapping never changes the look.
static func _sync_twin(solid: Material, fade: Material) -> void:
	if not (solid is ShaderMaterial and fade is ShaderMaterial and solid.shader and fade.shader):
		return
	for u in fade.shader.get_shader_uniform_list():
		fade.set_shader_parameter(u.name, solid.get_shader_parameter(u.name))


static func _key(node: Node, surface: int) -> String:
	return "%d|%d" % [node.get_instance_id(), surface]


static func _material_of(node: GeometryInstance3D, surface: int) -> Material:
	if surface < 0:
		return node.material_override
	return (node as MeshInstance3D).get_surface_override_material(surface)


static func _set_material_of(node: GeometryInstance3D, surface: int, mat: Material) -> void:
	if surface < 0:
		node.material_override = mat
	else:
		(node as MeshInstance3D).set_surface_override_material(surface, mat)


func _variant(source: BaseMaterial3D, fade: bool) -> Dictionary:
	var transparency := "opaque"
	match source.transparency:
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, BaseMaterial3D.TRANSPARENCY_ALPHA_HASH:
			transparency = "scissor"
		BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
			transparency = "alpha"
	var cull := "back"
	match source.cull_mode:
		BaseMaterial3D.CULL_DISABLED:
			cull = "disabled"
		BaseMaterial3D.CULL_FRONT:
			cull = "front"
	return {"transparency": transparency, "cull": cull,
		"billboard": source.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED,
		"unshaded": source.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
		"nearest": source.texture_filter in [BaseMaterial3D.TEXTURE_FILTER_NEAREST,
			BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS, BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC],
		"fade": fade}


func _cut_material(source: BaseMaterial3D) -> ShaderMaterial:
	if not _cut_materials.has(source):
		_cut_materials[source] = _look_alike(source, false)
	return _cut_materials[source]


## The blended twin (null when the look-alike is blended already, like windows).
func _fade_material(source: BaseMaterial3D) -> ShaderMaterial:
	if _variant(source, false).transparency == "alpha":
		return null
	if not _fade_materials.has(source):
		_fade_materials[source] = _look_alike(source, true)
	return _fade_materials[source]


func _look_alike(source: BaseMaterial3D, fade: bool) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _shader(_variant(source, fade))
	mat.resource_name = source.resource_name
	mat.set_shader_parameter("albedo", source.albedo_color)
	mat.set_shader_parameter("has_tex", source.albedo_texture != null)
	if source.albedo_texture:
		mat.set_shader_parameter("albedo_tex", source.albedo_texture)
	mat.set_shader_parameter("vertex_color", source.vertex_color_use_as_albedo)
	if source.normal_enabled and source.normal_texture:
		mat.set_shader_parameter("has_normal", true)
		mat.set_shader_parameter("normal_tex", source.normal_texture)
		mat.set_shader_parameter("normal_scale", source.normal_scale)
	mat.set_shader_parameter("roughness", source.roughness)
	mat.set_shader_parameter("metallic", source.metallic)
	if source.emission_enabled:
		var e := source.emission * source.emission_energy_multiplier
		mat.set_shader_parameter("emission", Vector3(e.r, e.g, e.b))
	mat.set_shader_parameter("scissor", source.alpha_scissor_threshold)
	mat.set_shader_parameter("uv_scale", source.uv1_scale)
	mat.set_shader_parameter("uv_offset", source.uv1_offset)
	return mat


func _shader(variant: Dictionary) -> Shader:
	var key := str(variant)
	if not _shaders.has(key):
		var modes: Array = ["cull_" + str(variant.cull)]
		if variant.unshaded:
			modes.append("unshaded")
		var alpha_lines := ""
		var cut := CUT_APPLY
		if variant.fade:  # blended, but solid where there's no hole (its depth prepass also keeps its shadow)
			modes.append_array(["blend_mix", "depth_prepass_alpha"])
			alpha_lines = ("if (c.a < scissor) { discard; } " if variant.transparency == "scissor" else "") + "ALPHA = 1.0;"
		else:
			match variant.transparency:
				"alpha":
					modes.append_array(["blend_mix", "depth_draw_opaque"])
					alpha_lines = "ALPHA = c.a;"
				"scissor":
					alpha_lines = "ALPHA = c.a; ALPHA_SCISSOR_THRESHOLD = scissor;"
				_:
					cut = CUT_APPLY_OPAQUE
		var shader := Shader.new()
		shader.code = LOOK_SHADER % [", ".join(modes),
			"filter_nearest_mipmap" if variant.nearest else "filter_linear_mipmap_anisotropic", CUT_GLSL,
			BILLBOARD_VERTEX if variant.billboard else "", alpha_lines, cut]
		_shaders[key] = shader
	return _shaders[key]


## Drawn by the image shader (visual_builder.gd), which has the cut behind the "see_cut_on" flag.
func _uses_image_shader(node: GeometryInstance3D) -> bool:
	var mats: Array = [node.material_override]
	if node is MeshInstance3D and node.mesh:
		for i in node.mesh.get_surface_count():
			mats.append(node.get_active_material(i))
	return mats.any(func(m): return m is ShaderMaterial and m.shader != null and m.shader.code.contains("see_cut_on"))
