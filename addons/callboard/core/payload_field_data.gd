@tool
class_name PayloadFieldData extends Resource
## Typed field declared for the payload of a Call or relay.

@export var event_id: StringName
@export var key: StringName
@export_enum("bool", "int", "float", "String") var type_name := "String"

func value_type() -> int:
	match type_name:
		"bool": return TYPE_BOOL
		"int": return TYPE_INT
		"float": return TYPE_FLOAT
		_: return TYPE_STRING

static func from_dictionary(source: Dictionary) -> PayloadFieldData:
	var field := PayloadFieldData.new()
	field.event_id = StringName(source.get("event_id", ""))
	field.key = StringName(source.get("key", ""))
	field.type_name = String(source.get("type", "String"))
	return field

func to_dictionary() -> Dictionary:
	return {"event_id": String(event_id), "key": String(key), "type": type_name}
