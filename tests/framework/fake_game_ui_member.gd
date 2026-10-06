extends Node
## 测试辅助：一个「长得像 `game_ui` 组成员」的最小替身。
##
## ## 为什么需要它
## `MatchResult._close_other_uis()` 是靠 `get_nodes_in_group("game_ui")` 遍历、
## 再用 `has_method("close_ui")` + `has_method("is_open")`  duck-typing 判定来关别的界面的。
## 若测试去依赖真实的 `game_menu.tscn` / `death_screen.tscn`：
##   · 它们各自 `_ready` 里会做一堆事（扫模型、连武器信号），把用例变成集成测试；
##   · 一旦它们因为**自身**原因加载失败，失败信号会混进「结算面板互斥」的断言里，误导排查。
## → 故用这个只有 `open_ui` / `close_ui` / `is_open` 的最小替身，
##   让用例精确地只测「互斥遍历逻辑」这一件事。
##
## ⚠ 它**不是**测试套件（方法不以 `test_` 开头），不会被 Runner 反射收集。
##   放在 `tests/framework/` 下以区别于 `tests/suites/`（真正的用例）。

var _open := false


func _ready() -> void:
	# ⚠ 必须加入 `game_ui` 组：`MatchResult._close_other_uis()` 是靠
	#   `get_tree().get_nodes_in_group(UI_GROUP)` 遍历来关别的界面的。
	#   不入组 → 遍历不到它 → 互斥断言会「假绿」（测了个寂寞）。
	add_to_group("game_ui")


func open_ui() -> void:
	_open = true


func close_ui() -> void:
	_open = false


func is_open() -> bool:
	return _open
