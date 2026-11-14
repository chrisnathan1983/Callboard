@tool
extends EditorPlugin
## Adds a "Callboard" main-screen tab next to 2D / 3D / Script, and a
## "Create New Stage..." entry under Project -> Tools.

const MENU_ITEM := "Create New Stage..."
const ExportPlugin := preload("res://addons/callboard/editor/export_plugin.gd")
const Settings := preload("res://addons/callboard/core/callboard_settings.gd")

var board: Callboard
var test_runner: VBoxContainer
var _opened := false
var _last_stage_folders: Array[String] = []
var _stage_dialog: ConfirmationDialog
var _stage_line_edit: LineEdit
var _stage_preview: Label
var _stage_error: Label
var _pending_navigate_path := ""
var _export_plugin: EditorExportPlugin

func _enter_tree() -> void:
	Settings.register_project_settings()
	board = Callboard.new()
	board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board.layout_saved.connect(func(path: String) -> void:
		EditorInterface.get_resource_filesystem().update_file(path))
	EditorInterface.get_editor_main_screen().add_child(board)
	_make_visible(false)
	test_runner = preload("res://addons/callboard/editor/test_runner_panel.gd").new()
	add_control_to_bottom_panel(test_runner, "Callboard Tests")
	add_tool_menu_item(MENU_ITEM, _on_create_stage_pressed)
	_export_plugin = ExportPlugin.new()
	add_export_plugin(_export_plugin)
	_setup_dialog()

func _exit_tree() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs and fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.disconnect(_on_filesystem_changed)
	if is_instance_valid(board):
		board.queue_free()
	if is_instance_valid(test_runner):
		test_runner.shutdown()
		remove_control_from_bottom_panel(test_runner)
		test_runner.queue_free()
	remove_tool_menu_item(MENU_ITEM)
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
	if is_instance_valid(_stage_dialog):
		_stage_dialog.queue_free()

func _has_main_screen() -> bool:
	return true

func _make_visible(visible: bool) -> void:
	if board:
		board.visible = visible
		if visible and not board.is_dirty():
			var folders := Settings.stage_directories()
			if not _opened or folders != _last_stage_folders:
				_opened = true
				_last_stage_folders = folders
				board.refresh()

func _get_plugin_name() -> String:
	return "Callboard"

func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("GraphEdit", "EditorIcons")

func _save_external_data() -> void:
	if is_instance_valid(board) and board.is_dirty():
		board.save()

func _get_unsaved_status(for_scene: String) -> String:
	if is_instance_valid(board) and board.is_dirty():
		return "Callboard has unsaved edits."
	return ""

# --- Dialog -----------------------------------------------------------------------

func _setup_dialog() -> void:
	_stage_dialog = ConfirmationDialog.new()
	_stage_dialog.title = "Create New Stage"
	_stage_dialog.ok_button_text = "Create"
	_stage_dialog.min_size = Vector2i(360, 140)
	_stage_dialog.dialog_hide_on_ok = false   # stay open so validation errors can be shown

	var vbox := VBoxContainer.new()
	var label := Label.new()
	label.text = "Stage name (e.g. stage_02):"
	_stage_line_edit = LineEdit.new()
	_stage_line_edit.placeholder_text = "stage_name"
	_stage_preview = Label.new()
	_stage_preview.add_theme_font_size_override("font_size", 12)
	_stage_preview.modulate = Color(1, 1, 1, 0.6)
	_stage_error = Label.new()
	_stage_error.add_theme_color_override("font_color", Color(1, 0.45, 0.45))
	_stage_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	vbox.add_child(label)
	vbox.add_child(_stage_line_edit)
	vbox.add_child(_stage_preview)
	vbox.add_child(_stage_error)
	_stage_dialog.add_child(vbox)
	EditorInterface.get_base_control().add_child(_stage_dialog)

	_stage_dialog.register_text_enter(_stage_line_edit)   # Enter confirms
	_stage_dialog.confirmed.connect(_on_dialog_confirmed)
	_stage_line_edit.text_changed.connect(_on_name_changed)

func _on_create_stage_pressed() -> void:
	_stage_line_edit.text = ""
	_stage_error.text = ""
	_on_name_changed("")
	_stage_dialog.popup_centered()
	_stage_line_edit.grab_focus()

## Shows what the typed name resolves to, so snake/Pascal conversion is never a surprise.
func _on_name_changed(text: String) -> void:
	_stage_error.text = ""
	var raw := text.strip_edges()
	if raw.is_empty():
		_stage_preview.text = ""
		return
	var safe := raw.to_snake_case()
	_stage_preview.text = "%s/   class %s" % [Settings.default_stage_folder().path_join(safe), safe.to_pascal_case()]

func _on_dialog_confirmed() -> void:
	var raw_name := _stage_line_edit.text.strip_edges()
	var error := _validate_stage_name(raw_name)
	if error != "":
		_stage_error.text = error
		return
	_stage_dialog.hide()
	_create_stage_files(raw_name)

## Returns an error message, or "" if the name is usable.
func _validate_stage_name(raw_name: String) -> String:
	if raw_name.is_empty():
		return "Enter a stage name."
	var safe := raw_name.to_snake_case()
	var cls := safe.to_pascal_case()
	if not safe.is_valid_identifier():
		return "'%s' is not a valid name (letters, digits and underscores; no leading digit)." % safe
	if cls == "Stage" or ClassDB.class_exists(cls):
		return "Class '%s' conflicts with an engine or base class." % cls
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == cls:
			return "Class '%s' already exists in the project." % cls
	var dir_path := Settings.default_stage_folder().path_join(safe)
	if DirAccess.dir_exists_absolute(dir_path):
		return "Stage '%s' already exists." % safe
	return ""

# --- Creation ---------------------------------------------------------------------

func _create_stage_files(stage_name: String) -> void:
	var safe_name := stage_name.to_snake_case()
	var pascal := safe_name.to_pascal_case()
	var dir_path := Settings.default_stage_folder().path_join(safe_name)
	var script_path := dir_path.path_join(safe_name + ".gd")
	var res_path := dir_path.path_join(safe_name + ".tres")
	var scene_path := dir_path.path_join(safe_name + ".tscn")

	for p in [script_path, res_path, scene_path]:
		if FileAccess.file_exists(p):
			push_error("Stage creation aborted: '%s' already exists." % p)
			return

	var dir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if dir_err != OK:
		push_error("Could not create '%s': %s" % [dir_path, error_string(dir_err)])
		return

	# 1. Stage GDScript
	var script_code := """@tool
class_name %s extends Stage

func _init() -> void:
	name = "%s"

func _build_props() -> void:
	pass
""" % [pascal, pascal]
	var f := FileAccess.open(script_path, FileAccess.WRITE)
	if f == null:
		push_error("Could not write '%s': %s" % [script_path, error_string(FileAccess.get_open_error())])
		return
	f.store_string(script_code)
	f.close()
	print("Created script: ", script_path)

	var editor_fs := EditorInterface.get_resource_filesystem()
	editor_fs.update_file(script_path)

	var stage_script := ResourceLoader.load(
			script_path, "", ResourceLoader.CACHE_MODE_REPLACE) as GDScript
	if stage_script == null or not stage_script.can_instantiate():
		push_error("Stage script failed to compile: %s" % script_path)
		return

	# 2. StageDefinition resource
	var new_def := StageDefinition.new()
	new_def.stage_script = stage_script
	new_def._migrate()
	var err := ResourceSaver.save(new_def, res_path)
	if err != OK:
		push_error("Failed to save resource: %s" % error_string(err))
		return
	print("Created stage resource: ", res_path)
	editor_fs.update_file(res_path)

	# Load from disk so the scene references the .tres instead of embedding a copy
	var stage_def := ResourceLoader.load(
			res_path, "", ResourceLoader.CACHE_MODE_REPLACE) as StageDefinition
	if stage_def == null:
		push_error("Could not reload resource: %s" % res_path)
		return

	# 3. Scene with the script attached and the definition assigned
	var root := stage_script.new() as Stage
	if root == null:
		push_error("Script '%s' does not extend Stage." % script_path)
		return
	root.name = pascal
	root.definition = stage_def

	var packed := PackedScene.new()
	var pack_err := packed.pack(root)
	root.free()
	if pack_err != OK:
		push_error("Failed to pack scene: %s" % error_string(pack_err))
		return
	var save_err := ResourceSaver.save(packed, scene_path)
	if save_err != OK:
		push_error("Failed to save scene: %s" % error_string(save_err))
		return
	print("Created stage scene: ", scene_path)
	editor_fs.update_file(scene_path)

	# 4. Refresh the board's picker (skipped if it has unsaved edits: refresh would drop them)
	if _opened and is_instance_valid(board) and not board.is_dirty():
		board.refresh()

	# 5. One scan; navigate once the dock has refreshed. A later creation just retargets the path.
	_pending_navigate_path = scene_path
	if not editor_fs.filesystem_changed.is_connected(_on_filesystem_changed):
		editor_fs.filesystem_changed.connect(_on_filesystem_changed, CONNECT_ONE_SHOT)
	editor_fs.scan()

func _on_filesystem_changed() -> void:
	if _pending_navigate_path.is_empty():
		return
	var path := _pending_navigate_path
	_pending_navigate_path = ""
	EditorInterface.get_file_system_dock().navigate_to_path(path)
	# Optional: open the new scene right away
	# EditorInterface.open_scene_from_path(path)
