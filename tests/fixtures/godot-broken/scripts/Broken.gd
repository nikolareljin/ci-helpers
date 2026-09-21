class_name Broken
extends RefCounted

# Deliberate syntax error. Do not "fix" this file: a self-test leg asserts the
# preset's lint default rejects this project, and repairing it would turn that
# leg into one that passes for the wrong reason.
static func add(a: int, b: int) -> int:
	return a +++
