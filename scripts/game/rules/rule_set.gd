class_name RuleSet
extends RefCounted
## 规则对象树 + 组合求值（规格 §4）—— **每端各自编译一次的本地产物，不跨端传输**
##
## ## 职责边界（规格 §3.4）
##   `MatchRuleset`（配置真值）→ `ConditionRegistry.compile()` → **本类** → `RuleSet.evaluate(snapshot)`
##   → `RuleEvaluation`（纯数据）→ `ScoreManager` 消费（唯一判定口径，A.6）。
##
## ## 纯度纪律（`control_checklist §4`）
##   本类**不碰** `multiplayer`、场景树、`Time` / `Engine`、任何节点。
##   → 规则求值可在 headless 下用字面量 Dictionary 直接断言。
##
## ## ⛔ 不可用条件的处理（规格 §8.4，本任务最重要的设计约束）
##   任一**启用**条件返回 `UNAVAILABLE` → **整个规则集不可信 → `should_end = false`**
##   并**恰好一次** `push_warning`（每局一次，不刷屏）。
##   理由：静默 `false` 会让「配了 5 个只跑通 1 个」看起来像「另外 4 个没达成」
##   —— 形态同 C-18「比分永远 0」（日志全正常、只有规则没生效，排查成本极高）。
##
## ## 顺序语义（规格 §4.2）
##   `conditions[]` 的顺序**是语义的一部分**：`decisive_type` / `decisive_peer`
##   报告**声明顺序里第一个成立**的条件。
##   ⚠ **不要**改成「哪个条件最紧急」—— 顺序在配置里固定，因此**跨端可复现**。

## 组合算子：`ALL_OF` = 全部启用条件成立才结束；`ANY_OF` = 任一成立即结束。
const COMBINE_ALL := "ALL_OF"
const COMBINE_ANY := "ANY_OF"

## 求值结果（规格 §1.3，纯数据，不含节点引用）。
class RuleEvaluation extends RefCounted:
	## 是否触发对局结束。
	var should_end := false
	## 触发的条件类型 id（`""` = 未结束）。
	var decisive_type := ""
	## 归属 peer（`MatchRule.NO_PEER` = -1 = 无归属，如超时）。
	var decisive_peer: int = MatchRule.NO_PEER
	## 本局失败的 peer 列表（本期恒为空 —— 规格 §4.4 只保留「非胜者即负」默认语义）。
	var failed_peers: Array[int] = []


## 组合算子（`ALL_OF` / `ANY_OF`）。
var combine: String = COMBINE_ANY
## 参与求值的规则对象（**已剔除** `enabled=false` 的条目 —— 顺序即求值顺序）。
var rules: Array[MatchRule] = []
## 声明顺序里全部启用条件的 type_id 快照（含不可用条件，用于诊断）。
var declared_types: Array[String] = []

## 本次求值是否因「存在不可用条件」而**拒绝结束对局**（诊断用）。
var _last_blocked_by_unavailable := false
## 本次求值遇到的不可用类型 id（诊断用）。
var _last_unavailable_types: Array[String] = []


## 构造规则集。`rules` 应为**已按声明顺序排好、已剔除禁用项**的数组。
func _init(combine_: String = COMBINE_ANY, rules_: Array = []) -> void:
	combine = combine_
	set_rules(rules_)


## 替换参与求值的规则（声明顺序 = 求值顺序）。
func set_rules(rules_: Array) -> void:
	rules.clear()
	declared_types.clear()
	for item: Variant in rules_:
		var rule := item as MatchRule
		if rule == null:
			continue
		rules.append(rule)
		declared_types.append(rule.type_id)


## 启用条件数（已剔除禁用项）。
func active_count() -> int:
	return rules.size()


## 本次求值是否被「不可用条件」阻断（诊断 / 测试用）。
func blocked_by_unavailable() -> bool:
	return _last_blocked_by_unavailable


## 本次求值遇到的不可用类型 id（诊断 / 测试用）。
func last_unavailable_types() -> Array[String]:
	return _last_unavailable_types.duplicate()


## 求值（**纯函数**：只读 snapshot，不写任何状态）。
##   返回 `RuleEvaluation`（新对象；调用方不得长期持有——每帧一个新实例）。
##   ⚠ 返回新实例而非复用成员：避免「上一帧的结果被这一帧改写」这类难查的别名 bug。
func evaluate(snapshot: Dictionary) -> RuleEvaluation:
	var result := RuleEvaluation.new()
	_last_blocked_by_unavailable = false
	_last_unavailable_types = []

	# ── 空列表语义（规格 §4.1）──
	#   ANY_OF + 空 → 恒false（永不自动结束，合法）
	#   ALL_OF + 空 → 恒 true（**危险**：开局即结束）→ **加载期就该拦掉**，
	#     但求值层仍按规格实现（纵深防御：万一有路径绕过加载器）。
	if rules.is_empty():
		result.should_end = combine == COMBINE_ALL
		return result

	# ── 先普查不可用条件（不受短路影响，规格 §8.4）──
	#   ⚠ 必须在组合求值**之前**普查：否则 `ANY_OF` 下第一个条件成立就短路返回了，
	#   后面的不可用条件永远没被看见 → 「配了 5 个只跑通 1 个」又变成静默失效。
	for rule in rules:
		if not rule.judgeable:
			_last_blocked_by_unavailable = true
			_last_unavailable_types.append(rule.type_id)

	if _last_blocked_by_unavailable:
		# 规则集不可信 → **不结束对局**（`should_end` 保持 false），由调用方push_warning。
		result.should_end = false
		result.decisive_type = ""
		result.decisive_peer = MatchRule.NO_PEER
		return result

	# ── 组合求值（短路，规格 §4.1）──
	for rule in rules:
		var status := rule.evaluate(snapshot)
		# 纵深防御：普查说可判定、evaluate 却说不可用（有人只翻 judgeable 没翻 evaluate）→
		#   按不可用处理，不结束对局。宁可漏判结束，也不静默按「没达成」算。
		if status == MatchRule.EVAL_UNAVAILABLE:
			_last_blocked_by_unavailable = true
			_last_unavailable_types.append(rule.type_id)
			result.should_end = false
			result.decisive_type = ""
			result.decisive_peer = MatchRule.NO_PEER
			return result
		var satisfied := status == MatchRule.EVAL_OK_TRUE
		if combine == COMBINE_ALL and not satisfied:
			return result # ALL_OF 短路：首个不成立即返回（should_end 保持 false）
		if combine == COMBINE_ANY and satisfied:
			result.should_end = true
			result.decisive_type = rule.type_id
			result.decisive_peer = rule.owner_of(snapshot)
			return result # ANY_OF 短路：首个成立即返回

	# 循环走完没短路：
	#   ANY_OF → 全不成立（should_end 保持 false）
	#   ALL_OF → 全成立（should_end 仍为 false，需在此置 true）
	if combine == COMBINE_ALL:
		result.should_end = true
		# decisive 取**声明顺序第一个**成立的条件（规格 §4.2：顺序是语义的一部分）。
		#   ⚠ 不是「最后一个成立的」—— 那会让「kill_target写在 time_limit 前」失去意义。
		for rule in rules:
			if rule.evaluate(snapshot) == MatchRule.EVAL_OK_TRUE:
				result.decisive_type = rule.type_id
				result.decisive_peer = rule.owner_of(snapshot)
				break
	return result


## 可诊断的一句话摘要（`push_warning` / 日志用；⚠ 断言不要依赖本字符串）。
func describe() -> String:
	return "RuleSet(combine=%s, 启用条件=%s%s)" % [
		combine, str(declared_types),
		"，含不可用条件 %s" % str(_last_unavailable_types) if _last_blocked_by_unavailable else "",
	]