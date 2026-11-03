extends Node3D
## Mirrors Foundry ambient lights. Light settings follow Foundry's own formulas
## (client/canvas/sources/base-light-source.mjs and rendering/shaders/lighting/base-lighting.mjs).
##
## Foundry restores the map under a light to a light level (dim: 25 % of the way from the night colour to
## white, bright: white) and adds the light's colour on top. Each Foundry light becomes a Godot light
## over the dim radius plus a "Bright" child over the bright radius, with energies that bring the floor to
## those levels (light_levels). The floor and flat images are lit without the slant falloff
## (FLAT_LIGHT), so a light's area is evenly lit like Foundry's.

const SceneInfo = preload("res://scripts/scene_info.gd")
const LightAnimator = preload("res://scripts/light_animator.gd")
const FloorDisc = preload("res://scripts/floor_disc.gd")
const SceneEnvironment = preload("res://scripts/environment.gd")

const LIGHT_HEIGHT := 2.0  # meters above the light's elevation
const CONE_TILT := -35.0  # degrees: cone lights aim down toward the floor
const BURN_TECHNIQUES := [4, 5, 6, 9]  # color burn, internal/external burn, invert absorption
const NEGATIVE_ENERGY := 2.0  # darkness sources: enough to take a lit floor back to night

## light() for surfaces lying flat (the map, flat tiles and tokens), drawn like Foundry's flat light discs:
## no slant (N·L) falloff, evenly lit out to where Foundry's falloff starts, then smoothly to the edge.
## Godot's point-light falloff is (1 - x^4)^2 with x = distance / range (attenuation 0), times shadow, so x
## comes back from ATTENUATION. Where the fade starts (0..1 of the range) comes in as the light's
## specular (SPECULAR_AMOUNT = 2 x light_specular, set in _set_shape). The sun keeps normal shading.
const FLAT_LIGHT := """
void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * ATTENUATION * max(dot(NORMAL, LIGHT), 0.0);
	} else {
		float x = pow(max(1.0 - sqrt(ATTENUATION), 0.0), 0.25);
		DIFFUSE_LIGHT += LIGHT_COLOR / PI * (1.0 - smoothstep(SPECULAR_AMOUNT, 1.0, x));
	}
}
"""

## Foundry's background adjustments (contrast, saturation, exposure, shadows), applied to the floor
## under the light. Reads what's already drawn and grades it, like Foundry's light background layer.
const GRADE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float contrast;
uniform float saturation;
uniform float shadows;
uniform float exposure;
uniform float attenuation;
uniform float ratio;
const vec3 BT709 = vec3(0.2126, 0.7152, 0.0722);
float perceivedBrightness(vec3 c) { return sqrt(dot(BT709, c * c)); }
vec3 to_srgb(vec3 c) { return mix(12.92 * c, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c)); }
vec3 to_linear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)); }
void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float dist = length(uv);
	if (dist > 1.0) discard;
	vec3 c = to_srgb(max(texture(screen_tex, SCREEN_UV).rgb, vec3(0.0)));
	if (contrast != 0.0) c = (c - 0.5) * (contrast + 1.0) + 0.5;
	if (saturation != 0.0) c = mix(vec3(perceivedBrightness(c)), c, 1.0 + saturation);
	if (exposure > 0.0) {
		float half_exposure = exposure * 0.5;
		float strength = attenuation * 0.25;
		float final_exposure = half_exposure
			* (1.0 - smoothstep(ratio * (0.98 - strength), clamp(ratio * (1.02 + strength), 0.0001, 1.0), dist))
			+ half_exposure;
		c *= (1.0 + final_exposure);
	}
	if (shadows != 0.0) c *= mix(1.0, smoothstep(0.50, 0.80, perceivedBrightness(c)), shadows);
	ALBEDO = to_linear(clamp(c, 0.0, 1.0));
	ALPHA = attenuation != 0.0 ? smoothstep(1.0, 1.0 - attenuation, dist) : 1.0;
}
"""

static var _grade_shader: Shader
## How strongly lights show as beams in volumetric fog (HD-2D "Light shafts"; set by post_process.gd).
static var volumetric_energy := 1.0

var info: SceneInfo
## Current scene darkness; lights only shine inside their own darkness range.
var darkness := 0.0
var _lights := {}  # id -> {"node": Light3D, "data": Dictionary}


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_lights.clear()


func upsert(data: Dictionary) -> void:
	var entry: Dictionary = _lights.get(data.id, {})
	if entry.is_empty():
		var node := OmniLight3D.new()
		node.name = "Light_" + data.id
		add_child(node)
		entry = {"node": node}
		_lights[data.id] = entry
	entry.data = data
	_apply(entry)


func remove(id: String) -> void:
	if _lights.has(id):
		var light: Light3D = _lights[id].node
		remove_child(light)
		light.queue_free()
		_lights.erase(id)


func set_darkness(value: float) -> void:
	darkness = value
	for entry in _lights.values():
		_apply(entry)


func get_light(id: String) -> Light3D:
	return _lights[id].node if _lights.has(id) else null


func _apply(entry: Dictionary) -> void:
	var data: Dictionary = entry.data
	var light: Light3D = entry.node
	light.position = info.to_3d(data.x, data.y, float(data.get("elevation", 0))) + Vector3.UP * LIGHT_HEIGHT
	light = apply_light_data(light, data, info, darkness, -LIGHT_HEIGHT, float(data.get("rotation", 0)))
	entry.node = light
	if data.get("hidden", false):
		light.visible = false


## Foundry's colorationAlpha: how strongly the light's color shows, per coloration technique.
static func coloration_alpha(alpha: float, technique: int) -> float:
	if technique == 0:
		return alpha * alpha  # legacy
	if technique in BURN_TECHNIQUES:
		return alpha
	return alpha * 2.0  # adaptive techniques


## Foundry maps the user's attenuation (0..1) through this curve before using it.
static func computed_attenuation(attenuation: float) -> float:
	return (cos(PI * pow(attenuation, 1.5)) - 1.0) / -2.0


## Shared with token lights. `data` holds Foundry LightData fields (bright/dim in grid units);
## `floor_offset` is the floor height relative to the light; `rotation` (degrees) aims cone lights.
## Returns the light node, which is replaced when a light switches between all-around and cone.
static func apply_light_data(light: Light3D, data: Dictionary, scene: SceneInfo, darkness: float,
		floor_offset: float, rotation: float) -> Light3D:
	var bright := float(data.get("bright", 0))
	var radius := maxf(bright, float(data.get("dim", 0)))
	var angle := float(data.get("angle", 360))
	light = _ensure_type(light, angle < 360.0 and radius > 0.0)
	# Foundry only shows a light while the scene darkness is inside its darkness range.
	var range_: Dictionary = data.get("darkness", {})
	var active := darkness >= float(range_.get("min", 0)) - 0.0001 and darkness <= float(range_.get("max", 1)) + 0.0001
	light.visible = radius > 0.0 and active
	if radius <= 0.0:
		return light
	var radius_m := scene.units_to_m(radius)
	var attenuation := computed_attenuation(float(data.get("attenuation", 0.5)))
	_set_shape(light, radius_m, 1.0 - attenuation, angle, rotation)  # Foundry: smoothstep(1, 1 - attenuation)
	light.light_negative = bool(data.get("negative", false))  # darkness source
	light.shadow_enabled = true
	light.light_volumetric_fog_energy = volumetric_energy

	var levels := light_levels(data, darkness, SceneEnvironment.colors)
	var bright_light := _bright_child(light, bright > 0.0 and bright < radius and not light.light_negative)
	if light.light_negative:
		light.light_color = Color.WHITE
		light.light_energy = NEGATIVE_ENERGY
	else:
		_set_energy(light, levels.dim if bright_light else levels.dim + levels.bright)
	if bright_light:
		# Foundry switches from bright to dim over ratio x (0.99 - a7 .. 1.01 + a7), a7 = 0.7 x attenuation.
		var a7 := attenuation * 0.7
		_set_shape(bright_light, scene.units_to_m(bright) * (1.01 + a7), (0.99 - a7) / (1.01 + a7), angle, 0.0)
		bright_light.rotation = Vector3.ZERO  # turns with its parent cone
		bright_light.shadow_enabled = true
		bright_light.light_volumetric_fog_energy = volumetric_energy
		_set_energy(bright_light, levels.bright)
		bright_light.set_meta("base_energy", bright_light.light_energy)

	_apply_grading(light, data, radius_m, floor_offset, attenuation, bright / radius)
	_apply_animation(light, data.get("animation", {}), light.light_energy, light.light_color, radius_m, floor_offset)
	return light


## Energy (linear RGB, as a Color that may go over 1) each part of a Foundry light adds to the floor:
## "dim" over the whole radius, "bright" on top inside the bright radius. Together with the scene's
## own light (the night colour) the floor reaches Foundry's level: map x (illumination + colour x
## colorationAlpha), worked out in sRGB as Foundry does and turned into linear light.
static func light_levels(data: Dictionary, darkness: float, colors: Dictionary) -> Dictionary:
	var background: Color = (colors.daylight as Color).lerp(colors.darkness, darkness)
	var bright_color: Color = colors.brightest
	var dim_color := background.lerp(bright_color, 0.25)
	var exposure := float(data.get("luminosity", 0.5)) * 2.0 - 1.0
	var bright_scale := 1.0 + exposure * 0.5 if exposure > 0.0 else 1.0 + exposure
	var dim_scale := 1.0 + exposure * 0.25 if exposure > 0.0 else 1.0 + exposure
	var tint := Color.BLACK
	var color = data.get("color")
	if color is String:
		var k := coloration_alpha(float(data.get("alpha", 0.5)), int(data.get("coloration", 1)))
		tint = Color.from_string(color, Color.WHITE) * k
	var level := func(illum: Color, scale: float) -> Color:
		var c := Color(maxf(illum.r * scale, background.r), maxf(illum.g * scale, background.g),
			maxf(illum.b * scale, background.b))
		return _linear(Color(c.r + tint.r, c.g + tint.g, c.b + tint.b))
	var base := _linear(background)
	var dim: Color = level.call(dim_color, dim_scale)
	var full: Color = level.call(bright_color, bright_scale)
	return {"dim": _positive(dim - base), "bright": _positive(full - dim)}


static func _linear(c: Color) -> Color:
	return Color(_to_linear(c.r), _to_linear(c.g), _to_linear(c.b))


## sRGB to linear, also for values over 1 (a coloured light on top of a fully lit floor).
static func _to_linear(c: float) -> float:
	return c / 12.92 if c < 0.04045 else pow((c + 0.055) / 1.055, 2.4)


static func _positive(c: Color) -> Color:
	return Color(maxf(c.r, 0.0), maxf(c.g, 0.0), maxf(c.b, 0.0))


## Puts a linear RGB energy on a light: its colour (sRGB, max channel 1) times its energy.
static func _set_energy(light: Light3D, v: Color) -> void:
	var peak := maxf(v.r, maxf(v.g, v.b))
	light.light_color = Color(v.r / peak, v.g / peak, v.b / peak).linear_to_srgb() if peak > 0.0 else Color.WHITE
	light.light_energy = peak


## Range and falloff: the light reaches `radius_m` across the floor (LIGHT_HEIGHT below it) and fades from
## `fade_start` (0..1 of the radius) to the edge on flat surfaces (FLAT_LIGHT), like Foundry's smoothstep.
static func _set_shape(light: Light3D, radius_m: float, fade_start: float, angle: float, rotation: float) -> void:
	var range_m := sqrt(radius_m * radius_m + LIGHT_HEIGHT * LIGHT_HEIGHT)
	light.light_specular = clampf(fade_start, 0.0, 0.999) * 0.5
	if light is SpotLight3D:
		var spot := light as SpotLight3D
		spot.spot_range = range_m
		spot.spot_angle = clampf(angle / 2.0, 1.0, 89.0)
		spot.spot_attenuation = 0.0
		# Foundry's rotation 0 points down the map (south), increasing clockwise.
		spot.rotation = Vector3(deg_to_rad(CONE_TILT), PI - deg_to_rad(rotation), 0.0)
	else:
		var omni := light as OmniLight3D
		omni.omni_range = range_m
		omni.omni_attenuation = 0.0


## The extra light over a Foundry light's bright radius (same type as `light`), or null when not needed.
static func _bright_child(light: Light3D, needed: bool) -> Light3D:
	var child := light.get_node_or_null("Bright") as Light3D
	if child and (not needed or (child is SpotLight3D) != (light is SpotLight3D)):
		light.remove_child(child)
		child.queue_free()
		child = null
	if needed and child == null:
		child = SpotLight3D.new() if light is SpotLight3D else OmniLight3D.new()
		child.name = "Bright"
		light.add_child(child)
	return child


## Swap an OmniLight3D for a SpotLight3D (or back), keeping name, parent and position.
static func _ensure_type(light: Light3D, cone: bool) -> Light3D:
	if (light is SpotLight3D) == cone:
		return light
	var replacement: Light3D = SpotLight3D.new() if cone else OmniLight3D.new()
	replacement.name = light.name
	replacement.position = light.position
	var parent := light.get_parent()
	if parent:
		var index := light.get_index()
		parent.remove_child(light)
		parent.add_child(replacement)
		parent.move_child(replacement, index)
	light.queue_free()
	return replacement


static func _apply_grading(light: Light3D, data: Dictionary, radius_m: float, floor_offset: float,
		attenuation: float, ratio: float) -> void:
	var contrast := float(data.get("contrast", 0))
	contrast = contrast * 0.5 if contrast < 0.0 else contrast  # as Foundry passes it to the shader
	var saturation := float(data.get("saturation", 0))
	var shadows := float(data.get("shadows", 0))
	var exposure := float(data.get("luminosity", 0.5)) * 2.0 - 1.0
	var disc := light.get_node_or_null("Grade") as MeshInstance3D
	var needed := contrast != 0.0 or saturation != 0.0 or shadows != 0.0 or exposure > 0.0
	if not needed:
		if disc:
			light.remove_child(disc)
			disc.queue_free()
		return
	if disc == null:
		if _grade_shader == null:
			_grade_shader = Shader.new()
			_grade_shader.code = GRADE_SHADER
		disc = FloorDisc.new()
		disc.name = "Grade"
		disc.mesh = PlaneMesh.new()
		var mat := ShaderMaterial.new()
		mat.shader = _grade_shader
		disc.material_override = mat
		light.add_child(disc)
	disc.floor_offset = floor_offset + 0.02
	(disc.mesh as PlaneMesh).size = Vector2.ONE * radius_m * 2.0
	var m := disc.material_override as ShaderMaterial
	m.set_shader_parameter("contrast", contrast)
	m.set_shader_parameter("saturation", saturation)
	m.set_shader_parameter("shadows", shadows)
	m.set_shader_parameter("exposure", exposure)
	m.set_shader_parameter("attenuation", attenuation)
	m.set_shader_parameter("ratio", ratio)


# ---------------------------------------------------------------------------
# What Foundry draws, on the CPU: the reference the light tests compare the 3D view against.
# ---------------------------------------------------------------------------

## The colour Foundry shows for one pixel of the map (`map`, sRGB) lit by one light at `dist` (0 = centre,
## 1 = edge of the dim radius). `colors`: Foundry's ambient colours {darkness, daylight, brightest}.
## Illumination (MAX_COLOR, multiplied onto the map) + coloration (added), from base-lighting.mjs,
## illumination-lighting.mjs, coloration-lighting.mjs and groups/environment.mjs.
static func foundry_light_cpu(map: Color, data: Dictionary, darkness: float, dist: float, colors: Dictionary) -> Color:
	var background: Color = (colors.daylight as Color).lerp(colors.darkness, darkness)
	var bright_color: Color = colors.brightest
	var dim_color := background.lerp(bright_color, 0.25)
	var bright := float(data.get("bright", 0))
	var radius := maxf(bright, float(data.get("dim", 0)))
	var ratio := bright / radius if radius > 0.0 else 0.0
	var attenuation := computed_attenuation(float(data.get("attenuation", 0.5)))
	var a7 := attenuation * 0.7
	var illum := bright_color.lerp(dim_color, _glsl_smoothstep(ratio * (0.99 - a7), clampf(ratio * (1.01 + a7), 0.0001, 1.0), dist))
	var exposure := float(data.get("luminosity", 0.5)) * 2.0 - 1.0
	if exposure > 0.0:
		var quart := exposure * 0.25
		var s := attenuation * 0.25
		illum *= 1.0 + quart * (1.0 - _glsl_smoothstep(ratio * (0.98 - s), clampf(ratio * (1.02 + s), 0.0001, 1.0), dist)) + quart
	elif exposure < 0.0:
		illum *= 1.0 + exposure
	var depth := 1.0 if dist <= 1.0 else 0.0
	if attenuation != 0.0:
		depth *= _glsl_smoothstep(1.0, 1.0 - attenuation, dist)
	illum = background.lerp(illum, depth)
	illum = Color(maxf(illum.r, background.r), maxf(illum.g, background.g), maxf(illum.b, background.b))
	var out := Color(map.r * illum.r, map.g * illum.g, map.b * illum.b)
	var color = data.get("color")
	if color is String:
		var c := Color.from_string(color, Color.WHITE)
		var reflection := sqrt(0.2126 * map.r * map.r + 0.7152 * map.g * map.g + 0.0722 * map.b * map.b)
		var k := coloration_alpha(float(data.get("alpha", 0.5)), int(data.get("coloration", 1))) * reflection * depth
		out += Color(c.r * k, c.g * k, c.b * k, 0.0)
	return Color(clampf(out.r, 0.0, 1.0), clampf(out.g, 0.0, 1.0), clampf(out.b, 0.0, 1.0))


## GLSL smoothstep, which also works with edge0 > edge1 (Foundry's falloff relies on that).
static func _glsl_smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func _apply_animation(light: Light3D, animation: Dictionary, energy: float, color: Color,
		radius_m: float, floor_offset: float) -> void:
	var type = animation.get("type")
	var key := "%s|%s|%s|%s|%.3f|%s|%.3f" % [type, animation.get("speed"), animation.get("intensity"),
		animation.get("reverse"), radius_m, color.to_html(), energy]
	if light.get_meta("animation_key", "") == key:
		return
	light.set_meta("animation_key", key)
	for child in light.get_children():
		if child.name != "Grade" and child.name != "Bright":
			light.remove_child(child)
			child.queue_free()
	if not type is String or type == "":
		return
	var animator := LightAnimator.new()
	animator.name = "Animator"
	light.add_child(animator)
	animator.setup(light, animation, energy, color, radius_m, floor_offset)
