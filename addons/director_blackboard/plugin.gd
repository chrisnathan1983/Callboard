@tool
extends EditorPlugin
## Adds a "Rule Board" main-screen tab next to 2D / 3D / Script.

var board: RuleBoard
var _opened := false
var _zone_dialog: ConfirmationDialog
var _zone_line_edit: LineEdit
var _pending_navigate_path := ""

func _enter_tree() -> void:
	board = RuleBoard.new()
	board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board.layout_saved.connect(func(path: String) -> void:
		EditorInterface.get_resource_filesystem().update_file(path))
	EditorInterface.get_editor_main_screen().add_child(board)
	_make_visible(false)
	# Adds "Create New Zone..." under the Project -> Tools menu
	add_tool_menu_item("Create New Zone...", _on_create_zone_pressed)
	_setup_dialog()

func _exit_tree() -> void:
	if board:
		board.queue_free()
	# Always remove menu items and clean up UI nodes on disable/exit
	remove_tool_menu_item("Create New Zone...")
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

func _setup_dialog() -> void:
	_zone_dialog = ConfirmationDialog.new()
	_zone_dialog.title = "Create New Zone"
	_zone_dialog.min_size = Vector2i(320, 100)
	
	var vbox := VBoxContainer.new()
	var label := Label.new()
	label.text = "Enter Zone Name (e.g. zone_02):"
	
	_zone_line_edit = LineEdit.new()
	_zone_line_edit.placeholder_text = "zone_name"
	
	vbox.add_child(label)
	vbox.add_child(_zone_line_edit)
	_zone_dialog.add_child(vbox)
	
	# Add dialog to the root editor control
	EditorInterface.get_base_control().add_child(_zone_dialog)
	
	_zone_dialog.confirmed.connect(_on_dialog_confirmed)

func _on_create_zone_pressed() -> void:
	_zone_line_edit.text = ""
	_zone_dialog.popup_centered()
	_zone_line_edit.grab_focus()

func _on_dialog_confirmed() -> void:
	var raw_name := _zone_line_edit.text.strip_edges()
	if raw_name.is_empty():
		push_error("Zone creation canceled: Name cannot be empty.")
		return
	_create_zone_files(raw_name)

const DEFINITION_PROP := "definition"  # <- change to match your Zone property

func _create_zone_files(zone_name: String) -> void:
	var safe_name := zone_name.to_snake_case()
	var dir_path := "res://zones/" + safe_name + "/"
	var script_path := dir_path + safe_name + ".gd"
	var res_path := dir_path + safe_name + ".tres"
	var scene_path := dir_path + safe_name + ".tscn"

	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	# 1. Generate Zone GDScript
	if not FileAccess.file_exists(script_path):
		var script_code := """@tool
class_name %s extends Zone

func _build_props() -> void:
	pass

func _build_blackboard() -> void:
	pass
""" % safe_name.to_pascal_case()
		var f := FileAccess.open(script_path, FileAccess.WRITE)
		f.store_string(script_code)
		f.close()
		print("Created script: ", script_path)
	else:
		print("Script already exists: ", script_path)

	var editor_fs := EditorInterface.get_resource_filesystem()
	editor_fs.update_file(script_path)

	var zone_script := ResourceLoader.load(
			script_path, "", ResourceLoader.CACHE_MODE_REPLACE) as GDScript
	if zone_script == null or not zone_script.can_instantiate():
		push_error("Zone script failed to compile: %s" % script_path)
		return

	# 2. Create ZoneDefinition resource
	if not FileAccess.file_exists(res_path):
		var new_def := ZoneDefinition.new()
		new_def.zone_script = zone_script
		var err := ResourceSaver.save(new_def, res_path)
		if err != OK:
			push_error("Failed to save resource: %s" % error_string(err))
			return
		print("Created zone resource: ", res_path)
	else:
		print("Resource already exists: ", res_path)
	editor_fs.update_file(res_path)

	# Load from disk so the scene references the .tres instead of embedding a copy
	var zone_def := ResourceLoader.load(
			res_path, "", ResourceLoader.CACHE_MODE_REPLACE) as ZoneDefinition

	# 3. Create scene with the script attached and the definition assigned
	if not FileAccess.file_exists(scene_path):
		var root = zone_script.new()
		root.name = safe_name.to_pascal_case()
		if DEFINITION_PROP in root:
			root.set(DEFINITION_PROP, zone_def)
		else:
			push_warning("Zone has no '%s' property; definition not assigned." % DEFINITION_PROP)

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
	else:
		print("Scene already exists: ", scene_path)
	editor_fs.update_file(scene_path)

	# 4. One scan; navigate once the dock has refreshed
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