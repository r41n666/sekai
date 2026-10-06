class_name TimeLimitRule
extends MatchRule
## 条件类型 `time_limit` —— 「对局时长耗尽即结束」（规格 §2.1 第 2′ 项，🟢 本期实现）
##
## 求值口径：`snapshot.time_remaining <= 0.0`。
##   ⚠ **必须与旧写死逻辑逐位一致**：原 `_check_end_condition()` 判的就是
##   `time_remaining <= 0.0`，不是 `elapsed >= duration_limit`——
##   后者在「测试/测试探针直接写 `time_remaining`」时会分叉（既有测试正是这么干的：
##   `test_score_manager.gd:79mgr.time_remaining = 0.0`）。
##   → 故 `duration_limit` 只作**配置层记录与下发**用，求值一律读 `time_remaining`。
##
## ⛔ **缺 `time_remaining` 键 → 返回 `UNAVAILABLE`，不返回 `false`**：
##   若缺键时fail-open 成 `0.0 <= 0.0 = true`，一个拼错的快照键会**直接结束整局**；
##   若 fail-soft 成 `false`，则「条件永不触发」且无任何日志（C-18 同款静默失效）。
##   → 唯一诚实的表达就是「判不了」。与「防空壳」是同一条纪律的另一个方向。
##
## 该条件**无归属 peer**（超时没有触发者）→ `owner_of` 沿用基类的 `NO_PEER`。
const TYPE_ID := "time_limit"

## 求值必需的 snapshot 键（缺则 UNAVAILABLE，见文件头说明）。
const REQUIRED_KEY := "time_remaining"


func _init(params: Dictionary = {}) -> void:
	super(params)
	type_id = TYPE_ID
	judgeable = true


func evaluate(snapshot: Dictionary) -> int:
	if not snapshot.has(REQUIRED_KEY):
		return EVAL_UNAVAILABLE
	return EVAL_OK_TRUE if float(snapshot[REQUIRED_KEY]) <= 0.0 else EVAL_OK_FALSE