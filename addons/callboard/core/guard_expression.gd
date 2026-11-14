@tool
class_name GuardExpression extends RefCounted
## Parses Blackboard guards and typed event-payload comparisons.

const COMPARISON_PATTERN := '^\\s*((?:payload\\.)?[A-Za-z_][A-Za-z0-9_]*)\\s*(>=|<=|==|!=|>|<)\\s*("(?:[^"\\\\]|\\\\.)*"|true|false|-?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+))\\s*$'
const PRESENCE_PATTERN := '^\\s*(has|missing)\\s*\\(\\s*payload\\.([A-Za-z_][A-Za-z0-9_]*)\\s*\\)\\s*$'
static var _comparison_regex: RegEx
static var _presence_regex: RegEx

static func parse(expression: String) -> Dictionary:
	var text := expression.strip_edges()
	if _presence_regex == null:
		_presence_regex = RegEx.new()
		_presence_regex.compile(PRESENCE_PATTERN)
	var presence := _presence_regex.search(text)
	if presence != null:
		return {"ok": true, "payload": true, "key": StringName(presence.get_string(2)),
			"presence": presence.get_string(1), "comparison": false}
	if _comparison_regex == null:
		_comparison_regex = RegEx.new()
		_comparison_regex.compile(COMPARISON_PATTERN)
	var found := _comparison_regex.search(text)
	if found != null:
		var ref := found.get_string(1)
		var literal := found.get_string(3)
		var value := _literal_value(literal)
		if _literal_type(literal) == TYPE_STRING and value == null:
			return {"ok": false, "payload": false, "key": &"", "comparison": false}
		return {"ok": true, "payload": ref.begins_with("payload."),
			"key": StringName(ref.trim_prefix("payload.")), "operator": found.get_string(2),
			"literal": literal, "value": value,
			"value_type": _literal_type(literal), "comparison": true}
	if text.is_valid_identifier():
		return {"ok": true, "payload": false, "key": StringName(text), "comparison": false}
	return {"ok": false, "payload": false, "key": &"", "comparison": false}

static func _literal_type(literal: String) -> int:
	if literal.begins_with('"'):
		return TYPE_STRING
	if literal == "true" or literal == "false":
		return TYPE_BOOL
	return TYPE_FLOAT if "." in literal else TYPE_INT

static func _literal_value(literal: String) -> Variant:
	match _literal_type(literal):
		TYPE_STRING: return JSON.parse_string(literal)
		TYPE_BOOL: return literal == "true"
		TYPE_INT: return literal.to_int()
		_: return literal.to_float()

static func evaluate(blackboard: Blackboard, expression: StringName,
		payload: Dictionary = {}, event_id: StringName = &"", schema: Dictionary = {}) -> bool:
	var parsed := parse(String(expression))
	if not parsed["ok"]:
		return false
	var key: StringName = parsed["key"]
	if parsed.get("presence", "") != "":
		var present := payload.has(key)
		return present if parsed["presence"] == "has" else not present
	if parsed["payload"]:
		if not parsed["comparison"] or not payload.has(key):
			return false
		var actual: Variant = payload[key]
		var expected: Variant = parsed["value"]
		var actual_type := typeof(actual)
		var expected_type: int = parsed["value_type"]
		var declared: int = schema.get(event_id, {}).get(key, TYPE_NIL)
		if declared != TYPE_NIL and actual_type != declared:
			return false
		if expected_type in [TYPE_INT, TYPE_FLOAT]:
			if actual_type not in [TYPE_INT, TYPE_FLOAT]: return false
			return _compare_numbers(float(actual), float(expected), parsed["operator"])
		if actual_type != expected_type or parsed["operator"] not in ["==", "!="]:
			return false
		return actual == expected if parsed["operator"] == "==" else actual != expected
	if not parsed["comparison"]:
		return blackboard.is_set(key)
	if not blackboard.has(key):
		return false
	var entry: Dictionary = blackboard.schema.get(blackboard.resolve_key(key), {})
	if entry.get("type") not in [TYPE_INT, TYPE_FLOAT] or parsed["value_type"] not in [TYPE_INT, TYPE_FLOAT]:
		return false
	return _compare_numbers(float(blackboard.get_var(key)), float(parsed["value"]), parsed["operator"])

static func _compare_numbers(actual: float, expected: float, operator: String) -> bool:
	match operator:
		">": return actual > expected
		">=": return actual >= expected
		"<": return actual < expected
		"<=": return actual <= expected
		"==": return is_equal_approx(actual, expected)
		"!=": return not is_equal_approx(actual, expected)
	return false

static func referenced_key(expression: StringName) -> StringName:
	var parsed := parse(String(expression))
	return parsed["key"] if parsed["ok"] and not parsed["payload"] else &""

static func referenced_payload_field(expression: StringName) -> StringName:
	var parsed := parse(String(expression))
	return parsed["key"] if parsed["ok"] and parsed["payload"] else &""

static func rename_key(expression: String, old_key: String, new_key: String) -> String:
	var parsed := parse(expression)
	if not parsed["ok"] or parsed["payload"] or parsed["key"] != StringName(old_key):
		return expression
	if not parsed["comparison"]:
		return new_key
	return "%s %s %s" % [new_key, parsed["operator"], parsed["literal"]]
