@tool
class_name RuleEngine extends RefCounted

signal rule_fired(rule_id: StringName, event: StringName)

var rules: Array[Rule] = []
var fired: Dictionary                 # injected, latches one-shot rules
var bb: Blackboard
var wait: Callable                    # func(seconds: float) -> Signal; tests swap this
var _gen := 0
var _active := {}                      # Rule -> pending payloads and restart request

func _init(p_bb: Blackboard, p_fired: Dictionary, p_wait: Callable) -> void:
	bb = p_bb
	fired = p_fired
	wait = p_wait

func token() -> int: return _gen
func cancel_all() -> void:
	_gen += 1
	_active.clear()

func fire(event: StringName, ctx := {}) -> void:
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
	rule_fired.emit(r.id, event)
	if not alive(r, gen):
		return
	var c := ctx.merged({"_rule": r}, true)
	for s in r.steps:
		if s.delay > 0.0:
			await wait.call(s.delay)
			if not alive(r, gen): return
		await s.fn.call(c)
		if not alive(r, gen): return
	if r.emits != &"":
		fire("relay:" + r.emits, ctx)

func passes(r: Rule) -> bool:
	if r.one_shot and fired.has(r.latch_key()): return false
	return r.requires.all(bb.is_set) and not r.forbids.any(bb.is_set)

func alive(r: Rule, gen: int) -> bool:
	return gen == _gen and not _active.get(r, {}).get("restart", false) and not r.cancel_if.any(bb.is_set)
