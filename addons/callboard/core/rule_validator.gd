@tool
class_name RuleValidator extends RefCounted

static func check(rules: Array[Rule], bb: Blackboard,
		external_calls: Array[StringName], external_vars: Array[StringName]) -> Array[String]:
	var problems: Array[String] = []
	var emitted := {}
	var settable := {}
	var seen := {}
	for k in external_vars:
		settable[bb.resolve_key(k)] = true
	for r in rules:
		if seen.has(r.id):
			problems.append("duplicate rule id '%s'" % r.id)
		seen[r.id] = true
		if r.emits != &"":
			emitted["relay:" + r.emits] = true
		for s in r.steps:
			if s.emits != &"":
				emitted["relay:" + s.emits] = true
			for k in s.sets:
				settable[k] = true
				if not bb.schema.has(k):
					problems.append("rule '%s' writes '%s' which is not declared on the Blackboard" % [r.id, k])
	for r in rules:
		if r.one_shot and r.reentry != Rule.ReentryPolicy.IGNORE:
			problems.append("rule '%s' is one-shot and must use Ignore re-entry" % r.id)
		if r.trigger == &"":
			problems.append("rule '%s' has no trigger" % r.id)
		elif not emitted.has(r.trigger) and not external_calls.has(r.trigger):
			problems.append("rule '%s' listens to '%s' but nothing emits it and it is not a declared external Call" % [r.id, r.trigger])
		for guard in r.requires + r.forbids + r.cancel_if:
			var parsed := GuardExpression.parse(String(guard))
			if not parsed["ok"]:
				problems.append("rule '%s' has an invalid guard '%s'" % [r.id, guard])
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
			problems.append("rule '%s' does nothing (no steps, no emit)" % r.id)
	for event in emitted:
		if not rules.any(func(x: Rule) -> bool: return x.trigger == event):
			problems.append("'%s' is emitted but no rule listens to it" % event)
	problems.append_array(_find_relay_cycles(rules))
	problems.append_array(_find_shared_trigger_conflicts(rules))
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
	for key in a.requires:
		if b.forbids.has(key):
			return true
	for key in b.requires:
		if a.forbids.has(key):
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
