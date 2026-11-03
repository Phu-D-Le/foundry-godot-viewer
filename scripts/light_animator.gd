extends Node
## Animates one light like Foundry's light animations (CONFIG.Canvas.lightAnimations).
## Matched: torch, flame (smooth-noise flicker), pulse / reactivepulse (cosine pulse), chroma (hue cycle),
##          siren and revolving (a rotating beam). Same timing as Foundry: time = speed * t / 5000.
## Approximated: types Foundry draws as shader patterns on the ground get an animated pattern disc.

const PATTERN_SHADER := """
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec3 tint = vec3(1.0);
uniform float time;
uniform float strength = 0.4;
uniform int mode;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {  // rotated octaves hide the value-noise grid
	float v = 0.0; float a = 0.5; mat2 m = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6));
	for (int i = 0; i < 5; i++) { v += a * noise(p); p = m * p; a *= 0.5; }
	return v;
}
vec3 hsb2rgb(vec3 c) {
	vec3 rgb = clamp(abs(mod(c.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
	return c.z * mix(vec3(1.0), rgb, c.y);
}
void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float d = length(uv);
	if (d > 1.0) discard;
	float fade = 1.0 - smoothstep(0.3, 1.0, d);
	float a = atan(uv.y, uv.x);
	float v = 0.0;
	vec3 col = tint;
	if (mode == 0) v = pow(0.5 + 0.5 * sin(a * 8.0 + time * 2.0), 3.0);                 // rays
	else if (mode == 1) v = pow(0.5 + 0.5 * sin(d * 18.0 - time * 3.0), 2.0);           // rings
	else if (mode == 2) v = fbm(uv * 3.0 + vec2(time * 0.3, -time * 0.2));              // fog / smoke / energy
	else if (mode == 3) v = pow(0.5 + 0.5 * sin(a * 3.0 + d * 10.0 - time * 2.0), 2.0); // swirl
	else if (mode == 4) { v = 0.7; col = hsb2rgb(vec3(a / 6.2831 + d - time * 0.2, 1.0, 1.0)); } // rainbow
	else if (mode == 5) { vec2 g = abs(fract(uv * 6.0 + vec2(0.0, time * 0.2)) - 0.5); v = smoothstep(0.42, 0.5, max(g.x, g.y)); } // cells
	else { vec2 cell = floor(uv * 14.0); float h = hash(cell); v = step(0.9, h) * (0.5 + 0.5 * sin(time * 3.0 + h * 40.0)); } // sparkles
	ALBEDO = col * v * fade * strength;
}
"""

const DARK_SHADER := """
shader_type spatial;
render_mode blend_mul, unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform float time;
uniform float strength = 0.6;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {  // rotated octaves hide the value-noise grid
	float v = 0.0; float a = 0.5; mat2 m = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6));
	for (int i = 0; i < 5; i++) { v += a * noise(p); p = m * p; a *= 0.5; }
	return v;
}
void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float d = length(uv);
	if (d > 1.0) discard;
	float shade = fbm(uv * 3.0 + time * 0.25) * (1.0 - smoothstep(0.4, 1.0, d)) * strength;
	ALBEDO = vec3(1.0 - shade);
}
"""

## Animation type -> pattern disc mode (see PATTERN_SHADER).
const PATTERNS := {
	"sunburst": 0, "revolving": 0,
	"wave": 1, "emanation": 1, "dome": 1, "ghost": 1,
	"fog": 2, "smokepatch": 2, "energy": 2,
	"vortex": 3, "witchwave": 3,
	"rainbowswirl": 4, "radialrainbow": 4,
	"hexa": 5, "grid": 5,
	"starlight": 6, "fairy": 6,
}
const DARKNESS_TYPES := ["magicalGloom", "roiling", "hole", "denseSmoke"]
const FLICKER_TYPES := {"torch": true, "flame": false, "siren": true}  # value: amplification = intensity / 5
const BEAM_TYPES := ["siren", "revolving"]
const FloorDisc = preload("res://scripts/floor_disc.gd")

static var _pattern_shader: Shader
static var _dark_shader: Shader

var light: Light3D
var type := ""
var speed := 5.0
var intensity := 5.0
var reverse := false
var base_energy := 1.0
var base_color := Color.WHITE
var _seed := randf() * 1000.0
var _noise := PackedFloat32Array()
var _beam: SpotLight3D
var _disc: MeshInstance3D


## `floor_offset` is the floor's height relative to the light (negative), `radius` in meters.
func setup(target: Light3D, animation: Dictionary, energy: float, color: Color, radius: float, floor_offset: float) -> void:
	light = target
	type = str(animation.get("type", ""))
	speed = float(animation.get("speed", 5))
	intensity = float(animation.get("intensity", 5))
	reverse = bool(animation.get("reverse", false))
	base_energy = energy
	base_color = color
	if type in FLICKER_TYPES:
		_noise.resize(2048)
		for i in _noise.size():
			_noise[i] = randf()
	if type in BEAM_TYPES:
		_beam = SpotLight3D.new()
		_beam.name = "Beam"
		_beam.spot_range = radius
		_beam.spot_angle = 20.0
		_beam.light_color = Color(1.0, 0.15, 0.1) if type == "siren" else color
		_beam.light_energy = energy * 1.5
		_beam.rotation.x = deg_to_rad(-20.0)
		light.add_child.call_deferred(_beam)
	if type in PATTERNS or type in DARKNESS_TYPES:
		_disc = FloorDisc.new()
		_disc.name = "Pattern"
		var plane := PlaneMesh.new()
		plane.size = Vector2.ONE * radius * 2.0
		_disc.mesh = plane
		_disc.floor_offset = floor_offset + 0.03
		var mat := ShaderMaterial.new()
		if type in DARKNESS_TYPES:
			if _dark_shader == null:
				_dark_shader = Shader.new()
				_dark_shader.code = DARK_SHADER
			mat.shader = _dark_shader
			mat.set_shader_parameter("strength", 0.3 + intensity * 0.05)
		else:
			if _pattern_shader == null:
				_pattern_shader = Shader.new()
				_pattern_shader.code = PATTERN_SHADER
			mat.shader = _pattern_shader
			mat.set_shader_parameter("mode", PATTERNS[type])
			mat.set_shader_parameter("tint", Vector3(color.r, color.g, color.b))
			mat.set_shader_parameter("strength", 0.02 + intensity * 0.014)  # intensity 5 -> 0.09
		_disc.material_override = mat
		light.add_child.call_deferred(_disc)


func _process(_delta: float) -> void:
	if light == null:
		return
	var t := float(Time.get_ticks_msec()) * (-1.0 if reverse else 1.0)
	var time := speed * t / 5000.0 + _seed  # animateTime in Foundry
	if type in FLICKER_TYPES:
		var amplification := intensity / 5.0 if FLICKER_TYPES[type] else 1.0
		light.light_energy = base_energy * (0.55 + _smooth_noise(time, 0.45 * amplification))  # brightnessPulse
	elif type == "pulse" or type == "reactivepulse":
		var low := (10.0 - intensity) * 0.1
		var w := 0.5 * (cos(time * 2.5) + 1.0)
		light.light_energy = base_energy * ((1.2 - low) * w + low)  # wave(1.2, i, w)
	elif type == "chroma":
		light.light_color = base_color.lerp(Color.from_hsv(fposmod(time * 0.25, 1.0), 1.0, 1.0), 0.8)
	elif _disc:
		light.light_energy = base_energy * (0.9 + 0.1 * sin(time * 2.0))
	var bright := light.get_node_or_null("Bright") as Light3D  # the bright radius (light_manager.gd) follows along
	if bright:
		var scale := light.light_energy / base_energy if base_energy > 0.0 else 1.0
		bright.light_energy = float(bright.get_meta("base_energy", bright.light_energy)) * scale
		if type == "chroma":
			bright.light_color = light.light_color
	if _beam:
		_beam.rotation.y = time * 2.0
	if _disc:
		_disc.material_override.set_shader_parameter("time", time)


## Foundry's SmoothNoise (scale 3): smoothstep-interpolated random references, range [0, amplitude].
func _smooth_noise(x: float, amplitude: float) -> float:
	var scaled := x * 3.0
	var x_floor := floori(scaled)
	var t := scaled - x_floor
	var smooth := t * t * (3.0 - 2.0 * t)
	var i0 := posmod(x_floor, _noise.size())
	var i1 := (i0 + 1) % _noise.size()
	return lerpf(_noise[i0], _noise[i1], smooth) * amplitude
