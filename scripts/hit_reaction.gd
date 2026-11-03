extends RefCounted
## Hit reaction effects on a token's visual, the same for every token style: flash, desaturation (downed),
## the hurt image and impact sparks. token_manager.gd plays the motion (knockback, shake, squash).
## Image surfaces (billboard, cross, flat, standee face) use the image shader of visual_builder.gd and the coin
## face the coin shader of token_mesh.gd; both have flash / flash_color / saturation uniforms. The coin rim and
## the standee edge are plain materials, changed directly. A .glb model gets a material overlay while it's needed.

## Drawn over a model's own materials: desaturates what the model rendered, then mixes in the flash.
const MODEL_OVERLAY_SHADER := """
shader_type spatial;
render_mode unshaded, depth_draw_never, shadows_disabled;
uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;
uniform vec4 flash_color : source_color = vec4(1.0);
uniform float flash = 0.0;
uniform float saturation = 1.0;
uniform vec4 status_tint : source_color = vec4(1.0, 1.0, 1.0, 0.0);
void fragment() {
	vec3 c = textureLod(screen, SCREEN_UV, 0.0).rgb;
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(vec3(luma), c, saturation);
	c = mix(c, luma * status_tint.rgb * 1.5, status_tint.a);
	ALBEDO = mix(c, flash_color.rgb, flash);
	ALPHA = 1.0;
}
"""

## Ethereal and Invisible (token_status.gd): drawn instead of an image surface (whose `ghosted` hides it), as its
## material overlay. Same billboard math as the image shader.
##   mode 1, Ethereal  - pale, see-through, the image wavering like a ghost, bobbing gently, glowing edge
##   mode 2, Invisible - bends what's behind it like heat haze, the token faintly there (15%), shimmering outline
const GHOST_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;
uniform sampler2D tex : filter_linear_mipmap;  // raw sRGB values, like the image shader
uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;
uniform bool billboard = false;
uniform float roll = 0.0;
uniform float tolerance = -1.0;
uniform bool circle = false;  // coin face: only the disc
uniform int mode = 1;
uniform vec4 ghost_color : source_color = vec4(0.6, 0.9, 1.0, 1.0);
vec3 to_linear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)); }
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
void vertex() {
	if (mode == 1) VERTEX.y += sin(TIME * 1.7) * 0.04 / max(length(MODEL_MATRIX[1].xyz), 0.001);  // floats
	if (billboard) {
		vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz));
		vec3 up = vec3(0.0, 1.0, 0.0);
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4((right * cos(roll) + up * sin(roll)) * length(MODEL_MATRIX[0].xyz), 0.0),
			vec4((up * cos(roll) - right * sin(roll)) * length(MODEL_MATRIX[1].xyz), 0.0),
			vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))) * length(MODEL_MATRIX[2].xyz), 0.0),
			MODEL_MATRIX[3]);
	}
}
float alpha_at(vec2 uv) {
	vec4 c = texture(tex, uv);
	float a = c.a;
	if (tolerance >= 0.0) a *= clamp((max(max(1.0 - c.r, 1.0 - c.g), 1.0 - c.b) - tolerance) / 0.1, 0.0, 1.0);
	if (circle && length(uv - vec2(0.5)) > 0.47) a = 0.0;
	return a;
}
void fragment() {
	vec2 uv = UV;
	if (mode == 1) uv.x += sin(UV.y * 9.0 + TIME * 2.2) * 0.03 + sin(UV.y * 23.0 - TIME * 3.3) * 0.01;  // wavering
	float a = smoothstep(0.25, 0.6, alpha_at(uv));
	vec2 e = vec2(0.02, 0.0);
	float gx = alpha_at(uv + e.xy) - alpha_at(uv - e.xy);
	float gy = alpha_at(uv + e.yx) - alpha_at(uv - e.yx);
	float edge = clamp(length(vec2(gx, gy)) * 1.5, 0.0, 1.0);
	vec3 rgb = to_linear(texture(tex, uv).rgb);
	if (mode == 1) {
		float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(vec3(l), ghost_color.rgb, 0.5) * 1.15 + ghost_color.rgb * edge;
		ALPHA = clamp(a * 0.42 + edge * 0.35, 0.0, 1.0);
	} else {
		vec2 bend = vec2(gx, gy) * 0.04 + (vec2(vnoise(UV * 10.0 + TIME * 1.3), vnoise(UV * 10.0 - TIME)) - 0.5) * 0.012;
		vec3 behind = textureLod(screen, SCREEN_UV - bend, 0.0).rgb;
		float shimmer = edge * (0.5 + 0.5 * sin(TIME * 4.0 + UV.y * 20.0));
		ALBEDO = mix(behind, rgb, 0.15) + ghost_color.rgb * shimmer * 0.35;
		ALPHA = max(a, edge * 0.6);
	}
}
"""
## How much a .glb model fades for each ghost mode (no wavering there).
const MODEL_GHOST := {1: 0.55, 2: 0.85}

static var _overlay_shader: Shader
static var _ghost_shader: Shader
static var _spark_materials := {}  # Color html -> ParticleProcessMaterial
static var _spark_mesh: QuadMesh


## What to drive on the token's current visual. Collected once per visual (cleared by token_manager.gd
## when it rebuilds the visual), not while the visual is still loading.
static func surfaces(token: Node3D) -> Dictionary:
	if token.has_meta("hit_surfaces"):
		return token.get_meta("hit_surfaces")
	var fx := {"images": [], "solids": [], "models": [], "sprites": [], "overlay": null,
		"flash": 0.0, "flash_color": Color.WHITE, "saturation": 1.0, "status_tint": Color(1, 1, 1, 0), "ghost": 0, "roll": 0.0}
	var visual: Node3D = token.get_node("Visual")
	if visual.get_child_count() == 0:
		return fx
	_collect(visual, fx)
	token.set_meta("hit_surfaces", fx)
	return fx


static func _collect(node: Node, fx: Dictionary) -> void:
	if node.has_meta("vfx"):  # an effect riding the token (a stuck arrow), not the token itself
		return
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.material_override is ShaderMaterial:
			_add_image(fx, mi.material_override, mi)
		elif mi.material_override is BaseMaterial3D:  # the coin rim, built for this token only
			_add_solid(fx, mi.material_override)
		elif mi.mesh:
			var has_image := false
			for i in mi.mesh.get_surface_count():
				if mi.get_surface_override_material(i) is ShaderMaterial:
					has_image = true
					_add_image(fx, mi.get_surface_override_material(i), mi)
			if has_image:  # standee: the edge material is shared through the mesh cache, so give this one its own
				for i in mi.mesh.get_surface_count():
					var shared := mi.mesh.surface_get_material(i)
					if mi.get_surface_override_material(i) == null and shared is BaseMaterial3D:
						var own := shared.duplicate() as BaseMaterial3D
						mi.set_surface_override_material(i, own)
						_add_solid(fx, own)
			else:  # part of a .glb model
				fx.models.append(mi)
	elif node is SpriteBase3D:  # Sprite3D billboard (images not drawn by the image shader)
		fx.sprites.append(node)
	for child in node.get_children():
		_collect(child, fx)


static func _add_image(fx: Dictionary, mat: ShaderMaterial, node: MeshInstance3D) -> void:
	for image in fx.images:
		if image.mat == mat:
			image.nodes.append(node)  # cross planes share one material
			return
	var param := "art" if mat.get_shader_parameter("art") != null else "tex"
	fx.images.append({"mat": mat, "param": param, "base": mat.get_shader_parameter(param), "nodes": [node],
		"ghost": null})


static func _add_solid(fx: Dictionary, mat: BaseMaterial3D) -> void:
	fx.solids.append({"mat": mat, "color": mat.albedo_color})
	mat.emission_enabled = true  # always on (at 0 energy): switching it would recompile the shader mid-hit
	mat.emission_energy_multiplier = 0.0


## `amount` 0..1: how much of the surfaces turns `color`.
static func set_flash(fx: Dictionary, amount: float, color := Color.WHITE) -> void:
	fx.flash = amount
	fx.flash_color = color
	_apply(fx)


## 1 = full color, 0.2 = downed (80% desaturated).
static func set_saturation(fx: Dictionary, value: float) -> void:
	fx.saturation = value
	_apply(fx)


## Condition color (token_status.gd): `color.a` is how much of it.
static func set_status_tint(fx: Dictionary, color: Color) -> void:
	fx.status_tint = color
	_apply(fx)


## 0: normal, 1: Ethereal, 2: Invisible (GHOST_SHADER). Models fade instead, tinted pale blue.
static func set_ghost(fx: Dictionary, mode: int) -> void:
	fx.ghost = mode
	_apply(fx)
	for image in fx.images:
		var mat: ShaderMaterial = image.mat
		mat.set_shader_parameter("ghosted", mode > 0)
		if mode > 0 and image.ghost == null:
			if _ghost_shader == null:
				_ghost_shader = Shader.new()
				_ghost_shader.code = GHOST_SHADER
			var ghost := ShaderMaterial.new()
			ghost.shader = _ghost_shader
			ghost.set_shader_parameter("tex", mat.get_shader_parameter(image.param))
			ghost.set_shader_parameter("billboard", mat.get_shader_parameter("billboard") == true)  # null on the coin
			var tolerance = mat.get_shader_parameter("tolerance")
			ghost.set_shader_parameter("tolerance", float(tolerance) if tolerance != null else -1.0)
			ghost.set_shader_parameter("circle", image.param == "art")
			image.ghost = ghost
		if image.ghost:
			(image.ghost as ShaderMaterial).set_shader_parameter("mode", mode)
			(image.ghost as ShaderMaterial).set_shader_parameter("roll", fx.roll)
		for node in image.nodes:
			if is_instance_valid(node):
				(node as GeometryInstance3D).material_overlay = image.ghost if mode > 0 else null
	for mesh in fx.models:
		if is_instance_valid(mesh):
			(mesh as GeometryInstance3D).transparency = MODEL_GHOST.get(mode, 0.0)


## Billboards turned in the view (token_status.gd: lying down, trembling), ghost overlays too.
static func set_roll(fx: Dictionary, roll: float) -> void:
	fx.roll = roll
	for image in fx.images:
		(image.mat as ShaderMaterial).set_shader_parameter("roll", roll)
		if image.ghost:
			(image.ghost as ShaderMaterial).set_shader_parameter("roll", roll)


## Show `texture` on the image surfaces instead of the token's image; null shows the token's image again.
static func set_texture(fx: Dictionary, texture: Texture2D) -> void:
	for image in fx.images:
		(image.mat as ShaderMaterial).set_shader_parameter(image.param, texture if texture else image.base)


static func _apply(fx: Dictionary) -> void:
	var flash: float = fx.flash
	var color: Color = fx.flash_color
	var saturation: float = fx.saturation
	var status_tint: Color = fx.status_tint
	for image in fx.images:
		var mat: ShaderMaterial = image.mat
		mat.set_shader_parameter("flash", flash)
		mat.set_shader_parameter("flash_color", color)
		mat.set_shader_parameter("saturation", saturation)
		mat.set_shader_parameter("status_tint", status_tint)
	for solid in fx.solids:
		var mat: BaseMaterial3D = solid.mat
		var base: Color = solid.color
		var grey := Color(base.get_luminance(), base.get_luminance(), base.get_luminance(), base.a)
		var tinted := status_tint * base.get_luminance() * 1.5
		mat.albedo_color = grey.lerp(base, saturation).lerp(Color(tinted, base.a), status_tint.a).lerp(color, flash)
		mat.emission = color
		mat.emission_energy_multiplier = flash
	for sprite in fx.sprites:
		(sprite as SpriteBase3D).modulate = Color.WHITE.lerp(color * 3.0, flash)
	if fx.models.is_empty():
		return
	if fx.ghost > 0:  # a fading model is tinted pale blue too
		status_tint = Color(0.6, 0.8, 1.0, maxf(status_tint.a, 0.6))
	var active := flash > 0.0 or saturation < 0.999 or status_tint.a > 0.001
	if active and fx.overlay == null:
		if _overlay_shader == null:
			_overlay_shader = Shader.new()
			_overlay_shader.code = MODEL_OVERLAY_SHADER
		fx.overlay = ShaderMaterial.new()
		fx.overlay.shader = _overlay_shader
	if fx.overlay:
		var overlay: ShaderMaterial = fx.overlay
		overlay.set_shader_parameter("flash", flash)
		overlay.set_shader_parameter("flash_color", color)
		overlay.set_shader_parameter("saturation", saturation)
		overlay.set_shader_parameter("status_tint", status_tint)
	for mesh in fx.models:
		if is_instance_valid(mesh):
			(mesh as GeometryInstance3D).material_overlay = fx.overlay if active else null


## One burst of impact sparks at `at` (local to `parent`), more for heavier hits. `gravity` > 0 floats up
## (embers, smoke), `speed` scales how far they fly.
static func spawn_sparks(parent: Node3D, at: Vector3, severity: float, color: Color, gravity := -6.0,
		speed := 1.0, name := "Sparks") -> GPUParticles3D:
	var sparks := GPUParticles3D.new()
	sparks.name = name
	sparks.one_shot = true
	sparks.explosiveness = 1.0
	sparks.amount = int(lerpf(8.0, 32.0, severity))
	sparks.lifetime = 0.35 + 0.15 * severity
	sparks.local_coords = false
	sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sparks.process_material = _spark_material(color, gravity, speed)
	sparks.draw_pass_1 = spark_quad()
	sparks.position = at
	parent.add_child(sparks)
	sparks.emitting = true
	var lifetime := sparks.lifetime
	parent.get_tree().create_timer(lifetime + 0.3).timeout.connect(func() -> void:
		if is_instance_valid(sparks):
			sparks.queue_free())
	return sparks


static func _spark_material(color: Color, gravity := -6.0, speed := 1.0) -> ParticleProcessMaterial:
	var key := "%s|%.1f|%.2f" % [color.to_html(), gravity, speed]
	if not _spark_materials.has(key):
		var m := ParticleProcessMaterial.new()
		m.direction = Vector3(0, 1, 0)
		m.spread = 180.0
		m.initial_velocity_min = 2.0 * speed
		m.initial_velocity_max = 5.0 * speed
		m.gravity = Vector3(0, gravity, 0)
		m.damping_min = 4.0
		m.damping_max = 6.0
		m.scale_min = 0.05
		m.scale_max = 0.14
		var fade := Gradient.new()
		fade.set_color(0, color)
		fade.set_color(1, Color(color, 0.0))
		var ramp := GradientTexture1D.new()
		ramp.gradient = fade
		m.color_ramp = ramp
		_spark_materials[key] = m
	return _spark_materials[key]


## Soft round dot, additive and unshaded so it glows (and blooms with the HD-2D look).
static func spark_quad() -> QuadMesh:
	if _spark_mesh == null:
		var dot := Gradient.new()
		dot.set_color(0, Color.WHITE)
		dot.set_color(1, Color(1, 1, 1, 0))
		var texture := GradientTexture2D.new()
		texture.gradient = dot
		texture.fill = GradientTexture2D.FILL_RADIAL
		texture.fill_from = Vector2(0.5, 0.5)
		texture.fill_to = Vector2(1.0, 0.5)
		texture.width = 32
		texture.height = 32
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.vertex_color_use_as_albedo = true
		mat.albedo_texture = texture
		_spark_mesh = QuadMesh.new()
		_spark_mesh.material = mat
	return _spark_mesh
