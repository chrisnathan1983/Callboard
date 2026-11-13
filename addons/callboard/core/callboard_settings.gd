@tool
class_name CallboardSettings extends RefCounted
## Project-level settings shared by the editor plugin and the Callboard panel.

const DEFAULT_STAGE_FOLDER := "callboard/default_stage_folder"
const STAGE_SCAN_FOLDERS := "callboard/stage_scan_folders"
const DEFAULT_FOLDER := "res://stages"
const LEGACY_DEFAULT_FOLDER := "callboard/stages_directory"
const LEGACY_SCAN_FOLDERS := "callboard/additional_stage_directories"

static func register_project_settings() -> void:
	_register_setting(DEFAULT_STAGE_FOLDER, LEGACY_DEFAULT_FOLDER, DEFAULT_FOLDER)
	_register_setting(STAGE_SCAN_FOLDERS, LEGACY_SCAN_FOLDERS, PackedStringArray())
	ProjectSettings.add_property_info({
		"name": DEFAULT_STAGE_FOLDER,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_DIR,
	})
	ProjectSettings.add_property_info({
		"name": STAGE_SCAN_FOLDERS,
		"type": TYPE_PACKED_STRING_ARRAY,
		"hint": PROPERTY_HINT_TYPE_STRING,
		"hint_string": "%d/%d:" % [TYPE_STRING, PROPERTY_HINT_DIR],
	})

static func _register_setting(key: String, legacy_key: String, default: Variant) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, ProjectSettings.get_setting(legacy_key, default))
	if ProjectSettings.has_setting(legacy_key):
		ProjectSettings.clear(legacy_key)
	ProjectSettings.set_initial_value(key, default)
	ProjectSettings.set_as_basic(key, true)

static func default_stage_folder() -> String:
	var directory := String(ProjectSettings.get_setting(
		DEFAULT_STAGE_FOLDER, DEFAULT_FOLDER)).strip_edges()
	if directory.is_empty():
		directory = DEFAULT_FOLDER
	return _normalize_directory(directory)

static func stage_directories() -> Array[String]:
	var directories: Array[String] = []
	var primary := default_stage_folder()
	directories.append(primary)
	var additional := PackedStringArray(ProjectSettings.get_setting(
		STAGE_SCAN_FOLDERS, PackedStringArray()))
	for value in additional:
		var directory := _normalize_directory(value.strip_edges())
		if not directory.is_empty() and not directories.has(directory):
			directories.append(directory)
	return directories

static func _normalize_directory(directory: String) -> String:
	if directory.is_empty():
		return ""
	while directory.ends_with("/") and directory != "res://":
		directory = directory.trim_suffix("/")
	return directory
