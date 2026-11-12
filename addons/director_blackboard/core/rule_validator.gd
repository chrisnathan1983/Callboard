class_name RuleValidator extends RefCounted

static func validate(rules: Array[Rule], bb: Blackboard,
		external_events: Array[StringName], external_vars: Array[StringName]) -> Array[String]:
	# body of today's Zone.validate(), plus the new cycle / shared-trigger checks
	var problems: Array[String] = []
	var emitted := {}
	var settable := {}
	var seen := {}
	for k in external_vars:
		settable[k] = true
	for r in rules:
		if seen.has(r.id):
			problems.append("duplicate rule id '%s'" % r.id)
		seen[r.id] = true
		if r.emits != &"":
			emitted["relay:" + r.emits] = true
		for s in r.steps:
			if s.emits != &"":
				emitted["relay:" + s.emits] = true
			for k in s.sets:
				settable[k] = true
				if not bb.schema.has(k):
					problems.append("rule '%s' writes '%s' which is not declared on the Blackboard" % [r.id, k])
	for r in rules:
		if r.trigger == &"":
			problems.append("rule '%s' has no trigger" % r.id)
		elif not emitted.has(r.trigger) and not external_events.has(r.trigger):
			problems.append("rule '%s' listens to '%s' but nothing emits it and it is not a declared external event" % [r.id, r.trigger])
		for k in r.requires + r.forbids + r.cancel_if:
			if not bb.schema.has(k):
				problems.append("rule '%s' checks key '%s' which is not declared on the Blackboard" % [r.id, k])
			elif not settable.has(k):
				problems.append("rule '%s' checks key '%s' but nothing sets it" % [r.id, k])
		for s in r.steps:
			if s.args.has(null):
				problems.append("rule '%s' has a '%s' step with an unset prop" % [r.id, s.verb])
		if r.steps.is_empty() and r.emits == &"":
			problems.append("rule '%s' does nothing (no steps, no emit)" % r.id)
	for event in emitted:
		if not rules.any(func(x: Rule) -> bool: return x.trigger == event):
			problems.append("'%s' is emitted but no rule listens to it" % event)
	return problems
