class_name UnavailableRule
extends MatchRule
## 条件类型的**显式不可用占位**（规格 §8.2 / §8.4）
##
## ## 覆盖的 4 个类型（用户点名但项目无支撑系统）
##   `survive_rounds` / `score_target` / `collect_items` / `defeat_boss`
##
## ## ⛔ 本类**唯一**的职责：让「配了但跑不了」变成**显式可见的配置错误**
## `evaluate()` **恒返回 `EVAL_UNAVAILABLE`，永不返回 `false`**。
##理由（同 C-18）：返回 `false` 会让「配了 5 个条件只跑通 1 个」看起来像
##   「另外 4 个没达成」—— 日志全正常、只有规则没生效，排查成本极高。
##   本项目已因此栽过两次（比分恒为 0，躲了两轮 G4）。
##
## ## 为什么是「占位」而不是「不注册」
## 不注册会在加载期被§3.3 拦下回落默认 → 用户配了 5 个条件、只有 1 个生效，
##   且**看不到任何提示是哪个类型不认识**。注册 + UNAVAILABLE 则能在
##   `push_warning` 里点名具体类型 id，配置错误可定位。
##
 ## 各类型为何本期不可用（规格 §2.2~§2.5 的摘要，完整论证见该文档）：
##   · `survive_rounds` —— 项目**无回合概念**（§2.2：三种"回合"定义都依赖不存在的系统；
##     `01_core_loop §4 方案 C` 已把回合制定为愿景层）。真「存活到时点」由 `time_limit` 承接。
##   · `score_target` —— 项目**无独立 score 字段**（只有 kills/deaths）；加第三键会撞
##     `ScoreManager::_freeze_scores()` 的结算冻结（§2.3）。零schema 过渡方案见 §8.2 备注。
##   · `collect_items` —— **无道具系统**，且 P2P 无服务器权威下"谁捡到了"必须由权威端裁定（§2.4）。
##   · `defeat_boss` —— **无 Boss 系统**（血量权威 / AI / 阶段 / 结算归属），量级是独立 Epic（§2.5）。
##
## ## 扩展方式（届时改这一处即可，判定函数本体不动 —— 开闭原则）
## 把某个类型从本占位里移出去、写成独立的 `MatchRule` 子类并在
## `ConditionRegistry` 注册真工厂 + 参数规格。`RuleSet` / `MatchRuleset` 无需改动。

## 全部占位类型 id → 未实现原因（一句话，供诊断输出）。
const REASONS := {
	"survive_rounds": "项目无回合概念（回合制为 01_core_loop §4 方案 C 愿景层）；「存活到时点」请用 time_limit",
	"score_target": "项目无独立 score 计分字段；加第三键会撞 ScoreManager 结算冻结（kills/deaths 之外无处落账）",
	"collect_items": "项目无玩法道具系统（拾取实体 / 道具 id 体系 / 跨端归属裁定均不存在）",
	"defeat_boss": "项目无 Boss 系统（血量权威 / AI / 阶段 / 结算归属均不存在）",
}


## 构造一个不可用占位条件。`type_id` 必须 ∈ `REASONS`（未登记的会补一条通用原因，便于扩展）。
func _init(type_id_: String, params: Dictionary = {}) -> void:
	super(params)
	type_id = type_id_
	judgeable = false # 静态事实：本项目判不了它（与 evaluate 的返回值互相印证）
	poll_mode = "TICK" # 仍走每帧轮询路径 —— 但恒返回 UNAVAILABLE，不产生判定


## ⛔ 恒返回 `EVAL_UNAVAILABLE`。**永不**返回 `EVAL_OK_FALSE`。
func evaluate(_snapshot: Dictionary) -> int:
	return EVAL_UNAVAILABLE


## 不可用条件没有归属（连"判不了"都谈不上归属）。
func owner_of(_snapshot: Dictionary) -> int:
	return NO_PEER


## 该类型不可用的原因（诊断 / `push_warning` 用）。
static func reason_for(type_id_: String) -> String:
	return String(REASONS.get(type_id_, "该条件类型尚未实现（占位）"))


## 全部占位类型 id（自省用：测试用它确保 4 个占位一个不少、也不多）。
static func placeholder_types() -> Array:
	var ids: Array = REASONS.keys()
	ids.sort()
	return ids