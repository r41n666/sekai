extends Node
## 测试辅助：一个「只广播信号、不做权威判定」的假 ScoreManager（复位闭环用例专用）。
##
## ## 为什么需要它（而不是直接用真 `ScoreManager`）
## 本文件服务于 `test_match_result.gd` 的「**客户端路径**」用例，要点是：
##   验证「本端**非权威**时，收到复位通知 → 结算面板关闭」。
## 若用真 `ScoreManager`，得把 `NetworkManager.is_online/is_server` 改成联机态
## 才能让 `is_authority()` 返回 false —— 而 `NetworkManager` 是 **Autoload 单例**，
## 改它会**跨用例污染**其他 suite（`test_scoreboard` / `test_match_result` 的
## 按钮权限用例都读它），且Godot 单帧内跑完所有用例、`after_each` 不保证跑到。
## → 故用这个「只有信号、没有权威逻辑」的替身：它让**被测对象（面板）**
##   走的是真实的信号消费路径，而**驱动源**是可控的、无副作用的。
##   ⚠ 权威侧口径（`_apply_reset` 是否真的 emit）由**真** `ScoreManager` 的
##   用例 `test_score_manager.gd` 负责，两边合起来才覆盖完整链路 ——
##   绝不允许「面板 + 假信号源」自说自话（那正是本轮缺陷的形态：信号缺了但两边都绿）。
##
## ## 纪律：本替身**不含**任何胜负/复位判定
## 它只是「一个会发 `match_reset` 的节点」。真实语义由 `ScoreManager` 保证。

## 与 `ScoreManager` A.5 逐字一致的契约信号（UI 侧绑定才对得上）
signal match_ended(winner_id: int, final_scores: Dictionary)
## EP-3 增补的复位信号（无载荷）
signal match_reset

## ⚠ 这两个状态量**必须**提供：`MatchResult._on_match_ended()` 会读它们算本局时长
##   （`float(_score_manager.get("match_duration"))`）。缺了会让 `get()` 返回 null、
##   `float(null)` 抛「Nonexistent 'float' constructor」→ **在 `open_ui()` 之前就中断**，
##   症状是「面板永远不打开」这种极具误导性的失败（本轮实测踩过一次）。
##   口径与 `manual_es42_fake_score_manager.gd` 一致（那里由探针 `set()` 注入）。
var match_duration := 300.0
var time_remaining := 300.0

## 复位信号被广播了几次（供幂等断言）
var reset_broadcasts := 0
## `request_reset()` 被调了几次（供「按钮把复位意图交给权威」断言）
var reset_calls := 0


## 模拟「本端收到房主广播的复位」→ 客户端 `_apply_reset()` 的等价效果。
func broadcast_reset() -> void:
	reset_broadcasts += 1
	match_reset.emit()


## 面板 `[再来一局]` 会调这个方法（`ScoreManager` 的 A.8 既有契约）。
## ⚠ 这里**只记录调用并广播复位**，不含任何权威判定 ——
##   真实权威端 `request_reset()` 开头是 `if not is_authority(): return`，
##   那是 `ScoreManager` 侧的事，本替身一律按「权威」处理。
func request_reset() -> void:
	reset_calls += 1
	broadcast_reset()


## 模拟房主广播结算。
func broadcast_ended(winner_id: int, final_scores: Dictionary) -> void:
	match_ended.emit(winner_id, final_scores)


## 面板 `bind()` 会读这个方法拿本端peer id。
func local_peer_id() -> int:
	return 2 # 固定为「客户端视角」，确保胜者行不会显示「你」


## 面板按钮权限用。`false` = 客户端（显示「等待房主…」且disabled）。
func is_authority() -> bool:
	return false
