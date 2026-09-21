extends SceneTree

# Prints a completion line on success. The preset's documented test command
# greps for it, because a runner that dies quietly prints nothing and Godot
# still exits 0.
func _init() -> void:
	if Adder.add(2, 2) != 4:
		push_error("Adder.add is wrong")
		quit(1)
		return
	print("all tests passed")
	quit(0)
