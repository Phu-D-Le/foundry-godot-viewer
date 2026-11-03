extends RefCounted
## Converts Foundry scene data (pixels, grid units) into Godot space (meters).
## Foundry (x, y) maps to Godot (x, z) with the scene's top-left corner at the origin;
## Foundry elevation (grid units, e.g. feet) maps to Godot +Y.

var id: String
var name: String
var mode: String
var rect: Rect2
var mpp: float  ## meters per pixel
var mpu: float  ## meters per grid unit (e.g. 0.3048 for feet)
var wall_height: float  ## grid units
var grid_m: float  ## one grid square, in meters
## Foundry's grid as it draws it (scene.grid), anchored at canvas (0, 0): type 0 gridless, 1 square,
## 2-5 hex (odd / even rows, odd / even columns); size in px; color, alpha and thickness (px) of its lines
var grid_type := 1
var grid_size := 100.0
var grid_color := Color.BLACK
var grid_alpha := 0.2
var grid_thickness := 1.0
var levels: Array = []  ## Array[Dictionary], sorted by bottom elevation


func _init(data: Dictionary) -> void:
	id = data.id
	name = data.get("name", "")
	mode = data.get("mode", "auto")
	var r: Dictionary = data.rect
	rect = Rect2(r.x, r.y, r.width, r.height)
	mpp = data.metersPerPixel
	mpu = data.metersPerUnit
	grid_m = mpp * float(data.get("gridSize", 100))
	var grid: Dictionary = data.get("grid", {}) if data.get("grid") is Dictionary else {}
	grid_size = float(grid.get("size", data.get("gridSize", 100)))
	grid_type = int(grid.get("type", 1))
	grid_color = Color.from_string(str(grid.get("color", "#000000")), Color.BLACK)
	grid_alpha = float(grid.get("alpha", 0.2))
	grid_thickness = float(grid.get("thickness", 1))
	wall_height = float(data.get("wallHeight", 10))
	levels = data.get("levels", []).duplicate()
	if levels.is_empty():
		levels.append({"id": "default", "name": "Ground", "bottom": 0, "top": null,
			"background": null, "color": "#999999", "offsetX": 0, "offsetY": 0})
	levels.sort_custom(func(a, b): return float(a.bottom) < float(b.bottom))


func to_3d(px: float, py: float, elevation: float = 0.0) -> Vector3:
	return Vector3((px - rect.position.x) * mpp, elevation * mpu, (py - rect.position.y) * mpp)


func px_to_m(px: float) -> float:
	return px * mpp


func units_to_m(units: float) -> float:
	return units * mpu


func size_m() -> Vector2:
	return rect.size * mpp


func level_by_id(level_id: String) -> Dictionary:
	for lv in levels:
		if lv.id == level_id:
			return lv
	return {}


## Vertical spans [bottom_m, height_m, level_id] a wall occupies. Walls not bound to
## any Level appear on every Level, each span capped by the scene's wall height.
func wall_spans(wall_levels: Array) -> Array:
	var ids: Array = wall_levels if not wall_levels.is_empty() else levels.map(func(l): return l.id)
	var spans := []
	for level_id in ids:
		var lv := level_by_id(level_id)
		if lv.is_empty():
			continue
		var bottom := float(lv.bottom)
		var height := wall_height
		if lv.top != null and float(lv.top) > bottom:
			height = minf(height, float(lv.top) - bottom)
		spans.append([units_to_m(bottom), units_to_m(height), level_id])
	if spans.is_empty():
		spans.append([0.0, units_to_m(wall_height), "default"])
	return spans
