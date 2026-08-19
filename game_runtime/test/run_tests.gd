extends SceneTree

var tests: Array[Callable] = []


func _init() -> void:
	var failures := 0

	for test in tests:
		if not test.call():
			failures += 1

	print("%d tests, %d failures" % [tests.size(), failures])
	quit(1 if failures > 0 else 0)
