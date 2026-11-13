@tool
class_name RuleConnections extends RefCounted
## Edits references to external Calls and relays in an authored graph.

const RELAY_PREFIX := "relay:"
static var _invalid_name_pattern: RegEx

static func ids(data: GraphDraft) -> Array:
	var names := {}
	for event in data.external_calls:
		names[event] = true
	for rule in data.rules:
		if rule.trigger.begins_with(RELAY_PREFIX) and rule.trigger != RELAY_PREFIX:
			names[rule.trigger] = true
		if rule.emit != "":
			names[RELAY_PREFIX + rule.emit] = true
		for step in rule.steps:
			var relay := data.relay_for(step)
			if not relay.is_empty():
				names[RELAY_PREFIX + relay] = true
	var result := names.keys()
	result.sort()
	return result

static func impact(data: GraphDraft, id: String) -> PackedStringArray:
	var lines := PackedStringArray()
	var relay := id.trim_prefix(RELAY_PREFIX) if id.begins_with(RELAY_PREFIX) else ""
	for rule in data.rules:
		if rule.trigger == id:
			lines.append("%s — trigger" % rule.id)
		if relay.is_empty():
			continue
		if rule.emit == relay:
			lines.append("%s — rule output" % rule.id)
		for i in rule.steps.size():
			var step: StepData = rule.steps[i]
			if data.relay_for(step) == relay:
				lines.append("%s — step %d (%s)" % [rule.id, i + 1, step.verb])
	return lines

static func edit_error(data: GraphDraft, id: String) -> String:
	if id == RELAY_PREFIX or not ids(data).has(id):
		return "This Call or relay no longer exists."
	return ""

static func new_call_error(data: GraphDraft, call_id: String) -> String:
	if call_id.is_empty():
		return "Enter a Call ID."
	var error := _name_error(call_id)
	if not error.is_empty():
		return error
	if data.external_calls.has(call_id):
		return "That Call already exists."
	return ""

static func _name_error(connection_name: String) -> String:
	if _invalid_name_pattern == null:
		_invalid_name_pattern = RegEx.create_from_string('[\\x00-\\x1f"\\\\]')
	if connection_name.is_empty() or connection_name.begins_with(RELAY_PREFIX) or _invalid_name_pattern.search(connection_name):
		return "Enter a name without quotes, backslashes, control characters, or the relay: prefix."
	return ""

## new_name is the bare relay name for relays, or the full Call ID for Calls.
static func rename(data: GraphDraft, id: String, new_name: String) -> String:
	var error := edit_error(data, id)
	if not error.is_empty():
		return error
	if id == "arrive":
		return "The stage lifecycle fires the built-in arrive Call."
	new_name = new_name.strip_edges()
	error = _name_error(new_name)
	if not error.is_empty():
		return error
	var is_relay := id.begins_with(RELAY_PREFIX)
	var new_id := RELAY_PREFIX + new_name if is_relay else new_name
	if id == new_id:
		return ""
	if ids(data).has(new_id) or new_id == "arrive":
		return "That name is already in use."
	if not is_relay:
		_replace_references(data, id, new_id)
		return ""

	var draft := GraphDraft.new()
	draft.definition = data.definition
	draft.catalog = data.catalog
	draft.props = data.props
	draft.restore(data.snapshot())
	var old_relay := id.trim_prefix(RELAY_PREFIX)
	var renamed_steps: Array[StepData] = []
	for rule_index in draft.rules.size():
		var rule := draft.rules[rule_index]
		var original_rule := data.rules[rule_index]
		if rule.emit == old_relay:
			rule.emit = new_name
		for step_index in rule.steps.size():
			var step := rule.steps[step_index]
			var original_step := original_rule.steps[step_index]
			if data.relay_for(original_step) != old_relay:
				continue
			var arg := data.step_metadata[original_step].relay_argument
			var params: Array = VerbCatalog.find(draft.catalog, step.verb).get("args", [])
			if arg < 0 or arg >= params.size():
				return "Rename the relay in the %s verb used by %s." % [step.verb, rule.id]
			var value: Variant = new_name if params[arg]["type"] == TYPE_STRING else StringName(new_name)
			VerbCatalog.set_arg(draft, step, arg, ExprText.format_literal(value))
			renamed_steps.append(step)
	_replace_references(draft, id, new_id)
	RuleGraphReader.analyze(draft)
	if renamed_steps.any(func(step: StepData) -> bool: return draft.relay_for(step) != new_name):
		return "The edited steps could not emit the new relay. Check the verb arguments."
	data.external_calls = draft.external_calls
	data.rules = draft.rules
	return ""

static func remove(data: GraphDraft, id: String) -> String:
	var error := edit_error(data, id)
	if not error.is_empty():
		return error
	_replace_references(data, id, "")
	if id.begins_with(RELAY_PREFIX):
		var relay := id.trim_prefix(RELAY_PREFIX)
		for rule in data.rules:
			if rule.emit == relay:
				rule.emit = ""
			rule.steps = rule.steps.filter(func(step: StepData) -> bool: return data.relay_for(step) != relay)
	return ""

static func _replace_references(data: GraphDraft, old_id: String, new_id: String) -> void:
	var declarations: Array = data.external_calls
	var index := declarations.find(old_id)
	if index >= 0:
		if new_id.is_empty():
			declarations.remove_at(index)
		else:
			declarations[index] = new_id
	for rule in data.rules:
		if rule.trigger == old_id:
			rule.trigger = new_id
