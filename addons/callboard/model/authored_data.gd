@tool
class_name AuthoredData extends RefCounted
## Creates and edits authored graph data.

const GUARDS := ["requires", "forbids", "cancel_if"]
const GuardExpression := preload("res://addons/callboard/core/guard_expression.gd")
static func new_rule(id: String, trigger: String) -> RuleData:
	var rule := RuleData.new()
	rule.id = id
	rule.trigger = trigger
	rule.state_key = new_state_key()
	return rule

static func unique_name(existing: Array, base: String) -> String:
	if not existing.has(base):
		return base
	var n := 2
	while existing.has("%s_%d" % [base, n]):
		n += 1
	return "%s_%d" % [base, n]

static func rule_ids(data: GraphDraft) -> Array:
	return data.rules.map(func(r: RuleData) -> String: return String(r.id))

static func new_state_key() -> String:
	return "@" + Crypto.new().generate_random_bytes(16).hex_encode()

## Renames a Blackboard key everywhere the model references it: guard lists and any
## step argument bound to a `key` parameter.
static func rename_key(data: GraphDraft, old: String, new_key: String) -> void:
	for v in data.variables:
		if v.key == old:
			if v.state_key.is_empty():
				v.state_key = v.key
			if not v.aliases.has(StringName(old)):
				v.aliases.append(StringName(old))
			v.key = new_key
	if data.external_vars.has(old):
		data.external_vars.erase(old)
		if not data.external_vars.has(new_key):
			data.external_vars.append(new_key)
	for writer: BlackboardWriterData in data.external_writers:
		if writer.key == old:
			writer.key = StringName(new_key)
	for rule in data.rules:
		for field in GUARDS:
			var guards: PackedStringArray = rule.get(field)
			for index in guards.size():
				guards[index] = GuardExpression.rename_key(guards[index], old, new_key)
			rule.set(field, guards)
		for step in rule.steps:
			var verb := VerbCatalog.find(data.catalog, step.verb)
			var params: Array = verb.get("args", [])
			for index in params.size():
				if params[index]["name"] != "key":
					continue
				var expression: String = step.args[index] if index < step.args.size() else params[index]["default"]
				if expression == '&"%s"' % old:
					VerbCatalog.set_arg(data, step, index, '&"%s"' % new_key)
