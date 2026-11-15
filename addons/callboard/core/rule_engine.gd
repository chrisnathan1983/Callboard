@tool
class_name RuleEngine extends RefCounted

const TriggerRoutingData = preload("res://addons/callboard/core/trigger_routing_data.gd")

signal rule_fired(rule_id: StringName, event: StringName)
signal trace_event(entry: Dictionary)
signal pending_changed(entries: Array)
signal run_cancelled(rule_id: StringName)
signal all_cancelled
signal dispatch_limit_reached(limit: String, event_chain: PackedStringArray, rule_id: StringName)
signal _event_received(event: StringName, payload: Dictionary)

class AwaitedSignal extends RefCounted:
	signal completed
	signal cancelled
	var is_complete := false

# Branches copy their run dictionaries for wait results. They share this
# lifetime so temporary host effects belong to the whole rule invocation.
class RunLifetime extends AwaitedSignal:
	signal ended
	var is_ended := false
	var main_done := false
	var background_branches := 0
	var cancel_if_watch_id := -1

var rules: Array[Rule] = []
var fired: Dictionary                 # injected, latches one-shot rules
var bb: Blackboard
var payload_schema: Dictionary = {}
## Only configured triggers appear here; absent triggers keep multi-match dispatch.
var trigger_routing: Dictionary = {}
## Managed Stages inject a stable per-instance dictionary from StageStateStore.
var random_group_states: Dictionary = {}
var wait: Callable                    # func(seconds: float) -> Signal; tests swap this
var _gen := 0
var _active := {}                      # Rule -> pending payloads and restart request
var _cancelling_all := false
var _pending_waits: Dictionary = {}
var _pending_callbacks: Dictionary = {}
var _awaited_signals: Dictionary = {}
var _tracked_wait_ids: Dictionary = {}
var _cancel_if_callbacks: Dictionary = {}
var _event_context_stack: Array[Dictionary] = []
var _next_wait_id := 1
const MAX_FIRE_DEPTH := 64
const MAX_PENDING_PER_RULE := 128
const MAX_DISPATCHES_PER_FRAME := 256
var _dispatch_frame := -1
var _dispatches_this_frame := 0

func _init(p_bb: Blackboard, p_fired: Dictionary, p_wait: Callable) -> void:
	bb = p_bb
	fired = p_fired
	wait = p_wait

func token() -> int: return _gen

## Advance an injected manual test clock. Returns false for normal runtime clocks.
func advance_test_time(seconds: float) -> bool:
	var clock := wait.get_object()
	if not is_instance_valid(clock) or not clock.has_method("advance"):
		return false
	clock.call("advance", seconds)
	pending_changed.emit(pending_snapshot())
	return true

func has_test_clock() -> bool:
	var clock := wait.get_object()
	return is_instance_valid(clock) and clock.has_method("advance")

func cancel_all() -> void:
	if _cancelling_all:
		return
	_cancelling_all = true
	_gen += 1
	all_cancelled.emit()
	for active: Dictionary in _active.values():
		var run: Dictionary = active.get("run", {})
		if run.is_empty():
			continue
		run["cancelled"] = true
		var lifetime: RunLifetime = run["cancel_signal"]
		_end_run_lifetime(lifetime)
		lifetime.cancelled.emit()
	_active.clear()
	_pending_waits.clear()
	for tracker in _pending_callbacks.values():
		var tracked_signal: Signal = tracker["signal"]
		var callback: Callable = tracker["callback"]
		var tracked_object := tracked_signal.get_object()
		if is_instance_valid(tracked_object) and tracked_signal.is_connected(callback):
			tracked_signal.disconnect(callback)
	_pending_callbacks.clear()
	for watcher in _cancel_if_callbacks.values():
		var watched_signal: Signal = watcher["signal"]
		var watch_callback: Callable = watcher["callback"]
		if watched_signal.is_connected(watch_callback):
			watched_signal.disconnect(watch_callback)
	_cancel_if_callbacks.clear()
	_tracked_wait_ids.clear()
	pending_changed.emit(pending_snapshot())
	var cancelled := _awaited_signals.values()
	_awaited_signals.clear()
	for entry: Dictionary in cancelled:
		_disconnect_wait_connections(entry)
		entry["completion"].completed.emit()
	_cancelling_all = false

func fire(event: StringName, payload := {}) -> void:
	var context := {"path": []}
	if not _event_context_stack.is_empty():
		context = _event_context_stack.back()
	_fire(event, payload, context)

## Carry an existing ancestry into public gameplay or host callbacks after a yield.
func fire_from_context(event: StringName, payload: Dictionary, context: Dictionary) -> void:
	_fire(event, payload, context)

func _fire(event: StringName, payload: Dictionary, parent_context: Dictionary) -> void:
	if _cancelling_all:
		return
	var path: Array = parent_context.get("path", []).duplicate()
	path.append(String(event))
	var depth := path.size()
	if depth > MAX_FIRE_DEPTH:
		_report_dispatch_limit("event depth", path)
		return
	var context := {"path": path}
	var gen := _gen
	_event_context_stack.append(context)
	_event_received.emit(event, payload)
	_emit_trace("event_fired", &"", event)
	_event_context_stack.pop_back()
	var candidates: Array[Rule] = []
	for candidate: Rule in rules:
		if candidate.trigger == event:
			candidates.append(candidate)
	var matching_rule_count := candidates.size()
	var rule_order := 0
	var routing: Dictionary = trigger_routing.get(event, {})
	var first_match := int(routing.get("mode", TriggerRoutingData.Mode.MULTI_MATCH)) == TriggerRoutingData.Mode.FIRST_MATCH
	var fallback_id := StringName(routing.get("fallback_rule_id", &"")) if first_match else &""
	var fallback_rule: Rule
	var matched := false
	for r in candidates:
		if gen != _gen:
			return
		rule_order += 1
		if first_match and r.id == fallback_id:
			fallback_rule = r
			continue
		if not _evaluate_rule(r, payload, event, rule_order, matching_rule_count):
			continue
		if not _consume_dispatch_budget(context):
			return
		_dispatch(r, event, payload.duplicate(true), gen, depth, context,
			rule_order, matching_rule_count)
		if first_match:
			matched = true
			break
	if first_match and not matched and fallback_rule != null and gen == _gen:
		var fallback_order := candidates.find(fallback_rule) + 1
		if _evaluate_rule(fallback_rule, payload, event, fallback_order, matching_rule_count):
			if _consume_dispatch_budget(context):
				_dispatch(fallback_rule, event, payload.duplicate(true), gen, depth, context,
					fallback_order, matching_rule_count)

func _dispatch(r: Rule, event: StringName, payload: Dictionary, gen: int, depth: int,
		context: Dictionary, rule_order: int, matching_rule_count: int) -> void:
	if _active.has(r):
		var active: Dictionary = _active[r]
		match r.reentry:
			Rule.ReentryPolicy.RESTART:
				_trace_reentry_decision(r, event, rule_order, matching_rule_count,
					"restart", "active run cancelled and latest Call will replace it")
				active["restart"] = true
				var current_run: Dictionary = active.get("run", {})
				current_run["cancelled"] = true
				var pending: Array = active["pending"]
				pending.clear()
				pending.append({"payload": payload.duplicate(true), "depth": depth,
					"context": context, "event": event})
				active["pending"] = pending
				_active[r] = active
				# The suspended dispatch can resume synchronously when cancelled is
				# emitted, so publish the replacement before waking the old run.
				_signal_run_cancelled(current_run, r.id)
				var lifetime: RunLifetime = current_run["cancel_signal"]
				_end_run_lifetime(lifetime)
				lifetime.cancelled.emit()
			Rule.ReentryPolicy.QUEUE:
				var pending: Array = active["pending"]
				if pending.size() >= MAX_PENDING_PER_RULE:
					_trace_reentry_decision(r, event, rule_order, matching_rule_count,
						"drop", "pending queue is full (%d)" % MAX_PENDING_PER_RULE)
					_report_dispatch_limit("pending queue", context.get("path", []), r.id)
					return
				pending.append({"payload": payload.duplicate(true), "depth": depth,
					"context": context, "event": event})
				active["pending"] = pending
				_active[r] = active
				_trace_reentry_decision(r, event, rule_order, matching_rule_count,
					"queue", "queued Call %d of %d" % [pending.size(), MAX_PENDING_PER_RULE])
			Rule.ReentryPolicy.IGNORE:
				_trace_reentry_decision(r, event, rule_order, matching_rule_count,
					"ignore", "active run kept; new Call discarded")
		return

	var active := {"pending": [], "restart": false}
	_active[r] = active
	await _run(r, event, payload, gen, depth, context, rule_order, matching_rule_count)
	while gen == _gen and is_same(_active.get(r), active) and not active["pending"].is_empty():
		var next: Dictionary = active["pending"].pop_front()
		active["restart"] = false
		active.erase("run")
		var next_payload: Dictionary = next["payload"]
		var next_event: StringName = next.get("event", event)
		var queued_order := _rule_order(r, next_event)
		var queued_total := _matching_rule_count(next_event)
		if _evaluate_rule(r, next_payload, next_event, queued_order, queued_total) and alive(r, gen, next_payload):
			await _run(r, next_event, next_payload, gen, int(next["depth"]), next["context"],
				queued_order, queued_total)
	if gen == _gen and is_same(_active.get(r), active):
		_active.erase(r)

func _run(rule: Rule, event: StringName, payload: Dictionary, generation: int, depth: int,
		context: Dictionary, rule_order: int, matching_rule_count: int) -> void:
	if generation != _gen or rule.cancel_if.any(func(guard: StringName) -> bool:
		return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())):
		return
	var lifetime := RunLifetime.new()
	var run := {
		"cancelled": false,
		"cancel_signal": lifetime,
		"payload": payload.duplicate(true),
		"event": event,
		"depth": depth,
		"context": context,
	}
	_active[rule]["run"] = run
	_watch_cancel_if(rule, run, generation, payload, event)
	if rule.one_shot:
		fired[rule.latch_key()] = true
	_event_context_stack.append(context)
	_emit_trace("rule_started", rule.id, event, -1, null, "",
		{"order": rule_order, "trigger_rule_count": matching_rule_count,
			"latch_key": String(rule.latch_key()), "latch_set": rule.one_shot and fired.has(rule.latch_key()),
			"one_shot": rule.one_shot,
			"reentry_policy": _reentry_policy_name(rule.reentry)})
	rule_fired.emit(rule.id, event)
	_event_context_stack.pop_back()
	if not alive(rule, generation):
		_cancel_run(run, rule.id, event)
		return
	var step_payload := payload.duplicate(true)
	step_payload["payload"] = payload.duplicate(true)
	step_payload["_callboard"] = {"rule": rule, "run": run}
	var outcome: Dictionary = await _run_steps(rule.steps, rule, event, payload,
		generation, context, step_payload, run, 0, true)
	if not outcome.get("completed", false):
		if outcome.get("timed_out", false):
			run["cancelled"] = true
			_end_run_lifetime(lifetime)
			lifetime.cancelled.emit()
			_finish_main_run(lifetime)
			var timeout_step: Step = outcome.get("step")
			if timeout_step != null and not timeout_step.emits.is_empty():
				_fire("relay:" + timeout_step.emits, payload, context)
			return
		var failed_step: Step = outcome.get("step")
		_cancel_run(run, rule.id, event, int(outcome.get("index", -1)), failed_step)
		_finish_main_run(lifetime)
		return
	if not rule.emits.is_empty():
		_fire("relay:" + rule.emits, payload, context)
	_emit_trace("rule_completed", rule.id, event)
	_finish_main_run(lifetime)
	# Keep the dispatch responsible for queued and replacement invocations
	# while unjoined branches are still using this run.
	if not lifetime.is_ended:
		await lifetime.ended

## Runs a sequential list. Parallel child sequences share the parent's run token,
## payload and cancellation signal, so Restart, Cancel If and Stage teardown own
## every branch uniformly.
func _run_steps(steps: Array, rule: Rule, event: StringName, payload: Dictionary,
		generation: int, context: Dictionary, step_payload: Dictionary, run: Dictionary,
		branch_id: int, is_main: bool) -> Dictionary:
	var lifetime: RunLifetime = run["cancel_signal"]
	for step_index in steps.size():
		var step: Step = steps[step_index]
		if lifetime.is_ended or not alive(rule, generation, payload):
			return {"completed": false, "index": step_index, "step": step}
		if step.delay > 0.0:
			_emit_branch_trace("delay_started", rule, event, step_index, step, branch_id, is_main,
				"%0.2fs" % step.delay)
			await interruptible(wait_tracked(step.delay, rule.id, "step delay"), Callable(),
				[lifetime.cancelled], run, true)
			if lifetime.is_ended or not alive(rule, generation, payload):
				return {"completed": false, "index": step_index, "step": step}
		if step.verb == &"conditional":
			var selected_branch := -1
			for branch_index in step.parallel_branches.size():
				if branch_index == step.default_branch_index:
					continue
				if branch_index < step.branch_conditions.size() and GuardExpression.evaluate(
						bb, step.branch_conditions[branch_index], payload, event, _payload_schema()):
					selected_branch = branch_index
					break
			if selected_branch < 0:
				selected_branch = step.default_branch_index
			if selected_branch < 0 or selected_branch >= step.parallel_branches.size():
				_emit_trace("branch_unmatched", rule.id, event, step_index, step,
					"no condition matched and no valid default branch exists")
				continue
			var condition := String(step.branch_conditions[selected_branch]) \
				if selected_branch < step.branch_conditions.size() else "Otherwise"
			_emit_trace("branch_selected", rule.id, event, step_index, step,
				"branch=%d; %s" % [selected_branch + 1,
				"Otherwise" if selected_branch == step.default_branch_index else condition])
			var branch_outcome: Dictionary = await _run_group_branch(
				step.parallel_branches[selected_branch], rule, event, payload, generation,
				context, step_payload, run, step_index, selected_branch)
			if not branch_outcome.get("completed", false):
				branch_outcome["index"] = step_index
				branch_outcome["step"] = branch_outcome.get("step", step)
				return branch_outcome
			continue
		if step.verb == &"random":
			var selected_branch := _choose_random_branch(step, rule, step_index)
			if selected_branch < 0:
				_emit_trace("branch_unmatched", rule.id, event, step_index, step,
					"random group has no selectable branches")
				continue
			_emit_trace("branch_selected", rule.id, event, step_index, step,
				"branch=%d; %s" % [selected_branch + 1,
					"uniform" if step.random_selection == 0 else "weighted"])
			var random_outcome: Dictionary = await _run_group_branch(
				step.parallel_branches[selected_branch], rule, event, payload, generation,
				context, step_payload, run, step_index, selected_branch)
			if not random_outcome.get("completed", false):
				random_outcome["index"] = step_index
				random_outcome["step"] = random_outcome.get("step", step)
				return random_outcome
			continue
		if step.verb == &"parallel":
			var branch_signals: Array[AwaitedSignal] = []
			for child_index in step.parallel_branches.size():
				var finished := AwaitedSignal.new()
				branch_signals.append(finished)
				if not step.join_parallel:
					lifetime.background_branches += 1
				_emit_trace("branch_started", rule.id, event, step_index, step,
					"branch=%d/%d; join=%s" % [child_index + 1, step.parallel_branches.size(), step.join_parallel])
				_run_parallel_branch(step.parallel_branches[child_index], rule, event, payload,
					generation, context, step_payload, run, step_index, child_index,
					finished, not step.join_parallel)
			if step.join_parallel:
				for branch_finished: AwaitedSignal in branch_signals:
					if not branch_finished.is_complete:
						await interruptible(branch_finished.completed, Callable(),
							[lifetime.cancelled], run, true)
				if lifetime.is_ended or not alive(rule, generation, payload):
					return {"completed": false, "index": step_index, "step": step}
			continue
		_emit_branch_trace("step_started", rule, event, step_index, step, branch_id, is_main)
		await step.fn.call(step_payload)
		if lifetime.is_ended or not alive(rule, generation, payload):
			return {"completed": false, "index": step_index, "step": step}
		var wait_outcome: String = run.get("wait_outcome", "")
		if not wait_outcome.is_empty():
			run.erase("wait_outcome")
			_emit_branch_trace("wait_" + wait_outcome, rule, event, step_index, step, branch_id, is_main)
			if lifetime.is_ended or not alive(rule, generation, payload):
				return {"completed": false, "index": step_index, "step": step}
			if wait_outcome == "timed_out":
				return {"completed": false, "timed_out": true, "index": step_index, "step": step}
		_emit_branch_trace("step_completed", rule, event, step_index, step, branch_id, is_main)
	return {"completed": true}

func _choose_random_branch(step: Step, rule: Rule, step_index: int) -> int:
	var count := step.parallel_branches.size()
	if count == 0:
		return -1
	var stable_id := step.group_id
	if stable_id.is_empty():
		stable_id = StringName("%s:%d" % [rule.latch_key(), step_index])
	var state_key := StringName("random:%s" % stable_id)
	var rng := RandomNumberGenerator.new()
	var stored_state: Variant = random_group_states.get(state_key)
	if stored_state is Dictionary and int(stored_state.get("seed", step.random_seed)) == step.random_seed:
		rng.state = int(stored_state.get("state", 0))
	else:
		rng.seed = step.random_seed
	var selected := 0
	if step.random_selection == 1:
		var total := 0.0
		for index in count:
			if index < step.branch_weights.size():
				total += maxf(0.0, step.branch_weights[index])
		if total <= 0.0:
			return -1
		var roll := rng.randf() * total
		for index in count:
			var weight := step.branch_weights[index] if index < step.branch_weights.size() else 0.0
			roll -= maxf(0.0, weight)
			if roll < 0.0:
				selected = index
				break
	else:
		selected = rng.randi_range(0, count - 1)
	random_group_states[state_key] = {"seed": step.random_seed, "state": rng.state}
	return selected

func _run_group_branch(steps: Array, rule: Rule, event: StringName, payload: Dictionary,
		generation: int, context: Dictionary, step_payload: Dictionary, run: Dictionary,
		group_index: int, branch_index: int) -> Dictionary:
	var branch_run := run.duplicate(false)
	branch_run.erase("wait_outcome")
	var branch_context := step_payload.duplicate(false)
	var callboard_context: Dictionary = branch_context.get("_callboard", {}).duplicate(false)
	callboard_context["run"] = branch_run
	branch_context["_callboard"] = callboard_context
	var outcome: Dictionary = await _run_steps(steps, rule, event, payload, generation,
		context, branch_context, branch_run, branch_index + 1, false)
	_emit_trace("branch_completed" if outcome.get("completed", false) else "branch_cancelled",
		rule.id, event, group_index, null,
		"branch=%d; %s" % [branch_index + 1,
		"completed" if outcome.get("completed", false) else "cancelled"])
	return outcome

func _run_parallel_branch(steps: Array, rule: Rule, event: StringName, payload: Dictionary,
		generation: int, context: Dictionary, step_payload: Dictionary, run: Dictionary,
		group_index: int, branch_index: int, finished: AwaitedSignal, background: bool) -> void:
	var branch_id := branch_index + 1
	var branch_context := step_payload.duplicate(false)
	# Wait results are branch-local; sharing the parent run dictionary would let
	# one branch's timeout accidentally end a sibling's sequence.
	var branch_run := run.duplicate(false)
	branch_run.erase("wait_outcome")
	var callboard_context: Dictionary = branch_context.get("_callboard", {}).duplicate(false)
	callboard_context["run"] = branch_run
	branch_context["_callboard"] = callboard_context
	var outcome: Dictionary = await _run_steps(steps, rule, event, payload, generation,
		context, branch_context, branch_run, branch_id, false)
	var detail := "branch=%d; %s" % [branch_id, "completed" if outcome.get("completed", false) else "cancelled"]
	_emit_trace("branch_completed" if outcome.get("completed", false) else "branch_cancelled",
		rule.id, event, group_index, null, detail)
	finished.is_complete = true
	finished.completed.emit()
	if background:
		var lifetime: RunLifetime = run["cancel_signal"]
		lifetime.background_branches -= 1
		_finish_run_if_idle(lifetime)

func _finish_main_run(lifetime: RunLifetime) -> void:
	lifetime.main_done = true
	_finish_run_if_idle(lifetime)

func _finish_run_if_idle(lifetime: RunLifetime) -> void:
	if lifetime.main_done and lifetime.background_branches == 0:
		_end_run_lifetime(lifetime)

func _end_run_lifetime(lifetime: RunLifetime) -> void:
	if lifetime == null or lifetime.is_ended:
		return
	lifetime.is_ended = true
	_release_cancel_if(lifetime)
	lifetime.ended.emit()

func _emit_branch_trace(kind: String, rule: Rule, event: StringName, step_index: int,
		step: Step, branch_id: int, is_main: bool, detail := "") -> void:
	var resolved := detail
	if not is_main:
		resolved = ("branch=%d" % branch_id) + ("; " + detail if not detail.is_empty() else "")
	_emit_trace(kind, rule.id, event, step_index, step, resolved)

func _cancel_run(run: Dictionary, rule_id: StringName, event: StringName,
		step_index := -1, step: Step = null) -> void:
	run["cancelled"] = true
	_end_run_lifetime(run.get("cancel_signal") as RunLifetime)
	var cancelled_signal: AwaitedSignal = run.get("cancel_signal") as AwaitedSignal
	if cancelled_signal != null:
		cancelled_signal.cancelled.emit()
	_signal_run_cancelled(run, rule_id)
	_emit_trace("rule_cancelled", rule_id, event, step_index, step)

func _signal_run_cancelled(run: Dictionary, rule_id: StringName) -> void:
	if run.get("cancel_notified", false):
		return
	run["cancel_notified"] = true
	run_cancelled.emit(rule_id)

func _watch_cancel_if(rule: Rule, run: Dictionary, generation: int,
		payload: Dictionary, event: StringName) -> void:
	if rule.cancel_if.is_empty():
		return
	var watch_id := _next_wait_id
	_next_wait_id += 1
	var lifetime: RunLifetime = run["cancel_signal"]
	var callback := func(_key: StringName, _value: Variant) -> void:
		if run.get("cancelled", false) or generation != _gen:
			return
		if rule.cancel_if.any(func(guard: StringName) -> bool:
			return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())):
			run["cancelled"] = true
			_signal_run_cancelled(run, rule.id)
			_end_run_lifetime(lifetime)
			lifetime.cancelled.emit()
	lifetime.cancel_if_watch_id = watch_id
	_cancel_if_callbacks[watch_id] = {"signal": bb.changed, "callback": callback}
	bb.changed.connect(callback)

func _release_cancel_if(lifetime: RunLifetime) -> void:
	var watch_id := lifetime.cancel_if_watch_id
	var watcher: Dictionary = _cancel_if_callbacks.get(watch_id, {})
	if not watcher.is_empty():
		var watched_signal: Signal = watcher["signal"]
		var callback: Callable = watcher["callback"]
		if watched_signal.is_connected(callback):
			watched_signal.disconnect(callback)
		_cancel_if_callbacks.erase(watch_id)
	lifetime.cancel_if_watch_id = -1

## Returns the engine's configured wait signal and publishes it to live diagnostics.
func wait_tracked(seconds: float, rule_id: StringName, label: String) -> Signal:
	var timeout: Signal = wait.call(seconds)
	var id := track_signal(timeout, rule_id, label, seconds)
	var signal_key := _signal_key(timeout)
	var ids: Array = _tracked_wait_ids.get(signal_key, [])
	ids.append(id)
	_tracked_wait_ids[signal_key] = ids
	return timeout

func wait_for_call(event: StringName, filter: StringName, seconds: float,
		rule_id: StringName, run: Dictionary) -> Signal:
	var matches := func(received: StringName, payload: Dictionary) -> bool:
		return received == event and (filter.is_empty() or
			GuardExpression.evaluate(bb, filter, payload, received, payload_schema))
	return _wait_for_match(_event_received, matches, seconds, rule_id, "wait for " + String(event), run)

## Wait for a matching arbitrary signal using the same timeout, cancellation, and diagnostics path.
func wait_for_signal(source: Signal, matches: Callable, seconds: float, rule_id: StringName,
		label: String, run: Dictionary, on_outcome: Callable = Callable()) -> Signal:
	return _wait_for_match(source, matches, seconds, rule_id, label, run, on_outcome)

func wait_until(condition: StringName, seconds: float, rule_id: StringName, run: Dictionary) -> Signal:
	var matches := func(..._change: Array) -> bool:
		return GuardExpression.evaluate(bb, condition, run["payload"], run["event"], payload_schema)
	if matches.call():
		run["wait_outcome"] = "matched"
		return Signal()
	return _wait_for_match(bb.changed, matches, seconds, rule_id, "wait until " + String(condition), run)

func _wait_for_match(source: Signal, matches: Callable, seconds: float, rule_id: StringName,
		label: String, run: Dictionary, on_outcome: Callable = Callable()) -> Signal:
	if run.get("cancelled", false):
		return Signal()
	var completion := AwaitedSignal.new()
	var id := completion.get_instance_id()
	var connections: Array[Dictionary] = []
	var settle := func(outcome: String) -> void:
		if run.has("wait_outcome") or (run.get("cancelled", false) and outcome != "cancelled"):
			return
		run["wait_outcome"] = outcome
		if on_outcome.is_valid():
			on_outcome.call(outcome)
		# Latch the first result now, then resume after the event or Blackboard
		# notification has finished dispatching and this step has begun awaiting.
		call_deferred("_complete_wait", id)
	var source_callback := func(...values: Array) -> void:
		if matches.callv(values):
			settle.call("matched")
	source.connect(source_callback)
	connections.append({"signal": source, "callback": source_callback})
	if seconds > 0.0:
		var timer: Signal = wait.call(seconds)
		var timeout_callback := func() -> void: settle.call("timed_out")
		timer.connect(timeout_callback)
		connections.append({"signal": timer, "callback": timeout_callback})
	var cancellation: AwaitedSignal = run["cancel_signal"]
	var cancel_callback := func() -> void:
		settle.call("cancelled")
	cancellation.cancelled.connect(cancel_callback)
	connections.append({"signal": cancellation.cancelled, "callback": cancel_callback})
	var tracked_id := _add_pending_wait(rule_id, label, seconds if seconds > 0.0 else -1.0)
	_awaited_signals[id] = {"connections": connections, "completion": completion, "tracked_id": tracked_id}
	pending_changed.emit(pending_snapshot())
	# A synchronous diagnostics listener can deactivate and release the wait.
	return completion.completed if _awaited_signals.has(id) else Signal()

## Completes when its source emits, its run is replaced, or the engine is deactivated.
## `completion_if` can ignore unrelated source emissions without dropping the wait.
func interruptible(source: Signal, completion_if := Callable(),
		cancel_on: Array[Signal] = [], run: Dictionary = {}, defer_cancel := false) -> Signal:
	var completion := AwaitedSignal.new()
	var id := completion.get_instance_id()
	var source_callback := func(...emitted_values: Array) -> void:
		if completion_if.is_valid() and not bool(completion_if.callv(emitted_values)):
			return
		_complete_wait(id)
	var connections: Array[Dictionary] = [{"signal": source, "callback": source_callback}]
	source.connect(source_callback)
	for cancel_signal: Signal in cancel_on:
		if cancel_signal.is_null():
			continue
		var cancel_callback := func(..._ignored: Array) -> void:
			if not run.is_empty():
				run["cancelled"] = true
			if defer_cancel:
				# Let multiple same-frame triggers coalesce before the suspended
				# dispatch consumes the replacement payload.
				call_deferred("_complete_wait", id)
			else:
				_complete_wait(id)
		connections.append({"signal": cancel_signal, "callback": cancel_callback})
		cancel_signal.connect(cancel_callback)
	var tracked_id := -1
	var signal_key := _signal_key(source)
	var tracked_ids: Array = _tracked_wait_ids.get(signal_key, [])
	if not tracked_ids.is_empty():
		tracked_id = int(tracked_ids.pop_front())
		if tracked_ids.is_empty():
			_tracked_wait_ids.erase(signal_key)
		else:
			_tracked_wait_ids[signal_key] = tracked_ids
	_awaited_signals[id] = {
		"connections": connections,
		"completion": completion,
		"tracked_id": tracked_id,
	}
	# A listener can restart the run while wait_tracked() publishes diagnostics,
	# before this cancellation connection has been installed. Defer completion so
	# the caller can begin awaiting the returned signal first.
	if run.get("cancelled", false):
		call_deferred("_complete_wait", id)
	return completion.completed

func _signal_key(signal_to_key: Signal) -> String:
	return "%d:%s" % [signal_to_key.get_object_id(), signal_to_key.get_name()]

func _complete_wait(id: int) -> void:
	var entry: Dictionary = _awaited_signals.get(id, {})
	_awaited_signals.erase(id)
	if not entry.is_empty():
		_disconnect_wait_connections(entry)
		var tracked_id := int(entry.get("tracked_id", -1))
		if tracked_id >= 0:
			_finish_tracked_signal(tracked_id)
		entry["completion"].completed.emit()

func _disconnect_wait_connections(entry: Dictionary) -> void:
	for connection: Dictionary in entry.get("connections", []):
		var source: Signal = connection["signal"]
		var callback: Callable = connection["callback"]
		var source_object := source.get_object()
		if is_instance_valid(source_object) and source.is_connected(callback):
			source.disconnect(callback)

## Tracks an awaited or non-blocking signal until it completes.
func track_signal(signal_to_track: Signal, rule_id: StringName, label: String, seconds := -1.0) -> int:
	var id := _add_pending_wait(rule_id, label, seconds)
	pending_changed.emit(pending_snapshot())
	var callback := func(..._emitted_values: Array) -> void: _finish_tracked_signal(id)
	_pending_callbacks[id] = {"signal": signal_to_track, "callback": callback}
	signal_to_track.connect(callback, CONNECT_ONE_SHOT)
	return id

func _add_pending_wait(rule_id: StringName, label: String, seconds: float) -> int:
	var id := _next_wait_id
	_next_wait_id += 1
	var clock := wait.get_object()
	var test_now := float(clock.call("time_seconds")) if is_instance_valid(clock) \
		and clock.has_method("time_seconds") else -1.0
	_pending_waits[id] = {
		"id": id,
		"rule": String(rule_id),
		"label": label,
		"started_ms": Time.get_ticks_msec(),
		"started_test_time": test_now,
		"duration": seconds,
	}
	return id

func pending_snapshot() -> Array:
	var now := Time.get_ticks_msec()
	var clock := wait.get_object()
	var test_now := float(clock.call("time_seconds")) if is_instance_valid(clock) \
		and clock.has_method("time_seconds") else -1.0
	var entries: Array = []
	for id in _pending_waits:
		var entry: Dictionary = _pending_waits[id].duplicate()
		var duration: float = entry["duration"]
		var elapsed := ((test_now - float(entry["started_test_time"])) if test_now >= 0.0
			and float(entry.get("started_test_time", -1.0)) >= 0.0
			else (now - int(entry["started_ms"])) / 1000.0)
		entry["remaining"] = maxf(0.0, duration - elapsed) if duration >= 0.0 else -1.0
		entries.append(entry)
	return entries

func active_snapshot() -> Array:
	var entries: Array = []
	for rule: Rule in _active:
		var active: Dictionary = _active[rule]
		entries.append({
			"rule": String(rule.id),
			"queued": active["pending"].size(),
			"restarting": active["restart"],
		})
	return entries

func _finish_tracked_signal(id: int) -> void:
	var callback_data: Dictionary = _pending_callbacks.get(id, {})
	if not callback_data.is_empty():
		var signal_to_track: Signal = callback_data["signal"]
		var callback: Callable = callback_data["callback"]
		var tracked_object := signal_to_track.get_object()
		if is_instance_valid(tracked_object) and signal_to_track.is_connected(callback):
			signal_to_track.disconnect(callback)
	_pending_callbacks.erase(id)
	if _pending_waits.erase(id):
		pending_changed.emit(pending_snapshot())

func _emit_trace(kind: String, rule_id: StringName, event: StringName,
		step_index := -1, step: Step = null, detail := "", metadata: Dictionary = {}) -> void:
	var entry := {
		"time_ms": Time.get_ticks_msec(),
		"kind": kind,
		"rule": String(rule_id),
		"event": String(event),
		"step": step_index + 1 if step_index >= 0 else 0,
		"verb": String(step.verb) if step != null else "",
		"relay": String(step.emits) if step != null else "",
		"relay_argument": step.emit_arg if step != null else -1,
		"detail": detail,
	}
	entry.merge(metadata, true)
	trace_event.emit(entry)

## Record the result of a store-mediated event send on the source Stage's trace.
func trace_cross_stage_dispatch(event_id: StringName, rule_id: StringName,
		target_instance_id: StringName, delivered_count: int) -> void:
	var route := "broadcast" if target_instance_id.is_empty() else "target=" + String(target_instance_id)
	_emit_trace("cross_stage_sent", rule_id, event_id, -1, null,
		"%s; recipients=%d" % [route, delivered_count])

func _consume_dispatch_budget(context: Dictionary) -> bool:
	var frame := Engine.get_process_frames()
	if frame != _dispatch_frame:
		_dispatch_frame = frame
		_dispatches_this_frame = 0
	if _dispatches_this_frame >= MAX_DISPATCHES_PER_FRAME:
		_report_dispatch_limit("per-frame dispatch budget", context.get("path", []))
		return false
	_dispatches_this_frame += 1
	return true

func _report_dispatch_limit(limit: String, path: Array, rule_id: StringName = &"") -> void:
	var chain := PackedStringArray()
	for event in path:
		chain.append(String(event))
	dispatch_limit_reached.emit(limit, chain, rule_id)
	var suffix := " while dispatching rule '%s'" % rule_id if not rule_id.is_empty() else ""
	push_error("Callboard stopped %s%s. Event chain: %s" % [limit, suffix, " -> ".join(chain)])

func _evaluate_rule(r: Rule, payload: Dictionary, event: StringName,
		rule_order: int, matching_rule_count: int) -> bool:
	var latch_key := r.latch_key()
	var latch_set := r.one_shot and fired.has(latch_key)
	if latch_set:
		_trace_rule_rejection(r, event, rule_order, matching_rule_count,
			"one-shot latch is already set", "", [])
		return false
	for guard: StringName in r.requires:
		var diagnostic := GuardExpression.diagnose(bb, guard, payload, event, _payload_schema())
		if not diagnostic["passed"]:
			_trace_rule_rejection(r, event, rule_order, matching_rule_count,
				"required guard failed", String(guard), diagnostic["observations"])
			return false
	for guard: StringName in r.forbids:
		var diagnostic := GuardExpression.diagnose(bb, guard, payload, event, _payload_schema())
		if diagnostic["passed"]:
			_trace_rule_rejection(r, event, rule_order, matching_rule_count,
				"forbidden guard matched", String(guard), diagnostic["observations"])
			return false
	for guard: StringName in r.cancel_if:
		var diagnostic := GuardExpression.diagnose(bb, guard, payload, event, _payload_schema())
		if diagnostic["passed"]:
			_trace_rule_rejection(r, event, rule_order, matching_rule_count,
				"Cancel If guard matched before start", String(guard), diagnostic["observations"])
			return false
	return true

func _trace_rule_rejection(r: Rule, event: StringName, rule_order: int,
		matching_rule_count: int, reason: String, guard: String,
		observations: Array) -> void:
	var detail := reason
	if not guard.is_empty():
		detail += ": %s" % guard
	var observed: PackedStringArray = []
	for item: Dictionary in observations:
		observed.append("%s [%s]" % [item.get("detail", ""),
			"pass" if item.get("passed", false) else "fail"])
	if not observed.is_empty():
		detail += " (%s)" % "; ".join(observed)
	_emit_trace("rule_rejected", r.id, event, -1, null, detail, {
		"order": rule_order,
		"trigger_rule_count": matching_rule_count,
		"reason": reason,
		"guard": guard,
		"observations": observations.duplicate(true),
		"latch_key": String(r.latch_key()),
		"latch_set": r.one_shot and fired.has(r.latch_key()),
		"one_shot": r.one_shot,
		"reentry_policy": _reentry_policy_name(r.reentry),
	})

func _trace_reentry_decision(r: Rule, event: StringName, rule_order: int,
		matching_rule_count: int, decision: String, detail: String) -> void:
	_emit_trace("reentry_decision", r.id, event, -1, null,
		"%s: %s" % [decision, detail], {
			"order": rule_order,
			"trigger_rule_count": matching_rule_count,
			"decision": decision,
			"latch_key": String(r.latch_key()),
			"latch_set": r.one_shot and fired.has(r.latch_key()),
			"one_shot": r.one_shot,
			"reentry_policy": _reentry_policy_name(r.reentry),
		})

func _reentry_policy_name(policy: int) -> String:
	match policy:
		Rule.ReentryPolicy.RESTART: return "Restart"
		Rule.ReentryPolicy.QUEUE: return "Queue"
		_: return "Ignore"

func _matching_rule_count(event: StringName) -> int:
	var count := 0
	for candidate: Rule in rules:
		if candidate.trigger == event:
			count += 1
	return count

func _rule_order(rule: Rule, event: StringName) -> int:
	var order := 0
	for candidate: Rule in rules:
		if candidate.trigger != event:
			continue
		order += 1
		if candidate == rule:
			return order
	return 0

func passes(r: Rule, payload: Dictionary = {}, event: StringName = &"") -> bool:
	if r.one_shot and fired.has(r.latch_key()): return false
	return (r.requires.all(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema()))
		and not r.forbids.any(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema()))
		and not r.cancel_if.any(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())))

func alive(r: Rule, gen: int, payload: Dictionary = {}) -> bool:
	var active_run: Dictionary = _active.get(r, {}).get("run", {})
	if payload.is_empty() and _active.has(r):
		payload = active_run.get("payload", {})
	var event: StringName = _active.get(r, {}).get("run", {}).get("event", r.trigger)
	return (gen == _gen and not active_run.get("cancelled", false)
		and not _active.get(r, {}).get("restart", false)
		and not r.cancel_if.any(func(guard: StringName) -> bool: return GuardExpression.evaluate(bb, guard, payload, event, _payload_schema())))

func _payload_schema() -> Dictionary:
	return payload_schema
