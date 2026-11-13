@tool
class_name AuthoredData extends RefCounted
## Creates and edits authored graph data.

const GUARDS := ["requires", "forbids", "cancel_if"]
const GuardExpression := preload("res://addons/callboard/core/guard_expression.gd")
const FIELD_ONE_SHOT := "one_shot"
const FIELD_HAS_POS := "has_pos"
const FIELD_STATE_KEY := "state_key"
const FIELD_REENTRY := "reentry"
const FIELD_ALLOW_OVERLAP := "allow_overlap"

static func new_rule(id: String, trigger: String) -> Dictionary:
	return {
		"id": id, "trigger": trigger, "requires": [], "forbids": [], "cancel_if": [],
		FIELD_ONE_SHOT: false, FIELD_REENTRY: Rule.ReentryPolicy.IGNORE, "emit": "", "steps": [],
		"group": "", "pos": Vector2.ZERO, FIELD_HAS_POS: false,
	}

static func new_step(verb: String, args: Array, delay := "") -> Dictionary:
	return {"verb": verb, "args": args, "delay": delay, "emits": "", "sets": []}

static func new_variable(key: String, scope: String, value: Variant) -> Dictionary:
	return {
		"key": key, "scope": scope, "default": value,
		"note": "",
	}

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
			v[FIELD_STATE_KEY] = v.get(FIELD_STATE_KEY, old)
			var aliases: Array = v.get("aliases", [])
			if not aliases.has(old):
				aliases.append(old)
			v["aliases"] = aliases
			v["key"] = new_key
	if data.get("external_vars", []).has(old):
		data["external_vars"].erase(old)
		if not data["external_vars"].has(new_key):
			data["external_vars"].append(new_key)
	for rd in data["rules"]:
		for g in GUARDS:
			rd[g] = rd[g].map(func(guard: String) -> String:
				return GuardExpression.rename_key(guard, old, new_key))
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
