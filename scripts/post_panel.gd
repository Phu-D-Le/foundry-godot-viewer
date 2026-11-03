extends PanelContainer
## The viewer's Post-Process panel (button / P key): one control per HD-2D setting. Edits are reported
## right away through `edited`; main.gd applies them and auto-saves them to the Foundry scene.

signal edited(settings: Dictionary)
signal reset_requested
signal preset_save_requested(name: String, settings: Dictionary)
signal preset_delete_requested(name: String)

const PostProcess = preload("res://scripts/post_process.gd")

var settings := PostProcess.DEFAULTS.duplicate()
var _controls := {}  # key -> Range or CheckBox
var _values := {}    # key -> Label showing the number
var _source: Label
var _presets := {"builtIn": {}, "user": {}}
var _preset_names: Array[String] = []
var _preset_pick: OptionButton
var _preset_name: LineEdit
var _preset_delete: Button


func _init() -> void:
	name = "PostPanel"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.text = "HD-2D Post-Process (saved with this scene)"
	box.add_child(title)
	_source = Label.new()
	_source.add_theme_font_size_override("font_size", 12)
	_source.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_source)

	# Presets: load one into this scene, or save the current look under a name for other scenes.
	var load_row := HBoxContainer.new()
	box.add_child(load_row)
	_preset_pick = OptionButton.new()
	_preset_pick.focus_mode = Control.FOCUS_NONE
	_preset_pick.custom_minimum_size.x = 210
	_preset_pick.item_selected.connect(func(_i: int) -> void: _sync_delete_button())
	load_row.add_child(_preset_pick)
	var load_button := Button.new()
	load_button.text = "Load preset"
	load_button.focus_mode = Control.FOCUS_NONE
	load_button.pressed.connect(load_selected_preset)
	load_row.add_child(load_button)
	_preset_delete = Button.new()
	_preset_delete.text = "Delete"
	_preset_delete.focus_mode = Control.FOCUS_NONE
	_preset_delete.pressed.connect(func() -> void:
		var preset := _selected_preset()
		if _presets.user.has(preset):
			preset_delete_requested.emit(preset))
	load_row.add_child(_preset_delete)
	var save_row := HBoxContainer.new()
	box.add_child(save_row)
	_preset_name = LineEdit.new()
	_preset_name.placeholder_text = "New preset name"
	_preset_name.custom_minimum_size.x = 210
	save_row.add_child(_preset_name)
	var save_button := Button.new()
	save_button.text = "Save as preset"
	save_button.focus_mode = Control.FOCUS_NONE
	save_button.pressed.connect(func() -> void:
		var preset := _preset_name.text.strip_edges()
		if preset != "":
			preset_save_requested.emit(preset, settings.duplicate())
			_preset_name.text = ""
			_preset_name.release_focus())
	save_row.add_child(save_button)
	box.add_child(HSeparator.new())

	for field in PostProcess.FIELDS:
		var row := HBoxContainer.new()
		box.add_child(row)
		var label := Label.new()
		label.text = field.label
		label.custom_minimum_size.x = 170
		row.add_child(label)
		var key: String = field.key
		if field.get("type") == "bool":
			var check := CheckBox.new()
			check.focus_mode = Control.FOCUS_NONE  # keep keyboard shortcuts working
			check.toggled.connect(func(on: bool) -> void: _on_edit(key, on))
			row.add_child(check)
			_controls[key] = check
		else:
			var slider := HSlider.new()
			slider.min_value = field.min
			slider.max_value = field.max
			slider.step = field.step
			slider.custom_minimum_size.x = 160
			slider.focus_mode = Control.FOCUS_NONE
			slider.value_changed.connect(func(v: float) -> void: _on_edit(key, v))
			row.add_child(slider)
			var value := Label.new()
			value.custom_minimum_size.x = 44
			row.add_child(value)
			_controls[key] = slider
			_values[key] = value
	var reset := Button.new()
	reset.text = "Use Foundry defaults"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(func() -> void: reset_requested.emit())
	box.add_child(reset)


## Show settings that came from Foundry without reporting them as edits.
func show_settings(values: Dictionary, own: bool) -> void:
	settings = PostProcess.normalize(values)
	for key in _controls:
		var control = _controls[key]
		if control is CheckBox:
			control.set_pressed_no_signal(settings[key])
		else:
			control.set_value_no_signal(settings[key])
			_values[key].text = "%.2f" % settings[key]
	_source.text = "Using this scene's own settings" if own else "Using the Foundry defaults (edit to give this scene its own)"


## The preset list from Foundry: {builtIn: {name: settings}, user: {name: settings}}.
func set_presets(presets: Dictionary) -> void:
	var previous := _selected_preset()
	_presets = {"builtIn": presets.get("builtIn", {}), "user": presets.get("user", {})}
	_preset_pick.clear()
	_preset_names.clear()
	for group in ["builtIn", "user"]:
		for preset in _presets[group]:
			_preset_names.append(preset)
			_preset_pick.add_item(("★ " if group == "user" else "") + preset)
	var index := _preset_names.find(previous)
	if index >= 0:
		_preset_pick.select(index)
	_sync_delete_button()


func select_preset(preset: String) -> void:
	var index := _preset_names.find(preset)
	if index >= 0:
		_preset_pick.select(index)
		_sync_delete_button()


## Load the chosen preset into this scene (applied at once and auto-saved, like any edit).
func load_selected_preset() -> void:
	var preset := _selected_preset()
	var values = _presets.user.get(preset, _presets.builtIn.get(preset))
	if not values is Dictionary:
		return
	show_settings(values, true)
	_source.text = "Loaded preset \"%s\" (saving...)" % preset
	edited.emit(settings.duplicate())


func _selected_preset() -> String:
	var index := _preset_pick.selected
	return _preset_names[index] if index >= 0 and index < _preset_names.size() else ""


func _sync_delete_button() -> void:
	_preset_delete.disabled = not _presets.user.has(_selected_preset())


## Change one setting as if the user had (used by tests too).
func set_setting(key: String, value) -> void:
	var control = _controls[key]
	if control is CheckBox:
		control.button_pressed = value
	else:
		control.value = value


func _on_edit(key: String, value) -> void:
	settings[key] = value
	if _values.has(key):
		_values[key].text = "%.2f" % value
	_source.text = "Using this scene's own settings (saving...)"
	edited.emit(settings.duplicate())
