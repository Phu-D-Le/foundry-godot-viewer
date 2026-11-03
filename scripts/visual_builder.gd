extends RefCounted
## Builds the 3D look of a token or a tile with "Custom Appearance", in one of the styles:
##   billboard - upright image that always turns to the camera
##   cross     - two or more upright planes with the image, crossing in an X or star (crossPlanes)
##   flat      - image lying on the floor, like Foundry's top-down view
##   standee   - image cut out along its outline and extruded (token_mesh.gd)
##   coin      - thick disc with the image on top (token_mesh.gd)
##   model     - a .glb model
## `d` holds the Foundry settings: img, model, scaleX/Y/Z (every style; X = width, Y = height, or the
## image's length for flat; Z = depth), modelScale (older uniform model scale), modelRotation, standeeThickness (cm).

const TokenMesh = preload("res://scripts/token_mesh.gd")
const LightManager = preload("res://scripts/light_manager.gd")
const OcclusionCutter = preload("res://scripts/occlusion_cutter.gd")

## HD-2D "Crisp pixel-art sprites" (post_process.gd): image surfaces skip texture smoothing.
static var pixel_art := false

const CLEARANCE := 0.04  # every style starts this far above the floor
const DEFAULT_STANDEE_THICKNESS_CM := 12.0

## "Cut out white" (color to alpha, same math as the Foundry module's tile-blend.js): white becomes
## transparent, clearly colored pixels stay exactly as they are, light edges fade with their color
## un-mixed from white. Lit like the rest of the scene. %s is filled in per variant (see _cutout_shader).
## tolerance < 0 ("plain" blend, used by tokens): the image as it is, with its own alpha.
## flash / saturation: token hit reactions (hit_reaction.gd); the defaults change nothing.
## hue: Hue Shift in degrees (tiles), the same matrix as the Foundry module's tile-blend.js hueMatrix.
## Surfaces lying flat are lit like Foundry's flat light discs (LightManager.FLAT_LIGHT).
const CUTOUT_SHADER := """
shader_type spatial;
render_mode cull_disabled%s;
uniform sampler2D tex : %s;  // raw sRGB values, as in the image editor math
uniform vec4 tint : source_color = vec4(1.0);
uniform float tolerance = 0.1;
uniform bool billboard = false;
uniform float roll = 0.0;
uniform vec4 flash_color : source_color = vec4(1.0);
uniform float flash = 0.0;
uniform float saturation = 1.0;
uniform vec4 status_tint : source_color = vec4(1.0, 1.0, 1.0, 0.0);  // rgb: color, a: amount (token_status.gd)
uniform bool ghosted = false;  // drawn by the ghost overlay instead (hit_reaction.gd: Ethereal, Invisible)
instance uniform bool see_cut_on = false;  // occlusion_cutter.gd: holes around tokens behind this tile (tiles only)
//SEE_CUT_GLSL
uniform float hue = 0.0;
const float SOFTNESS = 0.1;
vec3 to_linear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)); }
vec3 hue_shift(vec3 c, float degrees) {  // PIXI ColorMatrixFilter.hue, on sRGB values
	float r = radians(degrees);
	float k = (1.0 - cos(r)) / 3.0;
	float s = sqrt(1.0 / 3.0) * sin(r);
	float d = cos(r) + k;
	return clamp(vec3(d * c.r + (k - s) * c.g + (k + s) * c.b,
		(k + s) * c.r + d * c.g + (k - s) * c.b,
		(k - s) * c.r + (k + s) * c.g + d * c.b), 0.0, 1.0);
}
void vertex() {
	if (billboard) {  // upright, turning around Y to face the camera (like BILLBOARD_FIXED_Y), keeping the scale
		vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz));
		vec3 up = vec3(0.0, 1.0, 0.0);
		// roll: turned in the view (token_status.gd: lying down when prone, trembling when frightened)
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4((right * cos(roll) + up * sin(roll)) * length(MODEL_MATRIX[0].xyz), 0.0),
			vec4((up * cos(roll) - right * sin(roll)) * length(MODEL_MATRIX[1].xyz), 0.0),
			vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))) * length(MODEL_MATRIX[2].xyz), 0.0),
			MODEL_MATRIX[3]);
	}
}
void fragment() {
	if (ghosted) discard;
	vec4 c = texture(tex, UV);
	float a = 1.0;
	vec3 rgb = c.rgb;
	if (tolerance >= 0.0) {
		float d = max(max(1.0 - c.r, 1.0 - c.g), 1.0 - c.b);
		a = clamp((d - tolerance) / SOFTNESS, 0.0, 1.0);
		rgb = a > 0.0 ? clamp(1.0 - (1.0 - c.rgb) / a, 0.0, 1.0) : vec3(1.0);
	}
	if (hue != 0.0) rgb = hue_shift(rgb, hue);
	rgb = to_linear(rgb) * tint.rgb;
	float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
	rgb = mix(vec3(luma), rgb, saturation);
	rgb = mix(rgb, luma * status_tint.rgb * 1.5, status_tint.a);  // condition color (poisoned green, stone, ...)
	ALBEDO = mix(rgb, flash_color.rgb, flash);
	EMISSION = flash_color.rgb * flash * 0.4;  // still flashes in the dark, without a blooming blob
	ALPHA = c.a * a * tint.a;
	if (see_cut_on) {
//SEE_CUT_APPLY
	}
	%s
}
%s
"""

static var _cutout_shaders := {}  # "scissor|flat|nearest" -> Shader


## `scissor`: hard alpha edges (upright planes sort correctly; opaque images); otherwise soft alpha-blended
## edges. `flat`: lying on the floor, lit like Foundry's flat light discs.
static func _cutout_shader(scissor: bool, flat := false) -> Shader:
	var key := "%s|%s|%s" % [scissor, flat, pixel_art]
	if not _cutout_shaders.has(key):
		var shader := Shader.new()
		var filter := "filter_nearest_mipmap" if pixel_art else "filter_linear_mipmap_anisotropic"
		shader.code = (CUTOUT_SHADER % ([", depth_draw_opaque" if not scissor else "", filter,
			"ALPHA_SCISSOR_THRESHOLD = 0.5;" if scissor else "", LightManager.FLAT_LIGHT if flat else ""]) 			).replace("//SEE_CUT_GLSL", OcclusionCutter.CUT_GLSL).replace("//SEE_CUT_APPLY", OcclusionCutter.CUT_APPLY)
		_cutout_shaders[key] = shader
	return _cutout_shaders[key]


## Texture filter for image surfaces (smooth, or crisp for pixel art).
static func image_filter() -> BaseMaterial3D.TextureFilter:
	return BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS if pixel_art \
		else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


## Material for an image surface. `blend`: "normal", "cutout" (cut out white; `tolerance` 0..1) or "baked"
## (an image Foundry already cut out, edge refinements included: soft edges lying flat, alpha scissor upright)
## or "plain" (the image as it is, drawn by the image shader so it can flash and desaturate: tokens).
## `tint.a` is the opacity. `upright`: the surface stands up (billboard, cross, standee). `hue`: Hue Shift
## (degrees). Images lying flat always use the image shader, so lights fall on them like on the map.
static func image_material(texture: Texture2D, blend: String, tint := Color.WHITE, double_sided := false,
		billboard := false, tolerance := 0.1, upright := false, hue := 0.0) -> Material:
	var flat := not upright and not billboard
	if blend == "cutout" or blend == "plain" or flat or hue != 0.0:
		var m := ShaderMaterial.new()
		m.shader = _cutout_shader(not flat or (blend == "normal" and tint.a >= 0.99), flat)
		m.set_shader_parameter("tex", texture)
		m.set_shader_parameter("tint", tint)
		m.set_shader_parameter("tolerance", tolerance if blend == "cutout" else -1.0)
		m.set_shader_parameter("billboard", billboard)
		m.set_shader_parameter("hue", hue)
		return m
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = texture
	mat.albedo_color = tint
	var soft := tint.a < 0.99 or (blend == "baked" and not upright and not billboard)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if soft else BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.texture_filter = image_filter()
	if double_sided:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if billboard:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
		mat.billboard_keep_scale = true
	return mat


## Swap the image on a material made by image_material.
static func set_image_texture(material: Material, texture: Texture2D) -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter("tex", texture)
	elif material is StandardMaterial3D:
		(material as StandardMaterial3D).albedo_texture = texture

static func scale_of(d: Dictionary) -> Vector3:
	return Vector3(float(d.get("scaleX", 1)), float(d.get("scaleY", 1)), float(d.get("scaleZ", 1)))


## Identifies everything that changes the visual, so it's only rebuilt when needed.
static func cache_key(style: String, d: Dictionary, width_m: float, height_m: float, rim_color: Color,
		blend := "normal", tolerance := 0.1, hue := 0.0) -> String:
	return "%s|%s|%s|%.3f|%.3f|%s|%s|%s|%s|%s|%s|%s|%.3f|%.1f" % [style, d.get("img"), d.get("model"), width_m, height_m,
		scale_of(d), d.get("modelScale", 1), d.get("modelRotation", 0), d.get("standeeThickness", DEFAULT_STANDEE_THICKNESS_CM),
		d.get("crossPlanes", 2), rim_color.to_html(), blend, tolerance, hue] + ("|px" if pixel_art else "")


## Returns the visual, or null if its image/model couldn't be loaded. A "model" whose file is missing
## or broken falls back to a billboard. `blend` ("normal" / "cutout" / "baked") applies to the image surfaces
## of the flat, billboard, cross and standee styles; a cut-out standee is also cut along the subject's outline.
## `hue` (Hue Shift, degrees) too; coins and models keep their colours.
static func build(style: String, d: Dictionary, width_m: float, height_m: float, loader: Node, rim_color: Color,
		blend := "normal", tolerance := 0.1, hue := 0.0) -> Node3D:
	var footprint := minf(width_m, height_m)
	var scale := scale_of(d)
	if style == "model" and d.get("model") is String:
		var model := await _build_model(d, footprint, scale, loader)
		if model:
			return model
		style = "billboard"
	if not d.get("img") is String:
		return null
	var url: String = d.img
	var texture: Texture2D = await loader.fetch_texture(url)
	if texture == null:
		return null
	match style:
		"flat":
			return _build_flat(texture, width_m * scale.x, height_m * scale.y, blend, tolerance, hue)
		"cross":
			return _build_cross(texture, footprint, scale, maxi(2, int(d.get("crossPlanes", 2))), blend, tolerance, hue)
		"standee":
			var thickness := maxf(float(d.get("standeeThickness", DEFAULT_STANDEE_THICKNESS_CM)), 0.1) / 100.0
			var cutout := blend == "cutout"  # "baked" already has the subject's outline in its alpha
			var face: Material = null if blend == "normal" and hue == 0.0 else image_material(texture, blend, Color.WHITE,
				true, false, tolerance, true, hue)
			var standee := TokenMesh.build_standee(texture, loader.get_image(url), footprint, Color("3a3a3a"),
				"%s|%.3f|%.4f|%s|%.3f" % [url, footprint, thickness, blend, tolerance], thickness, face,
				tolerance if cutout else -1.0, image_filter())
			standee.scale = Vector3(scale.x, scale.y, 1.0)  # thickness has its own setting
			standee.position.y = CLEARANCE
			return standee
		"coin":
			var coin := TokenMesh.build_coin(texture, width_m, height_m, rim_color)
			coin.scale *= scale
			return coin
		_:
			if blend != "normal" or hue != 0.0:
				return _build_quad_billboard(texture, footprint, scale, blend, tolerance, hue)
			return _build_billboard(texture, footprint, scale)


## Upright planes crossing at the image's center: plane i turned i * 180 / n degrees.
static func _build_cross(texture: Texture2D, footprint: float, scale: Vector3, planes: int, blend: String,
		tolerance: float, hue := 0.0) -> Node3D:
	var size := Vector2(footprint, footprint * texture.get_height() / texture.get_width()) * Vector2(scale.x, scale.y)
	var cross := Node3D.new()
	cross.name = "Cross"
	var material := image_material(texture, blend, Color.WHITE, true, false, tolerance, true, hue)
	for i in planes:
		var plane := MeshInstance3D.new()
		plane.name = "Plane%d" % i
		var quad := QuadMesh.new()
		quad.size = size
		plane.mesh = quad
		plane.material_override = material
		plane.position.y = CLEARANCE + size.y / 2.0
		plane.rotation.y = PI * i / planes
		cross.add_child(plane)
	return cross


## Billboard drawn by the image shader (cut out white, or "plain" for tokens), unlike the Sprite3D one.
static func _build_quad_billboard(texture: Texture2D, footprint: float, scale: Vector3, blend: String,
		tolerance: float, hue := 0.0) -> Node3D:
	var size := Vector2(footprint, footprint * texture.get_height() / texture.get_width())
	var quad := MeshInstance3D.new()
	quad.name = "Billboard"
	var mesh := QuadMesh.new()
	mesh.size = size
	quad.mesh = mesh
	quad.material_override = image_material(texture, blend, Color.WHITE, true, true, tolerance, true, hue)
	quad.scale = Vector3(scale.x, scale.y, 1.0)  # the shader's billboard keeps the scale
	quad.position.y = CLEARANCE + size.y * scale.y / 2.0
	return quad


static func _build_billboard(texture: Texture2D, footprint: float, scale: Vector3) -> Node3D:
	var sprite := Sprite3D.new()
	sprite.name = "Billboard"
	sprite.texture = texture
	sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	sprite.shaded = true  # darkens at night and picks up nearby lights, like the rest of the scene
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.texture_filter = image_filter()
	sprite.pixel_size = footprint / texture.get_width()
	sprite.scale = Vector3(scale.x, scale.y, 1.0)
	sprite.position.y = CLEARANCE + texture.get_height() * sprite.pixel_size * scale.y / 2.0
	return sprite


static func _build_flat(texture: Texture2D, width_m: float, length_m: float, blend: String, tolerance: float,
		hue := 0.0) -> Node3D:
	var flat := MeshInstance3D.new()
	flat.name = "Flat"
	var plane := PlaneMesh.new()
	plane.size = Vector2(width_m, length_m)
	flat.mesh = plane
	flat.position.y = CLEARANCE  # same clearance as every other style
	flat.material_override = image_material(texture, blend, Color.WHITE, false, false, tolerance, false, hue)
	return flat


static func _build_model(d: Dictionary, footprint: float, axes: Vector3, loader: Node) -> Node3D:
	var url: String = d.model
	var body: PackedByteArray = await loader.fetch_bytes(url)
	if body.is_empty():
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_buffer(body, "", state) != OK:
		push_warning("Visuals: could not parse model %s" % url)
		return null
	var model := doc.generate_scene(state) as Node3D
	if model == null:
		return null
	model.name = "Model"
	# Fit the model's widest horizontal extent to the footprint, standing on the floor clearance.
	var acc := [null]
	_accumulate_aabb(model, Transform3D.IDENTITY, acc)
	var s := float(d.get("modelScale", 1.0))
	var center := Vector3.ZERO
	var bottom := 0.0
	if acc[0] != null:
		var aabb: AABB = acc[0]
		var extent := maxf(aabb.size.x, aabb.size.z)
		s *= footprint / extent if extent > 0.0001 else 1.0
		center = aabb.get_center()
		bottom = aabb.position.y
	# Wrap so the user's rotation turns the model around its own center.
	var pivot := Node3D.new()
	pivot.name = "ModelPivot"
	pivot.rotation.y = -deg_to_rad(float(d.get("modelRotation", 0)))
	pivot.position.y = CLEARANCE
	var model_scale := axes * s
	model.scale = model_scale
	model.position = Vector3(-center.x * model_scale.x, -bottom * model_scale.y, -center.z * model_scale.z)
	pivot.add_child(model)
	return pivot


static func _accumulate_aabb(node: Node, parent_xform: Transform3D, acc: Array) -> void:
	var xform := parent_xform
	if node is Node3D:
		xform = parent_xform * (node as Node3D).transform
	if node is VisualInstance3D:
		var box: AABB = xform * (node as VisualInstance3D).get_aabb()
		acc[0] = box if acc[0] == null else (acc[0] as AABB).merge(box)
	for child in node.get_children():
		_accumulate_aabb(child, xform, acc)
