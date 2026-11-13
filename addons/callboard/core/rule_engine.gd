@tool
class_name RuleEngine extends RefCounted

signal rule_fired(rule_id: StringName, event: StringName)
signal trace_event(entry: Dictionary)
signal pending_changed(entries: Array)

var rules: Array[Rule] = []
var fired: Dictionary                 # injected, latches one-shot rules
var bb: Blackboard
var wait: Callable                    # func(seconds: float) -> Signal; tests swap this
var _gen := 0
var _active := {}                      # Rule -> pending payloads and restart request
var _pending_waits: Dictionary = {}
var _pending_callbacks: Dictionary = {}
var _next_wait_id := 1

func _init(p_bb: Blackboard, p_fired: Dictionary, p_wait: Callable) -> void:
	bb = p_bb
	fired = p_fired
	wait = p_wait

func token() -> int: return _gen
func cancel_all() -> void:
	_gen += 1
	_active.clear()
	_pending_waits.clear()
	for tracker in _pending_callbacks.values():
		var tracked_signal: Signal = tracker["signal"]
		var callback: Callable = tracker["callback"]
		if tracked_signal.is_connected(callback):
			tracked_signal.disconnect(callback)
	_pending_callbacks.clear()
	pending_changed.emit(pending_snapshot())

func fire(event: StringName, ctx := {}) -> void:
	_emit_trace("event_fired", &"", event)
	var gen := _gen
	for r in rules:
		if gen != _gen:
			return
		if r.trigger == event and passes(r):
			_dispatch(r, event, ctx, gen)

func _dispatch(r: Rule, event: StringName, ctx: Dictionary, gen: int) -> void:
	if _active.has(r):
		var active: Dictionary = _active[r]
		var pending: Array[Dictionary] = active["pending"]
		match r.reentry:
			Rule.ReentryPolicy.RESTART:
				active["restart"] = true
				pending.clear()
				pending.append(ctx.duplicate(true))
			Rule.ReentryPolicy.QUEUE:
				pending.append(ctx.duplicate(true))
		return

	var pending: Array[Dictionary] = []
	var active := {"pending": pending, "restart": false}
	_active[r] = active
	await _run(r, event, ctx, gen)
	while gen == _gen and not pending.is_empty():
		var next: Dictionary = pending.pop_front()
		active["restart"] = false
		if passes(r) and alive(r, gen):
			await _run(r, event, next, gen)
	if gen == _gen:
		_active.erase(r)

func _run(r: Rule, event: StringName, ctx: Dictionary, gen: int) -> void:
	if r.one_shot:
		fired[r.latch_key()] = true
	_emit_trace("rule_started", r.id, event)
	rule_fired.emit(r.id, event)
	if not alive(r, gen):
		_emit_trace("rule_cancelled", r.id, event)
		return
	var c := ctx.merged({"_rule": r}, true)
	for i in r.steps.size():
		var s: Step = r.steps[i]
		if s.delay > 0.0:
			_emit_trace("delay_started", r.id, event, i, s, "%0.2fs" % s.delay)
			await wait_tracked(s.delay, r.id, "step delay")
			if not alive(r, gen):
				_emit_trace("rule_cancelled", r.id, event, i, s)
				return
		_emit_trace("step_started", r.id, event, i, s)
		await s.fn.call(c)
		if not alive(r, gen):
			_emit_trace("rule_cancelled", r.id, event, i, s)
			return
		_emit_trace("step_completed", r.id, event, i, s)
	if r.emits != &"":
		fire("relay:" + r.emits, ctx)
	_emit_trace("rule_completed", r.id, event)

## Returns the engine's configured wait signal and publishes it to live diagnostics.
func wait_tracked(seconds: float, rule_id: StringName, label: String) -> Signal:
	var timeout: Signal = wait.call(seconds)
	track_signal(timeout, rule_id, label, seconds)
	return timeout

## Tracks an awaited or non-blocking signal until it completes.
func track_signal(signal_to_track: Signal, rule_id: StringName, label: String, seconds := -1.0) -> void:
	var id := _next_wait_id
	_next_wait_id += 1
	_pending_waits[id] = {
		"id": id,
		"rule": String(rule_id),
		"label": label,
		"started_ms": Time.get_ticks_msec(),
		"duration": seconds,
	}
	pending_changed.emit(pending_snapshot())
	var callback := func() -> void: _finish_tracked_signal(id)
	_pending_callbacks[id] = {"signal": signal_to_track, "callback": callback}
	signal_to_track.connect(callback, CONNECT_ONE_SHOT)

func pending_snapshot() -> Array:
	var now := Time.get_ticks_msec()
	var entries: Array = []
	for id in _pending_waits:
		var entry: Dictionary = _pending_waits[id].duplicate()
		var duration: float = entry["duration"]
		entry["remaining"] = maxf(0.0, duration - (now - entry["started_ms"]) / 1000.0) if duration >= 0.0 else -1.0
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
	_pending_callbacks.erase(id)
	if _pending_waits.erase(id):
		pending_changed.emit(pending_snapshot())

func _emit_trace(kind: String, rule_id: StringName, event: StringName,
		step_index := -1, step: Step = null, detail := "") -> void:
	trace_event.emit({
		"time_ms": Time.get_ticks_msec(),
		"kind": kind,
		"rule": String(rule_id),
		"event": String(event),
		"step": step_index + 1 if step_index >= 0 else 0,
		"verb": String(step.verb) if step != null else "",
		"detail": detail,
	})

func passes(r: Rule) -> bool:
	if r.one_shot and fired.has(r.latch_key()): return false
	return r.requires.all(bb.is_set) and not r.forbids.any(bb.is_set)

func alive(r: Rule, gen: int) -> bool:
	return gen == _gen and not _active.get(r, {}).get("restart", false) and not r.cancel_if.any(bb.is_set)
