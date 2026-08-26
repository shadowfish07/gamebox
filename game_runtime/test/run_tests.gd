extends SceneTree

const TEST_SUITES := [
	preload("res://test/test_launch_config.gd"),
	preload("res://test/test_registry.gd"),
	preload("res://test/test_main.gd"),
	preload("res://test/test_protocol.gd"),
	preload("res://test/test_gomoku_state.gd"),
	preload("res://test/test_gomoku_preferences.gd"),
	preload("res://test/test_match_client.gd"),
	preload("res://test/test_gomoku_board.gd"),
	preload("res://test/test_gomoku_scene.gd"),
	preload("res://test/test_design_system.gd"),
	preload("res://test/test_design_system_components.gd"),
]


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var total := 0
	var failures := 0

	for suite in TEST_SUITES:
		for test_case in suite.cases():
			total += 1
			var passed: bool = await test_case["run"].call()
			if not passed:
				failures += 1
				print("FAIL: %s" % test_case["name"])
			else:
				print("PASS: %s" % test_case["name"])

	if total == 0:
		failures += 1
		print("FAIL: no tests executed")
	print("%d tests, %d failures" % [total, failures])
	if total > 0 and failures == 0:
		print("GAMEBOX_GODOT_TESTS_PASSED")
	quit(1 if failures > 0 else 0)
