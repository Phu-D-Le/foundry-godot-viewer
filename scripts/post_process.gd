extends Node
## HD-2D post-processing (the Octopath Traveler / Triangle Strategy look):
##   tilt-shift depth of field  - a sharp band at the camera's focus point, nearer and farther blurred
##   bloom                      - Environment glow
##   fog                        - volumetric haze
##   light shafts               - sun beams fixed in the world, slanting down from the sun (SunBeams) + lamp beams in the fog
##   grading                    - contrast / saturation (Environment adjustments) + warmth
##   vignette, film grain       - screen pass
##   light motes                - drifting glowing specks around the view
##   pixel art                  - unsmoothed token/tile sprites (VisualBuilder.pixel_art)
## Settings come from Foundry (module post-process.js): world defaults or the scene's own.

signal pixel_art_changed

const VisualBuilder = preload("res://scripts/visual_builder.gd")
const LightManager = preload("res://scripts/light_manager.gd")
const SunBeams = preload("res://scripts/sun_beams.gd")

## Same keys, ranges and defaults as POST_FIELDS / POST_DEFAULTS in the module's post-process.js.
const FIELDS := [
	{"key": "enabled", "label": "HD-2D post-processing", "type": "bool"},
	{"key": "dofStrength", "label": "Tilt-shift blur", "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "focusBand", "label": "Sharp band (grid units)", "min": 1.0, "max": 100.0, "step": 1.0},
	{"key": "bloom", "label": "Bloom", "min": 0.0, "max": 2.0, "step": 0.01},
	{"key": "bloomThreshold", "label": "Bloom threshold", "min": 0.0, "max": 2.0, "step": 0.01},
	{"key": "fog", "label": "Fog", "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "shafts", "label": "Light shafts", "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "vignette", "label": "Vignette", "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "warmth", "label": "Warmth", "min": -1.0, "max": 1.0, "step": 0.01},
	{"key": "saturation", "label": "Saturation", "min": 0.0, "max": 2.0, "step": 0.01},
	{"key": "contrast", "label": "Contrast", "min": 0.0, "max": 2.0, "step": 0.01},
	{"key": "grain", "label": "Film grain", "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "particles", "label": "Light motes", "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "pixelArt", "label": "Crisp pixel-art sprites", "type": "bool"},
]
const DEFAULTS := {
	"enabled": true, "dofStrength": 0.5, "focusBand": 20.0, "bloom": 0.8, "bloomThreshold": 0.9, "fog": 0.25, "shafts": 0.5,
	"vignette": 0.45, "warmth": 0.25, "saturation": 1.15, "contrast": 1.1, "grain": 0.1, "particles": 0.4,
	"pixelArt": true,
}
const MAX_MOTES := 300

const SCREEN_SHADER := """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform float warmth;
uniform float vignette;
uniform float grain;
void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	// Warmth: white-balance shift toward amber (+) or blue (-)
	c *= vec3(1.0 + 0.10 * warmth, 1.0 + 0.015 * warmth, 1.0 - 0.13 * warmth);
	// Vignette: soft darkening toward the corners
	float r = length((SCREEN_UV - 0.5) * vec2(1.0, 0.85)) * 1.55;
	c *= 1.0 - vignette * smoothstep(0.35, 1.05, r);
	// Film grain
	float n = fract(sin(dot(floor(FRAGCOORD.xy) + fract(TIME * 7.3) * 113.0, vec2(12.9898, 78.233))) * 43758.5453);
	c += (n - 0.5) * grain * 0.09;
	COLOR = vec4(clamp(c, 0.0, 1.0), 1.0);
}
"""

const MOTE_SHADER := """
shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, shadows_disabled, cull_disabled;
void vertex() {  // face the camera, keeping the particle's scale
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
}
void fragment() {
	float glow = pow(clamp(1.0 - length(UV - 0.5) * 2.0, 0.0, 1.0), 2.0);
	ALBEDO = vec3(1.6, 1.35, 0.9) * glow * COLOR.a;  // HDR, so bloom catches it
}
"""

signal lights_changed  ## light beam strength in the fog changed; lights must be re-applied

var env: Environment
var camera: Camera3D
var sun: DirectionalLight3D
var mpu := 0.3048  ## meters per grid unit, from the scene
var settings := DEFAULTS.duplicate()
## Scene weather has fog (weather.gd): volumetric fog stays on for it.
var weather_fog := false

var _attributes := CameraAttributesPractical.new()
var _layer: CanvasLayer
var _material: ShaderMaterial
var _motes: GPUParticles3D
var _motes_box: ParticleProcessMaterial
var _beams: Node3D


func _ready() -> void:
	camera.attributes = _attributes
	_layer = CanvasLayer.new()
	_layer.name = "PostProcess"
	_layer.layer = -1  # after Foundry's ambience (-2), below the 2D image view (0) and the HUD (1)
	add_child(_layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = SCREEN_SHADER
	_material = ShaderMaterial.new()
	_material.shader = shader
	rect.material = _material
	_layer.add_child(rect)
	_build_motes()
	_beams = SunBeams.new()
	_beams.name = "SunBeams"
	add_child(_beams)
	apply(DEFAULTS)


static func normalize(s: Dictionary) -> Dictionary:
	var out := {}
	for field in FIELDS:
		var key: String = field.key
		var value = s.get(key, DEFAULTS[key])
		if field.get("type") == "bool":
			out[key] = bool(value) if value is bool else DEFAULTS[key]
		else:
			out[key] = clampf(float(value), field.min, field.max) if (value is float or value is int) else DEFAULTS[key]
	return out


## Weather fog on or off (weather.gd); re-applies the settings so volumetric fog follows.
func set_weather_fog(on: bool) -> void:
	if on != weather_fog:
		weather_fog = on
		apply(settings)


func apply(s: Dictionary) -> void:
	var previous_pixel_art: bool = settings.get("pixelArt", false) and settings.get("enabled", false)
	settings = normalize(s)
	var on: bool = settings.enabled
	# Bloom
	env.glow_enabled = on and settings.bloom > 0.0
	env.glow_intensity = settings.bloom
	env.glow_strength = 1.0
	env.glow_bloom = clampf(settings.bloom * 0.08, 0.0, 1.0)
	env.glow_hdr_threshold = settings.bloomThreshold
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	for level in 7:
		env.set_glow_level(level, 1.0 if level >= 1 and level <= 4 else 0.0)
	# Fog & light shafts
	# Volumetric shafts need some air: a small floor of density when shafts are on, even with no haze.
	# Weather fog (weather.gd) is a FogVolume, which needs volumetric fog on even with HD-2D off.
	var haze: bool = on and (settings.fog > 0.0 or settings.shafts > 0.0)
	env.volumetric_fog_enabled = haze or weather_fog
	env.volumetric_fog_ambient_inject = 1.0 if weather_fog else 0.0  # weather fog is lit by the whole sky, like mist
	env.volumetric_fog_density = maxf(settings.fog * 0.012, settings.shafts * 0.004) if haze else 0.0
	env.volumetric_fog_albedo = Color(1.0, 0.95, 0.85)
	env.volumetric_fog_anisotropy = 0.6  # scatter forward: shafts toward the camera, less milky haze
	env.volumetric_fog_length = 80.0
	# Grading
	env.adjustment_enabled = on
	env.adjustment_contrast = settings.contrast
	env.adjustment_saturation = settings.saturation
	env.adjustment_brightness = 1.0
	# Screen pass
	_layer.visible = on and (settings.vignette > 0.0 or settings.grain > 0.0 or settings.warmth != 0.0)
	_material.set_shader_parameter("warmth", settings.warmth)
	_material.set_shader_parameter("vignette", settings.vignette)
	_material.set_shader_parameter("grain", settings.grain)
	# Light motes
	_motes.amount = maxi(1, int(MAX_MOTES * settings.particles))
	_motes.emitting = on and settings.particles > 0.0
	_motes.visible = _motes.emitting
	# Tilt-shift (distances follow the camera in update())
	_attributes.dof_blur_near_enabled = on and settings.dofStrength > 0.0
	_attributes.dof_blur_far_enabled = _attributes.dof_blur_near_enabled
	_attributes.dof_blur_amount = settings.dofStrength * 0.25
	# Light beams through the fog (every light; LightManager applies it)
	var beam_energy: float = 1.0 + (settings.shafts * 4.0 if on else 0.0)
	if not is_equal_approx(beam_energy, LightManager.volumetric_energy):
		LightManager.volumetric_energy = beam_energy
		lights_changed.emit()
	# Pixel art
	var pixel_art: bool = on and settings.pixelArt
	VisualBuilder.pixel_art = pixel_art
	if pixel_art != previous_pixel_art:
		pixel_art_changed.emit()


## Call every frame with the camera's distance to what it looks at (the orbit pivot).
func update(focus_distance: float, pivot: Vector3) -> void:
	var band := maxf(float(settings.focusBand) * mpu, 0.5)
	_attributes.dof_blur_near_distance = maxf(focus_distance - band / 2.0, 0.05)
	_attributes.dof_blur_near_transition = band * 0.75
	_attributes.dof_blur_far_distance = focus_distance + band / 2.0
	_attributes.dof_blur_far_transition = band * 1.5
	_update_beams()
	if _motes.emitting:
		_motes.global_position = pivot + Vector3.UP * 1.0
		var extent := clampf(focus_distance * 0.45, 3.0, 40.0)
		_motes_box.emission_box_extents = Vector3(extent, 1.2, extent)
		_motes.visibility_aabb = AABB(Vector3(-extent, -2.0, -extent) * 1.5, Vector3(extent, 4.0, extent) * 3.0)


## Lay out the sun beams for a scene (`size` in meters).
func set_scene(size: Vector2, scene_id: String) -> void:
	_beams.rebuild(size, scene_id)
	_update_beams()


## Beam brightness follows the setting and the sun (so they fade out as darkness falls).
func _update_beams() -> void:
	var strength := 0.0
	if settings.enabled and sun != null:
		strength = float(settings.shafts) * clampf(sun.light_energy / 0.6, 0.0, 1.0)
	_beams.update(sun, strength)


func _build_motes() -> void:
	_motes = GPUParticles3D.new()
	_motes.name = "LightMotes"
	_motes.local_coords = false  # motes stay in the world while the camera moves
	_motes.lifetime = 9.0
	_motes.preprocess = 9.0
	_motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_motes_box = ParticleProcessMaterial.new()
	_motes_box.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_motes_box.emission_box_extents = Vector3(8.0, 1.2, 8.0)
	_motes_box.direction = Vector3(0.0, 1.0, 0.0)
	_motes_box.spread = 70.0
	_motes_box.initial_velocity_min = 0.03
	_motes_box.initial_velocity_max = 0.12
	_motes_box.gravity = Vector3(0.0, 0.02, 0.0)
	_motes_box.turbulence_enabled = true
	_motes_box.turbulence_noise_strength = 0.4
	_motes_box.turbulence_noise_speed_random = 0.3
	_motes_box.scale_min = 0.6
	_motes_box.scale_max = 1.4
	var fade := Gradient.new()  # fade in and out over each mote's life
	fade.set_color(0, Color(1, 1, 1, 0))
	fade.set_color(1, Color(1, 1, 1, 0))
	fade.add_point(0.2, Color(1, 1, 1, 1))
	fade.add_point(0.8, Color(1, 1, 1, 1))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	_motes_box.color_ramp = ramp
	_motes.process_material = _motes_box
	var quad := QuadMesh.new()
	quad.size = Vector2(0.05, 0.05)
	var shader := Shader.new()
	shader.code = MOTE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	quad.material = mat
	_motes.draw_pass_1 = quad
	add_child(_motes)
