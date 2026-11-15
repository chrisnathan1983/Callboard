@tool
class_name RuleTemplateLibrary extends RefCounted
## Built-in rule templates and safe graph instantiation.

const Authored := preload("res://addons/callboard/model/authored_data.gd")
const ExprTextScript := preload("res://addons/callboard/core/expr_text.gd")
const TemplateScript := preload("res://addons/callboard/core/rule_template_data.gd")
const ParameterScript := preload("res://addons/callboard/core/rule_template_parameter.gd")

static func all() -> Array[TemplateScript]:
	return [interaction_outcome(), repeating_ambient(), conditional_sequence(), objective_completion()]

static func find(template_id: StringName) -> TemplateScript:
	for template in all():
		if template.id == template_id:
			return template
	return null

static func interaction_outcome() -> TemplateScript:
	var template := _new_template(&"interaction_outcome", "Interaction outcome",
		"Route an interaction Call by a Boolean payload field, update a scene prop on acceptance, and emit accepted or rejected relays.")
	template.parameters = [
		_param(&"call", "Interaction Call", ParameterScript.Kind.CALL),
		_param(&"field", "Accepted payload field", ParameterScript.Kind.PAYLOAD_FIELD, true, "", "", "bool"),
		_param(&"prop", "Prop to show on acceptance", ParameterScript.Kind.PROP, true, "", "", "", "Node3D"),
		_param(&"accepted", "Accepted relay", ParameterScript.Kind.RELAY),
		_param(&"rejected", "Rejected relay", ParameterScript.Kind.RELAY),
	]
	var rule := Authored.new_rule("interaction_outcome", "{{param:call}}")
	var branch := StepData.new()
	branch.verb = &"conditional"
	branch.branch_conditions = PackedStringArray(["payload.{{param:field}} == true", ""])
	branch.default_branch_index = 1
	var accepted_steps: Array = []
	accepted_steps.append(_step(&"show_node", ["{{param:prop}}", "true"]))
	accepted_steps.append(_step(&"emit_relay", ['&"{{param:accepted}}"']))
	var rejected_steps: Array = [_step(&"emit_relay", ['&"{{param:rejected}}"'])]
	branch.parallel_branches = [accepted_steps, rejected_steps]
	rule.steps.append(branch)
	template.rules.append(rule)
	return template

static func repeating_ambient() -> TemplateScript:
	var template := _new_template(&"repeating_ambient", "Repeating ambient behavior",
		"Start an ambient relay loop from a Call. Cancelling or deactivating the rule run stops the loop.")
	template.parameters = [
		_param(&"call", "Start Call", ParameterScript.Kind.CALL),
		_param(&"interval", "Tick interval in seconds", ParameterScript.Kind.NUMBER, true, "5.0"),
		_param(&"tick", "Tick relay (optional)", ParameterScript.Kind.RELAY, false),
	]
	var rule := Authored.new_rule("ambient_loop", "{{param:call}}")
	rule.steps.append(_step(&"repeat_emit", ["{{param:interval}}", '&"{{param:tick}}"']))
	template.rules.append(rule)
	return template

static func conditional_sequence() -> TemplateScript:
	var template := _new_template(&"conditional_sequence", "Conditional sequence",
		"Choose one ordered step sequence from a Boolean Blackboard value.")
	template.parameters = [
		_param(&"call", "Trigger Call", ParameterScript.Kind.CALL),
		_param(&"key", "Boolean Blackboard key", ParameterScript.Kind.KEY, true, "", "", "bool"),
		_param(&"prop", "Prop to show or hide", ParameterScript.Kind.PROP, true, "", "", "", "Node3D"),
	]
	var rule := Authored.new_rule("conditional_sequence", "{{param:call}}")
	var branch := StepData.new()
	branch.verb = &"conditional"
	branch.branch_conditions = PackedStringArray(["{{param:key}} == true", ""])
	branch.default_branch_index = 1
	branch.parallel_branches = [
		[_step(&"show_node", ["{{param:prop}}", "true"])],
		[_step(&"show_node", ["{{param:prop}}", "false"])],
	]
	rule.steps.append(branch)
	template.rules.append(rule)
	return template

static func objective_completion() -> TemplateScript:
	var template := _new_template(&"objective_completion", "Objective completion",
		"Consume an objective Call once, store completion in a fresh Saved key, and route through an internal relay to the configured completion relay.")
	template.parameters = [
		_param(&"call", "Objective Call", ParameterScript.Kind.CALL),
		_param(&"field", "Completed payload field", ParameterScript.Kind.PAYLOAD_FIELD, true, "", "", "bool"),
		_param(&"completed", "Completion relay", ParameterScript.Kind.RELAY),
	]
	var done := VariableData.new()
	done.key = &"objective_done"
	done.scope = "saved"
	done.default_value = false
	done.state_key = Authored.new_state_key()
	template.variables.append(done)
	template.internal_relays.append(&"completed_internal")
	var start := Authored.new_rule("objective_start", "{{param:call}}")
	start.requires = PackedStringArray(["payload.{{param:field}} == true", "{{var:objective_done}} == false"])
	start.one_shot = true
	start.steps.append(_step(&"set_var", ['&"{{var:objective_done}}"', "true"]))
	start.steps.append(_step(&"emit_relay", ['&"{{relay:completed_internal}}"']))
	var route := Authored.new_rule("objective_route", "relay:{{relay:completed_internal}}")
	route.requires = PackedStringArray(["{{var:objective_done}} == true"])
	route.emit = "{{param:completed}}"
	template.rules = [start, route]
	return template

static func validate_bindings(template: TemplateScript, bindings: Dictionary,
		data: GraphDraft) -> Array[String]:
	var errors: Array[String] = []
	if template == null:
		return ["No rule template is selected."]
	for parameter: ParameterScript in template.parameters:
		var value := String(bindings.get(parameter.name, parameter.default_value)).strip_edges()
		if value.is_empty():
			if parameter.required:
				errors.append("Missing required template parameter '%s'." % parameter.label)
			continue
		match parameter.kind:
			ParameterScript.Kind.PROP:
				var matching_prop: Dictionary = {}
				for prop: Dictionary in data.props:
					if String(prop.get("name", "")) == value:
						matching_prop = prop
						break
				if matching_prop.is_empty():
					errors.append("Prop '%s' is not available in this Stage preview." % value)
				elif not parameter.expected_prop_class.is_empty() and not ClassDB.is_parent_class(
						String(matching_prop.get("class", "")), parameter.expected_prop_class):
					errors.append("Prop '%s' must be a %s." % [value, parameter.expected_prop_class])
			ParameterScript.Kind.KEY:
				var matching_key: VariableData
				for variable: VariableData in data.variables:
					if String(variable.key) == value:
						matching_key = variable
						break
				if matching_key == null:
					errors.append("Blackboard key '%s' is not declared." % value)
				elif not parameter.expected_type.is_empty() and typeof(matching_key.default_value) != _type_id(parameter.expected_type):
					errors.append("Blackboard key '%s' must use the %s type." % [value, parameter.expected_type])
			ParameterScript.Kind.CALL:
				if not value.is_valid_identifier() or not data.external_calls.has(value):
					errors.append("Call '%s' is not a declared Call." % value)
			ParameterScript.Kind.RELAY:
				if not value.is_empty() and not value.is_valid_identifier():
					errors.append("Relay '%s' must be a non-empty identifier." % value)
			ParameterScript.Kind.PAYLOAD_FIELD:
				if not value.is_valid_identifier() or value in ["payload", "_callboard"]:
					errors.append("Payload field '%s' is not a valid field name." % value)
				else:
					var event_id := String(bindings.get(&"call", "")).strip_edges()
					var declared_fields: Array[PayloadFieldData] = data.payload_fields.filter(
						func(field: PayloadFieldData) -> bool: return String(field.event_id) == event_id)
					if not declared_fields.is_empty() and not declared_fields.any(
						func(field: PayloadFieldData) -> bool: return String(field.key) == value):
						errors.append("Payload field '%s' is not declared for Call '%s'." % [value, event_id])
					elif not parameter.expected_type.is_empty() and declared_fields.any(
						func(field: PayloadFieldData) -> bool: return String(field.key) == value \
							and field.value_type() != _type_id(parameter.expected_type)):
						errors.append("Payload field '%s' must use the %s type." % [value, parameter.expected_type])
			ParameterScript.Kind.NUMBER:
				if not value.is_valid_float() or not is_finite(value.to_float()) or value.to_float() <= 0.0:
					errors.append("Parameter '%s' must be a positive finite number." % parameter.label)
	return errors

static func _type_id(type_name: String) -> int:
	match type_name:
		"bool": return TYPE_BOOL
		"int": return TYPE_INT
		"float": return TYPE_FLOAT
		"String": return TYPE_STRING
		"StringName": return TYPE_STRING_NAME
		_: return TYPE_NIL

static func instantiate(template: TemplateScript, bindings: Dictionary,
		data: GraphDraft) -> Dictionary:
	var errors := validate_bindings(template, bindings, data)
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "rules": [], "variables": []}
	var parameters := {}
	for parameter: ParameterScript in template.parameters:
		parameters[String(parameter.name)] = String(bindings.get(parameter.name, parameter.default_value)).strip_edges()
	var variable_tokens := {}
	var variable_keys: Array = []
	for variable: VariableData in data.variables:
		variable_keys.append(String(variable.key))
		for alias: StringName in variable.aliases:
			variable_keys.append(String(alias))
	var variables: Array[VariableData] = []
	for source: VariableData in template.variables:
		var copy: VariableData = source.duplicate(true) as VariableData
		var old_key := String(source.key)
		var new_key := Authored.unique_name(variable_keys, old_key)
		variable_keys.append(new_key)
		variable_tokens[old_key] = new_key
		for alias: StringName in source.aliases:
			variable_tokens[String(alias)] = new_key
		copy.key = StringName(new_key)
		for index in copy.aliases.size():
			if String(copy.aliases[index]) == old_key:
				copy.aliases[index] = StringName(new_key)
		if not template.deliberately_shared_storage.has(source.key):
			copy.state_key = StringName(Authored.new_state_key())
		variables.append(copy)
	var internal_relay_tokens := {}
	var existing_relays := _existing_relay_names(data)
	for symbol: StringName in template.internal_relays:
		var internal_name := Authored.unique_name(existing_relays, "template_%s_%s" % [template.id, symbol])
		existing_relays.append(internal_name)
		internal_relay_tokens[String(symbol)] = internal_name
	var rule_ids: Array = Authored.rule_ids(data)
	var rules: Array[RuleData] = []
	var rule_tokens := {}
	for source: RuleData in template.rules:
		var new_id := Authored.unique_name(rule_ids, "%s_%s" % [template.id, source.id])
		rule_ids.append(new_id)
		rule_tokens[String(source.id)] = new_id
	for source: RuleData in template.rules:
		var copy := source.duplicate_deep(Resource.DEEP_DUPLICATE_ALL) as RuleData
		copy.id = StringName(rule_tokens[String(source.id)])
		copy.trigger = StringName(_expand(String(source.trigger), parameters, variable_tokens, internal_relay_tokens, rule_tokens))
		copy.emit = StringName(_expand(String(source.emit), parameters, variable_tokens, internal_relay_tokens, rule_tokens))
		copy.state_key = source.state_key if template.deliberately_shared_latches.has(source.id) \
			else StringName(Authored.new_state_key())
		for property in ["requires", "forbids", "cancel_if"]:
			var guards: PackedStringArray = copy.get(property)
			for index in guards.size():
				guards[index] = _expand(guards[index], parameters, variable_tokens, internal_relay_tokens, rule_tokens)
			copy.set(property, guards)
		var group_tokens := {}
		for step: StepData in copy.steps:
			_expand_step(step, parameters, variable_tokens, internal_relay_tokens, rule_tokens, group_tokens)
		copy.pos = Vector2.ZERO
		copy.has_pos = false
		rules.append(copy)
	return {"ok": true, "errors": [], "rules": rules, "variables": variables}

static func _existing_relay_names(data: GraphDraft) -> Array[String]:
	var result: Array[String] = []
	for rule: RuleData in data.rules:
		if not rule.emit.is_empty() and not result.has(String(rule.emit)):
			result.append(String(rule.emit))
		if String(rule.trigger).begins_with("relay:"):
			var trigger_name := String(rule.trigger).trim_prefix("relay:")
			if not trigger_name.is_empty() and not result.has(trigger_name):
				result.append(trigger_name)
		for step: StepData in _flatten_steps(rule.steps):
			var argument_index := 0 if step.verb == &"emit_relay" else 1 if step.verb == &"repeat_emit" else -1
			if argument_index < 0 or argument_index >= step.args.size():
				continue
			var parsed := ExprTextScript.parse_literal(step.args[argument_index])
			if parsed.ok and (parsed.value is StringName or parsed.value is String):
				var relay_name := String(parsed.value)
				if not relay_name.is_empty() and not result.has(relay_name):
					result.append(relay_name)
	return result

static func _flatten_steps(steps: Array[StepData]) -> Array[StepData]:
	var result: Array[StepData] = []
	for step: StepData in steps:
		result.append(step)
		for branch: Array in step.parallel_branches:
			result.append_array(_flatten_steps(branch))
	return result

static func _expand_step(step: StepData, parameters: Dictionary, variables: Dictionary,
		relays: Dictionary, rule_ids: Dictionary, group_tokens: Dictionary) -> void:
	for index in step.args.size():
		step.args[index] = _expand(step.args[index], parameters, variables, relays, rule_ids)
	step.delay = _expand(step.delay, parameters, variables, relays, rule_ids)
	for index in step.branch_conditions.size():
		step.branch_conditions[index] = _expand(step.branch_conditions[index], parameters, variables, relays, rule_ids)
	for branch: Array in step.parallel_branches:
		for child: StepData in branch:
			_expand_step(child, parameters, variables, relays, rule_ids, group_tokens)
	if not step.group_id.is_empty():
		var old_group_id := String(step.group_id)
		if not group_tokens.has(old_group_id):
			group_tokens[old_group_id] = Authored.new_state_key()
		step.group_id = StringName(group_tokens[old_group_id])

static func _expand(text: String, parameters: Dictionary, variables: Dictionary,
		relays: Dictionary, rule_ids: Dictionary) -> String:
	var result := text
	for key in parameters:
		result = result.replace("{{param:%s}}" % key, String(parameters[key]))
	for key in variables:
		result = result.replace("{{var:%s}}" % key, String(variables[key]))
	for key in relays:
		result = result.replace("{{relay:%s}}" % key, String(relays[key]))
	for key in rule_ids:
		result = result.replace("{{rule:%s}}" % key, String(rule_ids[key]))
	return result

static func _new_template(template_id: StringName, template_title: String, summary: String) -> TemplateScript:
	var template := TemplateScript.new()
	template.id = template_id
	template.title = template_title
	template.description = summary
	return template

static func _param(name: StringName, label: String, kind: ParameterScript.Kind,
		required := true, default_value := "", description := "", expected_type := "",
		expected_prop_class := "") -> ParameterScript:
	return ParameterScript.new(name, label, kind, required, default_value, description,
		expected_type, expected_prop_class)

static func _step(verb: StringName, args: Array) -> StepData:
	var step := StepData.new()
	step.verb = verb
	step.args = PackedStringArray(args)
	return step
