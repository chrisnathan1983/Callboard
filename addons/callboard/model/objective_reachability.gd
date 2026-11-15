@tool
extends RefCounted
## Bounded, resource-only exploration. Host code and scene hooks are never run.

const MAX_STATES := 256
const MAX_CALLS := 10
const MAX_TRANSITIONS := 8000
const MAX_NESTING := 24
const TriggerRouting := preload("res://addons/callboard/core/trigger_routing_data.gd")

enum Truth { NO, YES, UNKNOWN }

var _board := Blackboard.new()
var _defaults := {}
var _scopes := {}
var _host_keys: Array[StringName] = []
var _rules := {}
var _routing := {}
var _calls: Array[StringName] = []
var _schema := {}
var _builtin_verbs := {}
var _guard_cache := {}
var _condition: Dictionary
var _transitions := 0
var _limited := false
var _unresolved := {}

static func apply(data: GraphDraft, scene_writers: Array[BlackboardWriterData] = []) -> void:
	data.objective_results.clear()
	if data.objectives.is_empty():
		return
	var analysis = new()
	analysis._configure(data, scene_writers)
	var ids := {}
	for objective: ObjectiveData in data.objectives:
		if objective == null:
			data.errors.append("Stage has an empty objective declaration")
			continue
		if not objective.id.is_valid_identifier() or ids.has(objective.id):
			data.errors.append("Objective ID '%s' must be a unique identifier" % objective.id)
			continue
		ids[objective.id] = true
		var expression := StringName(objective.condition)
		var parsed := GuardExpression.parse(objective.condition)
		if not parsed.ok or not GuardExpression.referenced_payload_fields(expression).is_empty():
			data.errors.append("Objective '%s' needs a valid Blackboard guard without event payload fields" % objective.id)
			continue
		var missing := GuardExpression.referenced_keys(expression).filter(
			func(key: StringName) -> bool: return not analysis._board.has(key))
		if not missing.is_empty():
			data.errors.append("Objective '%s' references undeclared Blackboard keys: %s" % [
				objective.id, ", ".join(PackedStringArray(missing))])
			continue
		analysis._search(objective.id, parsed, data)

func _configure(data: GraphDraft, scene_writers: Array[BlackboardWriterData]) -> void:
	var storage_slots := {}
	for variable: VariableData in data.variables:
		var key := variable.key
		var scope := StringName(variable.scope)
		var storage := variable.state_key if not variable.state_key.is_empty() else key
		var slot := key
		# Aliases also cover variables intentionally linked to one stored value.
		if scope in [&"saved", &"shared", &"session"]:
			var identity := [scope, storage]
			slot = storage_slots.get_or_add(identity, key)
		if slot == key:
			_board.define(slot, &"local", variable.default_value)
			_defaults[slot] = variable.default_value
			_scopes[slot] = scope
		else:
			_board.alias(key, slot)
		for alias: StringName in variable.aliases:
			_board.alias(alias, slot)
		if scope == &"shared":
			_add_host_key(slot)
	for key: String in data.external_vars:
		_add_host_key(StringName(key))
	for writer: BlackboardWriterData in data.external_writers + scene_writers:
		if writer != null:
			_add_host_key(writer.key)
	for rule: RuleData in data.rules:
		if rule != null and not rule.trigger.is_empty():
			var listeners: Array = _rules.get_or_add(rule.trigger, [])
			listeners.append(rule)
	for route: Resource in data.trigger_routing:
		if route != null:
			_routing[route.trigger] = route
	for field: PayloadFieldData in data.payload_fields:
		if field != null:
			var fields: Dictionary = _schema.get_or_add(field.event_id, {})
			fields[field.key] = field.value_type()
	for call: String in data.external_calls:
		var event := StringName(call)
		if _rules.has(event) and event != &"arrive" and event != &"on_change" and not _calls.has(event):
			_calls.append(event)
	var factory := StagingVerbs.new(StepContext.new(_board, null, null, Callable()))
	for entry: Dictionary in RuntimeVerbCatalog.from_factory(factory):
		_builtin_verbs[StringName(entry["name"])] = true

func _add_host_key(key: StringName) -> void:
	var slot := _board.resolve_key(key)
	if _board.has(slot) and not _host_keys.has(slot):
		_host_keys.append(slot)

func _search(id: StringName, condition: Dictionary, data: GraphDraft) -> void:
	_condition = condition
	_transitions = 0
	_limited = false
	_unresolved.clear()
	var initial := {"values": _defaults.duplicate(true), "unknown": {}, "latches": {},
		"path": PackedStringArray(), "reasons": PackedStringArray(), "probe": {}}
	var queue: Array[Dictionary] = [initial]
	var reached: Dictionary = initial if _truth(_condition, initial) == Truth.YES else {}
	if _rules.has(&"arrive"):
		queue = _call(initial, &"arrive")
	var seen := {}
	var conditional := {}
	var blocked := {}
	var cursor := 0
	while cursor < queue.size():
		var state := queue[cursor]
		cursor += 1
		var signature := _signature(state)
		if seen.has(signature):
			continue
		if seen.size() >= MAX_STATES or _transitions >= MAX_TRANSITIONS:
			_limited = true
			break
		seen[signature] = true
		var result := _truth(_condition, state)
		if result != Truth.NO:
			if not state.probe.is_empty():
				if result == Truth.YES and state.reasons.is_empty() and blocked.is_empty():
					blocked = state
			elif result == Truth.YES and state.reasons.is_empty():
				if reached.is_empty():
					reached = state
			elif conditional.is_empty() or state.reasons.size() < conditional.reasons.size():
				conditional = state
			continue
		if state.path.size() >= MAX_CALLS:
			_limited = true
			continue
		for event: StringName in _calls:
			if _transitions >= MAX_TRANSITIONS:
				_limited = true
				break
			queue.append_array(_call(state, event))
		if not _host_keys.is_empty() and not state.reasons.has("declared host or Shared Blackboard writes"):
			var host := _assume(state, "declared host or Shared Blackboard writes")
			host.path.append("host write")
			for key: StringName in _host_keys:
				host.unknown[key] = true
			queue.append(host)
			if _rules.has(&"on_change"):
				queue.append_array(_dispatch(host, &"on_change", {}, true, [], 0, true))
	if not reached.is_empty():
		_report_reached(id, reached, data)
	elif not conditional.is_empty():
		data.warnings.append("Objective '%s' may be reachable via %s. Depends on %s." % [
			id, _path_text(conditional.path), ", ".join(conditional.reasons)])
	else:
		var reasons := PackedStringArray(_unresolved.keys())
		if _limited:
			reasons.append("the exploration limit")
		var detail := " No path from defaults was found."
		if not reasons.is_empty():
			detail += " Analysis is inconclusive because of %s." % ", ".join(reasons)
		data.warnings.append("Objective '%s'.%s" % [id, detail])
	if not blocked.is_empty():
		var probe: Dictionary = blocked.probe
		var origin: Dictionary = probe.origin
		var detail := "Its latch can be consumed on '%s' by '%s' before completion." % [origin.event, origin.rule]
		data.warnings.append("Objective '%s' can be blocked by one-shot rule '%s'. %s Allowing it to run would reach completion via %s."
			% [id, probe.rule, detail, _path_text(blocked.path)])

func _report_reached(id: StringName, state: Dictionary, data: GraphDraft) -> void:
	data.objective_results.append("Objective '%s' is reachable via %s." % [id, _path_text(state.path)])

func _path_text(path: PackedStringArray) -> String:
	return "Blackboard defaults" if path.is_empty() else " → ".join(path)

func _signature(state: Dictionary) -> String:
	var latched: Array = state.latches.keys()
	var unknown: Array = state.unknown.keys()
	latched.sort()
	unknown.sort()
	var reasons: PackedStringArray = state.reasons.duplicate()
	reasons.sort()
	return var_to_str([state.values, latched, unknown, reasons, state.probe.get("rule", &"")])

func _assume(state: Dictionary, reason: String) -> Dictionary:
	var copy := state.duplicate(true)
	if not copy.reasons.has(reason):
		copy.reasons.append(reason)
	return copy

func _spend(depth: int) -> bool:
	_transitions += 1
	if depth > MAX_NESTING or _transitions > MAX_TRANSITIONS:
		_limited = true
		return false
	return true

func _call(state: Dictionary, event: StringName) -> Array[Dictionary]:
	var next := state.duplicate(true)
	next.path.append(String(event))
	return _dispatch(next, event, {}, true, [], 0, true)

func _dispatch(state: Dictionary, event: StringName, payload: Dictionary, unknown_payload: bool,
		active: Array, depth: int, allow_probe: bool) -> Array[Dictionary]:
	var candidates: Array = _rules.get(event, [])
	if candidates.is_empty():
		return [state]
	if not _spend(depth):
		return []
	var route: Resource = _routing.get(event)
	var first_match: bool = route != null and route.mode == TriggerRouting.Mode.FIRST_MATCH
	if first_match and not route.fallback_rule_id.is_empty():
		candidates = candidates.duplicate()
		for index in candidates.size():
			if candidates[index].id == route.fallback_rule_id:
				candidates.append(candidates.pop_at(index))
				break
	var waiting: Array[Dictionary] = [state]
	var finished: Array[Dictionary] = []
	for rule: RuleData in candidates:
		var skipped: Array[Dictionary] = []
		for candidate: Dictionary in waiting:
			if not _spend(depth):
				return finished
			var eligibility := _rule_truth(rule, candidate, payload, unknown_payload, event)
			if eligibility == Truth.NO:
				skipped.append(candidate)
				continue
			var latch := _latch_key(rule)
			if rule.one_shot and candidate.latches.has(latch):
				skipped.append(candidate)
				if allow_probe and eligibility == Truth.YES and rule not in active and candidate.probe.is_empty() and candidate.reasons.is_empty():
					var probe := candidate.duplicate(true)
					probe.probe = {"rule": rule.id, "origin": probe.latches[latch]}
					var retried := _run(rule, probe, event, payload, unknown_payload, active, depth + 1, false)
					if first_match:
						finished.append_array(retried)
					else:
						skipped.append_array(retried)
				continue
			if rule in active:
				if rule.reentry != Rule.ReentryPolicy.IGNORE:
					_unresolved["re-entry of '%s'" % rule.id] = true
				skipped.append(candidate)
				continue
			if eligibility == Truth.UNKNOWN:
				candidate = _assume(candidate, "host payload or Blackboard inputs to '%s'" % rule.id)
				skipped.append(candidate)
			var outcomes := _run(rule, candidate, event, payload, unknown_payload, active, depth + 1, allow_probe)
			if first_match:
				finished.append_array(outcomes)
			else:
				skipped.append_array(outcomes)
		waiting = skipped
	finished.append_array(waiting)
	return finished

func _latch_key(rule: RuleData) -> StringName:
	return rule.id if rule.state_key.is_empty() else rule.state_key

func _rule_truth(rule: RuleData, state: Dictionary, payload: Dictionary,
		unknown_payload: bool, event: StringName) -> Truth:
	var result := Truth.YES
	for guard: String in rule.requires:
		var test := _guard(guard, state, payload, unknown_payload, event)
		if test == Truth.NO:
			return Truth.NO
		if test == Truth.UNKNOWN:
			result = Truth.UNKNOWN
	for guard: String in rule.forbids + rule.cancel_if:
		var test := _guard(guard, state, payload, unknown_payload, event)
		if test == Truth.YES:
			return Truth.NO
		if test == Truth.UNKNOWN:
			result = Truth.UNKNOWN
	return result

func _guard(source: String, state: Dictionary, payload: Dictionary,
		unknown_payload: bool, event: StringName) -> Truth:
	if not _guard_cache.has(source):
		_guard_cache[source] = GuardExpression.parse(source)
	return _truth(_guard_cache[source], state, payload, unknown_payload, event)

func _truth(node: Dictionary, state: Dictionary, payload := {}, unknown_payload := false,
		event := &"") -> Truth:
	if not node.ok:
		return Truth.NO
	if node.kind != "term":
		var decisive := Truth.NO if node.kind == "and" else Truth.YES
		var combined := Truth.YES if node.kind == "and" else Truth.NO
		for child: Dictionary in node.children:
			var result := _truth(child, state, payload, unknown_payload, event)
			if result == decisive:
				return decisive
			if result == Truth.UNKNOWN:
				combined = Truth.UNKNOWN
		return combined
	if node.payload and unknown_payload and (not _schema.has(event) or _schema[event].has(node.key)):
		return Truth.UNKNOWN
	if node.get("rhs_payload", false) and unknown_payload:
		return Truth.UNKNOWN
	if not node.payload and state.unknown.has(_board.resolve_key(node.key)):
		return Truth.UNKNOWN
	if node.has("rhs_key") and not node.rhs_payload and state.unknown.has(_board.resolve_key(node.rhs_key)):
		return Truth.UNKNOWN
	_board.local = state.values
	return Truth.YES if GuardExpression.evaluate(_board, node.source, payload, event, _schema) else Truth.NO

func _run(rule: RuleData, state: Dictionary, event: StringName, payload: Dictionary,
		unknown_payload: bool, active: Array, depth: int, allow_probe: bool) -> Array[Dictionary]:
	var started := state.duplicate(true)
	if rule.one_shot:
		started.latches[_latch_key(rule)] = {"rule": rule.id, "event": event}
	var context := {"rule": rule, "event": event, "payload": payload, "unknown_payload": unknown_payload,
		"active": active + [rule], "depth": depth, "allow_probe": allow_probe}
	var outputs: Array[Dictionary] = []
	for outcome: Dictionary in _steps(rule.steps, started, context):
		if outcome.stopped or rule.emit.is_empty():
			outputs.append(outcome.state)
		else:
			var completion: Dictionary = outcome.state
			var cancelled := _cancellation(completion, context)
			if cancelled != Truth.NO:
				completion = _assume(completion, "cancellation of '%s'" % rule.id) if cancelled == Truth.UNKNOWN else completion
				outputs.append(completion)
			if cancelled != Truth.YES:
				outputs.append_array(_relay(completion, rule.emit, context))
	return outputs

func _steps(steps: Array, state: Dictionary, context: Dictionary) -> Array[Dictionary]:
	var outcomes: Array[Dictionary] = [{"state": state, "stopped": false}]
	for step: StepData in steps:
		var next: Array[Dictionary] = []
		for outcome: Dictionary in outcomes:
			if outcome.stopped:
				next.append(outcome)
			elif _spend(context.depth):
				next.append_array(_step(step, outcome.state, context))
		outcomes = next
	return outcomes

func _relay(state: Dictionary, relay: StringName, context: Dictionary) -> Array[Dictionary]:
	return _dispatch(state, StringName("relay:" + String(relay)), context.payload,
		context.unknown_payload, context.active, context.depth + 1, context.allow_probe)

func _cancellation(state: Dictionary, context: Dictionary) -> Truth:
	var rule: RuleData = context.rule
	var result := Truth.NO
	for guard: String in rule.cancel_if:
		match _guard(guard, state, context.payload, context.unknown_payload, context.event):
			Truth.YES:
				return Truth.YES
			Truth.UNKNOWN:
				result = Truth.UNKNOWN
	return result

func _step(step: StepData, state: Dictionary, context: Dictionary) -> Array[Dictionary]:
	var cancelled := _cancellation(state, context)
	if cancelled == Truth.YES:
		return [{"state": state, "stopped": true}]
	if cancelled == Truth.UNKNOWN:
		state = _assume(state, "cancellation of '%s'" % context.rule.id)
	var outcomes := _perform(step, state, context)
	if cancelled == Truth.UNKNOWN:
		outcomes.append({"state": state, "stopped": true})
	return outcomes

func _perform(step: StepData, state: Dictionary, context: Dictionary) -> Array[Dictionary]:
	if not step.delay.is_empty():
		var delay := ExprText.parse_literal(step.delay.strip_edges())
		if not delay.ok or delay.value != 0.0:
			_unresolved["timing of delayed steps"] = true
			state = _assume(state, "timing of delayed steps")
	var next: Array[Dictionary] = []
	match step.verb:
		&"conditional", &"random", &"parallel":
			return _group(step, state, context)
		&"set_var", &"set_state", &"add_var", &"toggle_var", &"reset_var":
			next = _write(step, state, context)
		&"light":
			next = [state]
			var key := _literal(step, 3, &"")
			if not key.ok or (key.value is String or key.value is StringName) and not String(key.value).is_empty():
				var reason := "a scene light writing Blackboard state"
				_unresolved[reason] = true
				var scene_dependent := _assume(state, reason)
				var mirror := StepData.new()
				mirror.verb = &"set_var"
				mirror.args = PackedStringArray([step.args[3], step.args[1]])
				next.append_array(_write(mirror, scene_dependent, context))
		&"emit_relay":
			var relay := _literal(step, 0, &"")
			if relay.ok and (relay.value is String or relay.value is StringName):
				var mapped := context
				if step.args.size() > 1 and step.args[1].strip_edges() != "{}":
					mapped = context.duplicate()
					mapped.unknown_payload = true
					state = _assume(state, "relay payload mappings")
				next = _relay(state, StringName(relay.value), mapped)
			else:
				_unresolved["a computed relay name"] = true
				next = [state]
		&"repeat_emit":
			var tick := _literal(step, 1, &"")
			if tick.ok and (tick.value is String or tick.value is StringName) and not String(tick.value).is_empty():
				var ticking := _assume(state, "timing of repeat_emit")
				for result: Dictionary in _relay(ticking, StringName(tick.value), context):
					next.append({"state": result, "stopped": true})
			_unresolved["ambient loops"] = true
			next.append({"state": state, "stopped": true})
			return next
		&"wait_until", &"wait_for_call":
			return _wait(step, state, context)
		_:
			if not _builtin_verbs.has(step.verb) or step.verb in [&"gameplay_event", &"gameplay_request", &"emit_cross_stage"]:
				var reason := "host behavior in '%s'" % step.verb
				_unresolved[reason] = true
				state = _assume(state, reason)
				var host := state.duplicate(true)
				for key: StringName in _defaults:
					host.unknown[key] = true
				next = [state, host]
			else:
				next = [state]
	var results: Array[Dictionary] = []
	for item: Dictionary in next:
		results.append({"state": item, "stopped": false})
	return results

func _group(step: StepData, state: Dictionary, context: Dictionary) -> Array[Dictionary]:
	var nested := context.duplicate()
	nested.depth += 1
	if step.verb == &"parallel":
		var sequence: Array[StepData] = []
		for branch: Array in step.parallel_branches:
			sequence.append_array(branch)
		_unresolved["parallel scheduling"] = true
		return _steps(sequence, _assume(state, "parallel scheduling"), nested)
	var results: Array[Dictionary] = []
	if step.verb == &"random":
		for index in step.parallel_branches.size():
			if step.random_selection == 1 and (index >= step.branch_weights.size() or step.branch_weights[index] <= 0.0):
				continue
			var possibility := _assume(state, "random branch %d of '%s'" % [index + 1, context.rule.id])
			results.append_array(_steps(step.parallel_branches[index], possibility, nested))
		if results.is_empty():
			results.append({"state": state, "stopped": false})
		return results
	for index in step.parallel_branches.size():
		if index == step.default_branch_index or index >= step.branch_conditions.size():
			continue
		var check := _guard(step.branch_conditions[index], state, context.payload,
			context.unknown_payload, context.event)
		if check == Truth.NO:
			continue
		if check == Truth.UNKNOWN:
			state = _assume(state, "unresolved branch condition in '%s'" % context.rule.id)
		results.append_array(_steps(step.parallel_branches[index], state, nested))
		if check == Truth.YES:
			return results
	if step.default_branch_index >= 0 and step.default_branch_index < step.parallel_branches.size():
		results.append_array(_steps(step.parallel_branches[step.default_branch_index], state, nested))
	else:
		results.append({"state": state, "stopped": false})
	return results

func _wait(step: StepData, state: Dictionary, context: Dictionary) -> Array[Dictionary]:
	var guard := _literal(step, 0, "")
	if step.verb == &"wait_until" and guard.ok and (guard.value is String or guard.value is StringName):
		if _guard(String(guard.value), state, context.payload, context.unknown_payload, context.event) == Truth.YES:
			return [{"state": state, "stopped": false}]
	var reason := "a suspended '%s' in '%s'" % [step.verb, context.rule.id]
	_unresolved[reason] = true
	var results: Array[Dictionary] = [{"state": state, "stopped": true}]
	# Suspension may resolve after a later Call. Explore the timeout only when
	# authored, and leave resumption inconclusive without a modeled schedule.
	var timeout_index := 2 if step.verb == &"wait_until" else 3
	var timeout := _literal(step, timeout_index, &"")
	var seconds := _literal(step, timeout_index - 1, 0.0)
	if seconds.ok and (seconds.value is float or seconds.value is int) and seconds.value > 0.0 \
			and timeout.ok and (timeout.value is String or timeout.value is StringName) and not String(timeout.value).is_empty():
		for result: Dictionary in _relay(_assume(state, reason), StringName(timeout.value), context):
			results.append({"state": result, "stopped": true})
	return results

func _literal(step: StepData, index: int, fallback: Variant) -> Dictionary:
	if index >= step.args.size():
		return {"ok": true, "value": fallback}
	return ExprText.parse_literal(step.args[index].strip_edges())

func _write(step: StepData, state: Dictionary, context: Dictionary) -> Array[Dictionary]:
	var target := _literal(step, 0, &"")
	if not target.ok:
		var dynamic := _assume(state, "a computed Blackboard write target")
		for key: StringName in _defaults:
			dynamic.unknown[key] = true
		return [dynamic]
	if not (target.value is String or target.value is StringName):
		return [state]
	var key := _board.resolve_key(StringName(target.value))
	if not _defaults.has(key):
		return [state]
	var current: Variant = state.values[key]
	var value := _literal(step, 1, true)
	var known: bool = value.ok
	var desired: Variant = value.get("value")
	match step.verb:
		&"reset_var":
			desired = _defaults[key]
		&"toggle_var":
			if not current is bool:
				return [state]
			known = not state.unknown.has(key)
			desired = not current
		&"add_var":
			if not (current is int or current is float):
				return [state]
			if known and not (desired is int or desired is float):
				return [state]
			known = known and not state.unknown.has(key)
			if known:
				if current is int and not is_equal_approx(float(desired), roundf(float(desired))):
					return [state]
				desired = current + (int(desired) if current is int else float(desired))
		&"set_state":
			if desired is String:
				desired = StringName(desired)
			if not current is StringName or (known and (not desired is StringName or desired.is_empty())):
				return [state]
	if not known:
		_unresolved["a computed value for '%s'" % key] = true
		var dynamic := _assume(state, "a computed value for '%s'" % key)
		dynamic.unknown[key] = true
		return _dispatch(dynamic, &"on_change", {}, true, context.active, context.depth + 1, context.allow_probe)
	if current is float and desired is int:
		desired = float(desired)
	if typeof(desired) != typeof(current) or (desired == current and not state.unknown.has(key)):
		return [state]
	var changed := state.duplicate(true)
	var previous_unknown: bool = changed.unknown.erase(key)
	changed.values[key] = desired
	var payload := {"key": String(key), "previous": current, "value": desired,
		"scope": String(_scopes[key]), "writer": "rule:" + String(context.rule.id)}
	if context.event == &"on_change":
		changed = _assume(changed, "queued Blackboard change dispatch")
	return _dispatch(changed, &"on_change", payload, previous_unknown, context.active,
		context.depth + 1, context.allow_probe)
