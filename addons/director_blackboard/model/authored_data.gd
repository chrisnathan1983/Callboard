@tool
class_name AuthoredData extends RefCounted
## Dictionary defaults shared by the Rule Board and the script parser.

static func new_rule(id: String, trigger: String) -> Dictionary:
	return {
		"id": id, "trigger": trigger, "requires": [], "forbids": [], "cancel_if": [],
		"once": false, "emit": "", "steps": [], "group": "", "pos": Vector2.ZERO, "has_pos": false,
	}

static func new_step(verb: String, args: Array, delay := "") -> Dictionary:
	return {"verb": verb, "args": args, "delay": delay, "emits": "", "sets": []}

static func new_variable(key: String, scope: String, value: Variant, expression: String) -> Dictionary:
	return {
		"key": key, "scope": scope, "default": value, "default_expr": expression,
		"note": "", "note_pad": "   ",
	}
