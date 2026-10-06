extends Node
## 测试 Runner（`tests/test_runner.tscn` 的根节点）
##
## 运行方式（headless，Autoload 正常注册）：
##   "C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe" \
##       --headless --path . res://tests/test_runner.tscn
##
## 统一出口码：0 = 全通过（含 pending 跳过）；1 = 有失败。
##
## ⚠ 为什么必须用「测试场景 + Runner 节点」而不是 `-s`（SceneTree 脚本）：
##    `-s` 模式下 **Autoload 不注册** → 依赖 `NetworkManager` / `MusicManager` 的脚本会编译失败。
##    用普通场景运行（把本 .tscn 当主场景跑）则会正常注册 Autoload。这是项目踩过的坑（README §11 阶段 5）。

## 参与本次运行的 suite（新增用例时在此登记）
const SUITE_SCRIPTS: Array[String] = [
	"res://tests/suites/test_spawn_points.gd",
	"res://tests/suites/test_minimap_radius.gd",
	"res://tests/suites/test_damage_routing.gd",
	"res://tests/suites/test_invariants.gd",
]


func _ready() -> void:
	await get_tree().process_frame

	var total_tests := 0
	var total_asserts := 0
	var total_failures := 0
	var pending_suites := 0
	var failure_lines: Array[String] = []

	print("")
	print("=================== sekai 测试汇总 ===================")
	for path in SUITE_SCRIPTS:
		var suite_script: GDScript = load(path) as GDScript
		if suite_script == null:
			print("  ✗ [加载失败] %s" % path)
			total_failures += 1
			continue
		var suite := suite_script.new() as TestSuite
		if suite == null:
			print("  ✗ [实例化失败] %s" % path)
			total_failures += 1
			continue
		var suite_name := path.get_file().get_basename()
		add_child(suite)

		if suite.is_pending():
			pending_suites += 1
			print("  ○ PENDING  %s（依赖未就绪，本次跳过）" % suite_name)
			suite.queue_free()
			continue

		var tests := _collect_tests(suite)
		var before_failures := suite.failures.size()
		for test_name in tests:
			total_tests += 1
			suite.current_test = test_name
			var before := suite.failures.size()
			suite.before_each()
			suite.call(test_name)
			suite.after_each()
			if suite.failures.size() > before:
				print("  ✗ %s.%s" % [suite_name, test_name])
		total_asserts += suite.assert_count
		total_failures += suite.failures.size()
		if suite.failures.size() == before_failures:
			print("  ✓ %s（%d 用例 / %d 断言）" % [suite_name, tests.size(), suite.assert_count])
		for line in suite.failures:
			failure_lines.append("%s  %s" % [suite_name, line])
		for note in suite.pending_notes:
			print("    · skip %s" % note)
		suite.queue_free()

	print("-----------------------------------------------------")
	if not failure_lines.is_empty():
		print("失败明细：")
		for line in failure_lines:
			print("  - %s" % line)
		print("-----------------------------------------------------")
	print("用例 %d ｜ 断言 %d ｜ 失败 %d ｜ pending suite %d" % [
		total_tests, total_asserts, total_failures, pending_suites,
	])
	print("=================== %s ===================" % ("PASS" if total_failures == 0 else "FAIL"))
	print("")

	get_tree().quit(1 if total_failures > 0 else 0)


## 反射收集以 `test_` 开头的用例方法名（按名排序，保证稳定顺序）
func _collect_tests(suite: TestSuite) -> Array[String]:
	var names: Array[String] = []
	for method in suite.get_method_list():
		var method_name: String = str(method.get("name", ""))
		if method_name.begins_with("test_"):
			names.append(method_name)
	names.sort()
	return names
