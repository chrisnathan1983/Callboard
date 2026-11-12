@tool
class_name StepContext extends RefCounted
## Services available to verb factories.

var bb: Blackboard
var engine_ref: WeakRef
var wait: Callable
var host: Node
var score: Callable

func _init(p_bb: Blackboard, engine: RuleEngine, p_host: Node, p_score: Callable) -> void:
	bb = p_bb
	# Engine -> rule -> step -> closure must not keep the engine alive.
	engine_ref = weakref(engine)
	wait = engine.wait
	host = p_host
	score = p_score
