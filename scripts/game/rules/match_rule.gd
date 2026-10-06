class_name MatchRule
extends RefCounted
## 胜负条件规则基类（D2-04 · `design/gdd/05_rule_config_spec.md` §3.2）
##
## ## 契约（所有条件类型的唯一约定）
##   `evaluate(snapshot) -> int` 返回**三态**（不是 bool）：
##     · `EVAL_OK_TRUE`  —— 真判了，且成立
##     · `EVAL_OK_FALSE` —— 真判了，且不成立
##     · `EVAL_UNAVAILABLE` —— **判不了**（项目缺支撑系统）
##
## ## ⛔ 为什么不可用态**不允许**返回 `EVAL_OK_FALSE`
## 「配了 5 个条件只跑通 1 个」若表现为「另外 4 个没达成」，排查成本极高——
## 日志全正常、只有规则没生效，形态与 C-18「比分永远 0」完全同源（本项目已栽两次）。
## → **不可用必须是显式第三态**，让「配置错误」可见（规格 §8.4）。
##   `tests/suites/test_rule_config.gd::test_unavailable_conditions_never_report_false`
##   把这条钉死。
##
## ## 纪律：纯函数（`control_checklist §4` + 规格 §3.2）
##   `evaluate` / `owner_of` 只读传入的 `snapshot`：
##   **不得**触碰 `multiplayer`、场景树、`Engine` / `Time`、任何节点引用。
##   → 因此规则求值可在 headless 下用字面量 Dictionary 直接断言。
##   守护用例：`test_rule_config.gd::test_evaluation_layer_touches_no_engine_state`。
##
## ## `snapshot` 字段（规格 §3.2，纯数据、不含节点引用）
##   `scores: Dictionary` / `time_remaining: float` / `match_state: int` / `elapsed: float`
##   （`alive_peers` / `collected_items` / `defeated_bosses` 属未来字段，本期不提供——
##正因为不提供，依赖它们的条件才只能是 `EVAL_UNAVAILABLE`。）

## 三态求值结果：真·成立
const EVAL_OK_TRUE := 0
## 三态求值结果：真·不成立
const EVAL_OK_FALSE := 1
## 三态求值结果：**判不了**（缺支撑系统）。⛔ 不可用条件**禁止**返回本值以外的任何形态。
const EVAL_UNAVAILABLE := 2

## 「无归属 peer」语义值。与 `ScoreManager.WINNER_UNSET` 同值（-1）。
##   ⚠ 这里**不**直接引用 `ScoreManager.WINNER_UNSET`：`RuleSet` ↔ `ScoreManager` 互相
##   引用 `class_name` 会形成循环依赖（编译期报错）。改由
##   `test_rule_config.gd::test_unset_peer_value_matches_score_manager_constant` 锁住同值。
const NO_PEER := -1

## 条件类型 id（子类构造时写入；注册表也会用它做 key 校验）
var type_id: String = ""
## `"TICK"`=每 tick 轮询 / `"EVENT"`=可事件驱动（规格 §3.2 预留，本期一律 TICK）。
##   ⚠ 本期**保持每帧轮询**（规格 §5.2）：≤5 条件 × ≤4 peer ≈ 20 次整数比较/帧可忽略；
##   事件驱动会引入「事件漏发 → 规则永不触发」的失效模式，属过度工程。
var poll_mode: String = "TICK"
## 该条件是否**可判定**（静态事实：有= 有支撑系统能真判）。
##   ⚠ 与 `evaluate()` 的返回值是**两件事**：本字段供加载校验 + 运行期普查使用，
##   **不依赖 snapshot、不受求值顺序影响 → 因此永不被短路掩盖**。
##   即便如此，`evaluate()` 仍必须诚实返回 `EVAL_UNAVAILABLE`——
##   防空壳测试会**同时**钉这两条（只翻这个字段而 evaluate 仍返回 false 也会被抓住）。
var judgeable: bool = false

var _params: Dictionary = {}


func _init(params: Dictionary = {}) -> void:
	_params = params.duplicate(true)


## 该条件的阈值参数（注册表规格里声明过的那些）。
func get_params() -> Dictionary:
	return _params


## 取单个参数，缺失时用调用方给的兜底值。
func get_param(key: String, fallback: Variant) -> Variant:
	return _params.get(key, fallback)


## 三态求值（子类覆写）。基类恒为「判不了」。
func evaluate(_snapshot: Dictionary) -> int:
	return EVAL_UNAVAILABLE


## 归属 peer（无归属返回 `NO_PEER`）。
##   默认**无归属**（如超时结束没有触发者）；有归属的条件（如 `kill_target`）自行覆写。
func owner_of(_snapshot: Dictionary) -> int:
	return NO_PEER


## 从 snapshot 里取某个 peer 的击杀数（`kill_target` / `score_target` 共用口径）。
##   ⚠ 只读「权威端下发的 scores 副本」，判生死一律走它 —— 与 ADR-008 同款纪律。
static func kills_of(snapshot: Dictionary, peer_id: int) -> int:
	var scores: Dictionary = snapshot.get("scores", {})
	if not scores.has(peer_id):
		return 0
	var entry: Dictionary = scores[peer_id]
	return int(entry.get("kills", 0))


## snapshot 里达到 `threshold` 杀数的 peer（按 peer_id 升序取第一个 → 跨端可复现）。
##   ⚠ 必须**排序后**取：直接遍历 Dictionary 会拿到插入序，跨端不一致时 `decisive_peer` 会分叉。
static func first_peer_reaching(snapshot: Dictionary, threshold: int) -> int:
	var scores: Dictionary = snapshot.get("scores", {})
	var ids: Array = scores.keys()
	ids.sort()
	for key: Variant in ids:
		if kills_of(snapshot, int(key)) >= threshold:
			return int(key)
	return NO_PEER


## 三态的可读名（诊断日志用；⚠ 断言请按语义比对三态常量，不要依赖本字符串）。
static func status_name(status: int) -> String:
	match status:
		EVAL_OK_TRUE:
			return "OK_TRUE"
		EVAL_OK_FALSE:
			return "OK_FALSE"
		EVAL_UNAVAILABLE:
			return "UNAVAILABLE"
	return "UNKNOWN(%d)" % status