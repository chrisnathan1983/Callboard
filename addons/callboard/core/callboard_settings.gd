@tool
class_name CallboardSettings extends RefCounted
## Project-level settings shared by the editor plugin and the Callboard panel.

const STAGES_DIRECTORY := "callboard/stages_directory"
const DEFAULT_STAGES_DIRECTORY := "res://stages"
const ADDITIONAL_STAGE_DIRECTORIES := "callboard/additional_stage_directories"

static func register_project_settings() -> void:
	if not ProjectSettings.has_setting(STAGES_DIRECTORY):
		ProjectSettings.set_setting(STAGES_DIRECTORY, DEFAULT_STAGES_DIRECTORY)
	if not ProjectSettings.has_setting(ADDITIONAL_STAGE_DIRECTORIES):
		ProjectSettings.set_setting(ADDITIONAL_STAGE_DIRECTORIES, PackedStringArray())
	ProjectSettings.add_property_info({
		"name": STAGES_DIRECTORY,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_DIR,
	})
	ProjectSettings.add_property_info({
		"name": ADDITIONAL_STAGE_DIRECTORIES,
		"type": TYPE_PACKED_STRING_ARRAY,
	})

static func stages_directory() -> String:
	var directory := String(ProjectSettings.get_setting(
		STAGES_DIRECTORY, DEFAULT_STAGES_DIRECTORY)).strip_edges()
	if directory.is_empty():
		directory = DEFAULT_STAGES_DIRECTORY
	return _normalize_directory(directory)

static func stage_directories() -> Array[String]:
	var directories: Array[String] = []
	var primary := stages_directory()
	directories.append(primary)
	var additional := PackedStringArray(ProjectSettings.get_setting(
		ADDITIONAL_STAGE_DIRECTORIES, PackedStringArray()))
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
