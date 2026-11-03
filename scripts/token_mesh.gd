extends RefCounted
## Builds 3D token visuals from token art: an extruded cut-out "standee" and a "coin" disc.

const STANDEE_THICKNESS := 0.02  # meters, default
const COIN_HEIGHT := 0.06  # meters
const OUTLINE_RESOLUTION := 256.0  # the outline is traced on a downscaled copy of the image

const COIN_SHADER := """
shader_type spatial;
uniform sampler2D art : source_color, filter_linear_mipmap;
uniform vec4 rim_color : source_color;
uniform vec4 flash_color : source_color = vec4(1.0);  // hit reactions (hit_reaction.gd)
uniform float flash = 0.0;
uniform float saturation = 1.0;
uniform vec4 status_tint : source_color = vec4(1.0, 1.0, 1.0, 0.0);  // conditions (token_status.gd)
uniform bool ghosted = false;  // drawn by the ghost overlay instead (hit_reaction.gd: Ethereal, Invisible)
void fragment() {
	if (length(UV - vec2(0.5)) > 0.5) discard;
	if (ghosted) discard;
	vec4 c = texture(art, UV);
	vec3 rgb = mix(rim_color.rgb, c.rgb, c.a);  // transparent parts of the art show the rim color
	float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
	rgb = mix(vec3(luma), rgb, saturation);
	rgb = mix(rgb, luma * status_tint.rgb * 1.5, status_tint.a);
	ALBEDO = mix(rgb, flash_color.rgb, flash);
	EMISSION = flash_color.rgb * flash * 0.4;
	ROUGHNESS = 0.6;
}
"""

static var _coin_shader: Shader
static var _standee_cache := {}  # "url|width" -> ArrayMesh


## Upright cut-out of the image's opaque area, `width_m` wide, standing on y = 0 and facing +Z.
## `face_material`: optional material for the front and back (e.g. Cut out white); the cut edge keeps its own.
## `white_tolerance` >= 0: the image has a white background, so the outline follows the subject instead.
static func build_standee(texture: Texture2D, image: Image, width_m: float, edge_color: Color, cache_key: String,
		thickness := STANDEE_THICKNESS, face_material: Material = null, white_tolerance := -1.0,
		filter := BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS) -> MeshInstance3D:
	var mesh: ArrayMesh = _standee_cache.get(cache_key)
	if mesh == null:
		mesh = _standee_mesh(image, width_m, edge_color, thickness, white_tolerance)
		_standee_cache[cache_key] = mesh
	var instance := MeshInstance3D.new()
	instance.name = "Standee"
	instance.mesh = mesh
	if face_material:
		instance.set_surface_override_material(0, face_material)
		return instance
	var art := StandardMaterial3D.new()
	art.albedo_texture = texture
	art.cull_mode = BaseMaterial3D.CULL_DISABLED
	art.texture_filter = filter
	instance.set_surface_override_material(0, art)
	return instance


static func _standee_mesh(image: Image, width_m: float, edge_color: Color, thickness: float,
		white_tolerance: float) -> ArrayMesh:
	var outline := _outline(image, white_tolerance)  # normalized 0..1 image coordinates
	var indices := Geometry2D.triangulate_polygon(outline)
	if indices.is_empty():
		outline = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		indices = Geometry2D.triangulate_polygon(outline)
	var height_m := width_m * float(image.get_height()) / float(image.get_width())
	var half := thickness / 2.0
	var to_3d := func(p: Vector2, z: float) -> Vector3:
		return Vector3((p.x - 0.5) * width_m, (1.0 - p.y) * height_m, z)

	# Surface 0: front and back faces, textured with the art.
	var faces := SurfaceTool.new()
	faces.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [1.0, -1.0]:
		faces.set_normal(Vector3(0, 0, side))
		for i in indices:
			faces.set_uv(outline[i])
			faces.add_vertex(to_3d.call(outline[i], half * side))
	var mesh := faces.commit()

	# Surface 1: the cut edge around the outline.
	var edges := SurfaceTool.new()
	edges.begin(Mesh.PRIMITIVE_TRIANGLES)
	var clockwise := Geometry2D.is_polygon_clockwise(outline)
	for i in outline.size():
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % outline.size()]
		var dir := (b - a).normalized()
		var normal_2d := Vector2(dir.y, -dir.x) if clockwise else Vector2(-dir.y, dir.x)
		edges.set_normal(Vector3(normal_2d.x, -normal_2d.y, 0.0))
		var quad := [to_3d.call(a, half), to_3d.call(b, half), to_3d.call(b, -half), to_3d.call(a, -half)]
		for v in [quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]]:
			edges.add_vertex(v)
	edges.commit(mesh)
	var edge_mat := StandardMaterial3D.new()
	edge_mat.albedo_color = edge_color
	edge_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(1, edge_mat)
	return mesh


## Largest opaque region of the image as a polygon in 0..1 coordinates (full rectangle if none).
static func _outline(image: Image, white_tolerance := -1.0) -> PackedVector2Array:
	var small := image.duplicate() as Image
	small.clear_mipmaps()
	if small.is_compressed():
		small.decompress()
	var scale := minf(1.0, OUTLINE_RESOLUTION / maxf(small.get_width(), small.get_height()))
	if scale < 1.0:
		small.resize(maxi(1, int(small.get_width() * scale)), maxi(1, int(small.get_height() * scale)))
	if white_tolerance >= 0.0:
		color_to_alpha(small, white_tolerance)
	var size := Vector2(small.get_size())
	var bitmap := BitMap.new()
	bitmap.create_from_image_alpha(small, 0.5)
	var best := PackedVector2Array()
	var best_area := 0.0
	for polygon in bitmap.opaque_to_polygons(Rect2i(Vector2i.ZERO, small.get_size()), 1.5):
		var area := absf(_signed_area(polygon))
		if area > best_area:
			best_area = area
			best = polygon
	# No alpha (a plain square portrait) or a tiny speck: use the whole image.
	if best.size() < 3 or best_area < size.x * size.y * 0.05:
		return PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	var normalized := PackedVector2Array()
	for p in best:
		normalized.append(p / size)
	return normalized


## "Cut out white" on the CPU (same math as the cutout shader and the Foundry module), in place.
## Only used on the small outline copy, so a GDScript loop is fast enough.
static func color_to_alpha(image: Image, tolerance: float) -> void:
	image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			var d := maxf(maxf(1.0 - c.r, 1.0 - c.g), 1.0 - c.b)
			var a := clampf((d - tolerance) / 0.1, 0.0, 1.0)
			image.set_pixel(x, y, Color(c.r, c.g, c.b, c.a * a))


static func _signed_area(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for i in polygon.size():
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		area += a.x * b.y - b.x * a.y
	return area / 2.0


## Thick disc with the art on top, footprint_w x footprint_h meters, standing on y = 0.
static func build_coin(texture: Texture2D, footprint_w: float, footprint_h: float, rim_color: Color) -> Node3D:
	var coin := Node3D.new()
	coin.name = "Coin"
	coin.scale = Vector3(1.0, 1.0, footprint_h / footprint_w) if footprint_w > 0.0 else Vector3.ONE

	var rim := MeshInstance3D.new()
	rim.name = "Rim"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = footprint_w / 2.0
	cylinder.bottom_radius = footprint_w / 2.0
	cylinder.height = COIN_HEIGHT
	cylinder.radial_segments = 48
	rim.mesh = cylinder
	rim.position.y = COIN_HEIGHT / 2.0
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = rim_color
	rim_mat.roughness = 0.5
	rim.material_override = rim_mat
	coin.add_child(rim)

	if _coin_shader == null:
		_coin_shader = Shader.new()
		_coin_shader.code = COIN_SHADER
	var face := MeshInstance3D.new()
	face.name = "Face"
	var plane := PlaneMesh.new()
	plane.size = Vector2(footprint_w, footprint_w) * 0.94
	face.mesh = plane
	face.position.y = COIN_HEIGHT + 0.001
	var face_mat := ShaderMaterial.new()
	face_mat.shader = _coin_shader
	face_mat.set_shader_parameter("art", texture)
	face_mat.set_shader_parameter("rim_color", rim_color)
	face.material_override = face_mat
	coin.add_child(face)
	return coin
