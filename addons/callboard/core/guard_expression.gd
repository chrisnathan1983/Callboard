@tool
class_name GuardExpression extends RefCounted
## Parses Blackboard truthiness guards and numeric comparisons such as `heat >= 2.5`.

const COMPARISON_PATTERN := "^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*(>=|<=|==|!=|>|<)\\s*(-?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+))\\s*$"
static var _comparison_regex: RegEx

static func parse(expression: String) -> Dictionary:
	var text := expression.strip_edges()
	if _comparison_regex == null:
		_comparison_regex = RegEx.new()
		_comparison_regex.compile(COMPARISON_PATTERN)
	var found := _comparison_regex.search(text)
	if found != null:
		return {
			"ok": true,
			"key": StringName(found.get_string(1)),
			"operator": found.get_string(2),
			"literal": found.get_string(3),
			"value": found.get_string(3).to_float(),
			"comparison": true,
		}
	if text.is_valid_identifier():
		return {"ok": true, "key": StringName(text), "comparison": false}
	return {"ok": false, "key": &"", "comparison": false}

static func evaluate(blackboard: Blackboard, expression: StringName) -> bool:
	var parsed := parse(String(expression))
	if not parsed["ok"]:
		return false
	var key: StringName = parsed["key"]
	if not parsed["comparison"]:
		return blackboard.is_set(key)
	if not blackboard.has(key):
		return false
	var entry: Dictionary = blackboard.schema.get(blackboard.resolve_key(key), {})
	if entry.get("type") not in [TYPE_INT, TYPE_FLOAT]:
		return false
	var actual := float(blackboard.get_var(key))
	var expected: float = parsed["value"]
	match parsed["operator"]:
		">": return actual > expected
		">=": return actual >= expected
		"<": return actual < expected
		"<=": return actual <= expected
		"==": return is_equal_approx(actual, expected)
		"!=": return not is_equal_approx(actual, expected)
	return false

static func referenced_key(expression: StringName) -> StringName:
	var parsed := parse(String(expression))
	return parsed["key"] if parsed["ok"] else &""

static func rename_key(expression: String, old_key: String, new_key: String) -> String:
	var parsed := parse(expression)
	if not parsed["ok"] or parsed["key"] != StringName(old_key):
		return expression
	if not parsed["comparison"]:
		return new_key
	return "%s %s %s" % [new_key, parsed["operator"], parsed["literal"]]
