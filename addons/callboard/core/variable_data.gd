@tool
class_name VariableData extends Resource
## Serializable Blackboard key and default.

@export var key: StringName
@export_enum("local", "saved") var scope := "local"
@export var default_value: Variant = false
@export_multiline var note := ""
@export var state_key: StringName
@export var aliases: Array[StringName] = []

static func from_dictionary(source: Dictionary) -> VariableData:
	var data := VariableData.new()
	data.key = StringName(source.get("key", ""))
	data.scope = String(source.get("scope", "local"))
	data.default_value = source.get("default", false)
	data.note = String(source.get("note", ""))
	data.state_key = StringName(source.get("state_key", source.get("key", "")))
	for alias in source.get("aliases", []):
		data.aliases.append(StringName(alias))
	return data

func to_dictionary() -> Dictionary:
	return {
		"key": String(key), "scope": scope, "default": default_value,
		"note": note, "state_key": String(state_key), "aliases": aliases.map(func(alias: StringName) -> String: return String(alias)),
	}
