@tool
class_name ZoneSource extends RefCounted
## Parses and regenerates the two functions the Rule Board owns in a zone script:
## _build_blackboard() and _build_rules(). Everything else in the file is never touched.
##
## The grammar is deliberately small. Anything outside it makes parse() fail with a line
## number, and the board refuses to edit that zone instead of guessing.
##
## _build_blackboard():
##   define_saved(&"key", default)   # optional note
##   define_local(&"key", default)
##   Both declarations accept an optional third argument for the saved-state key.
## _build_rules():
##   # @group: "Name" rect=Rect2(x, y, w, h)
##   var r: Rule
##   # @node: pos=Vector2(x, y) group="Name"
##   r = rule(&"id", &"trigger")
##   r.requires = [&"a"]   r.forbids = [...]   r.cancel_if = [...]
##   r.once = true
##   r.state_key = &"original_id"   # optional once-latch key
##   r.emits = &"relay"
##   r.steps = [
##       verb(arg, arg).after(0.25),
##   ]
##
## Free-form comments inside those two functions are not preserved when regenerated.
##
## Model (what parse returns and generate consumes):
##   vars:   [{key, scope: "saved"|"local", default, default_expr, note, note_pad}]
##   groups: [{name, rect: Rect2}]
##   rules:  [{id, trigger, requires[], forbids[], cancel_if[], once, emit, group, pos, has_pos,
##             steps: [{verb, args: [expr strings], delay: expr string or "", emits, sets}]}]
## Step args are GDScript expression text, so constants and prop names round-trip exactly.

const FN_VARS := "_build_blackboard"
const FN_RULES := "_build_rules"
const GUARDS := ["requires", "forbids", "cancel_if"]
const NUM := "(-?[0-9.]+)"

# --- Locating the owned functions ------------------------------------------------

## Returns [start, end) line indices of a function body, or (-1, -1) if the function is missing.
static func body_range(lines: PackedStringArray, fn: String) -> Vector2i:
	var start := -1
	for i in lines.size():
		if lines[i].begins_with("func %s(" % fn):
			start = i + 1
			break
	if start < 0:
		return Vector2i(-1, -1)
	var end := start
	while end < lines.size():
		var l := lines[end]
		if l.strip_edges() == "" or l.begins_with("\t") or l.begins_with(" "):
			end += 1
		else:
			break
	while end > start and lines[end - 1].strip_edges() == "":
		end -= 1
	return Vector2i(start, end)

# --- Parsing ----------------------------------------------------------------------

static func parse(source: String) -> Dictionary:
	var out := {"ok": false, "error": "", "vars": [], "rules": [], "groups": []}
	var lines := source.split("\n")
	var bb := body_range(lines, FN_VARS)
	var rr := body_range(lines, FN_RULES)
	if bb.x < 0:
		out["error"] = "func %s() not found" % FN_VARS
		return out
	if rr.x < 0:
		out["error"] = "func %s() not found" % FN_RULES
		return out
	var err := _parse_vars(lines, bb, out)
	if err == "":
		err = _parse_rules(lines, rr, out)
	out["error"] = err
	out["ok"] = err == ""
	return out

static func _parse_vars(lines: PackedStringArray, r: Vector2i, out: Dictionary) -> String:
	var re := RegEx.create_from_string('^define_(saved|local)\\(\\s*&"([^"]+)"\\s*(?:,\\s*(.+?))?\\s*\\)(\\s*)(?:#\\s*(.*))?$')
	for i in range(r.x, r.y):
		var t := lines[i].strip_edges()
		if t == "" or t == "pass" or t.begins_with("#"):
			continue
		var m := re.search(t)
		if m == null:
			return "line %d: unsupported statement in %s(): %s" % [i + 1, FN_VARS, t]
		var args := split_args(m.get_string(3))
		var expr: String = args[0] if not args.is_empty() else "false"
		if expr == "":
			expr = "false"
		var lit := parse_literal(expr)
		if not lit["ok"]:
			return "line %d: default value '%s' must be a bool, number, or string literal" % [i + 1, expr]
		var variable := {"key": m.get_string(2), "scope": m.get_string(1), "default": lit["value"],
			"default_expr": expr, "note": m.get_string(5).strip_edges(), "note_pad": m.get_string(4)}
		if args.size() > 1:
			var state := parse_literal(args[1])
			if args.size() != 2 or not state["ok"] or typeof(state["value"]) != TYPE_STRING_NAME or state["value"] == &"":
				return "line %d: expected a StringName saved-state key" % (i + 1)
			variable["state_key"] = String(state["value"])
		out["vars"].append(variable)
	return ""

static func _parse_rules(lines: PackedStringArray, r: Vector2i, out: Dictionary) -> String:
	var re_group := RegEx.create_from_string('^#\\s*@group:\\s*"([^"]*)"\\s*rect=Rect2\\(\\s*%s\\s*,\\s*%s\\s*,\\s*%s\\s*,\\s*%s\\s*\\)$' % [NUM, NUM, NUM, NUM])
	var re_node := RegEx.create_from_string('^#\\s*@node:\\s*pos=Vector2\\(\\s*%s\\s*,\\s*%s\\s*\\)(?:\\s+group="([^"]*)")?$' % [NUM, NUM])
	var re_rule := RegEx.create_from_string('^r\\s*=\\s*rule\\(\\s*&"([^"]+)"\\s*,\\s*&"([^"]*)"\\s*\\)$')
	var re_list := RegEx.create_from_string('^r\\.(requires|forbids|cancel_if)\\s*=\\s*\\[(.*)\\]$')
	var re_name := RegEx.create_from_string('&"([^"]*)"')
	var re_once := RegEx.create_from_string('^r\\.once\\s*=\\s*(true|false)$')
	var re_state := RegEx.create_from_string('^r\\.state_key\\s*=\\s*&"([^"]+)"$')
	var re_emits := RegEx.create_from_string('^r\\.emits\\s*=\\s*&"([^"]*)"$')
	var cur := {}
	var pending := {}
	var in_steps := false
	for i in range(r.x, r.y):
		var t := lines[i].strip_edges()
		if in_steps:
			if t == "]":
				in_steps = false
			elif t != "" and not t.begins_with("#"):
				var step := _parse_step(t)
				if step.is_empty():
					return "line %d: cannot read step: %s" % [i + 1, t]
				cur["steps"].append(step)
			continue
		if t == "" or t == "pass" or t == "var r: Rule":
			continue
		var m := re_group.search(t)
		if m:
			out["groups"].append({"name": m.get_string(1), "rect": Rect2(
				m.get_string(2).to_float(), m.get_string(3).to_float(),
				m.get_string(4).to_float(), m.get_string(5).to_float())})
			continue
		m = re_node.search(t)
		if m:
			pending = {"pos": Vector2(m.get_string(1).to_float(), m.get_string(2).to_float()), "group": m.get_string(3)}
			continue
		m = re_rule.search(t)
		if m:
			cur = {"id": m.get_string(1), "trigger": m.get_string(2), "requires": [], "forbids": [],
				"cancel_if": [], "once": false, "emit": "", "steps": [],
				"has_pos": not pending.is_empty(), "pos": pending.get("pos", Vector2.ZERO),
				"group": pending.get("group", "")}
			pending = {}
			out["rules"].append(cur)
			continue
		if t.begins_with("#"):
			continue   # free comment: dropped on regenerate
		if cur.is_empty():
			return "line %d: expected `r = rule(&\"id\", &\"trigger\")` first: %s" % [i + 1, t]
		m = re_list.search(t)
		if m:
			for n in re_name.search_all(m.get_string(2)):
				cur[m.get_string(1)].append(n.get_string(1))
			continue
		m = re_once.search(t)
		if m:
			cur["once"] = m.get_string(1) == "true"
			continue
		m = re_state.search(t)
		if m:
			cur["state_key"] = m.get_string(1)
			continue
		m = re_emits.search(t)
		if m:
			cur["emit"] = m.get_string(1)
			continue
		if t == "r.steps = [":
			in_steps = true
			continue
		if t == "r.steps = []":
			continue
		return "line %d: unsupported statement in %s(): %s" % [i + 1, FN_RULES, t]
	if in_steps:
		return "unterminated r.steps list"
	return ""

static func _parse_step(t: String) -> Dictionary:
	if t.ends_with(","):
		t = t.left(-1).strip_edges()
	var delay := ""
	var re_after := RegEx.create_from_string('\\.after\\(\\s*(-?[0-9.]+)\\s*\\)$')
	var m := re_after.search(t)
	if m:
		delay = m.get_string(1)
		t = t.substr(0, m.get_start())
	var c := RegEx.create_from_string('^(\\w+)\\((.*)\\)$').search(t)
	if c == null:
		return {}
	return {"verb": c.get_string(1), "args": split_args(c.get_string(2)), "delay": delay, "emits": "", "sets": []}

## Splits "a, f(b, c), \"x, y\"" on top-level commas.
static func split_args(s: String) -> Array:
	var out: Array = []
	var depth := 0
	var in_str := false
	var cur := ""
	var i := 0
	while i < s.length():
		var ch := s[i]
		if in_str:
			cur += ch
			if ch == "\\" and i + 1 < s.length():
				i += 1
				cur += s[i]
			elif ch == '"':
				in_str = false
		elif ch == '"':
			in_str = true
			cur += ch
		elif ch in "([{":
			depth += 1
			cur += ch
		elif ch in ")]}":
			depth -= 1
			cur += ch
		elif ch == "," and depth == 0:
			out.append(cur.strip_edges())
			cur = ""
		else:
			cur += ch
		i += 1
	if cur.strip_edges() != "":
		out.append(cur.strip_edges())
	return out

static func parse_literal(expr: String) -> Dictionary:
	if expr == "true" or expr == "false":
		return {"ok": true, "value": expr == "true"}
	if RegEx.create_from_string('^-?[0-9]+$').search(expr):
		return {"ok": true, "value": expr.to_int()}
	if RegEx.create_from_string('^-?([0-9]+\\.[0-9]*|[0-9]*\\.[0-9]+)$').search(expr):
		return {"ok": true, "value": expr.to_float()}
	if expr.length() >= 2 and expr.begins_with('"') and expr.ends_with('"'):
		return {"ok": true, "value": expr.substr(1, expr.length() - 2).replace('\\"', '"')}
	if expr.length() >= 3 and expr.begins_with('&"') and expr.ends_with('"'):
		return {"ok": true, "value": StringName(expr.substr(2, expr.length() - 3))}
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
			return '"%s"' % String(v).replace('"', '\\"')
		TYPE_STRING_NAME:
			return '&"%s"' % String(v)
	return var_to_str(v)

# --- Generating -------------------------------------------------------------------

static func generate(source: String, data: Dictionary) -> String:
	var lines := source.split("\n")
	var bb := body_range(lines, FN_VARS)
	var rr := body_range(lines, FN_RULES)
	if bb.x < 0 or rr.x < 0:
		return source
	var edits := [[bb, _gen_vars(data)], [rr, _gen_rules(data)]]
	edits.sort_custom(func(a: Array, b: Array) -> bool: return a[0].x > b[0].x)   # bottom first
	for e in edits:
		var range_: Vector2i = e[0]
		var head := lines.slice(0, range_.x)
		var tail := lines.slice(range_.y)
		head.append_array(e[1])
		head.append_array(tail)
		lines = head
	return "\n".join(lines)

static func _gen_vars(data: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	for v in data["vars"]:
		var expr: String = v.get("default_expr", "")
		if expr == "":
			expr = format_literal(v["default"])
		var state_key: String = v.get("state_key", "")
		var state_arg := ', &"%s"' % state_key if not state_key.is_empty() else ""
		var line := '\tdefine_%s(&"%s", %s%s)' % [v["scope"], v["key"], expr, state_arg]
		if v.get("note", "") != "":
			line += v.get("note_pad", "   ") + "# " + v["note"]
		out.append(line)
	if out.is_empty():
		out.append("\tpass")
	return out

static func names_expr(list: Array) -> String:
	var parts: PackedStringArray = []
	for n in list:
		parts.append('&"%s"' % n)
	return ", ".join(parts)

static func step_text(step: Dictionary) -> String:
	var t := "%s(%s)" % [step["verb"], ", ".join(PackedStringArray(step["args"]))]
	if step.get("delay", "") != "":
		t += ".after(%s)" % step["delay"]
	return t

static func _gen_rules(data: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	for g in data["groups"]:
		var rc: Rect2 = g["rect"]
		out.append('\t# @group: "%s" rect=Rect2(%d, %d, %d, %d)' % [g["name"], roundi(rc.position.x), roundi(rc.position.y), roundi(rc.size.x), roundi(rc.size.y)])
	if data["rules"].is_empty():
		out.append("\tpass")
		return out
	out.append("\tvar r: Rule")
	for rd in data["rules"]:
		out.append("")
		if rd.get("has_pos", false):
			var p: Vector2 = rd["pos"]
			var line := "\t# @node: pos=Vector2(%d, %d)" % [roundi(p.x), roundi(p.y)]
			if rd.get("group", "") != "":
				line += ' group="%s"' % rd["group"]
			out.append(line)
		out.append('\tr = rule(&"%s", &"%s")' % [rd["id"], rd["trigger"]])
		for g in GUARDS:
			if not rd[g].is_empty():
				out.append("\tr.%s = [%s]" % [g, names_expr(rd[g])])
		if rd["once"]:
			out.append("\tr.once = true")
		if not rd.get("state_key", "").is_empty():
			out.append('\tr.state_key = &"%s"' % rd["state_key"])
		if rd["emit"] != "":
			out.append('\tr.emits = &"%s"' % rd["emit"])
		if not rd["steps"].is_empty():
			out.append("\tr.steps = [")
			for s in rd["steps"]:
				out.append("\t\t%s," % step_text(s))
			out.append("\t]")
	return out

# --- Model helpers ----------------------------------------------------------------

static func unique_name(existing: Array, base: String) -> String:
	if not existing.has(base):
		return base
	var n := 2
	while existing.has("%s_%d" % [base, n]):
		n += 1
	return "%s_%d" % [base, n]

static func rule_ids(data: Dictionary) -> Array:
	return data["rules"].map(func(r: Dictionary) -> String: return r["id"])

static func new_state_key() -> String:
	return "@" + Crypto.new().generate_random_bytes(16).hex_encode()

## Renames a Blackboard key everywhere the model references it: guard lists and any
## step argument bound to a `key` parameter.
static func rename_key(data: Dictionary, old: String, new_key: String) -> void:
	for v in data["vars"]:
		if v["key"] == old:
			v["state_key"] = v.get("state_key", old)
			v["key"] = new_key
	for rd in data["rules"]:
		for g in GUARDS:
			rd[g] = rd[g].map(func(k: String) -> String: return new_key if k == old else k)
		for s in rd["steps"]:
			var verb := VerbCatalog.find(data["catalog"], s["verb"])
			var params: Array = verb.get("args", [])
			for i in params.size():
				if params[i]["name"] != "key":
					continue
				var old_expr := '&"%s"' % old
				if i < s["args"].size():
					if s["args"][i] == old_expr:
						s["args"][i] = '&"%s"' % new_key
				elif params[i]["default"] == old_expr:
					# The key was implicit (a parameter default): make it explicit so it follows the rename.
					while s["args"].size() < i:
						var p: Dictionary = params[s["args"].size()]
						s["args"].append(p["default"] if p["default"] != "" else VerbCatalog.fallback(p, data))
					s["args"].append('&"%s"' % new_key)
