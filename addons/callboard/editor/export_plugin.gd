@tool
extends EditorExportPlugin
## Removes Callboard authoring code from release exports.

var _debug_export := false

func _export_begin(_features: PackedStringArray, is_debug: bool, _path: String, _flags: int) -> void:
	_debug_export = is_debug

func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if should_strip(path, _debug_export):
		skip()

static func should_strip(path: String, is_debug: bool) -> bool:
	if is_debug:
		return false
	return (path.begins_with("res://addons/callboard/editor/")
		or path.begins_with("res://addons/callboard/model/")
		or path in [
			"res://addons/callboard/plugin.gd", "res://addons/callboard/plugin.gd.uid",
			"res://addons/callboard/plugin.cfg",
		])
