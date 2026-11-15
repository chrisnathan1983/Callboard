@tool
class_name RuleTemplateParameter extends Resource
## One value required to instantiate a reusable rule template.

enum Kind { PROP, KEY, CALL, RELAY, PAYLOAD_FIELD, NUMBER, TEXT }

@export var name: StringName
@export var label := ""
@export var kind: Kind = Kind.TEXT
@export_multiline var description := ""
@export var required := true
@export var default_value := ""
@export var expected_type := ""
@export var expected_prop_class := ""

func _init(parameter_name: StringName = &"", parameter_label := "",
		parameter_kind: Kind = Kind.TEXT, parameter_required := true,
		parameter_default := "", parameter_description := "",
		parameter_expected_type := "", parameter_expected_prop_class := "") -> void:
	name = parameter_name
	label = parameter_label
	kind = parameter_kind
	required = parameter_required
	default_value = parameter_default
	description = parameter_description
	expected_type = parameter_expected_type
	expected_prop_class = parameter_expected_prop_class
