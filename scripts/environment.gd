extends Node
## Foundry's scene environment in 3D: darkness (night), global illumination and the ambience
## settings (Blend Ambience + base/dark Hue, Hue intensity, Luminosity, Saturation, Shadows).
##
## The ambience is a full-screen post-process running a direct port of Foundry's
## PrimaryCanvasGroupAmbienceFilter (client/canvas/rendering/filters/environment.mjs).
## Night follows Foundry's ambient colors (client/canvas/groups/environment.mjs).

signal darkness_changed(darkness: float)

const DARKNESS_COLOR := Color("303030")  # CONFIG.Canvas.darknessColor (Foundry v14)
const DAYLIGHT_COLOR := Color("eeeeee")  # CONFIG.Canvas.daylightColor (pure white without token vision)
const BRIGHTEST_COLOR := Color("ffffff")  # CONFIG.Canvas.brightestColor: what a bright light reaches
const SUN_ENERGY_DAY := 0.6
const AMBIENT_ENERGY_DAY := 0.45  # with the sun, a lit floor at darkness 0 shows the map about as bright as Foundry
const AMBIENT_ENERGY_NIGHT := 1.6  # at darkness 1 a floor is about the map x DARKNESS_COLOR, as in Foundry (offsets SSAO)

const AMBIENCE_SHADER := """
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform vec3 base_tint = vec3(1.0);  // linear RGB, like Foundry's uniform
uniform float base_intensity;
uniform float base_luminosity;
uniform float base_saturation;
uniform float base_shadows;
uniform vec3 dark_tint = vec3(1.0);
uniform float dark_intensity;
uniform float dark_luminosity;
uniform float dark_saturation;
uniform float dark_shadows;
uniform bool cycle = true;
uniform float darkness_level;

const vec3 BT709 = vec3(0.2126, 0.7152, 0.0722);
float luminance(vec3 c) { return dot(BT709, c); }
vec3 linear2grey(vec3 c) { return vec3(luminance(c)); }
vec3 linear2srgb(vec3 c) {
	vec3 a = 12.92 * c;
	vec3 b = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
	return mix(a, b, step(vec3(0.0031308), c));
}
vec3 srgb2linear(vec3 c) {
	vec3 a = c / 12.92;
	vec3 b = pow((c + 0.055) / 1.055, vec3(2.4));
	return mix(a, b, step(vec3(0.04045), c));
}
vec3 srgb2linearFast(vec3 c) { return c * c; }
vec3 colorClamp(vec3 c) { return clamp(c, vec3(0.0), vec3(1.0)); }
vec3 tintColorLinear(vec3 color, vec3 tint, float intensity) {
	float t = luminance(tint);
	float c = luminance(color);
	return mix(color, mix(mix(tint, vec3(1.0), (c - t) / (1.0 - t)), tint * (c / t), step(c, t)), intensity);
}

void fragment() {
	vec4 baseColor = texture(screen_tex, SCREEN_UV);
	float dl = darkness_level;

	vec3 tint;
	if (base_intensity > 0.0) tint = (cycle && dark_intensity > 0.0) ? mix(base_tint, dark_tint, dl) : base_tint;
	else if (dark_intensity > 0.0 && cycle) tint = dark_tint;
	else tint = vec3(1.0);
	float luminosityBase = cycle ? mix(base_luminosity, dark_luminosity, dl) : base_luminosity;
	float luminosity = luminosityBase * (luminosityBase >= 0.0 ? 1.2 : 0.8);
	float shadows = (cycle ? mix(base_shadows, dark_shadows, dl) : base_shadows) * 0.15;
	float intensity = cycle ? mix(base_intensity * base_intensity, dark_intensity * dark_intensity, dl)
		: base_intensity * base_intensity;
	float saturation = cycle ? mix(base_saturation, dark_saturation, dl) : base_saturation;

	vec3 rgb = baseColor.rgb;
	if (shadows > 0.0) {
		float l = luminance(srgb2linearFast(rgb));
		rgb *= min(l / shadows, 1.0);
	}
	if (luminosity != 0.0) rgb *= (1.0 + luminosity);
	rgb = srgb2linear(rgb);
	if (saturation != 0.0) rgb = mix(linear2grey(rgb), rgb, 1.0 + saturation);
	if (intensity > 0.0) rgb = tintColorLinear(colorClamp(rgb), tint, intensity);
	else rgb = colorClamp(rgb);
	COLOR = vec4(linear2srgb(rgb), 1.0);
}
"""

## Foundry's ambient colours for the current scene (sent by the module; Foundry's defaults until then).
## Lights use them too (light_manager.gd).
static var colors := {"darkness": DARKNESS_COLOR, "daylight": DAYLIGHT_COLOR, "brightest": BRIGHTEST_COLOR}

var env: Environment
var sun: DirectionalLight3D
## Darkness level currently shown (tweens toward the scene's value).
var darkness := 0.0

var _data := {}
var _layer: CanvasLayer
var _material: ShaderMaterial
var _tween: Tween


func _ready() -> void:
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR  # keep map colors as Foundry shows them
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.background_mode = Environment.BG_COLOR

	_layer = CanvasLayer.new()
	_layer.name = "Ambience"
	_layer.layer = -2  # right above the 3D view; then HD-2D post (-1), 2D image view (0), HUD (1)
	add_child(_layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = AMBIENCE_SHADER
	_material = ShaderMaterial.new()
	_material.shader = shader
	rect.material = _material
	_layer.add_child(rect)
	_layer.visible = false
	_show_darkness(0.0)


## Apply a Foundry environment block (serializeEnvironment in the module).
## `duration` (seconds): 0 shows the darkness right away (frames streamed from Foundry's own transition);
## more than 0 fades over that time (the Day/Night buttons when the scene isn't on the GM's canvas).
func apply(data: Dictionary, duration: float) -> void:
	_data = data
	var sent: Dictionary = data.get("colors", {})
	var daylight: Color = DAYLIGHT_COLOR if data.get("tokenVision", true) else Color.WHITE
	colors = {
		"darkness": Color.from_string(str(sent.get("darkness", "")), DARKNESS_COLOR),
		"daylight": Color.from_string(str(sent.get("daylight", "")), daylight),
		"brightest": Color.from_string(str(sent.get("brightest", "")), BRIGHTEST_COLOR)}
	var base: Dictionary = data.get("base", {})
	var dark: Dictionary = data.get("dark", {})
	var cycle: bool = data.get("cycle", true)
	_material.set_shader_parameter("cycle", cycle)
	for prefix in ["base", "dark"]:
		var values: Dictionary = base if prefix == "base" else dark
		_material.set_shader_parameter(prefix + "_tint", hue_tint(float(values.get("hue", 0))))
		for key in ["intensity", "luminosity", "saturation", "shadows"]:
			_material.set_shader_parameter("%s_%s" % [prefix, key], float(values.get(key, 0)))
	# Same condition as Foundry's ambienceFilter.enabled
	_layer.visible = has_effect(base) or (cycle and has_effect(dark))

	var target := clampf(float(data.get("darkness", 0)), 0.0, 1.0)
	if _tween:
		_tween.kill()
	if duration > 0.0 and not is_equal_approx(target, darkness):
		_tween = create_tween()
		_tween.tween_method(_show_darkness, darkness, target, duration)
	else:
		_show_darkness(target)


## Foundry's tint uniform: Color.fromHSL([hue, 1, 0.5]).linear
static func hue_tint(hue: float) -> Vector3:
	var c := Color.from_hsv(fposmod(hue, 1.0), 1.0, 1.0).srgb_to_linear()
	return Vector3(c.r, c.g, c.b)


static func has_effect(values: Dictionary) -> bool:
	return float(values.get("luminosity", 0)) != 0.0 or float(values.get("shadows", 0)) > 0.0 \
		or float(values.get("intensity", 0)) > 0.0 or float(values.get("saturation", 0)) != 0.0


func _show_darkness(d: float) -> void:
	darkness = d
	_material.set_shader_parameter("darkness_level", d)
	var daylight: Color = colors.daylight
	var background: Color = (colors.darkness as Color).lerp(daylight, 1.0 - d)  # Foundry's colors.background
	var lit_d := d
	var ambient := background
	var gl: Dictionary = _data.get("globalLight", {})
	var gl_range: Dictionary = gl.get("darkness", {})
	if gl.get("enabled", false) and d >= float(gl_range.get("min", 0)) and d <= float(gl_range.get("max", 1)):
		# Global illumination lights the whole scene: bright = daylight, dim = Foundry's "dim" color.
		var light_color := Color.from_string(str(gl.get("color")), Color.WHITE) if gl.get("color") is String else Color.WHITE
		if gl.get("bright", false):
			ambient = daylight * light_color
			lit_d = 0.0
		else:
			ambient = background.lerp(Color.WHITE, 0.25) * light_color
	sun.light_energy = SUN_ENERGY_DAY * (1.0 - lit_d)
	env.ambient_light_color = ambient
	env.ambient_light_energy = lerpf(AMBIENT_ENERGY_DAY, AMBIENT_ENERGY_NIGHT, lit_d)
	env.background_color = Color(0.02, 0.02, 0.04).lerp(Color(0.3, 0.32, 0.36), 1.0 - d)
	darkness_changed.emit(d)


# ---------------------------------------------------------------------------
# CPU copy of the ambience shader, used by the smoke test to check the math against Foundry's.
# ---------------------------------------------------------------------------

static func ambience_cpu(srgb: Vector3, data: Dictionary, dl: float) -> Vector3:
	var base: Dictionary = data.base
	var dark: Dictionary = data.dark
	var cycle: bool = data.cycle
	var bt := hue_tint(base.hue)
	var dt := hue_tint(dark.hue)
	var tint := Vector3.ONE
	if base.intensity > 0.0:
		tint = bt.lerp(dt, dl) if (cycle and dark.intensity > 0.0) else bt
	elif dark.intensity > 0.0 and cycle:
		tint = dt
	var lum_base: float = lerpf(base.luminosity, dark.luminosity, dl) if cycle else base.luminosity
	var luminosity := lum_base * (1.2 if lum_base >= 0.0 else 0.8)
	var shadows: float = (lerpf(base.shadows, dark.shadows, dl) if cycle else base.shadows) * 0.15
	var intensity: float = lerpf(base.intensity ** 2, dark.intensity ** 2, dl) if cycle else base.intensity ** 2
	var saturation: float = lerpf(base.saturation, dark.saturation, dl) if cycle else base.saturation
	var rgb := srgb
	if shadows > 0.0:
		var l := _lum(rgb * rgb)
		rgb *= minf(l / shadows, 1.0)
	if luminosity != 0.0:
		rgb *= 1.0 + luminosity
	rgb = Vector3(_to_linear(rgb.x), _to_linear(rgb.y), _to_linear(rgb.z))
	if saturation != 0.0:
		rgb = Vector3.ONE * _lum(rgb) + (rgb - Vector3.ONE * _lum(rgb)) * (1.0 + saturation)
	rgb = rgb.clamp(Vector3.ZERO, Vector3.ONE)
	if intensity > 0.0:
		var t := _lum(tint)
		var c := _lum(rgb)
		var tinted := tint * (c / t) if c <= t else tint.lerp(Vector3.ONE, (c - t) / (1.0 - t))
		rgb = rgb.lerp(tinted, intensity)
	return Vector3(_to_srgb(rgb.x), _to_srgb(rgb.y), _to_srgb(rgb.z))


static func _lum(c: Vector3) -> float:
	return c.dot(Vector3(0.2126, 0.7152, 0.0722))


static func _to_linear(c: float) -> float:
	return c / 12.92 if c < 0.04045 else pow((c + 0.055) / 1.055, 2.4)


static func _to_srgb(c: float) -> float:
	return 12.92 * c if c < 0.0031308 else 1.055 * pow(c, 1.0 / 2.4) - 0.055
