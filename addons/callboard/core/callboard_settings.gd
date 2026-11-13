@tool
class_name CallboardSettings extends RefCounted
## Project-level settings shared by the editor plugin and the Callboard panel.

const STAGES_DIRECTORY := "callboard/stages_directory"
const DEFAULT_STAGES_DIRECTORY := "res://stages"

static func register_project_settings() -> void:
	if not ProjectSettings.has_setting(STAGES_DIRECTORY):
		ProjectSettings.set_setting(STAGES_DIRECTORY, DEFAULT_STAGES_DIRECTORY)
	ProjectSettings.add_property_info({
		"name": STAGES_DIRECTORY,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_DIR,
	})

static func stages_directory() -> String:
	var directory := String(ProjectSettings.get_setting(
		STAGES_DIRECTORY, DEFAULT_STAGES_DIRECTORY)).strip_edges()
	if directory.is_empty():
		directory = DEFAULT_STAGES_DIRECTORY
	while directory.ends_with("/") and directory != "res://":
		directory = directory.trim_suffix("/")
	return directory
