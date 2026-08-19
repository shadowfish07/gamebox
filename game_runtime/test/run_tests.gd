extends SceneTree

const TEST_SUITES := [
	preload("res://test/test_launch_config.gd"),
	preload("res://test/test_registry.gd"),
]


func _init() -> void:
	var total := 0
	var failures := 0

	for suite in TEST_SUITES:
		for test_case in suite.cases():
			total += 1
			if not test_case["run"].call():
				failures += 1
				print("FAIL: %s" % test_case["name"])
			else:
				print("PASS: %s" % test_case["name"])

	print("%d tests, %d failures" % [total, failures])
	quit(1 if failures > 0 else 0)
