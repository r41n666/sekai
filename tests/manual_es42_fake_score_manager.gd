extends Node
## ES-4.2 窗口实测探针的**假 ScoreManager**（一次性，不进产品）
##
## 面板 `bind()` 只需要三样东西：
##   1. `match_ended(winner_id, final_scores)` 信号（附录 A.5 绑定面）
##   2. `local_peer_id() -> int`（决定胜者行显示「你」还是昵称）
##   3. `match_duration` / `time_remaining` 两个状态量（算本局时长）
## 这里只实现这四样，**不含**任何计分/胜负逻辑 —— 权威判定仍在
## 真实 `ScoreManager._evaluate_winner()` 那边（test_score_manager.gd 覆盖）。
##
##⚠ 刻意**不** `extends ScoreManager`：探针要验的是**渲染路径**，
##   若接上真实计分器，探针失败就分不清是「渲染坏了」还是「计分坏了」。

## 契约信号（签名与 `ScoreManager` A.5 逐字一致，UI 侧绑定才对得上）
signal match_ended(winner_id: int, final_scores: Dictionary)

var match_duration := 300.0
var time_remaining := 300.0
var _local_peer_id := 1


func local_peer_id() -> int:
	return _local_peer_id


## 权威端在离线时即本端（对齐 `ScoreManager.is_authority()` 的离线分支）
func is_authority() -> bool:
	return true
