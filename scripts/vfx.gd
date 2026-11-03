extends RefCounted
## Procedural effect shapes for hit and status VFX (hit_styles.gd, token_status.gd): no image files, everything
## is drawn by small shaders on quads, or by textures generated once at runtime.
##   SLASH   - crescent arc with a white-hot core, its head sweeping along (`progress`), tail fading
##   THRUST  - tapered spear streak with a sharp tip (`jag` > 0: a jagged lightning bolt)
##   STAR    - spiked starburst (puncture, muzzle flash, blunt impact, radiant rays), optional ring
##   CRACK   - jagged ground cracks radiating from the center (blunt impacts), lying on the floor
##   SMOKE   - soft noisy puff (gun smoke, dust)
##   FLAME   - flame tongue licking upward (burning, fire hits), always turned to the camera
##   HAZE    - swirling noise cloud (cursed, poison fumes, necrotic), always turned to the camera
## Additive shapes glow; smoke, haze, blood and bubbles are alpha-blended so they keep their own color.

const NOISE := """
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * vnoise(p); p *= 2.03; a *= 0.5; }
	return v;
}
"""

## Turned to the camera every frame, keeping the node's scale (for long-lived quads: flames, haze).
const BILLBOARD := """
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz), INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz), MODEL_MATRIX[3]);
}
"""

const ADD := "render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;\n"
const MIX := "render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;\n"

const SHADERS := {
	"slash": MIX + """
uniform vec4 color : source_color = vec4(1.0, 0.85, 0.6, 1.0);
uniform float progress = 0.0;  // head of the swing along the arc, 0..1.4
uniform float fade = 1.0;
uniform float thickness = 0.14;
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	p.y = -p.y + 0.55;  // arc around a center below the middle
	float r = length(p);
	float t = (atan(p.x, p.y) + 1.25) / 2.5;  // along the arc, 0..1 over about 143 degrees
	float behind = progress - t;
	if (t < 0.0 || t > 1.0 || behind < 0.0) discard;
	float tail = 1.0 - clamp(behind / 0.6, 0.0, 1.0);
	float w = thickness * tail * smoothstep(0.0, 0.1, t) * smoothstep(1.0, 0.85, t) + 0.004;
	float d = abs(r - 0.9);
	float band = 1.0 - smoothstep(w * 0.55, w, d);
	float outline = 1.0 - smoothstep(w, w * 1.45 + 0.004, d);  // thin dark edge, so it shows over anything
	float core = 1.0 - smoothstep(0.0, w * 0.35, d);
	vec3 c = mix(color.rgb * 1.6, vec3(2.2), core);
	ALBEDO = mix(vec3(0.02), c, band);
	ALPHA = max(band, outline * 0.6) * tail * fade;
}
""",
	"thrust": MIX + NOISE + """
uniform vec4 color : source_color = vec4(1.0);
uniform float progress = 1.0;  // how far it has shot out, 0..1 (UV.x: base 0 to tip 1)
uniform float fade = 1.0;
uniform float jag = 0.0;  // > 0: jagged lightning bolt
uniform float seed = 0.0;
void fragment() {
	float x = UV.x;
	if (x > progress) discard;
	float y = UV.y * 2.0 - 1.0;
	y += (vnoise(vec2(x * 9.0, seed)) - 0.5) * jag * 4.0 + (vnoise(vec2(x * 23.0, seed + 5.0)) - 0.5) * jag * 1.5;
	float w = clamp(min(x / max(progress, 0.001) * 1.4, (progress - x) / 0.08), 0.0, 1.0) * (jag > 0.0 ? 0.35 : 0.9);
	float band = 1.0 - smoothstep(w * 0.55, w + 0.001, abs(y));
	float outline = 1.0 - smoothstep(w + 0.001, w * 1.5 + 0.02, abs(y));
	float core = 1.0 - smoothstep(0.0, w * 0.35 + 0.001, abs(y));
	ALBEDO = mix(vec3(0.02), mix(color.rgb * 1.6, vec3(2.2), core), band);
	ALPHA = max(band, outline * (jag > 0.0 ? 0.0 : 0.55)) * fade;
}
""",
	"star": ADD + """
uniform vec4 color : source_color = vec4(1.0);
uniform float spikes = 7.0;
uniform float size = 1.0;  // grows 0..1
uniform float fade = 1.0;
uniform float sharp = 24.0;  // higher = thinner spikes
uniform float ring = 0.0;  // > 0: a ring at this radius too
uniform float seed = 0.0;
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float ang = atan(p.y, p.x) + seed;
	float k = floor((ang / TAU + 0.5) * spikes + 0.5);
	float len = 0.55 + 0.45 * fract(sin(k * 12.9898 + seed * 7.0) * 43758.5453);  // uneven spike lengths
	float ray = pow(abs(cos(ang * spikes * 0.5)), sharp);
	float spike = ray * (1.0 - smoothstep(0.0, len * size, r));
	float hot = 1.0 - smoothstep(0.0, 0.2 * size, r);
	float rim = ring > 0.0 ? (1.0 - smoothstep(0.015, 0.06, abs(r - ring * size))) * 0.8 : 0.0;
	float a = clamp(spike + hot + rim, 0.0, 1.0) * fade;
	ALBEDO = mix(color.rgb, vec3(1.0), hot) * 2.2;
	ALPHA = a;
}
""",
	"crack": MIX + NOISE + """
uniform float grow = 1.0;
uniform float fade = 1.0;
uniform float seed = 0.0;
uniform float heat = 1.0;  // 1: glowing hot, 0: cooled to dark
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float ang = atan(p.y, p.x);
	if (ang < 0.0) ang += TAU;
	float n = 7.0;
	float k = floor(ang / TAU * n + 0.5);
	float len = (0.55 + 0.45 * hash(vec2(k, seed))) * grow;
	float wander = (vnoise(vec2(r * 7.0, k * 3.1 + seed)) - 0.5) * 0.55 + (vnoise(vec2(r * 19.0, k + seed)) - 0.5) * 0.18;
	float da = abs(ang - k / n * TAU - wander * r) * r;
	float line = (1.0 - smoothstep(0.004, 0.022 * (1.0 - r * 0.6), da)) * step(r, len);
	float scorch = (1.0 - smoothstep(0.0, 0.35 * grow, r)) * 0.35;  // dark dent in the middle
	vec3 hot = vec3(2.0, 1.2, 0.5) * (1.0 - r * 0.7);
	ALBEDO = mix(vec3(0.04, 0.035, 0.03), hot, heat * line);
	ALPHA = clamp(line * 0.95 + scorch * (1.0 - heat * 0.6), 0.0, 1.0) * fade;
}
""",
	"smoke": MIX + NOISE + BILLBOARD + """
uniform vec4 color : source_color = vec4(0.6, 0.6, 0.6, 1.0);
uniform float fade = 1.0;
uniform float seed = 0.0;
void fragment() {
	float d = length(UV * 2.0 - 1.0);
	float n = fbm(UV * 3.0 + vec2(seed, TIME * 0.4));
	float a = (1.0 - smoothstep(0.25, 1.0, d + (n - 0.5) * 0.6)) * fade * 0.75;
	ALBEDO = color.rgb * (0.75 + 0.5 * n);
	ALPHA = a;
}
""",
	"flame": ADD + NOISE + """
uniform vec4 core_color : source_color = vec4(1.0, 0.85, 0.35, 1.0);
uniform vec4 edge_color : source_color = vec4(1.0, 0.25, 0.05, 1.0);
uniform float intensity = 1.0;
uniform float speed = 1.6;
uniform float seed = 0.0;
void vertex() {  // upright, turning around Y to face the camera, keeping the scale
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)) * length(MODEL_MATRIX[0].xyz), 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))) * length(MODEL_MATRIX[2].xyz), 0.0),
		MODEL_MATRIX[3]);
}
void fragment() {
	float y = 1.0 - UV.y;  // 0 at the base, 1 at the top
	float x = UV.x * 2.0 - 1.0;
	float n = fbm(vec2(UV.x * 2.5 + seed, UV.y * 2.0 + TIME * speed));
	float n2 = fbm(vec2(UV.x * 5.0 - seed, UV.y * 4.0 + TIME * speed * 1.7));
	x += (n - 0.5) * 0.9 * y;  // the tip licks side to side
	float width = 0.8 * pow(max(1.0 - y, 0.0), 0.8) * smoothstep(-0.05, 0.2, y);
	float body = 1.0 - smoothstep(width * 0.5, width + 0.001, abs(x));
	body *= 1.0 - smoothstep(0.45, 0.95, y + (n2 - 0.5) * 0.6);  // ragged, flickering top
	float core = (1.0 - smoothstep(0.0, width * 0.5 + 0.001, abs(x))) * (1.0 - smoothstep(0.1, 0.6, y));
	ALBEDO = mix(edge_color.rgb, core_color.rgb, core) * 2.0;
	ALPHA = body * intensity;
}
""",
	"haze": MIX + NOISE + BILLBOARD + """
uniform vec4 color : source_color = vec4(0.4, 0.1, 0.55, 1.0);
uniform float strength = 0.55;
uniform float speed = 0.35;  // swirl, negative turns the other way
uniform float seed = 0.0;
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float ang = atan(p.y, p.x) + TIME * speed + r * 2.5;
	vec2 q = vec2(cos(ang), sin(ang)) * r;
	float n = fbm(q * 2.2 + vec2(seed, TIME * 0.15));
	float a = (1.0 - smoothstep(0.3, 1.0, r)) * smoothstep(0.35, 0.8, n) * strength;
	ALBEDO = color.rgb * (0.55 + 0.7 * n);
	ALPHA = a;
}
""",
}

static var _shaders := {}
static var _textures := {}


static func shader(name: String) -> Shader:
	if not _shaders.has(name):
		var s := Shader.new()
		s.code = "shader_type spatial;\n" + SHADERS[name]
		_shaders[name] = s
	return _shaders[name]


## A quad drawn by one of the shaders, added under `parent` at the global position `at`.
static func quad(parent: Node, name: String, shader_name: String, size: Vector2, at: Vector3,
		params := {}) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := QuadMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = shader(shader_name)
	for key in params:
		mat.set_shader_parameter(key, params[key])
	node.material_override = mat
	parent.add_child(node)
	node.global_position = at
	return node


## Tween a shader parameter of `node`'s material.
static func animate(node: MeshInstance3D, param: String, from: float, to: float, time: float, delay := 0.0,
		trans := Tween.TRANS_LINEAR) -> Tween:
	var mat := node.material_override as ShaderMaterial
	mat.set_shader_parameter(param, from)
	var tween := node.create_tween()
	if delay > 0.0:
		tween.tween_interval(delay)
	tween.tween_method(func(v: float) -> void: mat.set_shader_parameter(param, v), from, to, time).set_trans(trans)
	return tween


static func free_after(node: Node, time: float) -> void:
	node.get_tree().create_timer(time).timeout.connect(func() -> void:
		if is_instance_valid(node):
			node.queue_free())


## Turn a quad to the camera, rotated `roll` radians in the view (`mirror`: flipped left-right).
static func face_camera(node: Node3D, roll: float, mirror := false) -> void:
	var camera := node.get_viewport().get_camera_3d()
	if camera:
		var keep := node.scale
		node.global_basis = camera.global_basis * Basis(Vector3.BACK, roll)
		node.scale = Vector3(-keep.x if mirror else keep.x, keep.y, keep.z)


## Lay a quad along `dir` (its UV.x running along it), its face turned to the camera as much as possible.
static func orient_along(node: Node3D, dir: Vector3) -> void:
	var x := dir.normalized()
	if x.length() < 0.001:
		return
	var keep := node.scale
	var camera := node.get_viewport().get_camera_3d()
	var to_camera := camera.global_position - node.global_position if camera else Vector3.UP
	var z := (to_camera - x * to_camera.dot(x)).normalized()
	if z.length() < 0.001:
		z = Vector3.UP if absf(x.y) < 0.9 else Vector3.BACK
	node.global_basis = Basis(x, z.cross(x).normalized(), z)
	node.scale = keep


## `at` moved `distance` toward the camera, so a flat effect is drawn in front of the token it's on, not cut by it.
static func in_front(node: Node, at: Vector3, distance := 0.45) -> Vector3:
	var camera := node.get_viewport().get_camera_3d()
	if camera == null:
		return at
	return at + (camera.global_position - at).normalized() * distance


## Which way `dir` points on screen: 1 = right, -1 = left.
static func screen_side(node: Node3D, dir: Vector3) -> float:
	var camera := node.get_viewport().get_camera_3d()
	if camera == null:
		return 1.0
	return 1.0 if dir.dot(camera.global_basis.x) >= 0.0 else -1.0


## Particles with one of the generated textures. `opts`: amount, lifetime, one_shot, gravity (> 0 rises),
## speed (min, max), spread, direction, scale (min, max), additive, fixed_y (upright along the fall, for drops).
static func particles(parent: Node3D, name: String, at: Vector3, texture: String, color: Color,
		opts := {}) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = name
	p.amount = int(opts.get("amount", 8))
	p.lifetime = float(opts.get("lifetime", 0.6))
	p.one_shot = bool(opts.get("one_shot", true))
	p.explosiveness = 1.0 if p.one_shot else 0.0
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := ParticleProcessMaterial.new()
	m.direction = opts.get("direction", Vector3.UP)
	m.spread = float(opts.get("spread", 180.0))
	var speed: Vector2 = opts.get("speed", Vector2(1.0, 3.0))
	m.initial_velocity_min = speed.x
	m.initial_velocity_max = speed.y
	m.gravity = Vector3(0.0, float(opts.get("gravity", -9.0)), 0.0)
	m.damping_min = float(opts.get("damping", 0.0))
	m.damping_max = float(opts.get("damping", 0.0))
	var scale: Vector2 = opts.get("scale", Vector2(0.04, 0.08))
	m.scale_min = scale.x
	m.scale_max = scale.y
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = float(opts.get("radius", 0.05))
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	fade.colors = PackedColorArray([color, color, Color(color, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	m.color_ramp = ramp
	p.process_material = m
	var mesh := QuadMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if opts.get("additive", false):
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y if opts.get("fixed_y", false) else BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = texture_named(texture)
	mesh.material = mat
	if texture == "drop" or texture == "shard":
		mesh.size = Vector2(0.5, 1.0)  # tall: drops and shards are longer than wide
	p.draw_pass_1 = mesh
	parent.add_child(p)
	p.global_position = at
	p.emitting = true
	if p.one_shot:
		free_after(p, p.lifetime + 0.5)
	return p


## Generated particle textures: dot (soft glow), drop (teardrop, point up), bubble (ring with a highlight),
## shard (thin diamond), splat (irregular blob with spatters).
static func texture_named(name: String) -> Texture2D:
	if not _textures.has(name):
		var size := 64
		var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var blobs := []
		if name == "splat":
			for i in 7:
				var angle := rng.randf() * TAU
				var dist := rng.randf_range(0.45, 0.85)
				blobs.append([Vector2(cos(angle), sin(angle)) * dist, rng.randf_range(0.05, 0.13)])
		for y in size:
			for x in size:
				var u := (x + 0.5) / size * 2.0 - 1.0
				var v := (y + 0.5) / size * 2.0 - 1.0  # -1 top .. 1 bottom
				var a := 0.0
				var shade := 1.0
				match name:
					"dot":
						a = clampf(1.0 - Vector2(u, v).length(), 0.0, 1.0)
						a *= a
					"drop":  # round bottom, tapering to a point at the top
						var body := Vector2(u, (v - 0.35) * 1.0).length() - 0.55
						var taper := absf(u) - 0.55 * clampf((v + 0.95) / 1.3, 0.0, 1.0)
						var d := minf(body, maxf(taper, -v - 0.95))
						a = clampf(0.5 - d * 12.0, 0.0, 1.0)
						shade = 1.0 + 0.6 * clampf(1.0 - Vector2(u + 0.2, v - 0.15).length() * 4.0, 0.0, 1.0)  # highlight
					"bubble":
						var r := Vector2(u, v).length()
						a = clampf(1.0 - absf(r - 0.8) * 9.0, 0.0, 1.0) + (0.15 if r < 0.8 else 0.0)
						a += clampf(1.0 - Vector2(u + 0.35, v + 0.35).length() * 6.0, 0.0, 1.0)
						a = clampf(a, 0.0, 1.0)
					"shard":
						a = clampf((1.0 - (absf(u) * 2.2 + absf(v))) * 6.0, 0.0, 1.0)
					"splat":
						var r := Vector2(u, v).length()
						var wobble := 0.08 * sin(atan2(v, u) * 7.0) + 0.05 * sin(atan2(v, u) * 13.0 + 1.0)
						a = clampf((0.5 + wobble - r) * 14.0, 0.0, 1.0)
						for blob in blobs:
							a = maxf(a, clampf((blob[1] - Vector2(u, v).distance_to(blob[0])) * 30.0, 0.0, 1.0))
				image.set_pixel(x, y, Color(shade, shade, shade, a) if shade <= 1.0 else Color(1, 1, 1, a))
		_textures[name] = ImageTexture.create_from_image(image)
	return _textures[name]
