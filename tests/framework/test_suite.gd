class_name TestSuite
extends Node
## 轻量测试基类（自研 harness 的一部分）
##
## 约定：
##   - 用例 = 本类子脚本里以 `test_` 开头的方法；Runner 用 `get_method_list()` 反射收集（按名排序）。
##   - 断言失败**只记录、不中断**：跑完全部用例再汇总（对齐「回归基线」的用法）。
##   - 作为 `Node` 子类，`add_child()` 进入场景树后即可直接 `add_child(临时节点)` 做场景级用例。
##   - `is_pending() == true` 时整个 suite 跳过、不计失败（用于「依赖尚未实现的功能」的用例）。
##
## 为什么自研而不是 GUT / gdUnit4：见 `tests/README.md`「技术选型」。

## 本次 suite 收集到的失败消息（Runner 汇总用）
var failures: Array[String] = []
## 跳过说明（例如依赖资产缺失）
var pending_notes: Array[String] = []
## 当前用例名（Runner 设置，用于失败定位）
var current_test := ""
## 断言计数
var assert_count := 0


## 覆盖：本 suite 是否处于 pending（依赖未就绪）——返回 true 时 Runner 只打印、不计失败
func is_pending() -> bool:
	return false


## 每个用例前 / 后钩子（默认空实现）
func before_each() -> void:
	pass


func after_each() -> void:
	pass


## 记录一次断言失败
func fail(message: String) -> void:
	failures.append("[%s] %s" % [current_test, message])


## 标记跳过（不算失败）——例如依赖的资产不存在
func pending(reason: String) -> void:
	pending_notes.append("[%s] %s" % [current_test, reason])


func check_true(condition: bool, message: String) -> void:
	assert_count += 1
	if not condition:
		fail("应为真：%s" % message)


func check_false(condition: bool, message: String) -> void:
	assert_count += 1
	if condition:
		fail("应为假：%s" % message)


func check_eq(actual: Variant, expected: Variant, message: String) -> void:
	assert_count += 1
	if actual != expected:
		fail("%s（期望 %s，实际 %s）" % [message, str(expected), str(actual)])


func check_ge(actual: float, minimum: float, message: String) -> void:
	assert_count += 1
	if actual < minimum:
		fail("%s（要求 ≥ %s，实际 %s）" % [message, str(minimum), str(actual)])


func check_le(actual: float, maximum: float, message: String) -> void:
	assert_count += 1
	if actual > maximum:
		fail("%s（要求 ≤ %s，实际 %s）" % [message, str(maximum), str(actual)])


func check_near(actual: float, expected: float, tolerance: float, message: String) -> void:
	assert_count += 1
	if absf(actual - expected) > tolerance:
		fail("%s（期望 %s ± %s，实际 %s）" % [message, str(expected), str(tolerance), str(actual)])
