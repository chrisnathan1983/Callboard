@tool
class_name TriggerRoutingData extends Resource
## Optional per-trigger dispatch behavior. Missing entries use multi-match.

enum Mode { MULTI_MATCH, FIRST_MATCH }

@export var trigger: StringName
@export var mode := Mode.MULTI_MATCH
## In First Match mode this rule is considered only if no other rule passes.
@export var fallback_rule_id: StringName

static func from_dictionary(source: Dictionary) -> Resource:
	var data := (load("res://addons/callboard/core/trigger_routing_data.gd") as Script).new() as Resource
	data.set("trigger", StringName(source.get("trigger", "")))
	data.set("mode", int(source.get("mode", Mode.MULTI_MATCH)))
	data.set("fallback_rule_id", StringName(source.get("fallback_rule_id", "")))
	return data

func to_dictionary() -> Dictionary:
	return {"trigger": String(trigger), "mode": mode,
		"fallback_rule_id": String(fallback_rule_id)}
