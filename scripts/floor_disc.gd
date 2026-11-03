extends MeshInstance3D
## A flat disc that lies on the floor under its parent light, even when the light is tilted
## (cone lights) or moves (token lights). Used for light patterns and Foundry's light color grading.

## Floor height relative to the light (negative, meters).
var floor_offset := 0.0


func _init() -> void:
	top_level = true  # ignore the light's rotation
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _process(_delta: float) -> void:
	var parent := get_parent() as Node3D
	if parent:
		global_transform = Transform3D(Basis.IDENTITY, parent.global_position + Vector3(0.0, floor_offset, 0.0))
