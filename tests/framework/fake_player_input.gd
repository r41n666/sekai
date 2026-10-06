extends Node
## 测试辅助：一个「长得像 `player` 组成员」的最小替身（只带输入闸门那几样）。
##
## ## 为什么需要它
## `MatchResult._set_input_blocked()` / `_capture_mouse()` 是靠
## `get_tree().get_first_node_in_group("player")` 找玩家、再duck-typing 调
## `set_input_blocked` / `capture_mouse` 的。若测试去实例化真的 `player.tscn`：
##   · 它 `_ready` 里会 `_setup_local_player()` → 抢摄像机_current、`capture_mouse()`、
##     `_equip_slot("Rifle")`、建四个武器槽 —— 把一条「输入闸门是否对称」的断言
##     变成重量级集成测试，且它自身的失败会混进本suite 的断言里、误导排查；
##   · 真实 `player.set_input_blocked()` 内部还会连带 `release_mouse()` /
##     `velocity` 归零 / 武器 `set_trigger_enabled(false)`，一旦那条链自己坏了，
##     本 suite 会误报「结算面板没恢复输入」。
## → 故仿照 `fake_game_ui_member.gd`（同一目录、同一取舍思路），
##   只留 `set_input_blocked` / `capture_mouse` / `input_blocked` 三样，
##   让用例精确地只测「面板开/关时输入闸门是否对称」这一件事。
##
## ## 为什么必须入 `player` 组
## `MatchResult._get_player()` 是靠 `get_first_node_in_group("player")` 取节点的。
## 不入组 → 遍历不到 → `input_blocked` 永远是初值 `false` →
## 「打开面板后必须为 true」这条断言会**假绿**（测了个寂寞）。
## 这与 `fake_game_ui_member.gd` 必须 `add_to_group("game_ui")` 是同一个坑。
##
## ⚠ 它**不是**测试套件（方法不以 `test_` 开头），不会被 Runner 反射收集。

## 本端输入是否被屏蔽（对齐 `player.gd::input_blocked` 的语义与初值）
var input_blocked := false
## 统计 `capture_mouse()` 被调了几次 —— 用来验证「关闭面板时鼠标确实被交还玩家」
var capture_calls := 0
## 统计 `set_input_blocked()` 被调了几次（不分参数）—— 用来验证对称性
var set_blocked_calls := 0


func _ready() -> void:
	# ⚠ 必须加入 `player` 组（理由见文件头）。
	add_to_group("player")


## 对齐 `player.gd::set_input_blocked(blocked)` 的最小契约。
func set_input_blocked(blocked: bool) -> void:
	input_blocked = blocked
	set_blocked_calls += 1


## 对齐 `player.gd::capture_mouse()` 的最小契约（无参、无返回值）。
func capture_mouse() -> void:
	capture_calls += 1
