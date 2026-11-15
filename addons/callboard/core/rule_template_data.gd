@tool
class_name RuleTemplateData extends Resource
## Reusable graph fragment with named parameter and internal-reference tokens.

const ParameterScript := preload("res://addons/callboard/core/rule_template_parameter.gd")

@export var id: StringName
@export var title := ""
@export_multiline var description := ""
@export var parameters: Array[ParameterScript] = []
@export var rules: Array[RuleData] = []
@export var variables: Array[VariableData] = []
## Variable template keys listed here intentionally retain their storage identity.
@export var deliberately_shared_storage: Array[StringName] = []
## Rule IDs listed here intentionally retain their authored one-shot latch identity.
@export var deliberately_shared_latches: Array[StringName] = []
## Relay symbols referenced as {{relay:name}} get one unique name per instance.
@export var internal_relays: Array[StringName] = []
