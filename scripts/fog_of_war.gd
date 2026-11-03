extends MeshInstance3D
## Foundry's vision and fog of war in 3D (play mode): what the player's tokens see right now stays as it is,
## explored areas are dimmed, unexplored ones are black, exactly where Foundry's own vision says so. The module's
## play client (play-client.js) sends Foundry's vision mask and explored-fog images ("vision.update"); a
## full-screen pass finds the floor point behind every pixel from the depth buffer and darkens it by those images,
## so walls, tokens and tiles darken with the floor. Off when the scene has no token vision, and in dev mode.

const EXPLORED_LEVEL := 0.35  # how bright explored-but-not-seen areas stay

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, fog_disabled;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D vision_mask : filter_linear, repeat_disable;
uniform sampler2D explored_mask : filter_linear, repeat_disable;
uniform bool has_explored = false;
uniform vec2 origin;  // world XZ of the images' top-left corner
uniform vec2 size;    // world XZ size the images cover
uniform float explored_level = 0.35;
void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);  // a quad covering the screen
}
void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).x;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	view.xyz /= view.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	vec2 uv = (world.xz - origin) / size;
	float inside = step(0.0, uv.x) * step(0.0, uv.y) * step(uv.x, 1.0) * step(uv.y, 1.0);
	float seen = texture(vision_mask, uv).r * inside;
	float explored = has_explored ? texture(explored_mask, uv).r * inside : 0.0;
	float light = max(seen, explored * explored_level);
	ALBEDO = vec3(light);
}
"""

var _material := ShaderMaterial.new()


func _ready() -> void:
	name = "FogOfWar"
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh = quad
	var shader := Shader.new()
	shader.code = SHADER
	_material.shader = shader
	_material.render_priority = 127  # after everything else
	_material.set_shader_parameter("explored_level", EXPLORED_LEVEL)
	material_override = _material
	extra_cull_margin = 16384.0  # never culled: it covers the screen wherever the camera is
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


## A play client's "vision.update": {mask, explored, rect: {x, y, width, height} (Foundry px), tokenVision}.
## `info`: the scene (Foundry px -> meters).
func apply(msg: Dictionary, info) -> void:
	if not msg.get("tokenVision", false) or info == null:
		visible = false
		return
	var mask := _texture(msg.get("mask"))
	if mask:
		_material.set_shader_parameter("vision_mask", mask)
	var explored := _texture(msg.get("explored"))
	if explored:
		_material.set_shader_parameter("explored_mask", explored)
		_material.set_shader_parameter("has_explored", true)
	elif msg.has("fogExploration") and not msg.fogExploration:
		_material.set_shader_parameter("has_explored", false)  # the scene doesn't keep explored areas
	var rect: Dictionary = msg.get("rect", {})
	if not rect.is_empty():
		var corner: Vector3 = info.to_3d(float(rect.x), float(rect.y))
		_material.set_shader_parameter("origin", Vector2(corner.x, corner.z))
		_material.set_shader_parameter("size", Vector2(info.px_to_m(float(rect.width)), info.px_to_m(float(rect.height))))
	visible = _material.get_shader_parameter("vision_mask") != null


## A PNG data URL -> texture (null when absent or broken).
static func _texture(data_url) -> Texture2D:
	if not data_url is String or not (data_url as String).begins_with("data:image/png;base64,"):
		return null
	var image := Image.new()
	if image.load_png_from_buffer(Marshalls.base64_to_raw((data_url as String).get_slice(",", 1))) != OK:
		return null
	return ImageTexture.create_from_image(image)


func clear() -> void:
	visible = false
	_material.set_shader_parameter("vision_mask", null)
	_material.set_shader_parameter("explored_mask", null)
	_material.set_shader_parameter("has_explored", false)
