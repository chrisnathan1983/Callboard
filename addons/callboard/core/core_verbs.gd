@tool
class_name CoreVerbs extends RefCounted
## Blackboard writes, scoring and repeatable relays.

const RuntimeInputRefScript := preload("res://addons/callboard/core/runtime_input_ref.gd")

var context: StepContext
var runtime_input_event: StringName = &""

func _init(p_context: StepContext) -> void:
	context = p_context

## Authored expression helper: resolves a declared payload field when a rule step runs.
func callboard_payload(key_value: Variant) -> RefCounted:
	if not (key_value is String or key_value is StringName):
		return RuntimeInputRefScript.new(RuntimeInputRefScript.Source.PAYLOAD, &"", TYPE_NIL, false,
			"payload input key must be a String or StringName")
	var key := StringName(String(key_value))
	var engine := context.engine_ref.get_ref() as RuleEngine
	var schema: Dictionary = engine.payload_schema.get(runtime_input_event, {}) if engine != null else {}
	if not key.is_valid_identifier():
		return RuntimeInputRefScript.new(RuntimeInputRefScript.Source.PAYLOAD, key, TYPE_NIL, false,
			"payload field '%s' is not a valid identifier" % key)
	if engine != null and engine.payload_schema.has(runtime_input_event) and not schema.has(key):
		return RuntimeInputRefScript.new(RuntimeInputRefScript.Source.PAYLOAD, key, TYPE_NIL, false,
			"payload field '%s' is not declared for '%s'" % [key, runtime_input_event])
	return RuntimeInputRefScript.new(RuntimeInputRefScript.Source.PAYLOAD, key, schema.get(key, TYPE_NIL))

## Authored expression helper: resolves the current value of a declared Blackboard key.
func callboard_blackboard(key_value: Variant) -> RefCounted:
	if not (key_value is String or key_value is StringName):
		return RuntimeInputRefScript.new(RuntimeInputRefScript.Source.BLACKBOARD, &"", TYPE_NIL, false,
			"Blackboard input key must be a String or StringName")
	var key := StringName(String(key_value))
	var resolved: StringName = context.bb.resolve_key(key)
	if not key.is_valid_identifier() or not context.bb.schema.has(resolved):
		return RuntimeInputRefScript.new(RuntimeInputRefScript.Source.BLACKBOARD, key, TYPE_NIL, false,
			"Blackboard key '%s' is not declared" % key)
	return RuntimeInputRefScript.new(RuntimeInputRefScript.Source.BLACKBOARD, resolved,
		context.bb.schema[resolved].get("type", TYPE_NIL))

func set_var(key: StringName, value: Variant = true) -> Step:
	var bb := context.bb
	var step := Step.new(func(c: Dictionary) -> void:
		bb.write(key, value, _rule_writer(c), _dispatch_context(c)))
	step.sets = [key]
	return step

## Add to a declared numeric Blackboard value when this step executes.
func add_var(key: StringName, delta: float) -> Step:
	var bb := context.bb
	var step := Step.new(func(_c: Dictionary) -> void:
		var resolved := bb.resolve_key(key)
		if not bb.schema.has(resolved):
			push_warning("Callboard add_var skipped: Blackboard key '%s' is not declared." % key)
			return
		var key_type: int = bb.schema[resolved].get("type", TYPE_NIL)
		if key_type == TYPE_INT:
			if not is_equal_approx(delta, roundf(delta)):
				push_warning("Callboard add_var skipped: fractional delta for integer key '%s'." % key)
				return
			bb.write(key, int(bb.get_var(key)) + int(delta), _rule_writer(_c), _dispatch_context(_c))
		elif key_type == TYPE_FLOAT:
			bb.write(key, float(bb.get_var(key)) + delta, _rule_writer(_c), _dispatch_context(_c))
		else:
			push_warning("Callboard add_var skipped: Blackboard key '%s' must be int or float." % key))
	step.reads = [key]
	step.sets = [key]
	return step

## Run the first branch whose guard matches, or the explicit default branch.
## Branch arrays and their steps execute in the order supplied. The RuleEngine
## owns branch cancellation, including Restart, Cancel If, and Stage teardown.
func branch_if(conditions: Array[StringName], branches: Array[Array],
		default_branch_index: int = -1) -> Step:
	return Step.conditional(conditions, branches, default_branch_index)

## Choose one ordered branch. Selection 0 is uniform and 1 uses relative
## non-negative weights. Give the group a stable ID to preserve its seeded
## selection stream across branch or step reordering and managed Stage reloads.
func choose_random(branches: Array[Array], weights: PackedFloat32Array = PackedFloat32Array(),
		seed_value: int = 1, stable_group_id: StringName = &"", selection: int = 0) -> Step:
	return Step.random_choice(branches, weights, seed_value, stable_group_id, selection)

func _rule_writer(context_data: Dictionary) -> StringName:
	var callboard: Dictionary = context_data.get("_callboard", {})
	var rule: Rule = callboard.get("rule") as Rule
	return StringName("rule:" + String(rule.id)) if rule != null else &"rule"

func _dispatch_context(context_data: Dictionary) -> Dictionary:
	var callboard: Dictionary = context_data.get("_callboard", {})
	var run: Dictionary = callboard.get("run", {})
	return run.get("context", {}).duplicate(true)

func score(points: int) -> Step:
	var emit_score := context.score
	return Step.new(func(_c: Dictionary) -> void: emit_score.call(points))

## Immediately emit a relay from this point in the sequence. An empty field_map
## forwards the full input payload; otherwise each {output_name: input_name}
## pair selects or renames one incoming field.
func emit_relay(relay: StringName, field_map: Dictionary = {}) -> Step:
	var ctx := context
	var step := Step.new(func(c: Dictionary) -> void:
		if relay.is_empty():
			push_warning("Callboard emit_relay skipped: relay name is empty.")
			return
		var engine := ctx.engine_ref.get_ref() as RuleEngine
		if engine == null:
			return
		var input_payload: Dictionary = c.get("payload", {})
		var output_payload: Dictionary = input_payload.duplicate(true)
		if not field_map.is_empty():
			output_payload.clear()
			for output_field: Variant in field_map:
				var input_field: Variant = field_map[output_field]
				if not _is_payload_field_name(output_field):
					push_warning("Callboard emit_relay skipped: output field names must use String or StringName.")
					return
				var output_name := StringName(String(output_field))
				if not output_name.is_valid_identifier():
					push_warning("Callboard emit_relay skipped: '%s' is not a valid output field name." % output_name)
					return
				if input_field is RuntimeInputRefScript:
					var resolved := (input_field as RuntimeInputRefScript).resolve(c, ctx.bb)
					if not resolved["ok"]:
						push_warning("Callboard emit_relay skipped: %s" % resolved["error"])
						return
					output_payload[String(output_name)] = resolved["value"]
					continue
				if not _is_payload_field_name(input_field):
					push_warning("Callboard emit_relay skipped: field mappings must use String or StringName input names or typed runtime references.")
					return
				var input_name := StringName(String(input_field))
				if input_payload.has(input_name):
					output_payload[String(output_name)] = input_payload[input_name].duplicate(true) if input_payload[input_name] is Array or input_payload[input_name] is Dictionary else input_payload[input_name]
				elif input_payload.has(String(input_name)):
					var value: Variant = input_payload[String(input_name)]
					output_payload[String(output_name)] = value.duplicate(true) if value is Array or value is Dictionary else value
		var relay_event := StringName("relay:" + String(relay))
		if not field_map.is_empty() and not _mapped_payload_matches_schema(engine, relay_event, output_payload):
			return
		var callboard: Dictionary = c.get("_callboard", {})
		var run: Dictionary = callboard.get("run", {})
		engine.fire_from_context(relay_event, output_payload, run.get("context", {})))
	step.emits = relay
	step.emit_arg = 0
	return step

func _is_payload_field_name(value: Variant) -> bool:
	return value is String or value is StringName

func _mapped_payload_matches_schema(engine: RuleEngine, relay_event: StringName,
		payload: Dictionary) -> bool:
	var schema: Dictionary = engine.payload_schema.get(relay_event, {})
	if schema.is_empty():
		return true
	for field: Variant in payload:
		var key := StringName(String(field))
		if not schema.has(key):
			push_warning("Callboard emit_relay skipped: output field '%s' is not declared for '%s'." % [key, relay_event])
			return false
		var expected_type: int = schema[key]
		var actual_type := typeof(payload[field])
		if expected_type == TYPE_FLOAT and actual_type == TYPE_INT:
			payload[field] = float(payload[field])
		elif expected_type != TYPE_NIL and actual_type != expected_type:
			push_warning("Callboard emit_relay skipped: output field '%s' has type %s, expected %s for '%s'." % [
				key, type_string(actual_type), type_string(expected_type), relay_event])
			return false
	return true

## Wait for a future Call or relay on this Stage. The optional payload guard
## checks the incoming event. A timeout ends the rule and can emit a relay.
func wait_for_call(event: StringName, payload_guard: StringName = &"", timeout: float = 0.0,
		timeout_relay: StringName = &"") -> Step:
	var engine_ref := context.engine_ref
	var step := Step.new(func(c: Dictionary) -> void:
		var engine := engine_ref.get_ref() as RuleEngine
		var callboard: Dictionary = c["_callboard"]
		var rule: Rule = callboard["rule"]
		if engine != null:
			var completion := engine.wait_for_call(event, payload_guard, timeout, rule.id, callboard["run"])
			engine = null
			if not completion.is_null():
				await completion)
	step.wait_event = event
	step.emits = timeout_relay
	step.emit_arg = 3
	return step

## Continue immediately if the guard passes, or recheck after Blackboard writes.
func wait_until(condition: StringName, timeout: float = 0.0, timeout_relay: StringName = &"") -> Step:
	var engine_ref := context.engine_ref
	var step := Step.new(func(c: Dictionary) -> void:
		var engine := engine_ref.get_ref() as RuleEngine
		var callboard: Dictionary = c["_callboard"]
		var rule: Rule = callboard["rule"]
		if engine != null:
			var completion := engine.wait_until(condition, timeout, rule.id, callboard["run"])
			engine = null
			if not completion.is_null():
				await completion)
	step.reads.append_array(GuardExpression.referenced_keys(condition))
	step.emits = timeout_relay
	step.emit_arg = 2
	return step

## Stops when the running rule is cancelled or its engine deactivates.
func repeat_emit(interval: float, tick: StringName) -> Step:
	var ctx := context
	var run := func(c: Dictionary) -> void:
		var callboard: Dictionary = c["_callboard"]
		var rule: Rule = callboard["rule"]
		var authored_payload: Dictionary = c["payload"]
		var engine := ctx.engine_ref.get_ref() as RuleEngine
		if not engine:
			return
		var gen := engine.token()
		while engine.alive(rule, gen):
			var run_state: Dictionary = callboard["run"]
			var cancellation: RuleEngine.AwaitedSignal = run_state["cancel_signal"]
			var timeout := engine.interruptible(
				engine.wait_tracked(interval, rule.id, "repeat_emit loop"), Callable(),
				[cancellation.cancelled], run_state, true)
			engine = null
			await timeout
			engine = ctx.engine_ref.get_ref() as RuleEngine
			if not engine or not engine.alive(rule, gen):
				return
			engine.fire("relay:" + tick, authored_payload)
	var step := Step.new(run)
	step.emits = tick
	step.emit_arg = 1
	return step
