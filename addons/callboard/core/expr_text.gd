@tool
class_name ExprText extends RefCounted
## Formats authored step expressions and recognizes literals for inspector controls.

static var _integer_pattern: RegEx
static var _float_pattern: RegEx

static func parse_literal(expr: String) -> Dictionary:
	if _integer_pattern == null:
		_integer_pattern = RegEx.create_from_string('^-?[0-9]+$')
		_float_pattern = RegEx.create_from_string('^-?([0-9]+\\.[0-9]*|[0-9]*\\.[0-9]+)$')
	if expr == "true" or expr == "false":
		return {"ok": true, "value": expr == "true"}
	if _integer_pattern.search(expr):
		return {"ok": true, "value": expr.to_int()}
	if _float_pattern.search(expr):
		return {"ok": true, "value": expr.to_float()}
	if expr.length() >= 2 and expr.begins_with('"') and expr.ends_with('"'):
		var parsed: Variant = JSON.parse_string(expr)
		return {"ok": true, "value": parsed} if parsed is String else {"ok": false, "value": null}
	if expr.length() >= 3 and expr.begins_with('&"') and expr.ends_with('"'):
		var parsed_name: Variant = JSON.parse_string(expr.substr(1))
		return {"ok": true, "value": StringName(parsed_name)} if parsed_name is String else {"ok": false, "value": null}
	return {"ok": false, "value": null}

static func format_literal(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			var s := str(v)
			if not "." in s and not "e" in s:
				s += ".0"
			return s
		TYPE_STRING:
			return JSON.stringify(String(v))
		TYPE_STRING_NAME:
			return '&%s' % JSON.stringify(String(v))
	return var_to_str(v)

static func step_text(step: Dictionary) -> String:
	var t := "%s(%s)" % [step["verb"], ", ".join(PackedStringArray(step["args"]))]
	if step.get("delay", "") != "":
		t += ".after(%s)" % step["delay"]
	return t
