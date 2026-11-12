## Migration status

- [x] Delegate Blackboard storage and validation from `Zone`.
- [x] Route live rules and editor previews through `RuleEngine`.
- [x] Extract `CoreVerbs` and `StagingVerbs` with a per-zone factory hook. Compile resource step metadata from authored arguments.
- [x] Preserve script-authored rules through the `Zone` facade and cover both authoring paths in tests.

The proposal below records the original design. The sample zone uses the default staging factory. Registered verb resources remain a possible follow-up.

I'd split it along its dependency lines. Right now `Zone` is five things at once:

| Concern | Currently in `Zone` | Needs |
|---|---|---|
| Blackboard | `schema`, `local_vars`, `saved_vars`, `define_*`, `get/write/is_set` | nothing |
| Rule engine | `rules`, `fire`, `_run`, `passes`, `alive`, `_gen`, `fired` | blackboard, a timer |
| Validator | `validate()` | rules, blackboard |
| Verbs | `show_node` … `repeat_emit` | tree (tweens), blackboard, engine |
| Host/lifecycle | `build`, `_build_props`, `activate`, `_restore_state` | everything above |

## Target structure

```
Blackboard (RefCounted)  ←──  RuleEngine (RefCounted)  ←──  Verbs (RefCounted)
        ↑                            ↑                           ↑
        └────────────  Zone (Node3D): wires it all together  ────┘
RuleValidator (static): reads rules + blackboard, depends on nothing live
```

Nothing in the lower layers knows about `Node3D` or `Zone`, and the arrows never loop.

### 1. Blackboard

This is a pure move, with the same logic and a signal on the object itself.

```gdscript
class_name Blackboard extends RefCounted

signal changed(key: StringName, value: Variant)

var schema := {}
var local := {}
var saved: Dictionary          # injected by the manager

func _init(p_saved := {}) -> void:
	saved = p_saved

func define(key: StringName, scope: StringName, default: Variant) -> void:
	schema[key] = {"scope": scope, "default": default}
	if scope == &"saved":
		if not saved.has(key): saved[key] = default
	else:
		local[key] = default

func get_var(key: StringName) -> Variant:
	return saved.get(key) if schema.get(key, {}).get("scope") == &"saved" else local.get(key)

func write(key: StringName, value: Variant) -> void:
	assert(schema.has(key) or OS.is_debug_build() == false, "Undeclared key '%s'" % key)
	(saved if schema.get(key, {}).get("scope") == &"saved" else local)[key] = value
	changed.emit(key, value)

func is_set(key: StringName) -> bool:
	return bool(get_var(key))
```

This replaces `_saved_keys` with the schema as the single source of truth. It also gives you the debug assert for undeclared keys that I mentioned earlier.

### 2. RuleEngine

The engine takes its timer as an injected `Callable`, which is what makes it testable without waiting real seconds.

```gdscript
class_name RuleEngine extends RefCounted

signal rule_fired(rule_id: StringName, event: StringName)

var rules: Array[Rule] = []
var fired: Dictionary                 # injected, latches `once`
var bb: Blackboard
var wait: Callable                    # func(seconds: float) -> Signal; tests swap this
var _gen := 0

func _init(p_bb: Blackboard, p_fired: Dictionary, p_wait: Callable) -> void:
	bb = p_bb; fired = p_fired; wait = p_wait

func token() -> int: return _gen
func cancel_all() -> void: _gen += 1

func fire(event: StringName, ctx := {}) -> void:
	for r in rules:
		if r.trigger == event and passes(r):
			_run(r, event, ctx)

func _run(r: Rule, event: StringName, ctx: Dictionary) -> void:
	if r.once: fired[r.id] = true
	rule_fired.emit(r.id, event)
	var gen := _gen
	var c := ctx.merged({"_rule": r})
	for s in r.steps:
		if s.delay > 0.0:
			await wait.call(s.delay)
			if not alive(r, gen): return
		await s.fn.call(c)
		if not alive(r, gen): return
	if r.emits != &"":
		fire("relay:" + r.emits, ctx)

func passes(r: Rule) -> bool:
	if r.once and fired.has(r.id): return false
	return r.requires.all(bb.is_set) and not r.forbids.any(bb.is_set)

func alive(r: Rule, gen: int) -> bool:
	return gen == _gen and not r.cancel_if.any(bb.is_set)
```

In the game, `wait` is `func(s): return tree.create_timer(s).timeout`. In tests it's a fake clock you advance manually, which removes the 4-second sleeps from the smoke test.

### 3. RuleValidator

```gdscript
class_name RuleValidator extends RefCounted

static func validate(rules: Array[Rule], bb: Blackboard,
		external_events: Array[StringName], external_vars: Array[StringName]) -> Array[String]:
	# body of today's Zone.validate(), plus the new cycle / shared-trigger checks
```

It's static and takes plain data, so unit tests can feed it hand-built rules.

### 4. Verbs

Verbs currently close over `self` (the zone). Have them close over a small context instead:

```gdscript
class_name StepContext extends RefCounted
var bb: Blackboard
var engine: RuleEngine
var host: Node            # for create_tween(), get_tree()
var scored: Signal        # or a Callable
```

```gdscript
class_name CoreVerbs extends StepFactory   # StepFactory holds `ctx` and the _step() helper

func set_var(key: StringName, value: Variant = true) -> Step:
	var s := _step(&"set_var", [key, value], func(_c) -> void: ctx.bb.write(key, value))
	s.sets = [key]
	return s

func repeat_emit(interval: float, tick: StringName) -> Step: ...  # uses ctx.engine
```

```gdscript
class_name StagingVerbs extends CoreVerbs  # show_node, pop, bounce, say, move_to, flash, jump, light, stun_player
class_name Zone01Verbs extends StagingVerbs  # zone-specific verbs
```

I'd chain these by inheritance rather than using separate "packs". `ZoneDefinition._build_step` evaluates with `Expression`, and `Expression` takes one base instance. With a chain, the factory is that base instance. The zone's props and constants then go in as `Expression` input variables, which it already does for constants. Your `VerbCatalog.from_zone` becomes `from_factory(factory)` with the same `get_method_list` logic.

The end state, if you want it, is verbs as registered `Verb` resources with declared params. That would also remove the hand-synced `args` arrays, but I'd do it after the inheritance version.

### 5. Zone becomes a thin host

```gdscript
class_name Zone extends Node3D

signal rule_fired(rule_id, event)
@export var definition: ZoneDefinition
var bb: Blackboard
var engine: RuleEngine
var verbs: StepFactory

func build() -> void:
	bb = Blackboard.new(saved_vars)
	engine = RuleEngine.new(bb, fired, func(s): return get_tree().create_timer(s).timeout)
	verbs = _make_verbs()          # override per zone; default StagingVerbs
	verbs.ctx = StepContext.new(bb, engine, self)
	_build_props()
	# apply definition / _build_blackboard / graph as today

# Facade so BumpProp, TriggerArea and gameplay code don't change:
func fire(e: StringName, ctx := {}) -> void: engine.fire(e, ctx)
func get_var(k): return bb.get_var(k)
func write_var(k, v) -> void: bb.write(k, v)
func is_set(k) -> bool: return bb.is_set(k)
```

## Migration order

Each step keeps the game and the editor working:

1. **Blackboard.** Zone delegates to it, and the facade methods keep every caller unchanged. Update `BlackboardPanel.refresh_live` and the HUD (`zone.local_vars` becomes `zone.bb.local`).
2. **Validator.** Move `validate()` out and leave a one-line forwarder on `Zone`.
3. **Engine.** Update `RuleGraphReader` and `ZonePreview` to use `zone.engine.rules` instead of `zone.rules`.
4. **Verbs.** This is the biggest change. It touches `VerbCatalog`, `ZoneDefinition._build_step`, and `zone_01.gd`, whose custom verbs would move into a `Zone01Verbs` subclass.

## Gotchas

- **Lambda lifetime:** the code already notes that `rules.clear()` must happen before `free()`. With `RefCounted` engines and contexts, that mostly takes care of itself, but keep the clear in `ZonePreview.dispose` until you've confirmed it.
- **Dictionary snapshot/undo** only touches the data model, not these runtime classes, so it's unaffected.
- **The extra indirection** (`verbs.ctx.bb`) is a small cost. It buys you a rule engine and validator you can test with no scene tree at all, and verb sets that different zones can mix and match.
