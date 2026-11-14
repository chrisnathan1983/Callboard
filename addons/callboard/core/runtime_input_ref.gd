@tool
class_name RuntimeInputRef extends RefCounted
## Build-time marker for a value resolved from a rule's payload or Blackboard at run time.

enum Source { PAYLOAD, BLACKBOARD }

var source: Source
var key: StringName
var value_type := TYPE_NIL
var valid := true
var issue := ""

func _init(p_source: Source = Source.PAYLOAD, p_key: StringName = &"",
		p_type := TYPE_NIL, p_valid := true, p_issue := "") -> void:
	source = p_source
	key = p_key
	value_type = p_type
	valid = p_valid
	issue = p_issue

func resolve(context: Dictionary, blackboard: Blackboard) -> Dictionary:
	if not valid:
		return {"ok": false, "error": issue}
	var value: Variant
	if source == Source.PAYLOAD:
		var payload: Dictionary = context.get("payload", {})
		if payload.has(key):
			value = payload[key]
		elif payload.has(String(key)):
			value = payload[String(key)]
		else:
			return {"ok": false, "error": "payload field '%s' is missing" % key}
	else:
		if blackboard == null or not blackboard.has(key):
			return {"ok": false, "error": "Blackboard key '%s' is no longer declared" % key}
		value = blackboard.get_var(key)
	if value_type != TYPE_NIL and typeof(value) != value_type:
		return {"ok": false, "error": "source '%s' has runtime type %s, expected %s" % [
			key, type_string(typeof(value)), type_string(value_type)]}
	return {"ok": true, "value": value}
