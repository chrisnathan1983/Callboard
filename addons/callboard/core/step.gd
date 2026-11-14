@tool
class_name Step extends RefCounted
## One verb call inside a rule. Usually built by a verb factory.
## `verb` and `args` are display/serialization metadata for the Callboard.

var fn: Callable                       # func(ctx: Dictionary), may await or return a Signal
var delay := 0.0                       # deliberate beat before this step runs
var emits: StringName = &""            # relay this step fires itself (validator bookkeeping)
var wait_event: StringName = &""       # Call or relay observed by wait_for_call
var reads: Array[StringName] = []       # Blackboard keys read by the step
var emit_arg := -1                     # argument index the Callboard can edit to change the relay
var sets: Array[StringName] = []       # blackboard keys this step writes (validator bookkeeping)
var verb: StringName = &""             # e.g. &"say"
var args: Array = []                   # the arguments the verb was called with
var parallel_branches: Array[Array] = [] # authored child sequences for a parallel group.
var join_parallel := true              # wait for every branch before the parent continues.

## Construct a parallel group. Branch order is authored order; all branches start
## in that order during the same dispatch and then run concurrently. A joined
## group resumes after every branch completes. An unjoined group lets the parent
## continue while its branches remain owned by the parent rule run.
static func parallel(branches: Array[Array], join := true) -> Step:
	var step := Step.new()
	step.verb = &"parallel"
	step.parallel_branches = branches
	step.join_parallel = join
	return step

func _init(f: Callable = Callable()) -> void:
	fn = f

## Deliberate pause before the step. Not for matching animation lengths.
func after(seconds: float) -> Step:
	delay = seconds
	return self
