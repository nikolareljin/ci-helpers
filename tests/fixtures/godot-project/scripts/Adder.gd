class_name Adder
extends RefCounted

# Referred to by `class_name` from tests/TestRunner.gd. Resolving that name
# needs .godot/global_script_class_cache.cfg, which only exists after an import.
static func add(a: int, b: int) -> int:
	return a + b
