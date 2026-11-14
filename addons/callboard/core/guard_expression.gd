@tool
class_name GuardExpression extends RefCounted
## Parses and evaluates Blackboard and typed event-payload guards.

const COMPARISON_PATTERN := '^\\s*((?:payload\\.)?[A-Za-z_][A-Za-z0-9_]*)\\s*(>=|<=|==|!=|>|<)\\s*(&(?:"(?:[^"\\\\]|\\\\.)*")|"(?:[^"\\\\]|\\\\.)*"|true|false|-?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)|(?:payload\\.)?[A-Za-z_][A-Za-z0-9_]*)\\s*$'
const PRESENCE_PATTERN := '^\\s*(has|missing)\\s*\\(\\s*payload\\.([A-Za-z_][A-Za-z0-9_]*)\\s*\\)\\s*$'
static var _comparison_regex: RegEx
static var _presence_regex: RegEx

## Grammar: `or`/`||` over `and`/`&&` over parenthesized terms and `any(...)`.
## A plain term may test truthiness, payload presence, or compare two operands.
static func parse(expression: String) -> Dictionary:
	var text := expression.strip_edges()
	if text.is_empty():
		return _invalid()
	if _has_outer_parentheses(text):
		return parse(text.substr(1, text.length() - 2))
	var split := _split_boolean(text, "or")
	if split.size() > 1:
		return _parse_group("or", split)
	split = _split_boolean(text, "and")
	if split.size() > 1:
		return _parse_group("and", split)
	if text.begins_with("any(") and text.ends_with(")") and _has_outer_call_parentheses(text):
		var arguments := _split_commas(text.substr(4, text.length() - 5))
		if arguments.size() < 2:
			return _invalid()
		return _parse_group("or", arguments)
	return _parse_term(text)

static func _invalid() -> Dictionary:
	return {"ok": false, "kind": "invalid", "payload": false, "key": &"", "comparison": false}

static func _parse_group(kind: String, sources: Array[String]) -> Dictionary:
	var children: Array[Dictionary] = []
	for source in sources:
		var child := parse(source)
		if not child.get("ok", false):
			return _invalid()
		children.append(child)
	if children.size() < 2:
		return _invalid()
	return {"ok": true, "kind": kind, "children": children,
		"payload": false, "key": &"", "comparison": false}

static func _parse_term(text: String) -> Dictionary:
	if _presence_regex == null:
		_presence_regex = RegEx.new()
		_presence_regex.compile(PRESENCE_PATTERN)
	var presence := _presence_regex.search(text)
	if presence != null:
		return {"ok": true, "kind": "term", "payload": true,
			"key": StringName(presence.get_string(2)), "presence": presence.get_string(1),
			"comparison": false, "source": text}
	if _comparison_regex == null:
		_comparison_regex = RegEx.new()
		_comparison_regex.compile(COMPARISON_PATTERN)
	var found := _comparison_regex.search(text)
	if found != null:
		var left := found.get_string(1)
		var right := found.get_string(3)
		var left_payload := left.begins_with("payload.")
		var key := StringName(left.trim_prefix("payload."))
		var result := {"ok": true, "kind": "term", "payload": left_payload,
			"key": key, "operator": found.get_string(2), "comparison": true,
			"source": text}
		if right.begins_with("&\"") or right.begins_with("\""):
			var string_name := right.begins_with("&\"")
			var literal := right.substr(1) if string_name else right
			var value: Variant = JSON.parse_string(literal)
			if value == null:
				return _invalid()
			result["literal"] = right
			result["value"] = StringName(value) if string_name else value
			result["value_type"] = TYPE_STRING_NAME if string_name else TYPE_STRING
		elif right == "true" or right == "false":
			result["literal"] = right
			result["value"] = right == "true"
			result["value_type"] = TYPE_BOOL
		elif _is_number(right):
			result["literal"] = right
			result["value"] = right.to_float() if "." in right else right.to_int()
			result["value_type"] = TYPE_FLOAT if "." in right else TYPE_INT
		else:
			result["rhs_payload"] = right.begins_with("payload.")
			result["rhs_key"] = StringName(right.trim_prefix("payload."))
			result["value_type"] = TYPE_NIL
		return result
	if text.is_valid_identifier():
		return {"ok": true, "kind": "term", "payload": false,
			"key": StringName(text), "comparison": false, "source": text}
	return _invalid()

static func _is_number(text: String) -> bool:
	return text.is_valid_int() or text.is_valid_float()

static func _has_outer_parentheses(text: String) -> bool:
	if not text.begins_with("(") or not text.ends_with(")"):
		return false
	var depth := 0
	var quoted := false
	var escaped := false
	for index in text.length():
		var character := text.substr(index, 1)
		if quoted:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				quoted = false
			continue
		if character == "\"":
			quoted = true
		elif character == "(":
			depth += 1
		elif character == ")":
			depth -= 1
			if depth == 0 and index < text.length() - 1:
				return false
	return depth == 0 and not quoted

static func _has_outer_call_parentheses(text: String) -> bool:
	var depth := 0
	var quoted := false
	var escaped := false
	for index in range(3, text.length()):
		var character := text.substr(index, 1)
		if quoted:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				quoted = false
			continue
		if character == "\"":
			quoted = true
		elif character == "(":
			depth += 1
		elif character == ")":
			depth -= 1
			if depth == 0 and index != text.length() - 1:
				return false
	return depth == 0 and not quoted

static func _split_boolean(text: String, word: String) -> Array[String]:
	var parts: Array[String] = []
	var depth := 0
	var quoted := false
	var escaped := false
	var start := 0
	var index := 0
	while index < text.length():
		var character := text.substr(index, 1)
		if quoted:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				quoted = false
			index += 1
			continue
		if character == "\"":
			quoted = true
			index += 1
			continue
		if character == "(":
			depth += 1
			index += 1
			continue
		if character == ")":
			depth -= 1
			index += 1
			continue
		if depth == 0:
			var separator_length := 0
			if text.substr(index, 2) == ("||" if word == "or" else "&&"):
				separator_length = 2
			elif text.substr(index, word.length()) == word:
				var before := text.substr(index - 1, 1) if index > 0 else " "
				var after_index := index + word.length()
				var after := text.substr(after_index, 1) if after_index < text.length() else " "
				if before in [" ", "\t", "\n", "("] and after in [" ", "\t", "\n", ")"]:
					separator_length = word.length()
			if separator_length > 0:
				parts.append(text.substr(start, index - start).strip_edges())
				index += separator_length
				start = index
				continue
		index += 1
	if not parts.is_empty():
		parts.append(text.substr(start).strip_edges())
	return parts

static func _split_commas(text: String) -> Array[String]:
	var parts: Array[String] = []
	var depth := 0
	var quoted := false
	var escaped := false
	var start := 0
	for index in text.length():
		var character := text.substr(index, 1)
		if quoted:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				quoted = false
			continue
		if character == "\"":
			quoted = true
		elif character == "(":
			depth += 1
		elif character == ")":
			depth -= 1
		elif character == "," and depth == 0:
			parts.append(text.substr(start, index - start).strip_edges())
			start = index + 1
	if not parts.is_empty():
		parts.append(text.substr(start).strip_edges())
	return parts

static func evaluate(blackboard: Blackboard, expression: StringName,
		payload: Dictionary = {}, event_id: StringName = &"", schema: Dictionary = {}) -> bool:
	var parsed := parse(String(expression))
	return _evaluate_node(blackboard, parsed, payload, event_id, schema) if parsed.get("ok", false) else false

static func _evaluate_node(blackboard: Blackboard, node: Dictionary, payload: Dictionary,
		event_id: StringName, schema: Dictionary) -> bool:
	var kind: String = node.get("kind", "term")
	if kind == "or":
		for child: Dictionary in node["children"]:
			if _evaluate_node(blackboard, child, payload, event_id, schema):
				return true
		return false
	if kind == "and":
		for child: Dictionary in node["children"]:
			if not _evaluate_node(blackboard, child, payload, event_id, schema):
				return false
		return true
	var key: StringName = node["key"]
	if node.get("presence", "") != "":
		if schema.has(event_id) and not schema[event_id].has(key):
			return false
		var present := payload.has(key) or payload.has(String(key))
		return present if node["presence"] == "has" else not present
	var left: Variant
	var left_type: int
	if node["payload"]:
		if schema.has(event_id) and not schema[event_id].has(key):
			return false
		if not payload.has(key) and not payload.has(String(key)):
			return false
		left = payload.get(key, payload.get(String(key)))
		left_type = typeof(left)
		var declared: int = schema.get(event_id, {}).get(key, TYPE_NIL)
		if declared != TYPE_NIL and left_type != declared:
			return false
	else:
		var resolved: StringName = blackboard.resolve_key(key)
		if not blackboard.has(key):
			return false
		left = blackboard.get_var(resolved)
		left_type = blackboard.schema.get(resolved, {}).get("type", TYPE_NIL)
	if not node["comparison"]:
		return blackboard.is_set(key)
	var right: Variant
	var right_type: int
	if node.has("rhs_key"):
		var rhs_key: StringName = node["rhs_key"]
		if node["rhs_payload"]:
			if schema.has(event_id) and not schema[event_id].has(rhs_key):
				return false
			if not payload.has(rhs_key) and not payload.has(String(rhs_key)):
				return false
			right = payload.get(rhs_key, payload.get(String(rhs_key)))
			right_type = typeof(right)
			var declared_rhs: int = schema.get(event_id, {}).get(rhs_key, TYPE_NIL)
			if declared_rhs != TYPE_NIL and right_type != declared_rhs:
				return false
		else:
			if not blackboard.has(rhs_key):
				return false
			var resolved_rhs := blackboard.resolve_key(rhs_key)
			right = blackboard.get_var(resolved_rhs)
			right_type = blackboard.schema.get(resolved_rhs, {}).get("type", TYPE_NIL)
	else:
		right = node["value"]
		right_type = node["value_type"]
	return _compare_typed(left, left_type, right, right_type, node["operator"])

static func _compare_typed(left: Variant, left_type: int, right: Variant,
		right_type: int, operator: String) -> bool:
	if left_type in [TYPE_INT, TYPE_FLOAT] and right_type in [TYPE_INT, TYPE_FLOAT]:
		return _compare_numeric_variants(left, right, operator)
	if operator not in ["==", "!="]:
		return false
	if left_type in [TYPE_STRING, TYPE_STRING_NAME] and right_type in [TYPE_STRING, TYPE_STRING_NAME]:
		var equal := String(left) == String(right)
		return equal if operator == "==" else not equal
	if left_type != right_type:
		return false
	var same: bool = left == right
	return same if operator == "==" else not same

static func _compare_numeric_variants(actual: Variant, expected: Variant, operator: String) -> bool:
	if typeof(actual) == TYPE_INT and typeof(expected) == TYPE_INT:
		return _compare_integers(actual, expected, operator)
	return _compare_numbers(float(actual), float(expected), operator)

static func _compare_integers(actual: int, expected: int, operator: String) -> bool:
	match operator:
		">": return actual > expected
		">=": return actual >= expected
		"<": return actual < expected
		"<=": return actual <= expected
		"==": return actual == expected
		"!=": return actual != expected
	return false

static func _compare_numbers(actual: float, expected: float, operator: String) -> bool:
	match operator:
		">": return actual > expected
		">=": return actual >= expected
		"<": return actual < expected
		"<=": return actual <= expected
		"==": return is_equal_approx(actual, expected)
		"!=": return not is_equal_approx(actual, expected)
	return false

static func terms(expression: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var parsed := parse(expression)
	if parsed.get("ok", false):
		_collect_terms(parsed, result)
	return result

static func _collect_terms(node: Dictionary, result: Array[Dictionary]) -> void:
	if node.get("kind", "term") in ["and", "or"]:
		for child: Dictionary in node["children"]:
			_collect_terms(child, result)
	else:
		result.append(node)

static func referenced_keys(expression: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	for term: Dictionary in terms(String(expression)):
		if not term.get("payload", false):
			_append_unique(result, term.get("key", &""))
		if term.get("comparison", false) and term.has("rhs_key") and not term.get("rhs_payload", false):
			_append_unique(result, term["rhs_key"])
	return result

static func referenced_payload_fields(expression: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	for term: Dictionary in terms(String(expression)):
		if term.get("payload", false):
			_append_unique(result, term.get("key", &""))
		if term.get("comparison", false) and term.has("rhs_key") and term.get("rhs_payload", false):
			_append_unique(result, term["rhs_key"])
	return result

static func _append_unique(items: Array[StringName], value: StringName) -> void:
	if not value.is_empty() and not items.has(value):
		items.append(value)

static func referenced_key(expression: StringName) -> StringName:
	var keys := referenced_keys(expression)
	return keys[0] if not keys.is_empty() else &""

static func referenced_payload_field(expression: StringName) -> StringName:
	var fields := referenced_payload_fields(expression)
	return fields[0] if not fields.is_empty() else &""

static func rename_key(expression: String, old_key: String, new_key: String) -> String:
	var parsed := parse(expression)
	if not parsed.get("ok", false):
		return expression
	return _format_renamed(parsed, StringName(old_key), new_key)

static func _format_renamed(node: Dictionary, old_key: StringName, new_key: String) -> String:
	var kind: String = node.get("kind", "term")
	if kind in ["and", "or"]:
		var children: Array[String] = []
		for child: Dictionary in node["children"]:
			children.append(_format_renamed(child, old_key, new_key))
		return "(" + (" and " if kind == "and" else " or ").join(children) + ")"
	if not node["comparison"]:
		if node.has("presence"):
			return "%s(payload.%s)" % [node["presence"], node["key"]]
		return new_key if node["key"] == old_key else String(node["key"])
	var left := String(node["key"])
	if node["payload"]:
		left = "payload." + left
	elif node["key"] == old_key:
		left = new_key
	var right: String
	if node.has("rhs_key"):
		right = ("payload." if node["rhs_payload"] else "") + String(node["rhs_key"])
		if not node["rhs_payload"] and node["rhs_key"] == old_key:
			right = new_key
	else:
		right = String(node["literal"])
	return "%s %s %s" % [left, node["operator"], right]
