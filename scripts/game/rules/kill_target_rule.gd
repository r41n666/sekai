class_name KillTargetRule
extends MatchRule
## 条件类型 `kill_target` —— 「击杀 N 个目标即结束」（规格 §2.1 第 1 项，🟢 本期实现）
##
## 求值口径：`scores` 里**任一** peer 的 `kills >= target_kills` 即成立。
##   ⚠ 归属 peer 用 `first_peer_reaching()`（按 peer_id 升序）而非「谁先打到」——
##   同一帧多人达成时必须有**确定性**归属，否则 `decisive_peer` 会跨端分叉。
##
## 阈值来源（MVP 关键约束，规格 §7.1）：
##   内置默认规则集 `ffa_kill15` 的 `target_kills` **必须读 `ScoreManager.kill_target` 字段**，
##   不能在配置里另写一份 15 —— 否则既有测试 `mgr.kill_target = 3` 会当场失效。
##
## ⛔ **缺 `scores` 键 → 返回 `UNAVAILABLE`**（与 `time_limit` 同款纪律）：
##   空表判「未达成」是合理的（真的没人到目标），但「**根本没有 scores 数据**」
##   判「未达成」就是静默失效 —— 两者必须可区分。
const TYPE_ID := "kill_target"

## 求值必需的 snapshot 键（缺则 UNAVAILABLE，见文件头说明）。
const REQUIRED_KEY := "scores"


func _init(params: Dictionary = {}) -> void:
	super(params)
	type_id = TYPE_ID
	judgeable = true


## 取生效的目标杀数（缺参数时回落 1，保证「配了但漏写阈值」不会变成「永不达成」；
##   非正值由 `ConditionRegistry` 在**加载期**拦下，不留到求值期）。
func target_kills() -> int:
	return maxi(int(get_param("target_kills", 1)), 1)


func evaluate(snapshot: Dictionary) -> int:
	if not snapshot.has(REQUIRED_KEY):
		return EVAL_UNAVAILABLE
	return EVAL_OK_TRUE if first_peer_reaching(snapshot, target_kills()) != NO_PEER \
		else EVAL_OK_FALSE


func owner_of(snapshot: Dictionary) -> int:
	if not snapshot.has(REQUIRED_KEY):
		return NO_PEER
	return first_peer_reaching(snapshot, target_kills())