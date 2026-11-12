@tool
extends EditorPlugin
## Adds a "Rule Board" main-screen tab next to 2D / 3D / Script, and a
## "Create New Zone..." entry under Project -> Tools.

const ZONES_DIR := "res://zones/"
const MENU_ITEM := "Create New Zone..."

var board: RuleBoard
var _opened := false
var _zone_dialog: ConfirmationDialog
var _zone_line_edit: LineEdit
var _zone_preview: Label
var _zone_error: Label
var _pending_navigate_path := ""

func _enter_tree() -> void:
	board = RuleBoard.new()
	board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board.layout_saved.connect(func(path: String) -> void:
		EditorInterface.get_resource_filesystem().update_file(path))
	EditorInterface.get_editor_main_screen().add_child(board)
	_make_visible(false)
	add_tool_menu_item(MENU_ITEM, _on_create_zone_pressed)
	_setup_dialog()

func _exit_tree() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs and fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.disconnect(_on_filesystem_changed)
	if is_instance_valid(board):
		board.queue_free()
	remove_tool_menu_item(MENU_ITEM)
	if is_instance_valid(_zone_dialog):
		_zone_dialog.queue_free()

func _has_main_screen() -> bool:
	return true

func _make_visible(visible: bool) -> void:
	if board:
		board.visible = visible
		if visible and not _opened:
			_opened = true
			board.refresh()

func _get_plugin_name() -> String:
	return "Rule Board"

func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("GraphEdit", "EditorIcons")

# --- Dialog -----------------------------------------------------------------------

func _setup_dialog() -> void:
	_zone_dialog = ConfirmationDialog.new()
	_zone_dialog.title = "Create New Zone"
	_zone_dialog.ok_button_text = "Create"
	_zone_dialog.min_size = Vector2i(360, 140)
	_zone_dialog.dialog_hide_on_ok = false   # stay open so validation errors can be shown

	var vbox := VBoxContainer.new()
	var label := Label.new()
	label.text = "Zone name (e.g. zone_02):"
	_zone_line_edit = LineEdit.new()
	_zone_line_edit.placeholder_text = "zone_name"
	_zone_preview = Label.new()
	_zone_preview.add_theme_font_size_override("font_size", 12)
	_zone_preview.modulate = Color(1, 1, 1, 0.6)
	_zone_error = Label.new()
	_zone_error.add_theme_color_override("font_color", Color(1, 0.45, 0.45))
	_zone_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	vbox.add_child(label)
	vbox.add_child(_zone_line_edit)
	vbox.add_child(_zone_preview)
	vbox.add_child(_zone_error)
	_zone_dialog.add_child(vbox)
	EditorInterface.get_base_control().add_child(_zone_dialog)

	_zone_dialog.register_text_enter(_zone_line_edit)   # Enter confirms
	_zone_dialog.confirmed.connect(_on_dialog_confirmed)
	_zone_line_edit.text_changed.connect(_on_name_changed)

func _on_create_zone_pressed() -> void:
	_zone_line_edit.text = ""
	_zone_error.text = ""
	_on_name_changed("")
	_zone_dialog.popup_centered()
	_zone_line_edit.grab_focus()

## Shows what the typed name resolves to, so snake/Pascal conversion is never a surprise.
func _on_name_changed(text: String) -> void:
	_zone_error.text = ""
	var raw := text.strip_edges()
	if raw.is_empty():
		_zone_preview.text = ""
		return
	var safe := raw.to_snake_case()
	_zone_preview.text = "%s%s/   class %s" % [ZONES_DIR, safe, safe.to_pascal_case()]

func _on_dialog_confirmed() -> void:
	var raw_name := _zone_line_edit.text.strip_edges()
	var error := _validate_zone_name(raw_name)
	if error != "":
		_zone_error.text = error
		return
	_zone_dialog.hide()
	_create_zone_files(raw_name)

## Returns an error message, or "" if the name is usable.
func _validate_zone_name(raw_name: String) -> String:
	if raw_name.is_empty():
		return "Enter a zone name."
	var safe := raw_name.to_snake_case()
	var cls := safe.to_pascal_case()
	if not safe.is_valid_identifier():
		return "'%s' is not a valid name (letters, digits and underscores; no leading digit)." % safe
	if cls == "Zone" or ClassDB.class_exists(cls):
		return "Class '%s' conflicts with an engine or base class." % cls
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == cls:
			return "Class '%s' already exists in the project." % cls
	var dir_path := ZONES_DIR + safe + "/"
	if DirAccess.dir_exists_absolute(dir_path):
		return "Zone '%s' already exists." % safe
	return ""

# --- Creation ---------------------------------------------------------------------

func _create_zone_files(zone_name: String) -> void:
	var safe_name := zone_name.to_snake_case()
	var pascal := safe_name.to_pascal_case()
	var dir_path := ZONES_DIR + safe_name + "/"
	var script_path := dir_path + safe_name + ".gd"
	var res_path := dir_path + safe_name + ".tres"
	var scene_path := dir_path + safe_name + ".tscn"

	for p in [script_path, res_path, scene_path]:
		if FileAccess.file_exists(p):
			push_error("Zone creation aborted: '%s' already exists." % p)
			return

	var dir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if dir_err != OK:
		push_error("Could not create '%s': %s" % [dir_path, error_string(dir_err)])
		return

	# 1. Zone GDScript
	var script_code := """@tool
class_name %s extends Zone

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

	var zone_script := ResourceLoader.load(
			script_path, "", ResourceLoader.CACHE_MODE_REPLACE) as GDScript
	if zone_script == null or not zone_script.can_instantiate():
		push_error("Zone script failed to compile: %s" % script_path)
		return

	# 2. ZoneDefinition resource
	var new_def := ZoneDefinition.new()
	new_def.zone_script = zone_script
	var err := ResourceSaver.save(new_def, res_path)
	if err != OK:
		push_error("Failed to save resource: %s" % error_string(err))
		return
	print("Created zone resource: ", res_path)
	editor_fs.update_file(res_path)

	# Load from disk so the scene references the .tres instead of embedding a copy
	var zone_def := ResourceLoader.load(
			res_path, "", ResourceLoader.CACHE_MODE_REPLACE) as ZoneDefinition
	if zone_def == null:
		push_error("Could not reload resource: %s" % res_path)
		return

	# 3. Scene with the script attached and the definition assigned
	var root := zone_script.new() as Zone
	if root == null:
		push_error("Script '%s' does not extend Zone." % script_path)
		return
	root.name = pascal
	root.definition = zone_def

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
	print("Created zone scene: ", scene_path)
	editor_fs.update_file(scene_path)

	# 4. Refresh the board's picker (skipped if it has unsaved edits: refresh would drop them)
	if _opened and is_instance_valid(board) and not board._dirty:
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