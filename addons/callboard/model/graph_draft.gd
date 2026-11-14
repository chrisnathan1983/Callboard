@tool
class_name GraphDraft extends RefCounted
## A working copy of a StageDefinition, with editor analysis stored separately.

class StepAnalysis extends RefCounted:
	var relay: String
	var relay_argument: int

var definition: StageDefinition
var rules: Array[RuleData] = []
var variables: Array[VariableData] = []
var groups: Array[GroupData] = []
var external_calls: Array[String] = []
var external_vars: Array[String] = []
var external_writers: Array[BlackboardWriterData] = []
var payload_fields: Array[PayloadFieldData] = []
var call_positions: Dictionary = {}
var catalog: Array = []
var props: Array = []
var errors: Array[String] = []
var warnings: Array[String] = []
var load_failed := false

# Compiled metadata is keyed by draft step identity and never enters undo history.
var step_metadata: Dictionary[StepData, StepAnalysis] = {}

func find_rule(id: String) -> RuleData:
	for rule in rules:
		if rule.id == id:
			return rule
	return null

func relay_for(step: StepData) -> String:
	var analysis: StepAnalysis = step_metadata.get(step)
	return analysis.relay if analysis != null else ""

func errors_for(rule: RuleData) -> Array[String]:
	return _messages_for(rule, errors)

func warnings_for(rule: RuleData) -> Array[String]:
	return _messages_for(rule, warnings)

func _messages_for(rule: RuleData, messages: Array[String]) -> Array[String]:
	var quoted_id := "'%s'" % rule.id
	return messages.filter(func(message: String) -> bool: return quoted_id in message)

func snapshot() -> Dictionary:
	return {
		"rules": rules.map(func(rule: RuleData) -> Dictionary: return rule.to_dictionary()),
		"variables": variables.map(func(variable: VariableData) -> Dictionary: return variable.to_dictionary()),
		"groups": groups.map(func(group: GroupData) -> Dictionary: return group.to_dictionary()),
		"external_calls": external_calls.duplicate(),
		"external_vars": external_vars.duplicate(),
		"external_writers": external_writers.map(func(writer: BlackboardWriterData) -> Dictionary: return writer.to_dictionary()),
		"payload_fields": payload_fields.map(func(field: PayloadFieldData) -> Dictionary: return field.to_dictionary()),
		"call_positions": call_positions.duplicate(true),
	}

func restore(snapshot_data: Dictionary) -> void:
	rules.assign(snapshot_data["rules"].map(RuleData.from_dictionary))
	variables.assign(snapshot_data["variables"].duplicate(true).map(VariableData.from_dictionary))
	groups.assign(snapshot_data["groups"].map(GroupData.from_dictionary))
	external_calls.assign(snapshot_data["external_calls"])
	external_vars.assign(snapshot_data["external_vars"])
	external_writers.assign(snapshot_data.get("external_writers", []).map(BlackboardWriterData.from_dictionary))
	payload_fields.assign(snapshot_data.get("payload_fields", []).map(PayloadFieldData.from_dictionary))
	call_positions = snapshot_data["call_positions"].duplicate(true)
	step_metadata.clear()

static func load_error(message: String) -> GraphDraft:
	var draft := GraphDraft.new()
	draft.load_failed = true
	draft.errors.append(message)
	return draft
