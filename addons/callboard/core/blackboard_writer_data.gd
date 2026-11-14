@tool
class_name BlackboardWriterData extends Resource
## Describes an external producer of a Blackboard key.

@export var key: StringName
@export var source: StringName = &""
@export_enum("Variant", "bool", "int", "float", "String", "StringName") var value_type := "Variant"

func duplicate_data() -> BlackboardWriterData:
	var copy := BlackboardWriterData.new()
	copy.key = key
	copy.source = source
	copy.value_type = value_type
	return copy

func to_dictionary() -> Dictionary:
	return {"key": String(key), "source": String(source), "value_type": value_type}

static func from_dictionary(data: Dictionary) -> BlackboardWriterData:
	var writer := BlackboardWriterData.new()
	writer.key = StringName(data.get("key", ""))
	writer.source = StringName(data.get("source", ""))
	writer.value_type = String(data.get("value_type", "Variant"))
	return writer

func type_id() -> int:
	match value_type:
		"bool": return TYPE_BOOL
		"int": return TYPE_INT
		"float": return TYPE_FLOAT
		"String": return TYPE_STRING
		"StringName": return TYPE_STRING_NAME
		_: return TYPE_NIL
