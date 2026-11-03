extends MeshInstance3D
## Play mode: Foundry's grid, faded in around the pointer while a player drags their token (play_mode.gd), so they
## can see where it will land. Drawn like Foundry does (scene.grid via scene_info.gd): anchored at canvas (0, 0),
## square or hex (common/grid/hexagonal.mjs: rows are cells `size` wide and size*2/sqrt(3) tall, every other
## row shifted half a cell; columns the same turned 90 degrees), in the scene's grid color. The cells the token
## would land in are lit. Gridless scenes show nothing.

const SceneInfo = preload("res://scripts/scene_info.gd")
const FADE_TIME := 0.2
const RADIUS_CELLS := 6.0  ## how far around the pointer the grid shows
const MIN_ALPHA := 0.35    ## Foundry's default 0.2 is too faint over a 3D floor

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform int grid_type = 1;          // 1 square, 2 / 3 hex odd / even rows, 4 / 5 hex odd / even columns
uniform float cell_px = 100.0;
uniform vec2 origin_px;             // Foundry px of this mesh's local (0, 0): the scene rect's top-left
uniform float mpp = 0.01524;        // meters per Foundry px
uniform vec4 line_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float line_alpha = 0.35;
uniform float thickness_px = 1.0;
uniform vec2 pointer_px;
uniform float radius_px = 600.0;
uniform vec4 fill_color : source_color = vec4(1.0, 0.6, 0.16, 1.0);
uniform vec4 fill_rect;             // square grids: the token's landing footprint (x0, y0, x1, y1) in px
uniform float fade = 0.0;

varying vec2 px;

void vertex() {
	px = origin_px + VERTEX.xz / mpp;
}

// Row hex lattice (hexagonal.mjs getVertices): cells w wide, h = w * 2 / sqrt(3) tall, rows 0.75 h apart,
// a row shifted half a cell left when `even` matches whether its index is odd. Returns the point relative to
// the nearest cell's center (xy) and that cell's (i, j) (zw).
vec4 hex_cell(vec2 p, float w, bool even) {
	float h = w * 2.0 / sqrt(3.0);
	float i0 = floor(p.y / (0.75 * h));
	vec4 best = vec4(1e9, 1e9, 0.0, 0.0);
	for (int k = -1; k <= 1; k++) {
		float i = i0 + float(k);
		bool odd_row = mod(abs(i), 2.0) > 0.5;
		float shift = (even == odd_row) ? 0.5 * w : 0.0;
		float j = floor((p.x + shift) / w);
		vec2 c = vec2(j * w - shift + 0.5 * w, 0.75 * h * i + 0.5 * h);
		vec2 d = p - c;
		if (dot(d, d) < dot(best.xy, best.xy)) {
			best = vec4(d, i, j);
		}
	}
	return best;
}

// Distance from a point (relative to a pointy-top hex's center) to the hex's edge, inside: the inradius minus
// its largest projection on the three edge normals.
float hex_edge(vec2 d, float w) {
	vec2 a = abs(d);
	float m = max(a.x, abs(0.5 * d.x + 0.8660254 * d.y));
	m = max(m, abs(0.5 * d.x - 0.8660254 * d.y));
	return 0.5 * w - m;
}

void fragment() {
	float aa = max(fwidth(px.x), fwidth(px.y));
	float edge;
	bool lit;
	if (grid_type == 1) {
		vec2 f = fract(px / cell_px);
		edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)) * cell_px;
		lit = px.x >= fill_rect.x && px.x < fill_rect.z && px.y >= fill_rect.y && px.y < fill_rect.w;
	} else {
		bool columns = grid_type >= 4;
		bool even = grid_type == 3 || grid_type == 5;
		vec2 p = columns ? px.yx : px;
		vec2 q = columns ? pointer_px.yx : pointer_px;
		vec4 cell = hex_cell(p, cell_px, even);
		edge = hex_edge(cell.xy, cell_px);
		lit = all(equal(cell.zw, hex_cell(q, cell_px, even).zw));
	}
	float half_w = max(thickness_px * 0.5, aa * 0.75);
	float line = 1.0 - smoothstep(half_w - aa * 0.5, half_w + aa * 0.5, edge);
	float near = 1.0 - smoothstep(radius_px * 0.55, radius_px, distance(px, pointer_px));
	float a_line = line * line_alpha;
	float a_fill = lit ? 0.28 : 0.0;
	float a = (lit ? max(a_line, a_fill) : a_line * near) * fade;  // the landing cells always show in full
	vec3 col = mix(fill_color.rgb, line_color.rgb, a_line / max(a_line + a_fill, 1e-4));
	ALBEDO = col;
	ALPHA = a;
}
"""

var info: SceneInfo
var _mat := ShaderMaterial.new()
var _tween: Tween
var _target := 0.0  ## the fade it's heading to


func _ready() -> void:
	var shader := Shader.new()
	shader.code = SHADER
	_mat.shader = shader
	_mat.render_priority = 2
	_mat.set_shader_parameter("fade", 0.0)
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


## Show (fading in) around `at` (a floor point), lighting where a token `width_px` x `height_px` (Foundry px) would
## land with its center there. Nothing on gridless scenes.
func show_at(at: Vector3, width_px: float, height_px: float, fill := Color(1.0, 0.6, 0.16)) -> void:
	if info == null or info.grid_type == 0:
		return
	var size := info.size_m()
	if not (mesh is PlaneMesh) or not (mesh as PlaneMesh).size.is_equal_approx(size):
		var plane := PlaneMesh.new()
		plane.size = size
		plane.center_offset = Vector3(size.x / 2.0, 0.0, size.y / 2.0)
		mesh = plane
	position = Vector3(0.0, at.y + 0.02, 0.0)
	var cell := info.grid_size
	var pointer := Vector2(info.rect.position.x + at.x / info.mpp, info.rect.position.y + at.z / info.mpp)
	_mat.set_shader_parameter("grid_type", info.grid_type)
	_mat.set_shader_parameter("cell_px", cell)
	_mat.set_shader_parameter("origin_px", info.rect.position)
	_mat.set_shader_parameter("mpp", info.mpp)
	_mat.set_shader_parameter("line_color", Color(info.grid_color, 1.0))
	_mat.set_shader_parameter("line_alpha", maxf(info.grid_alpha, MIN_ALPHA))
	_mat.set_shader_parameter("thickness_px", maxf(info.grid_thickness, 1.0))
	_mat.set_shader_parameter("pointer_px", pointer)
	_mat.set_shader_parameter("radius_px", cell * RADIUS_CELLS)
	_mat.set_shader_parameter("fill_color", fill)
	# Square grids: Foundry snaps the token's top-left corner to the grid
	var w := maxf(width_px, cell)
	var h := maxf(height_px, cell)
	var corner := ((pointer - Vector2(w, h) / 2.0) / cell).round() * cell
	_mat.set_shader_parameter("fill_rect", Vector4(corner.x, corner.y, corner.x + w, corner.y + h))
	if not visible or _fading_out():
		visible = true
		_fade_to(1.0)


## Fade out (then hidden).
func hide_grid() -> void:
	if visible and not _fading_out():
		_fade_to(0.0)


func fade() -> float:
	return float(_mat.get_shader_parameter("fade"))


func _fading_out() -> bool:
	return _target == 0.0


func _fade_to(value: float) -> void:
	_target = value
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(func(v: float) -> void: _mat.set_shader_parameter("fade", v), fade(), value, FADE_TIME)
	if value == 0.0:
		_tween.tween_callback(func() -> void: visible = false)
