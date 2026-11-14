@tool
class_name RuleValidator extends RefCounted

static func check(rules: Array[Rule], bb: Blackboard,
		external_calls: Array[StringName], external_vars: Array[StringName],
		payload_schema: Dictionary = {}, external_writers: Array[BlackboardWriterData] = []) -> Array[String]:
	var problems: Array[String] = []
	var emitted := {}
	var settable := {}
	var seen := {}
	var payload_names := {}
	for event_id in payload_schema:
		payload_names[event_id] = {}
		for field_name in payload_schema[event_id]:
			payload_names[event_id][field_name] = payload_schema[event_id][field_name]
	for k in external_vars:
		settable[bb.resolve_key(k)] = true
	for writer: BlackboardWriterData in external_writers:
		if writer == null:
			continue
		var key: StringName = bb.resolve_key(writer.key)
		if not bb.has(writer.key):
			problems.append("external writer '%s' declares '%s', which is not declared on the Blackboard" % [writer.source, writer.key])
			continue
		settable[key] = true
		var expected_type: int = writer.type_id()
		var declared_type: int = bb.schema[key].get("type", TYPE_NIL)
		if expected_type != TYPE_NIL and expected_type != declared_type \
				and not (expected_type == TYPE_INT and declared_type == TYPE_FLOAT):
			problems.append("external writer '%s' outputs %s for '%s', which is declared as %s" % [
				writer.source, writer.value_type, writer.key, type_string(declared_type)])
	for r in rules:
		if seen.has(r.id):
			problems.append("duplicate rule id '%s'" % r.id)
		seen[r.id] = true
		if r.emits != &"":
			emitted["relay:" + r.emits] = true
		for s in r.steps:
			if s.verb == &"emit_relay":
				problems.append_array(_validate_mapped_relay_step(r, s, payload_names))
			for k in s.reads:
				if not bb.has(k):
					problems.append("rule '%s' reads '%s' which is not declared on the Blackboard" % [r.id, k])
			if s.emits != &"":
				emitted["relay:" + s.emits] = true
			for k in s.sets:
				settable[bb.resolve_key(k)] = true
				if not bb.has(k):
					problems.append("rule '%s' writes '%s' which is not declared on the Blackboard" % [r.id, k])
			if s.verb == &"set_var":
				if s.args.size() < 2:
					problems.append("rule '%s' has a set_var step without a key and value" % r.id)
				else:
					var target: Variant = s.args[0]
					var value: Variant = s.args[1]
					if not target is StringName:
						problems.append("rule '%s' set_var target must be a Blackboard key" % r.id)
					elif not bb.has(target):
						problems.append("rule '%s' set_var target '%s' is not declared on the Blackboard" % [r.id, target])
					else:
						var target_type: int = bb.schema[bb.resolve_key(target)].get("type", TYPE_NIL)
						var value_type := typeof(value)
						if value_type != target_type and not (target_type == TYPE_FLOAT and value_type == TYPE_INT):
							problems.append("rule '%s' set_var value of type %s is incompatible with key '%s' declared as %s" % [
								r.id, type_string(value_type), target, type_string(target_type)])
			if s.verb == &"add_var":
				if s.args.size() < 2:
					problems.append("rule '%s' has an add_var step without a key and delta" % r.id)
				else:
					var target: Variant = s.args[0]
					var delta: Variant = s.args[1]
					if not target is StringName:
						problems.append("rule '%s' add_var target must be a Blackboard key" % r.id)
					elif not bb.has(target):
						problems.append("rule '%s' add_var target '%s' is not declared on the Blackboard" % [r.id, target])
					else:
						var target_type: int = bb.schema[bb.resolve_key(target)].get("type", TYPE_NIL)
						if target_type not in [TYPE_INT, TYPE_FLOAT]:
							problems.append("rule '%s' add_var target '%s' must be int or float" % [r.id, target])
						if not (delta is int or delta is float):
							problems.append("rule '%s' add_var delta must be numeric" % r.id)
						elif target_type == TYPE_INT and delta is float and not is_equal_approx(delta, roundf(delta)):
							problems.append("rule '%s' add_var delta for integer key '%s' must be a whole number" % [r.id, target])
	for r in rules:
		if r.one_shot and r.reentry != Rule.ReentryPolicy.IGNORE:
			problems.append("rule '%s' is one-shot and must use Ignore re-entry" % r.id)
		if r.trigger == &"":
			problems.append("rule '%s' has no trigger" % r.id)
		elif r.trigger != &"on_change" and not emitted.has(r.trigger) and not external_calls.has(r.trigger):
			problems.append("rule '%s' listens to '%s', which has no relay emitter or external declaration" % [r.id, r.trigger])
		if r.trigger == &"on_change":
			var listened_keys := {}
			for guard in r.requires:
				var change_guard := GuardExpression.parse(String(guard))
				if not change_guard.get("payload", false) or change_guard.get("key") != &"key" or not change_guard.get("comparison", false) or change_guard.get("operator") != "==" or change_guard.get("value_type", TYPE_NIL) != TYPE_STRING:
					continue
				var listened_key := StringName(change_guard["value"])
				if listened_keys.has(listened_key):
					continue
				listened_keys[listened_key] = true
				if not bb.has(listened_key):
					problems.append("rule '%s' listens for on_change key '%s', which is not declared on the Blackboard" % [r.id, listened_key])
				elif not settable.has(bb.resolve_key(listened_key)):
					problems.append("rule '%s' listens for on_change key '%s' but no writer is declared" % [r.id, listened_key])
		for guard in r.requires + r.forbids + r.cancel_if:
			var parsed := GuardExpression.parse(String(guard))
			if not parsed["ok"]:
				problems.append("rule '%s' has an invalid guard '%s'" % [r.id, guard])
				continue
			if parsed["payload"]:
				var trigger_schema: Dictionary = payload_names.get(r.trigger, {})
				var field_key: StringName = parsed["key"]
				if parsed.get("presence", "") != "":
					if payload_names.has(r.trigger) and not trigger_schema.has(field_key):
						problems.append("rule '%s' checks undeclared payload field '%s' for trigger '%s'" % [r.id, field_key, r.trigger])
					continue
				if parsed["comparison"]:
					if payload_names.has(r.trigger) and not trigger_schema.has(field_key):
						problems.append("rule '%s' checks undeclared payload field '%s' for trigger '%s'" % [r.id, field_key, r.trigger])
						continue
					# An event without any schema is intentionally dynamic: runtime checks
					# the actual Variant type. A declared schema is strict, including when
					# only some of an event's fields are listed.
					if not payload_names.has(r.trigger):
						continue
					var field_type: int = trigger_schema.get(field_key, TYPE_NIL)
					var literal_type: int = parsed["value_type"]
					var operator: String = parsed["operator"]
					var compatible := false
					if field_type == TYPE_NIL:
						compatible = true # Dynamic Variant fields, including on_change values.
					elif field_type in [TYPE_INT, TYPE_FLOAT]:
						compatible = literal_type in [TYPE_INT, TYPE_FLOAT]
					elif field_type in [TYPE_BOOL, TYPE_STRING]:
						compatible = literal_type == field_type and operator in ["==", "!="]
					if not compatible:
						problems.append("rule '%s' compares payload field '%s' with an incompatible literal or operator" % [r.id, field_key])
				continue
			var key: StringName = bb.resolve_key(parsed["key"])
			if not bb.schema.has(key):
				problems.append("rule '%s' checks key '%s' which is not declared on the Blackboard" % [r.id, key])
				continue
			if parsed["comparison"] and bb.schema[key].get("type") not in [TYPE_INT, TYPE_FLOAT]:
				problems.append("rule '%s' compares '%s', which is not an int or float Blackboard key" % [r.id, key])
			if not settable.has(key):
				problems.append("rule '%s' checks key '%s' but nothing sets it" % [r.id, key])
		for s in r.steps:
			if s.args.has(null):
				problems.append("rule '%s' has a '%s' step with an unset prop" % [r.id, s.verb])
		if r.steps.is_empty() and r.emits == &"":
			problems.append("rule '%s' has no steps or completion relay" % r.id)
	for event in emitted:
		if not rules.any(func(x: Rule) -> bool: return x.trigger == event):
			problems.append("'%s' is emitted but no rule listens to it" % event)
	problems.append_array(_find_relay_cycles(rules))
	problems.append_array(_find_shared_trigger_conflicts(rules))
	return problems

static func _validate_mapped_relay_step(rule: Rule, step: Step,
		payload_schemas: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	if step.args.is_empty() or not (step.args[0] is StringName or step.args[0] is String):
		problems.append("rule '%s' emit_relay requires a literal relay name" % rule.id)
		return problems
	var relay_name := String(step.args[0])
	if relay_name.is_empty() or not relay_name.is_valid_identifier():
		problems.append("rule '%s' emit_relay relay '%s' must be a non-empty identifier" % [rule.id, relay_name])
		return problems
	var field_map: Dictionary = {}
	if step.args.size() > 1:
		if not step.args[1] is Dictionary:
			problems.append("rule '%s' emit_relay field_map must evaluate to a Dictionary" % rule.id)
			return problems
		field_map = step.args[1]
	for output_field: Variant in field_map:
		var input_field: Variant = field_map[output_field]
		if not (output_field is String or output_field is StringName) or not (input_field is String or input_field is StringName):
			problems.append("rule '%s' emit_relay field mappings must use String or StringName field names" % rule.id)
			continue
		var output_name := StringName(String(output_field))
		var input_name := StringName(String(input_field))
		if not output_name.is_valid_identifier() or not input_name.is_valid_identifier():
			problems.append("rule '%s' emit_relay maps invalid field name '%s' to '%s'" % [rule.id, output_name, input_name])
			continue
		var source_schema: Dictionary = payload_schemas.get(rule.trigger, {})
		if payload_schemas.has(rule.trigger) and not source_schema.has(input_name):
			problems.append("rule '%s' emit_relay reads undeclared input field '%s' for '%s'" % [rule.id, input_name, rule.trigger])
			continue
		var relay_event := StringName("relay:" + relay_name)
		var target_schema: Dictionary = payload_schemas.get(relay_event, {})
		if payload_schemas.has(relay_event) and not target_schema.has(output_name):
			problems.append("rule '%s' emit_relay writes undeclared output field '%s' for '%s'" % [rule.id, output_name, relay_event])
			continue
		if source_schema.has(input_name) and target_schema.has(output_name) and source_schema[input_name] != TYPE_NIL and source_schema[input_name] != target_schema[output_name]:
			problems.append("rule '%s' emit_relay maps '%s' (%s) to '%s' (%s) with incompatible types" % [
				rule.id, input_name, type_string(source_schema[input_name]),
				output_name, type_string(target_schema[output_name])])
	return problems

static func _find_shared_trigger_conflicts(rules: Array[Rule]) -> Array[String]:
	var problems: Array[String] = []
	var by_trigger := {}
	for r in rules:
		if r.trigger == &"":
			continue
		if not by_trigger.has(r.trigger):
			by_trigger[r.trigger] = []
		by_trigger[r.trigger].append(r)
	for trigger in by_trigger:
		var sharing: Array = by_trigger[trigger]
		for i in range(sharing.size()):
			for j in range(i + 1, sharing.size()):
				var a: Rule = sharing[i]
				var b: Rule = sharing[j]
				if not a.allow_overlap and not b.allow_overlap and not _guards_are_exclusive(a, b):
					problems.append(
						"rules '%s' and '%s' share trigger '%s' and may both run; add mutually exclusive requires/forbids guards"
						% [a.id, b.id, trigger])
	return problems

static func _guards_are_exclusive(a: Rule, b: Rule) -> bool:
	if _has_contradictory_guards(a) or _has_contradictory_guards(b):
		return true
	if _payload_equalities_are_exclusive(a, b):
		return true
	for key in a.requires:
		if b.forbids.has(key):
			return true
	for key in b.requires:
		if a.forbids.has(key):
			return true
	return false

static func _payload_equalities_are_exclusive(a: Rule, b: Rule) -> bool:
	for a_guard in a.requires:
		var left := GuardExpression.parse(String(a_guard))
		if not left.get("payload", false) or not left.get("comparison", false) or left.get("operator") != "==":
			continue
		for b_guard in b.requires:
			var right := GuardExpression.parse(String(b_guard))
			if not right.get("payload", false) or not right.get("comparison", false) or right.get("operator") != "==":
				continue
			if left.get("key") != right.get("key"):
				continue
			var left_type: int = left.get("value_type", TYPE_NIL)
			var right_type: int = right.get("value_type", TYPE_NIL)
			var same_literal: bool = left_type == right_type and left.get("value") == right.get("value")
			if left_type in [TYPE_INT, TYPE_FLOAT] and right_type in [TYPE_INT, TYPE_FLOAT]:
				same_literal = is_equal_approx(float(left.get("value")), float(right.get("value")))
			if not same_literal:
				return true
	return false

static func _has_contradictory_guards(r: Rule) -> bool:
	for key in r.requires:
		if r.forbids.has(key):
			return true
	return false

static func _find_relay_cycles(rules: Array[Rule]) -> Array[String]:
	var graph := {}
	for r in rules:
		if not String(r.trigger).begins_with("relay:"):
			continue
		var outputs: Array[StringName] = []
		if r.emits != &"":
			outputs.append(StringName("relay:" + String(r.emits)))
		for s in r.steps:
			if s.emits != &"":
				outputs.append(StringName("relay:" + String(s.emits)))
		if outputs.is_empty():
			continue
		if not graph.has(r.trigger):
			graph[r.trigger] = []
		for output in outputs:
			graph[r.trigger].append({"event": output, "rule": r.id})

	var problems: Array[String] = []
	var state := {}
	var stack: Array[StringName] = []
	var entry_rules: Array[StringName] = []
	var reported := {}
	for event in graph:
		if state.get(event, 0) == 0:
			_visit_relay(event, &"", graph, state, stack, entry_rules, reported, problems)
	return problems

static func _visit_relay(event: StringName, incoming_rule: StringName,
		graph: Dictionary, state: Dictionary,
		stack: Array[StringName], entry_rules: Array[StringName],
		reported: Dictionary, problems: Array[String]) -> void:
	state[event] = 1
	stack.append(event)
	entry_rules.append(incoming_rule)
	for edge in graph.get(event, []):
		var next: StringName = edge["event"]
		var rule_id: StringName = edge["rule"]
		if state.get(next, 0) == 0:
			_visit_relay(next, rule_id, graph, state, stack, entry_rules, reported, problems)
		elif state.get(next, 0) == 1:
			var start := stack.find(next)
			var path: Array[String] = []
			var cycle_rules := {}
			for i in range(start, stack.size()):
				path.append(String(stack[i]))
				if i > start:
					cycle_rules[entry_rules[i]] = true
			path.append(String(next))
			cycle_rules[rule_id] = true
			var rule_names: Array[String] = []
			for id in cycle_rules:
				rule_names.append("'%s'" % id)
			rule_names.sort()
			var key := " -> ".join(path) + "|" + ",".join(rule_names)
			if not reported.has(key):
				reported[key] = true
				problems.append("relay cycle %s (rules: %s)" % [" -> ".join(path), ", ".join(rule_names)])
	state[event] = 2
	stack.pop_back()
	entry_rules.pop_back()
