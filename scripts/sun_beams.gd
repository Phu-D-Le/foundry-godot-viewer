extends Node3D
## Sun beams: shafts of sunlight fixed in the world, slanting down from above along the sun's direction
## (the HD-2D "god rays" through a canopy or windows). Each beam is a long quad that turns around its own
## axis to face the camera, so it never looks edge-on, while its place and slant stay put in the world.
## Layout is seeded by the scene id, so a scene always gets the same beams.

const TOP_HEIGHT := 12.0      ## meters above the floor where the beams start
const AREA_PER_BEAM := 60.0   ## m² of scene per beam
const MAX_BEAMS := 40
const MIN_BEAMS := 4

const BEAM_SHADER := """
shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform float strength = 0.5;
uniform vec3 beam_color : source_color = vec3(1.0, 0.88, 0.65);
instance uniform float seed = 0.0;
varying float facing;

void vertex() {
	// Turn around the beam's axis (local Y) toward the camera
	vec3 axis = normalize(MODEL_MATRIX[1].xyz);
	vec3 center = (MODEL_MATRIX * vec4(0.0, VERTEX.y, 0.0, 1.0)).xyz;
	vec3 to_cam = CAMERA_POSITION_WORLD - center;
	vec3 side = cross(axis, to_cam);
	side = length(side) > 0.0001 ? normalize(side) : normalize(MODEL_MATRIX[0].xyz);
	vec3 world = center + side * VERTEX.x;
	// Looking straight along a beam shows a bright blob: fade those
	facing = 1.0 - abs(dot(axis, normalize(to_cam)));
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
}

void fragment() {
	// UV.y: 0 at the top (toward the sun), 1 at the floor
	float across = pow(sin(UV.x * PI), 2.0);
	float along = smoothstep(0.0, 0.2, UV.y) * mix(1.0, 0.45, UV.y) * (1.0 - smoothstep(0.85, 1.0, UV.y));
	// Dust drifting down the beam
	float dust = 0.85 + 0.15 * sin(UV.y * 17.0 - TIME * 0.35 + seed * 7.0) * (0.6 + 0.4 * sin(UV.x * 3.1 + seed * 3.0));
	// Soft where the beam meets the floor, walls and tokens
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -view.z / view.w;
	float soft = clamp((scene_z - (-VERTEX.z)) / 0.8, 0.0, 1.0);
	float a = across * along * dust * soft * smoothstep(0.05, 0.4, facing) * strength;
	ALBEDO = beam_color * a * 0.45;
}
"""

var _material: ShaderMaterial
var _beams: Array[MeshInstance3D] = []
var _bases: Array[Vector3] = []  ## where each beam meets the floor
var _direction := Vector3.ZERO   ## sunlight travel direction the beams were laid out for


func _ready() -> void:
	var shader := Shader.new()
	shader.code = BEAM_SHADER
	_material = ShaderMaterial.new()
	_material.shader = shader
	visible = false


## Lay the beams out over a scene of `size` meters (x by z), seeded so it's stable per scene.
func rebuild(size: Vector2, seed_text: String) -> void:
	for beam in _beams:
		beam.queue_free()
	_beams.clear()
	_bases.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text)
	var count := clampi(int(size.x * size.y / AREA_PER_BEAM), MIN_BEAMS, MAX_BEAMS)
	for i in count:
		var width := rng.randf_range(0.6, 2.5)
		var quad := QuadMesh.new()
		quad.size = Vector2(width, 1.0)
		quad.center_offset = Vector3(0.0, 0.5, 0.0)  # local Y runs 0 (floor) .. 1 (top), scaled to length
		var beam := MeshInstance3D.new()
		beam.name = "Beam%d" % i
		beam.mesh = quad
		beam.material_override = _material
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		beam.extra_cull_margin = width  # the shader turns the quad, past its own bounds
		beam.set_instance_shader_parameter("seed", rng.randf() * 10.0)
		_bases.append(Vector3(rng.randf_range(0.0, size.x), 0.0, rng.randf_range(0.0, size.y)))
		add_child(beam)
		_beams.append(beam)
	_direction = Vector3.ZERO  # re-aim on the next update


## Point the beams along the sun's light and set their brightness (0 hides them).
func update(sun: DirectionalLight3D, strength: float) -> void:
	visible = strength > 0.001 and not _beams.is_empty()
	if not visible:
		return
	_material.set_shader_parameter("strength", strength)
	_material.set_shader_parameter("beam_color", Color(sun.light_color.r, sun.light_color.g * 0.9, sun.light_color.b * 0.72))
	var travel := -sun.global_transform.basis.z
	if travel.y > -0.2:  # sun near the horizon: keep beams from lying flat
		travel = Vector3(travel.x, -0.2, travel.z).normalized()
	if travel.is_equal_approx(_direction):
		return
	_direction = travel
	var up := -travel                       # from the floor toward the sun
	var length := TOP_HEIGHT / up.y
	var side := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	var normal := side.cross(up).normalized()
	for i in _beams.size():
		_beams[i].transform = Transform3D(Basis(side, up * length, normal), _bases[i])
