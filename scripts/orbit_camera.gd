extends Node3D
## Orbit camera around a ground pivot (this node's position).
## Left-drag: orbit · Right/middle-drag: pan · Wheel: zoom · WASD: pan · Q/E: rotate · T: top-down

const ORBIT_SPEED := 0.005
const KEY_PAN_SPEED := 0.8  # fraction of the zoom distance per second
const MIN_PITCH := -89.9
const MAX_PITCH := -5.0

var distance := 30.0
var yaw := 0.0
var pitch := deg_to_rad(-60.0)
var follow: Node3D = null  ## when set, the pivot glides after this node
## Set while the cinematic camera drives the pose: WASD / QE / follow are skipped (shake still plays).
var driven := false
## Play mode: only the player moves the camera (no follow, no director). Shake still plays.
var manual_only := false

## The user moved the camera by hand (drag, wheel, WASD, QE, T): the cinematic camera steps aside.
signal user_input

var camera := Camera3D.new()

## Camera shake (heavy token hits): offset up to `_shake_strength` x distance, fading out over the duration.
var _shake_strength := 0.0
var _shake_duration := 0.0
var _shake_left := 0.0
var _shake_offset := Vector2.ZERO
var _shake_next := 0.0
const SHAKE_RATE := 40.0  # new random offsets per second


func _ready() -> void:
	camera.far = 4000.0
	add_child(camera)
	_update_camera()


## Center the view on a rectangle of the ground plane of the given size (meters).
func frame(center: Vector3, size: Vector2) -> void:
	position = center
	distance = maxf(size.x, size.y) * 0.9 + 5.0
	_update_camera()


## `strength`: largest offset as a fraction of the zoom distance, so it looks the same at any zoom.
func shake(strength: float, duration: float) -> void:
	var current := _shake_strength * _shake_fade()
	if strength >= current:
		_shake_strength = strength
		_shake_duration = duration
		_shake_left = duration


func _shake_fade() -> float:
	var k := _shake_left / _shake_duration if _shake_duration > 0.0 else 0.0
	return k * k


func top_down() -> void:
	yaw = 0.0
	pitch = deg_to_rad(MIN_PITCH)


## A mouse drag of `relative` px: orbit around the pivot. Called directly by play mode too (play_mode.gd): its
## drags come from the page, and fake motion events would be swallowed by the WebView control.
func orbit_by(relative: Vector2) -> void:
	user_input.emit()
	yaw -= relative.x * ORBIT_SPEED
	pitch = clampf(pitch - relative.y * ORBIT_SPEED, deg_to_rad(MIN_PITCH), deg_to_rad(MAX_PITCH))


## A mouse drag of `relative` px: pan the pivot along the ground.
func pan_by(relative: Vector2) -> void:
	user_input.emit()
	_pan(Vector2(-relative.x, relative.y) * distance * 0.0015)


## One wheel step.
func zoom_step(zoom_in: bool) -> void:
	user_input.emit()
	distance = maxf(1.0, distance * 0.9) if zoom_in else minf(2000.0, distance * 1.1)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			orbit_by(event.relative)
		elif event.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE):
			pan_by(event.relative)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			zoom_step(event.button_index == MOUSE_BUTTON_WHEEL_UP)
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		user_input.emit()
		top_down()


func _process(delta: float) -> void:
	if _shake_left > 0.0:
		_shake_left = maxf(0.0, _shake_left - delta)
		_shake_next -= delta
		if _shake_next <= 0.0:
			_shake_next = 1.0 / SHAKE_RATE
			_shake_offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
	if get_viewport().gui_get_focus_owner() is LineEdit:  # typing in the UI, e.g. a preset name
		_update_camera()
		return
	var move := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S)))
	var turn := float(Input.is_key_pressed(KEY_Q)) - float(Input.is_key_pressed(KEY_E))
	if move != Vector2.ZERO or turn != 0.0:
		user_input.emit()  # the cinematic camera hands over (clears `driven`) before the keys apply
	if manual_only:
		follow = null
		driven = false
	if driven:
		_update_camera()
		return
	if move != Vector2.ZERO:
		_pan(move * distance * KEY_PAN_SPEED * delta)
	yaw += turn * 1.5 * delta
	if follow and is_instance_valid(follow):
		position = position.lerp(follow.global_position, 1.0 - exp(-6.0 * delta))
	_update_camera()


## Move the pivot along the ground: x = screen right, y = screen up (away from the camera).
func _pan(amount: Vector2) -> void:
	follow = null
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	position += right * amount.x + forward * amount.y


func _update_camera() -> void:
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	var origin := b.z * distance
	if _shake_left > 0.0:
		origin += (b.x * _shake_offset.x + b.y * _shake_offset.y) * _shake_strength * _shake_fade() * distance
	camera.transform = Transform3D(b, origin)
