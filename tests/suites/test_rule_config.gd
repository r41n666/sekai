extends TestSuite
## D2-04 · 规则配置化 + 玩家属性（`design/gdd/05_rule_config_spec.md`）
##
## 需求出处：`design/gdd/05_rule_config_spec.md` §1~§8（结构 / 条件类型 / 注册与加载 /
##   组合语义 / 挂接时机 / 属性配置化 / 迁移路径 / MVP 边界）+ `docs/architecture/control_checklist.md` §4
##
## ══════════════════════════════════════════════════════════════════════
##  本 suite 存在的理由：G4 已关闭的判据不得回退，且本次改动**触碰了判定链路本身**
## ══════════════════════════════════════════════════════════════════════
##  `ScoreManager._check_end_condition()` 从「两条写死判断」换成「求值规则集」。
##  这类改动最危险的失败形态是**静默退化**：判定变成「永不结束」或「永远结束」，
##  而测试全绿（形态同 C-18「比分永远 0」—— 本项目已栽两次）。
##  → 故本 suite 的第 1 组用例是**等价性**断言：默认规则集的求值结果与旧写死逻辑逐位相同。
##
## ── 判定方法 ──
##   · `RuleSet.evaluate(snapshot)` 是**纯函数**（不碰 multiplayer / 场景树 / 时间）
##     → 可直接用字面量 Dictionary 断言，无需引擎特性、无需真实对局。
##   · `ScoreManager` 侧仍走既有「可测核心逻辑与 RPC 外壳分离」路线（见 test_score_manager.gd）。
##   · `PlayerStats.apply_player_stats()` 在 **`add_child()` 之前**调用（规格 §6.3），
##     因为 `player.gd::_ready()` 会执行 `health = max_health`。
##
## ── ⚠ 本 suite 全程**不依赖 await** ──
##   `test_runner.gd` 用 `suite.call(name)` **同步调用**用例；用例里一旦 `await`，
##   会在首个 `await` 处静默返回、后续断言不执行且**不报错**（本项目陷阱）。

## 规则层源码路径（纪律锁用；读源码时**必须剥注释**，见 §4-13）。
const RULE_SRC_DIR := "res://scripts/game/rules/"
const RULE_FILES := [
	"res://scripts/game/rules/match_rule.gd",
	"res://scripts/game/rules/kill_target_rule.gd",
	"res://scripts/game/rules/time_limit_rule.gd",
	"res://scripts/game/rules/unavailable_rule.gd",
	"res://scripts/game/rules/rule_set.gd",
]
const REGISTRY_SRC := "res://scripts/game/rules/condition_registry.gd"
const RULESET_SRC := "res://scripts/game/rules/match_ruleset.gd"
const STATS_SRC := "res://scripts/game/rules/player_stats.gd"
const SCORE_MANAGER_SRC := "res://scripts/game/score_manager.gd"
const MAIN_SRC := "res://scripts/main.gd"
const PLAYER_SRC := "res://scripts/player.gd"
const PLAYER_SCENE := "res://scenes/player.tscn"

## 4 个本期「注册但显式不可用」的条件类型（规格 §8.2）。
const UNAVAILABLE_TYPES := ["collect_items", "defeat_boss", "score_target", "survive_rounds"]
## 2 个本期真实现的条件类型。
const AVAILABLE_TYPES := ["kill_target", "time_limit"]

## 内置默认规则集 id。
const DEFAULT_ID := "ffa_kill15"


# ══════════════════════════════════════════════════════════════════════
#  测试辅助
# ══════════════════════════════════════════════════════════════════════

## 读源码并**剥注释**（§4-13 铁律：纪律锁若不剥注释，会搜到自己的注释文本）。
##   ⚠ 剥注释时**只保留 `#` 之前的代码**，不能「有 `#` 就整行丢」——
##   那会把 `xxx(true) # 注释` 这类「代码 + 行尾注释」的**代码部分**也丢掉，
##   导致代码明明在、纪律锁却报「没调用」（ES-4.2 实测）。
func _strip_comments(src: String) -> String:
	var out: Array[String] = []
	for raw: String in src.split("\n"):
		var code := ""
		var in_str := false
		var quote := ""
		for i in raw.length():
			var ch := raw[i]
			if in_str:
				code += ch
				if ch == quote:
					in_str = false
				continue
			if ch == "\"" or ch == "'":
				in_str = true
				quote = ch
				code += ch
				continue
			if ch == "#":
				break
			code += ch
		out.append(code)
	return "\n".join(out)


func _read_source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		fail("无法读取源码 %s" % path)
		return ""
	return f.get_as_text()


func _read_code(path: String) -> String:
	return _strip_comments(_read_source(path))


## 造一份求值快照（纯数据；缺键的用例单独构造）。
func _snap(scores: Dictionary, time_remaining: float) -> Dictionary:
	return {
		"scores": scores,
		"time_remaining": time_remaining,
		"match_state": 2,
		"elapsed": maxf(300.0 - time_remaining, 0.0),
	}


## 造一个「手工驱动」的 ScoreManager（关掉 `_process` 自动驱动）。
func _new_manager() -> ScoreManager:
	var mgr := ScoreManager.new()
	mgr.auto_drive = false
	add_child(mgr)
	return mgr


## 造一份「自定义阈值」配置（等价于房主配 3 杀）。
func _custom_config(target_kills: int, combine_: String = "ANY_OF",
		duration: float = 300.0) -> Dictionary:
	return {
		"schema_version": 1,
		"ruleset_id": "custom_%d" % target_kills,
		"label": "自定义 · 先到 %d 杀" % target_kills,
		"combine": combine_,
		"winner_policy": "MAX_KILLS",
		"duration_limit": duration,
		"conditions": [
			{"type": "kill_target", "enabled": true, "params": {"target_kills": target_kills}},
			{"type": "time_limit", "enabled": true, "params": {}},
		],
		"fail_conditions": [],
		"player_defaults": {},
	}


# ══════════════════════════════════════════════════════════════════════
#  ① 等价性：默认规则集求值 ≡ 旧写死逻辑（规格 §7.2 M2 / §7.3 第 1 条）
# ══════════════════════════════════════════════════════════════════════

## ⛔ 本组是整个 suite 最重要的一组：**规则化不得改变任何既有判定结果**。
## 旧写死逻辑只有两条：`time_remaining <= 0.0` **或** `_max_kills() >= kill_target`。
## 逐例覆盖：① 未达标不结束 ② 超时结束 ③ 达标结束 ④ 两者同时成立也结束
##            ⑤ 阈值边界（target-1 不结束 / target 结束）⑥ 空表不结束。
func test_default_ruleset_matches_legacy_end_condition() -> void:
	var rs := MatchRuleset.builtin_default(15, 300.0)
	check_eq(rs.ruleset_id(), DEFAULT_ID, "内置默认规则集 id 应为 ffa_kill15")
	var cases := [
		# [说明, scores, time_remaining, kill_target, 旧逻辑期望, 说明]
		["开局未达标", {1: {"kills": 0, "deaths": 0}}, 300.0, 15, false],
		["差1 杀未达标", {1: {"kills": 14, "deaths": 0}}, 300.0, 15, false],
		["恰好达标", {1: {"kills": 15, "deaths": 0}}, 300.0, 15, true],
		["超额达标", {1: {"kills": 20, "deaths": 5}}, 300.0, 15, true],
		["超时（未达标）", {1: {"kills": 3, "deaths": 1}}, 0.0, 15, true],
		["超时（恰好0 杀）", {}, 0.0, 15, true],
		["超时（负值被夹前也应结束）", {1: {"kills": 0, "deaths": 0}}, -1.0, 15, true],
		["空表 + 未超时", {}, 300.0, 15, false],
		["多人：他人达标", {1: {"kills": 2, "deaths": 0}, 2: {"kills": 15, "deaths": 9}}, 300.0, 15, true],
		["自定义阈值 3 杀", {1: {"kills": 3, "deaths": 0}}, 300.0, 3, true],
		["自定义阈值 3 杀未达标", {1: {"kills": 2, "deaths": 0}}, 300.0, 3, false],
	]
	for c: Array in cases:
		var scores: Dictionary = c[1]
		var t_rem := float(c[2])
		var k_target := int(c[3])
		var legacy := bool(c[4])
		# 旧写死逻辑（逐字复制迁移前的实现，作为等价性基准）
		var legacy_result := t_rem <= 0.0
		var max_kills := 0
		for key: Variant in scores:
			max_kills = maxi(max_kills, int((scores[key] as Dictionary).get("kills", 0)))
		if max_kills >= k_target:
			legacy_result = true
		var actual := MatchRuleset.builtin_default(k_target, 300.0).rule_set.evaluate(
			_snap(scores, t_rem))
		check_eq(actual.should_end, legacy_result,
			"「%s」：规则集求值应与旧写死逻辑相同" % str(c[0]))
		check_eq(actual.should_end, legacy, "「%s」：基准期望值本身应自洽" % str(c[0]))


## 默认规则集的两个阈值**必须从 `ScoreManager` 字段读**（规格 §7.1，本任务最容易踩的坑）。
##   既有测试直接写 `mgr.kill_target = 3` / `mgr.match_duration = 10.0`；
##   若阈值被写死在配置里，这两条既有测试会当场转红。
func test_default_ruleset_thresholds_track_manager_fields() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 3, "deaths": 0}}
	mgr.time_remaining = 300.0
	# 默认 15 杀 → 3 杀不结束
	check_false(mgr._check_end_condition(), "默认 kill_target=15 时3 杀不应结束")
	# 改字段 → 判定随之改变（这是既有测试 test_live_tick_ends_on_kill_target 的护栏）
	mgr.kill_target = 3
	check_true(mgr._check_end_condition(), "kill_target 改成 3 后 3 杀应结束（阈值必须读字段）")
	# 再改回 → 判定随之回退（证明不是「一次性缓存」）
	mgr.kill_target = 15
	check_false(mgr._check_end_condition(), "kill_target 改回 15 后 3 杀不应结束（不得缓存旧阈值）")
	mgr.queue_free()


## `match_duration` 字段同样必须被读到（既有测试写 `mgr.match_duration = 10.0`）。
func test_default_ruleset_reads_match_duration_field() -> void:
	var mgr := _new_manager()
	mgr.kill_target = 15
	mgr.start_match()
	mgr._drive_countdown(ScoreManager.COUNTDOWN_SECONDS + 0.01)
	mgr.match_duration = 10.0
	mgr.time_remaining = 10.0
	mgr._tick_live(4.0)
	check_near(mgr.time_remaining, 6.0, 0.001, "match_duration=10.0 时 LIVE 应从 10开始递减")
	check_eq(mgr.match_state, ScoreManager.MatchState.LIVE, "未到 0 不应结算")
	mgr.queue_free()


## 端到端等价：走真实 `_tick_live` → `_check_end_condition` → `_end_match` 路径，
##   超时与达标两条路都要与迁移前一致（判定链路整体没被改坏）。
func test_live_tick_end_paths_still_equivalent() -> void:
	# 路径①：达标结束
	var mgr := _new_manager()
	mgr.start_match()
	mgr._drive_countdown(ScoreManager.COUNTDOWN_SECONDS + 0.01)
	mgr.kill_target = 3
	for i in 3:
		mgr._apply_kill(1, 2)
	mgr._tick_live(0.016)
	check_eq(mgr.match_state, ScoreManager.MatchState.ENDED, "3 杀达标应触发结算")
	check_eq(mgr.winner_id, 1, "达标者应为胜者")
	mgr.queue_free()
	# 路径②：超时结束（比击杀数多者胜 —— `_evaluate_winner` 口径未变）
	var mgr2 := _new_manager()
	mgr2.scores = {1: {"kills": 3, "deaths": 1}, 2: {"kills": 5, "deaths": 4}}
	mgr2.start_match()
	mgr2._drive_countdown(ScoreManager.COUNTDOWN_SECONDS + 0.01)
	mgr2.match_duration = 10.0
	mgr2.time_remaining = 10.0
	mgr2._tick_live(11.0)
	check_eq(mgr2.match_state, ScoreManager.MatchState.ENDED, "时间耗尽应触发结算")
	check_eq(mgr2.winner_id, 2, "超时结算应比击杀数：5 杀者胜出")
	mgr2.queue_free()


## 并列语义未被规则化破坏（`WINNER_TIE = -2`；规格 §4.3：一个字节都不改）。
func test_tie_semantics_preserved_under_rule_evaluation() -> void:
	var mgr := _new_manager()
	mgr.scores = {
		1: {"kills": 4, "deaths": 2},
		2: {"kills": 4, "deaths": 2},
	}
	check_eq(mgr._evaluate_winner(), ScoreManager.WINNER_TIE,
		"kills/deaths 全同且≥2 人应判并列 WINNER_TIE")
	mgr.queue_free()


# ══════════════════════════════════════════════════════════════════════
#  ② 组合语义：ALL_OF / ANY_OF（规格 §4.1）
# ══════════════════════════════════════════════════════════════════════

## `ANY_OF`：任一成立即结束（默认口径）。
func test_any_of_semantics() -> void:
	var rs := MatchRuleset.builtin_default(15, 300.0)
	check_eq(rs.combine_mode(), "ANY_OF", "内置默认应为 ANY_OF")
	var low_kills := _snap({1: {"kills": 1, "deaths": 0}}, 300.0)
	check_false(rs.rule_set.evaluate(low_kills).should_end,
		"ANY_OF：两项都不成立不应结束")
	var reached := _snap({1: {"kills": 15, "deaths": 0}}, 300.0)
	check_true(rs.rule_set.evaluate(reached).should_end, "ANY_OF：击杀达标应结束")
	var expired := _snap({1: {"kills": 1, "deaths": 0}}, 0.0)
	check_true(rs.rule_set.evaluate(expired).should_end, "ANY_OF：超时应结束")


## `ALL_OF`：全部成立才结束（**含「只成立一项时不得结束」这个反向断言**）。
func test_all_of_semantics() -> void:
	var cfg := _custom_config(15, "ALL_OF")
	cfg["conditions"] = [
		{"type": "kill_target", "enabled": true, "params": {"target_kills": 15}},
		{"type": "time_limit", "enabled": true, "params": {}},
	]
	var rs := MatchRuleset.new(cfg)
	check_eq(rs.combine_mode(), "ALL_OF", "配置里的 ALL_OF 应生效")
	# 只满足一项 → **不结束**（这是与 ANY_OF 的关键差异）
	var only_kills := _snap({1: {"kills": 15, "deaths": 0}}, 300.0)
	check_false(rs.rule_set.evaluate(only_kills).should_end,
		"ALL_OF：只满足击杀条件时不应结束（这是与 ANY_OF 的核心差异）")
	var only_time := _snap({1: {"kills": 0, "deaths": 0}}, 0.0)
	check_false(rs.rule_set.evaluate(only_time).should_end,
		"ALL_OF：只满足超时条件时不应结束")
	# 两项都满足 → 结束
	var both := _snap({1: {"kills": 15, "deaths": 0}}, 0.0)
	check_true(rs.rule_set.evaluate(both).should_end, "ALL_OF：两项都满足应结束")


## ⛔ 变异目标 #3：`ALL_OF` 改成 `ANY_OF` 必须被抓住。
##   上面的 `only_kills` / `only_time` 两条反向断言就是牙齿。
func test_all_of_is_not_silently_any_of() -> void:
	var cfg := _custom_config(15, "ALL_OF")
	var rs := MatchRuleset.new(cfg)
	check_eq(rs.rule_set.combine, "ALL_OF", "combine 应原样传给 RuleSet（不得被改写）")
	var one_only := _snap({1: {"kills": 15, "deaths": 0}}, 300.0)
	check_false(rs.rule_set.evaluate(one_only).should_end,
		"ALL_OF 语义必须真的生效：单项成立不得结束")


## 短路：`ANY_OF` 首个成立即返回（后面的条件**不再求值**）。
##   验证方式：放一个「求值就会自增计数」的探针条件放在末尾 —— 它不该被求值。
##   ⚠ 这样断言的是**语义**（短路真的省掉了求值），不是"结果一样"。
func test_any_of_short_circuits_after_first_satisfied() -> void:
	var probe := _CountingRule.new("probe_short_circuit", true)
	var rs := RuleSet.new("ANY_OF", [
		KillTargetRule.new({"target_kills": 1}),
		probe,
	])
	var result := rs.evaluate(_snap({1: {"kills": 1, "deaths": 0}}, 300.0))
	check_true(result.should_end, "ANY_OF 首个成立应结束")
	check_eq(probe.calls, 0, "ANY_OF 短路：首个成立后**不应**再求值后面的条件")


## 短路：`ALL_OF` 首个不成立即返回。
func test_all_of_short_circuits_after_first_failed() -> void:
	var probe := _CountingRule.new("probe_short_circuit2", true)
	var rs := RuleSet.new("ALL_OF", [
		KillTargetRule.new({"target_kills": 99}),
		probe,
	])
	var result := rs.evaluate(_snap({1: {"kills": 1, "deaths": 0}}, 300.0))
	check_false(result.should_end, "ALL_OF 首个不成立不应结束")
	check_eq(probe.calls, 0, "ALL_OF 短路：首个不成立后**不应**再求值后面的条件")


## 禁用项：编译期被剔除（规格 §1.2.2「等价于从列表移除」），且不参与求值。
func test_disabled_condition_is_skipped() -> void:
	# 判定口径：`RuleSet` 只接收**已剔除**的规则数组，剔除发生在
	# `MatchRuleset._compile`（那是配置 → 规则对象的唯一编译入口）。
	# 故这里断言两件事：① 编译后启用条件数正确 ② 被剔除的条件不参与求值。
	var cfg := _custom_config(3)
	cfg["conditions"] = [
		{"type": "kill_target", "enabled": false, "params": {"target_kills": 1}},
		{"type": "time_limit", "enabled": true, "params": {}},
	]
	var mrs := MatchRuleset.new(cfg)
	check_eq(mrs.rule_set.active_count(), 1,
		"enabled=false 的条目应在编译期被剔除（等价于从列表移除）")
	check_eq(mrs.rule_set.rules[0].type_id, "time_limit", "剩下的应是唯一启用的条件")
	check_eq(mrs.rule_set.declared_types, ["time_limit"],
		"声明顺序快照里也不该含被剔除的条件")
	# 被剔除的 kill_target(1 杀) 若仍参与求值 → 1 杀就会结束；剔除后只有超时条件。
	check_eq(mrs.effective_kill_target(15), 15,
		"被剔除的 kill_target 不应贡献生效阈值（回落兜底值）")
	check_false(mrs.rule_set.evaluate(_snap({1: {"kills": 5, "deaths": 0}}, 300.0)).should_end,
		"被剔除的 kill_target(1杀) 不得参与求值 —— 否则 5 杀就会误结束对局")
	check_true(mrs.rule_set.evaluate(_snap({1: {"kills": 0, "deaths": 0}}, 0.0)).should_end,
		"剩下的 time_limit 仍应正常判定")
	check_false(mrs.has_unavailable_conditions(), "剔除后不应报告含不可用条件")


## 空列表语义（规格 §4.1）：`ANY_OF` + 空 → 恒 false；`ALL_OF` + 空 → 恒 true。
func test_empty_condition_list_semantics() -> void:
	var any_empty := RuleSet.new("ANY_OF", [])
	check_false(any_empty.evaluate(_snap({1: {"kills": 99, "deaths": 0}}, 0.0)).should_end,
		"ANY_OF + 空条件：恒不结束（合法，用于只靠显式失败条件结束的对局）")
	var all_empty := RuleSet.new("ALL_OF", [])
	check_true(all_empty.evaluate(_snap({}, 300.0)).should_end,
		"ALL_OF + 空条件：恒 true（危险，故加载期必须拦掉）")


## `ALL_OF` + 空条件必须在**加载期**被拒（规格 §4.1：交给作者踩不如拦掉）。
func test_all_of_with_empty_conditions_is_rejected_on_load() -> void:
	var cfg := _custom_config(15, "ALL_OF")
	cfg["conditions"] = []
	var errors := MatchRuleset.validate_config(cfg)
	check_true(not errors.is_empty(), "ALL_OF + 空启用条件应被判为配置错误")
	# ⚠ 断言按**语义**（这条配置确实非法）而非搜字面量
	var hit := false
	for msg: String in errors:
		if msg.contains("ALL_OF") and msg.contains("条件"):
			hit = true
	check_true(hit, "错误信息应点明是 ALL_OF 与空条件的组合（否则用户不知怎么改）")


# ══════════════════════════════════════════════════════════════════════
#  ③ 自定义阈值真的生效
# ══════════════════════════════════════════════════════════════════════

## 配置 3 杀 → 3 杀结束、2 杀不结束；且 `ScoreManager.effective_kill_target()` 返回 3。
func test_custom_kill_target_takes_effect() -> void:
	var mgr := _new_manager()
	check_true(mgr.set_ruleset(_custom_config(3)), "权威端应能设置合法规则集")
	check_eq(mgr.effective_kill_target(), 3, "生效的击杀目标应是配置里的 3")
	mgr.scores = {1: {"kills": 2, "deaths": 0}}
	mgr.time_remaining = 300.0
	check_false(mgr._check_end_condition(), "2 杀不应结束（配置为 3 杀）")
	mgr.scores = {1: {"kills": 3, "deaths": 0}}
	check_true(mgr._check_end_condition(), "3 杀应结束（配置为 3 杀）")
	mgr.queue_free()


## 自定义阈值经由**真实对局链路**同样生效（`start_match` → `_tick_live` → ENDED）。
func test_custom_threshold_ends_real_match() -> void:
	var mgr := _new_manager()
	mgr.set_ruleset(_custom_config(3))
	mgr.start_match()
	mgr._drive_countdown(ScoreManager.COUNTDOWN_SECONDS + 0.01)
	for i in 3:
		mgr._apply_kill(1, 2)
	mgr._tick_live(0.016)
	check_eq(mgr.match_state, ScoreManager.MatchState.ENDED, "配 3 杀后 3 杀应结束对局")
	mgr.queue_free()


## 自定义 `duration_limit` → `effective` 时长口径一致。
func test_custom_duration_limit_is_recorded() -> void:
	var cfg := _custom_config(15, "ANY_OF", 60.0)
	var rs := MatchRuleset.new(cfg)
	check_near(rs.duration_limit(), 60.0, 0.001, "配置里的 duration_limit 应被保留")
	check_true(rs.has_time_limit(), "配了 time_limit 条件 → has_time_limit 应为真")


# ══════════════════════════════════════════════════════════════════════
#  ④⑤ 不可用条件的三态 + 防空壳锁（本任务最重要的设计约束）
# ══════════════════════════════════════════════════════════════════════

## ⛔⛔ **防空壳锁**：4 个未实现条件**绝不允许**返回 `false`。
##   理由：返回 `false` 会让「配了 5 个条件只跑通 1 个」看起来像
##   「另外 4 个没达成」—— 日志全正常、只有规则没生效，排查成本极高
##   （形态同 C-18「比分永远 0」，本项目已栽两次）。
##   ⚠ 断言按**语义**写（返回值 != OK_FALSE），**不搜字面量**（§4-16）。
func test_unavailable_conditions_never_report_false() -> void:
	var snapshot := _snap({1: {"kills": 999, "deaths": 0}}, -99.0)
	for type_id: String in UNAVAILABLE_TYPES:
		var rule := ConditionRegistry.compile(type_id, {})
		check_true(rule != null, "「%s」应能编译出规则对象（注册表留位）" % type_id)
		if rule == null:
			continue
		check_false(rule.judgeable, "「%s」是占位类型，judgeable 应为 false" % type_id)
		var status := rule.evaluate(snapshot)
		check_true(status != MatchRule.EVAL_OK_FALSE,
			"⛔「%s」不得返回 OK_FALSE —— 不可用条件返回 false 就是静默失效（C-18 同源）"
			% type_id)
		check_eq(status, MatchRule.EVAL_UNAVAILABLE,
			"「%s」求值必须返回 UNAVAILABLE" % type_id)
		check_eq(rule.owner_of(snapshot), MatchRule.NO_PEER,
			"「%s」判不了就没有归属 peer" % type_id)
		# ⚠ 换一个"看起来该成立"的快照再验一次：占位条件必须**恒**不可用，
		#   不能因为快照内容恰好满足就变成 true/false。
		var other := _snap({}, 300.0)
		check_eq(rule.evaluate(other), MatchRule.EVAL_UNAVAILABLE,
			"「%s」在任何快照下都应是 UNAVAILABLE" % type_id)


## 真实现的条件**必须**能返回 true/false 两态（否则就是「全都不可用」的假端）。
##   这一条与上面的防空壳锁成对：**两个方向都要钉**（§4-16「弱断言有两个方向」）。
func test_available_conditions_do_return_both_states() -> void:
	var kt := ConditionRegistry.compile("kill_target", {"target_kills": 3})
	check_eq(kt.evaluate(_snap({1: {"kills": 1, "deaths": 0}}, 300.0)),
		MatchRule.EVAL_OK_FALSE, "kill_target 未达标应返回 OK_FALSE（真判了）")
	check_eq(kt.evaluate(_snap({1: {"kills": 3, "deaths": 0}}, 300.0)),
		MatchRule.EVAL_OK_TRUE, "kill_target 达标应返回 OK_TRUE")
	var tl := ConditionRegistry.compile("time_limit", {})
	check_eq(tl.evaluate(_snap({}, 300.0)), MatchRule.EVAL_OK_FALSE,
		"time_limit 未超时应返回 OK_FALSE")
	check_eq(tl.evaluate(_snap({}, 0.0)), MatchRule.EVAL_OK_TRUE,
		"time_limit 超时应返回 OK_TRUE")


## 不可用条件被配进**启用条件**时 → 规则集判为不可信 → **不结束对局**。
func test_unavailable_condition_blocks_match_end() -> void:
	var cfg := _custom_config(15)
	cfg["conditions"] = [
		{"type": "kill_target", "enabled": true, "params": {"target_kills": 1}},
		{"type": "collect_items", "enabled": true, "params": {}},
	]
	# 直接构造（绕过加载器的回落）以验证**求值层**的独立防线
	var rs := MatchRuleset.new(cfg)
	# 快照刻意让 kill_target **成立**：若不可用条件被静默当 false，
	# ANY_OF 会因 kill_target 成立而结束对局 —— 那就是静默失效。
	var snapshot := _snap({1: {"kills": 1, "deaths": 0}}, 300.0)
	var result := rs.rule_set.evaluate(snapshot)
	check_true(rs.rule_set.blocked_by_unavailable(),
		"规则集含不可用条件时应被标记为不可信")
	check_false(result.should_end,
		"⛔ 含不可用条件时**不得结束对局**（即使其它条件已成立）")
	check_eq(result.decisive_type, "",
		"被不可用条件阻断时不应报出决定性条件类型")


## ⚠ 不可用条件**被短路掩盖**的形态必须堵死。
##   `ANY_OF` 下若先普查不可用、再组合求值，`kill_target` 成立就会短路返回，
##   后面的 `collect_items` 永远没被看见 → 静默失效。
##   → 故求值层必须**先普查全部不可用条件**再判组合。
func test_unavailable_condition_is_not_masked_by_short_circuit() -> void:
	var probe := _CountingRule.new("probe_unavailable_mask", true)
	var rs := RuleSet.new("ANY_OF", [
		KillTargetRule.new({"target_kills": 1}),
		UnavailableRule.new("collect_items", {}),
		probe,
	])
	var result := rs.evaluate(_snap({1: {"kills": 1, "deaths": 0}}, 300.0))
	check_false(result.should_end, "含不可用条件时不得结束（即使首个条件成立）")
	check_true(rs.blocked_by_unavailable(), "不可用条件必须被普查到（不得被短路掩盖）")
	var names := rs.last_unavailable_types()
	check_true(names.has("collect_items"),
		"诊断信息应点名是哪个类型不可用（否则用户不知怎么改）")


## `push_warning` 恰好一次（规格 §8.4「一次/局，不刷屏」）。
##   ⚠ 不靠抓 stderr（脆弱），而是**计数 ScoreManager 自己的告警状态**。
##   每帧都判定、连判 5 次 → 仍只应告警一次。
func test_unavailable_condition_warns_exactly_once_per_match() -> void:
	var mgr := _new_manager()
	var cfg := _custom_config(1)
	cfg["conditions"] = [
		{"type": "kill_target", "enabled": true, "params": {"target_kills": 1}},
		{"type": "defeat_boss", "enabled": true, "params": {}},
	]
	mgr._ruleset = MatchRuleset.new(cfg) # 直接注入，绕过加载器回落
	mgr.scores = {1: {"kills": 5, "deaths": 0}}
	mgr.time_remaining = 300.0
	# 连判 5 次：应始终不结束，且只告警一次
	for i in 5:
		check_false(mgr._check_end_condition(), "第 %d 次判定：含不可用条件不得结束对局" % (i + 1))
	check_true(mgr._ruleset_warned, "本局应已就「不可用条件」告警过一次")
	# 复位后允许再告警（新的一局）
	mgr._apply_reset()
	check_false(mgr._ruleset_warned, "复位后应允许再次告警（新的一局）")
	mgr.queue_free()


## ⚠ 「一次/局」的**另一半**：`push_warning` 那个调用本身必须真的在。
#### 为什么必须单独一条（这是变异测试 M2 抓出来的真实弱断言）
##   上一条只断言 `_ruleset_warned` 标志 —— 而该标志是在`push_warning` **之前**置位的，
##   于是「把`push_warning(...)` 整行删掉、只留标志」照样全绿（变异体存活）。
##   → 这正是本项目反复栽的「弱断言」形态：断言了状态，没断言**行为**。
##   → 故补一条源码纪律锁：告警函数体内必须有 `push_warning(` 调用。
##   ⚠ 按 §4-13 先剥注释；按语义判「这个告警函数有没有发出告警」，
##     而**不是**去比对整条 `push_warning` 文本（守恒对照组见变异脚本 g3）。
func test_unavailable_warning_actually_emits_a_warning() -> void:
	var code := _read_code(SCORE_MANAGER_SRC)
	var start := code.find("func _warn_unavailable_once")
	check_true(start >= 0, "ScoreManager 应有 _warn_unavailable_once 告警函数")
	if start < 0:
		return
	var end := code.find("\nfunc ", start + 1)
	var body := code.substr(start, (end - start) if end > start else -1)
	check_true(body.contains("push_warning("),
		"⛔ 告警函数体内必须有 push_warning 调用 —— 只置标志不告警 = "
		+ "「规则没生效但全程静默」，与 C-18「比分永远 0」同源")


## `disabled` 的不可用条件**不阻断**对局（禁用 = 从列表移除，规格 §1.2.2）。
func test_disabled_unavailable_condition_does_not_block() -> void:
	var cfg := _custom_config(1)
	cfg["conditions"] = [
		{"type": "kill_target", "enabled": true, "params": {"target_kills": 1}},
		{"type": "score_target", "enabled": false, "params": {}},
	]
	var rs := MatchRuleset.new(cfg)
	check_eq(rs.rule_set.active_count(), 1, "禁用的占位条件应被剔除，不进编译产物")
	var result := rs.rule_set.evaluate(_snap({1: {"kills": 1, "deaths": 0}}, 300.0))
	check_true(result.should_end, "禁用的不可用条件不应阻断对局")
	check_false(rs.has_unavailable_conditions(), "剔除后不应再报告含不可用条件")


## 加载期就把「配了占位条件」拦下并回落（规格 §3.3：不静默失败）。
func test_placeholder_condition_rejected_on_load() -> void:
	for type_id: String in UNAVAILABLE_TYPES:
		var cfg := _custom_config(15)
		cfg["conditions"] = [
			{"type": "kill_target", "enabled": true, "params": {"target_kills": 15}},
			{"type": type_id, "enabled": true, "params": {}},
		]
		var errors := MatchRuleset.validate_config(cfg)
		check_true(not errors.is_empty(),
			"配了占位条件「%s」应在加载期被拒（规格 §3.3）" % type_id)
		var loaded := MatchRuleset.load_ruleset(cfg, 15, 300.0)
		check_eq(loaded.ruleset_id(), DEFAULT_ID,
			"配了占位条件「%s」应回落到内置默认" % type_id)


# ══════════════════════════════════════════════════════════════════════
#  ⑥ 属性应用（规格 §6.1/ §6.3）
# ══════════════════════════════════════════════════════════════════════

## 7 项属性**逐项**生效，且落地到正确的字段（player 自身 / weapon 槽）。
func test_all_seven_player_stats_take_effect() -> void:
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate()
	add_child(player)
	var rifle: Node = player.get_node_or_null("MikuModel/WeaponMount/Rifle")
	check_true(rifle != null, "player.tscn 应有 Rifle 槽（属性落地目标）")
	if rifle == null:
		player.queue_free()
		return
	var overrides := {
		"max_health": 200.0, "walk_speed": 5.0, "sprint_speed": 9.0,
		"jump_velocity": 7.0, "weapon_damage": 40.0,
		"weapon_magazine_size": 45.0, "weapon_reload_time": 1.2,
	}
	var applied := PlayerStats.apply_player_stats(player, overrides, true)
	# player 侧 4 项
	check_eq(int(applied.size()), 7, "7 项属性都应被应用")
	check_near(player.get("max_health"), 200.0, 0.001, "max_health 应生效")
	check_near(player.get("walk_speed"), 5.0, 0.001, "walk_speed 应生效")
	check_near(player.get("sprint_speed"), 9.0, 0.001, "sprint_speed 应生效")
	check_near(player.get("jump_velocity"), 7.0, 0.001, "jump_velocity 应生效")
	# weapon 侧 3 项（落到 Rifle 槽）
	check_near(rifle.get("damage"), 40.0, 0.001, "weapon_damage 应落到 Rifle.damage")
	check_near(float(rifle.get("magazine_size")), 45.0, 0.001,
		"weapon_magazine_size 应落到 Rifle.magazine_size")
	check_near(rifle.get("reload_time"), 1.2, 0.001,
		"weapon_reload_time 应落到 Rifle.reload_time")
	player.queue_free()


## ⚠ 默认值必须与现有 `@export` **逐字一致**（防默认值漂移）。
##   这是规格 §6.1 的硬要求：属性规格表的 default 写错了，
##   「不配置时行为与改造前不一致」且**没有任何报错**。
func test_player_stat_defaults_match_exports() -> void:
	# player 侧 4 项 —— 直接对着 player 节点的实际 @export 值比
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate()
	add_child(player)
	var expected := {
		"max_health": "max_health",
		"walk_speed": "walk_speed",
		"sprint_speed": "sprint_speed",
		"jump_velocity": "jump_velocity",
	}
	for stat_id: String in expected:
		var field := String(expected[stat_id])
		check_near(PlayerStats.default_of(stat_id), float(player.get(field)), 0.0001,
			"属性「%s」的规格默认值必须与 player 的 @export %s 逐字一致" % [stat_id, field])
	player.queue_free()
	# weapon 侧 3 项
	var weapon_scene := "res://scenes/weapons/rifle.tscn"
	if not ResourceLoader.exists(weapon_scene):
		# 回落到任意一个 weapon 槽场景（属性默认值是 Weapon 基类的 @export）
		weapon_scene = "res://scenes/weapons/usp.tscn"
	var rifle := (load(weapon_scene) as PackedScene).instantiate()
	add_child(rifle)
	var weapon_expected := {
		"weapon_damage": "damage",
		"weapon_magazine_size": "magazine_size",
		"weapon_reload_time": "reload_time",
	}
	for stat_id: String in weapon_expected:
		var field := String(weapon_expected[stat_id])
		# ⚠ USP 场景覆盖了这三个值（magazine_size=12 / damage=34 / reload=2.2），
		#   故只在 Rifle（未覆盖）上做逐字比对；非 Rifle 场景只断言"规格值在合理区间"。
		if weapon_scene.ends_with("rifle.tscn"):
			check_near(PlayerStats.default_of(stat_id), float(rifle.get(field)), 0.0001,
				"属性「%s」的规格默认值必须与 weapon 的 @export %s 逐字一致" % [stat_id, field])
		else:
			check_true(PlayerStats.default_of(stat_id) > 0.0,
				"属性「%s」应有正的默认值" % stat_id)
	rifle.queue_free()


## 恰好 7 项属性（不多不少）—— 防止有人漏接或偷偷多加。
func test_exactly_seven_stats_registered() -> void:
	var ids := PlayerStats.stat_ids()
	check_eq(ids.size(), 7, "本期应恰好接入 7 项属性")
	for expected_id: String in [
		"max_health", "walk_speed", "sprint_speed", "jump_velocity",
		"weapon_damage", "weapon_magazine_size", "weapon_reload_time",
	]:
		check_true(ids.has(expected_id), "属性「%s」应登记在册" % expected_id)
	# ⚠ 视角/姿态/特效参数**本期不接**（规格 §6.1）——钉住"不多"
	for not_connected: String in ["mouse_sensitivity", "tracer_lifetime", "stance_height"]:
		check_false(ids.has(not_connected),
			"「%s」本期不应接入（视角属个人偏好 / 姿态是 const / 特效属美术配置）"
			% not_connected)


## 越界值被**夹取**到 min/max，不报错（规格 §6.1）。
func test_out_of_range_stats_are_clamped() -> void:
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate()
	add_child(player)
	PlayerStats.apply_player_stats(player, {"max_health": 99999.0, "walk_speed": -50.0}, true)
	check_near(player.get("max_health"), 1000.0, 0.001, "超上限应夹到规格 max")
	check_near(player.get("walk_speed"), 0.1, 0.001, "负值应夹到规格 min")
	# 夹取是纯函数，边界值本身应原样通过
	check_near(PlayerStats.clamp_stat("max_health", 1.0), 1.0, 0.001, "下边界值应原样通过")
	check_near(PlayerStats.clamp_stat("max_health", 1000.0), 1000.0, 0.001,
		"上边界值应原样通过")
	player.queue_free()


## 未登记的属性 id 被**剔除**并可被诊断（不静默带进应用阶段）。
func test_unknown_stat_ids_are_reported_not_silently_ignored() -> void:
	var unknown := PlayerStats.unknown_ids({"max_health": 200.0, "mouse_sens": 0.1})
	check_true(unknown.has("mouse_sens"), "未登记的属性 id 应被诊断出来")
	check_false(unknown.has("max_health"), "已登记的属性不该被误报")
	var normalized := PlayerStats.normalize({"max_health": 200.0, "bogus": 1.0})
	check_false(normalized.has("bogus"), "归一化时应剔除未登记项")
	check_true(normalized.has("max_health"), "归一化应保留已登记项")


## 客户端（非权威）写战斗属性被**拒绝**（规格 §6.2 公平性）。
##   理由：P2P 无服务器权威（ADR-006）下 `max_health` / `damage` 无任何一端二次校验，
##   再开「客户端自选属性」等于在既有信任模型上叠一个免费作弊面。
func test_non_authority_cannot_write_combat_stats() -> void:
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate()
	add_child(player)
	var before := float(player.get("max_health"))
	var applied := PlayerStats.apply_player_stats(player, {"max_health": 999.0}, false)
	check_eq(applied.size(), 0, "非权威端写战斗属性应被拒绝（不应有任何项被应用）")
	check_near(player.get("max_health"), before, 0.0001,
		"非权威端的 max_health 不应被改动")
	# 权威端则可以
	var applied2 := PlayerStats.apply_player_stats(player, {"max_health": 999.0}, true)
	check_eq(applied2.size(), 1, "权威端应能写战斗属性")
	check_near(player.get("max_health"), 999.0, 0.001, "权威端写入应生效")
	player.queue_free()


## `ScoreManager.set_ruleset` 在客户端身份下被拒（客户端不得自定规则）。
func test_non_authority_cannot_set_ruleset() -> void:
	var mgr := _new_manager()
	var old := NetworkManager.is_online
	var old_server := NetworkManager.is_server
	NetworkManager.is_online = true
	NetworkManager.is_server = false
	check_false(mgr.set_ruleset(_custom_config(3)),
		"客户端不得设置规则集（那等于自己定胜负）")
	check_eq(mgr.effective_kill_target(), 15,
		"被拒后生效目标应仍是内置默认 15（配置未生效）")
	NetworkManager.is_online = old
	NetworkManager.is_server = old_server
	mgr.queue_free()


# ══════════════════════════════════════════════════════════════════════
#  ⑦ 属性必须在 add_child() 之前应用（规格 §6.3，本任务最容易踩的坑）
# ══════════════════════════════════════════════════════════════════════

## ⛔⛔ **变异目标 #5 的护栏**：属性在 `add_child()` 之后应用会怎样？
##   `player.gd::_ready()` 执行 `health = max_health` —— 入树后再写 `max_health`，
##   `health` 已被定死 → 表现为「改了血量上限但血条还是 100」，**且不报任何错**。
##   → 本用例钉死两条：① 入树前应用时 health 同步为新值；
##     ②「入树后只写 max_health 而不补health」的确会产生不一致的血量上限。
func test_stats_applied_before_add_child_keeps_health_in_sync() -> void:
	# 路径①（正确）：入树前应用 → 入树后 health == max_health == 200
	var early := (load(PLAYER_SCENE) as PackedScene).instantiate()
	PlayerStats.apply_player_stats(early, {"max_health": 200.0}, true)
	add_child(early) # 此时才_ready() → health = max_health(=200)
	check_near(early.get("max_health"), 200.0, 0.001, "入树前应用：上限应为 200")
	check_near(early.get("health"), 200.0, 0.001,
		"⛔ 入树前应用：_ready() 之后 health 必须等于新的 max_health（不能还是默认 100）")
	early.queue_free()
	# 路径②（错误形态，用于证明这条断言有牙齿）：先入树再写 max_health
	#   —— 若只写上限不补 health，血量就会停在旧值（正是本条要防的缺陷形态）。
	var late := (load(PLAYER_SCENE) as PackedScene).instantiate()
	add_child(late)
	var health_before := float(late.get("health"))
	var max_before := float(late.get("max_health"))
	late.set("max_health", 200.0) # 模拟「入树后才写属性」且没补 health
	check_near(health_before, max_before, 0.0001,
		"入树时 health 应等于当时的 max_health（默认上限）")
	check_true(health_before != 200.0,
		"⛔ 入树后才改 max_health，health 不会自动跟随（这正是必须入树前应用的原因）")
	late.queue_free()


## `PlayerStats.apply_player_stats` 自身会连带同步 `health`（纵深防御）。
##   万一将来某条路径不得不入树后调用，也不该静默半生效。
func test_apply_player_stats_syncs_health_as_belt_and_braces() -> void:
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate()
	add_child(player)
	player.set("health", 30.0) # 先把血打掉
	PlayerStats.apply_player_stats(player, {"max_health": 200.0}, true)
	check_near(player.get("max_health"), 200.0, 0.001, "上限应为 200")
	check_near(player.get("health"), 200.0, 0.001,
		"apply_player_stats 应连带把 health 同步为新的上限（不留半生效状态）")
	player.queue_free()


## `main.gd` 必须在 `add_child()` **之前**调用属性应用（源码纪律锁）。
##   ⚠ 剥注释后按**语义**判：`_make_player` 里 `apply_player_stats` 的调用
##     出现在 `return player` 之前，而 `add_child` 在**调用方**`_sync_players` /
##     `_ready` 里 —— 判据是「`_make_player` 内部不出现 `add_child`」。
func test_main_applies_stats_before_adding_child() -> void:
	var src := _read_code(MAIN_SRC)
	# 抽出 _make_player 函数体
	var start := src.find("func _make_player")
	check_true(start >= 0, "main.gd 应有 _make_player")
	if start < 0:
		return
	var end := src.find("\nfunc ", start + 1)
	var body := src.substr(start, (end - start) if end > start else -1)
	check_true(body.find("PlayerStats.apply_player_stats") >= 0,
		"_make_player 内必须调用 PlayerStats.apply_player_stats")
	check_true(body.find("add_child") < 0,
		"⛔ _make_player 内不得出现 add_child —— 属性必须在入树前应用完"
		+ "（入树后 _ready() 会把 health 定死，见规格 §6.3）")


## ADR-008 冲突 1 的护栏：两端 `max_health` 相等时，显示守卫行为**不变**。
##   （规格 §6.4：`get_display_max_health()` 改读本端已应用的本局配置值，
##     但「超上限 = 协议污染 → 整条丢弃」的**语义一字未改**。）
func test_display_health_guard_semantics_unchanged_after_config() -> void:
	var a := (load(PLAYER_SCENE) as PackedScene).instantiate()
	add_child(a)
	PlayerStats.apply_player_stats(a, {"max_health": 200.0}, true)
	var b := (load(PLAYER_SCENE) as PackedScene).instantiate()
	add_child(b)
	PlayerStats.apply_player_stats(b, {"max_health": 200.0}, true)
	check_near(a.get_display_max_health(), b.get_display_max_health(), 0.0001,
		"配置同步后两端显示上限必须相等（否则血量广播会被永久丢弃）")
	# 守卫语义不变：超上限仍判非法
	check_false(a.call("_is_valid_display_health", 200.5, a.get_display_max_health()),
		"超上限仍必须判非法（ADR-008 铁律，不得因可配置而放宽）")
	check_true(a.call("_is_valid_display_health", 150.0, a.get_display_max_health()),
		"上限内的值仍必须合法")
	a.queue_free()
	b.queue_free()


## 配置了 200 血时，200 的血量广播必须被接受（跨端一致的直接后果）。
func test_configured_max_health_accepts_its_own_broadcast() -> void:
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate()
	add_child(player)
	PlayerStats.apply_player_stats(player, {"max_health": 200.0}, true)
	# 模拟收到远端广播：满血200 应被接受
	player.call("apply_network_state", Vector3.ZERO, 0.0, 200.0)
	check_near(player.get_display_health(), 200.0, 0.001,
		"两端一致时 200 的广播必须被显示（不能被守卫丢弃）")
	player.queue_free()


# ══════════════════════════════════════════════════════════════════════
#  ⑧ 比分板目标文案读实际生效值（M4）
# ══════════════════════════════════════════════════════════════════════

## 造一个**真实**比分板节点（必须用 `scoreboard.tscn`：
##   裸 `Scoreboard.new()` 没有 `$Compact/Box/Row/Objective` 子节点，
##   `@onready` 全是 null → 无法验证目标文案）。
func _new_scoreboard() -> Scoreboard:
	var sb := (load("res://scenes/ui/scoreboard.tscn") as PackedScene).instantiate() as Scoreboard
	add_child(sb)
	return sb


## 取目标文案的当前文本（读真实 Label，验证的是**渲染出来的那句话**）。
func _objective_text(sb: Scoreboard) -> String:
	var label := sb.get_node_or_null("Compact/Box/Row/Objective")
	if label == null:
		fail("比分板缺少 Objective 标签节点")
		return ""
	return str((label as Label).text)


## 配 3 杀→ 比分板文案是「先到 3 杀」，不是硬编码的「先到 15 杀」。
## ⚠ 这条是**第二处硬编码**的护栏（`scoreboard.gd:29 const KILL_TARGET := 15`）。
func test_scoreboard_objective_text_reads_effective_target() -> void:
	var sb := _new_scoreboard()
	var mgr := _new_manager()
	mgr.set_ruleset(_custom_config(3))
	sb.bind(mgr)
	var text := _objective_text(sb)
	check_true(text.contains("3"), "配 3 杀时目标文案应显示 3，实际「%s」" % text)
	check_false(text.contains("15"),
		"⛔ 配 3 杀时目标文案不得仍显示硬编码的 15（实际「%s」）" % text)
	sb.queue_free()
	mgr.queue_free()


## `is_near_target` 的**默认参数 15 必须保留**（既有测试依赖，向后兼容）。
func test_is_near_target_default_parameter_preserved() -> void:
	check_true(Scoreboard.is_near_target(14), "默认参数下 14 杀应处于临界（既有契约）")
	check_false(Scoreboard.is_near_target(15), "默认参数下 15 杀已达标，不该判临界")
	check_false(Scoreboard.is_near_target(3), "默认参数下 3 杀不临界")
	# 显式传参仍工作（配置化后的真实用法）
	check_true(Scoreboard.is_near_target(2, 3), "配 3 杀时 2 杀应处于临界")
	check_false(Scoreboard.is_near_target(3, 3), "配 3 杀时 3 杀已达标")


## 目标文案随规则集下发而刷新（客户端路径：`_apply_ruleset` → 文案变化）。
func test_scoreboard_refreshes_objective_after_ruleset_applied() -> void:
	var sb := _new_scoreboard()
	var mgr := _new_manager()
	sb.bind(mgr)
	check_true(_objective_text(sb).contains("15"),
		"未下发配置前应显示默认 15 杀，实际「%s」" % _objective_text(sb))
	mgr._apply_ruleset(_custom_config(7), "custom_7") # 模拟客户端收到下发
	check_true(_objective_text(sb).contains("7"),
		"收到规则集后目标文案应刷新为 7 杀，实际「%s」" % _objective_text(sb))
	sb.queue_free()
	mgr.queue_free()


# ══════════════════════════════════════════════════════════════════════
#  ⑨ 配置不能自相矛盾
# ══════════════════════════════════════════════════════════════════════

## ⛔ `ALL_OF` 里塞两条阈值不同的 `kill_target` → **必须报错**，不许静默取一个。
##   为什么必须拦：`ALL_OF` 语义是「全部成立」，而「3杀 且 5杀」永不可满足
##   → 对局**永不结束**且不报任何错（与「比分永远 0」同款静默失效，只换了条件类型）。
func test_contradictory_duplicate_conditions_are_rejected() -> void:
	var cfg := _custom_config(15, "ALL_OF")
	cfg["conditions"] = [
		{"type": "kill_target", "enabled": true, "params": {"target_kills": 3}},
		{"type": "kill_target", "enabled": true, "params": {"target_kills": 5}},
	]
	var errors := MatchRuleset.validate_config(cfg)
	check_true(not errors.is_empty(),
		"ALL_OF 里塞两个冲突的 kill_target 阈值应被判为配置错误")
	# 必须整份回落默认，而不是静默取其中一个
	var loaded := MatchRuleset.load_ruleset(cfg, 15, 300.0)
	check_eq(loaded.ruleset_id(), DEFAULT_ID, "自相矛盾的配置应整份回落到内置默认")
	check_eq(loaded.effective_kill_target(), 15,
		"回落后生效阈值应是默认 15（不是静默取 3 或 5）")


## 阈值**相同**的重复条目不算矛盾（冗余但无害，应放过 —— 避免过度拦截）。
func test_identical_duplicate_conditions_are_allowed() -> void:
	var cfg := _custom_config(15)
	cfg["conditions"] = [
		{"type": "kill_target", "enabled": true, "params": {"target_kills": 15}},
		{"type": "kill_target", "enabled": true, "params": {"target_kills": 15}},
		{"type": "time_limit", "enabled": true, "params": {}},
	]
	var errors := MatchRuleset.validate_config(cfg)
	check_true(errors.is_empty(),
		"阈值相同的重复条目属冗余而非矛盾，不该被拒（实际：%s）" % str(errors))


## 其余加载期校验（规格 §3.3）：schema_version / combine / duration / 必填参数 / 非正值。
func test_load_time_validation_covers_the_spec_cases() -> void:
	# ① 未注册的类型
	var unknown_type := _custom_config(15)
	unknown_type["conditions"] = [
		{"type": "no_such_type", "enabled": true, "params": {}},
	]
	check_true(not MatchRuleset.validate_config(unknown_type).is_empty(),
		"未注册的类型应在加载期被拒")
	# ② 缺必填参数
	var missing := _custom_config(15)
	missing["conditions"] = [{"type": "kill_target", "enabled": true, "params": {}}]
	check_true(not MatchRuleset.validate_config(missing).is_empty(),
		"缺必填参数 target_kills 应在加载期被拒")
	# ③ 非正值（0 与负数）
	for bad: Variant in [0, -1, 0.0]:
		var non_positive := _custom_config(15)
		non_positive["conditions"] = [
			{"type": "kill_target", "enabled": true, "params": {"target_kills": bad}},
		]
		check_true(not MatchRuleset.validate_config(non_positive).is_empty(),
			"target_kills=%s 必须为正数，应在加载期被拒" % str(bad))
	# ④ schema_version 不识别
	var bad_version := _custom_config(15)
	bad_version["schema_version"] = 99
	check_true(not MatchRuleset.validate_config(bad_version).is_empty(),
		"schema_version=99 应被拒（不匹配即回落默认）")
	# ⑤ combine 非法
	var bad_combine := _custom_config(15)
	bad_combine["combine"] = "SOME_OF"
	check_true(not MatchRuleset.validate_config(bad_combine).is_empty(),
		"combine=SOME_OF 应被拒")
	# ⑥ duration_limit 非正
	var bad_duration := _custom_config(15)
	bad_duration["duration_limit"] = 0.0
	check_true(not MatchRuleset.validate_config(bad_duration).is_empty(),
		"duration_limit=0 应被拒（必须为正）")
	# ⑦ winner_policy 本期仅 MAX_KILLS
	var bad_policy := _custom_config(15)
	bad_policy["winner_policy"] = "LAST_SURVIVOR"
	check_true(not MatchRuleset.validate_config(bad_policy).is_empty(),
		"winner_policy=LAST_SURVIVOR 本期不可用，应被拒")
	# ⑧ fail_conditions 本期不可用（会推翻 ⚑L-4）
	var fail_conds := _custom_config(15)
	fail_conds["fail_conditions"] = [{"type": "kill_target", "enabled": true, "params": {}}]
	check_true(not MatchRuleset.validate_config(fail_conds).is_empty(),
		"fail_conditions 本期不可用（死亡即失败会推翻 ⚑L-4），应被拒")
	# ⑨ player_defaults 含未登记属性
	var bad_stats := _custom_config(15)
	bad_stats["player_defaults"] = {"bogus_stat": 1.0}
	check_true(not MatchRuleset.validate_config(bad_stats).is_empty(),
		"player_defaults 含未登记属性应被拒")


## 全部合法配置通过校验（守恒对照：确保校验器没有「一律拒绝」的假绿）。
func test_valid_configurations_pass_validation() -> void:
	check_true(MatchRuleset.validate_config(_custom_config(15)).is_empty(),
		"合法的 ANY_OF 配置应通过校验")
	check_true(MatchRuleset.validate_config(_custom_config(15, "ALL_OF")).is_empty(),
		"合法的 ALL_OF 配置应通过校验")
	check_true(MatchRuleset.validate_config(
		_custom_config(1)).is_empty(), "1 杀（边界正值）应通过校验")


## 缺 `time_remaining` 键 → `UNAVAILABLE`（不fail-open 成「已超时」→ 直接结束整局）。
func test_time_limit_missing_key_is_unavailable_not_true() -> void:
	var rule := ConditionRegistry.compile("time_limit", {})
	var status := rule.evaluate({"scores": {}})# 故意缺 time_remaining
	check_eq(status, MatchRule.EVAL_UNAVAILABLE,
		"缺 time_remaining 键应报 UNAVAILABLE（fail-open 成 true 会直接结束整局）")
	check_true(status != MatchRule.EVAL_OK_TRUE, "⛔ 绝不可在缺键时判为成立")


## 缺 `scores` 键 → `UNAVAILABLE`（区分「没人达标」与「根本没有比分数据」）。
func test_kill_target_missing_scores_key_is_unavailable() -> void:
	var rule := ConditionRegistry.compile("kill_target", {"target_kills": 1})
	var status := rule.evaluate({"time_remaining": 300.0}) # 故意缺 scores
	check_eq(status, MatchRule.EVAL_UNAVAILABLE,
		"缺 scores 键应报 UNAVAILABLE（与「空表没人达标」必须可区分）")
	# 对照：空表是「真判了，没达标」
	var empty_table := rule.evaluate(_snap({}, 300.0))
	check_eq(empty_table, MatchRule.EVAL_OK_FALSE,
		"空表应返回 OK_FALSE（确实判了，只是没人达标）")


# ══════════════════════════════════════════════════════════════════════
#  ⑩ 纪律锁（§4-13/ §4-16）
# ══════════════════════════════════════════════════════════════════════

## ⛔ 求值层**不得**碰 `multiplayer` / 场景树 / 时间 → headless 可测、跨端可复现。
##   ⚠ 剥注释后搜；且按**语义**（引擎入口的名字）而非搜某个字面量表达式。
func test_evaluation_layer_touches_no_engine_state() -> void:
	# 求值链路的全部文件（注册表与配置层允许 push_warning，故不含它们）
	for path: String in RULE_FILES:
		var code := _read_code(path)
		if code.strip_edges() == "":
			fail("无法读取规则层源码 %s" % path)
			continue
		for forbidden: String in [
			"multiplayer", # 网络状态
			"get_tree",             # 场景树
			"get_node",             # 场景树
			"Engine.",              # 引擎单例（时间/帧数）
			"Time.",                 # 时间
			"get_ticks",             # 时间
			"OS.",                   # 引擎 / 环境
			"await",                 # 异步 → 与每帧轮询的确定性判定冲突
			"Input.",                # 输入
		]:
			check_false(code.contains(forbidden),
				"规则求值层 %s 不得触碰「%s」（必须是纯函数才能 headless 断言 + 跨端可复现）"
				% [path.get_file(), forbidden])


## `poll_mode` 字段按规格预留，且本期一律 TICK（规格 §5.2：保持每帧轮询）。
func test_poll_mode_reserved_and_defaults_to_tick() -> void:
	check_eq(KillTargetRule.new({}).poll_mode, "TICK", "kill_target 本期应为 TICK")
	check_eq(TimeLimitRule.new({}).poll_mode, "TICK", "time_limit 本期应为 TICK")
	check_eq(UnavailableRule.new("collect_items", {}).poll_mode, "TICK",
		"占位条件也应声明 TICK（它仍走轮询路径，只是恒不可用）")
	# 判定频率仍是每帧（`_tick_live` 调 `_check_end_condition`，未引入新调度器）
	var code := _read_code(SCORE_MANAGER_SRC)
	check_true(code.find("_check_end_condition()") >= 0,
		"判定仍应由 _tick_live 每帧驱动（不得引入脏标记/事件驱动）")


## 条件顺序是语义的一部分：`decisive_type` 报**声明顺序里第一个**成立者（规格 §4.2）。
##   ⚠ 这是「跨端可复现」的保证 —— 改成「最紧急的」会让两端报不同类型。
func test_decisive_type_follows_declaration_order() -> void:
	# kill_target 在前 → 两者同时成立时报 kill_target
	var kt_first := RuleSet.new("ANY_OF", [
		KillTargetRule.new({"target_kills": 1}),
		TimeLimitRule.new({}),
	])
	var r1 := kt_first.evaluate(_snap({1: {"kills": 1, "deaths": 0}}, 0.0)) # 两者都成立
	check_eq(r1.decisive_type, "kill_target",
		"两者同时成立时应报**声明顺序里第一个**成立的条件")
	# 调换顺序 → 报time_limit（证明顺序确实是语义的一部分）
	var time_first := RuleSet.new("ANY_OF", [
		TimeLimitRule.new({}),
		KillTargetRule.new({"target_kills": 1}),
	])
	var r2 := time_first.evaluate(_snap({1: {"kills": 1, "deaths": 0}}, 0.0))
	check_eq(r2.decisive_type, "time_limit",
		"调换声明顺序后应报另一个条件（顺序是语义的一部分，不可改成'最紧急'）")


## `decisive_peer` 必须是**确定性**的归属（同一帧多人达标时不能随遍历顺序分叉）。
func test_decisive_peer_is_deterministic_when_tied() -> void:
	var snapshot := _snap({
		7: {"kills": 5, "deaths": 0},
		3: {"kills": 5, "deaths": 0},
		5: {"kills": 5, "deaths": 0},
	}, 300.0)
	var rule := ConditionRegistry.compile("kill_target", {"target_kills": 5})
	var first := rule.owner_of(snapshot)
	for i in 5:
		check_eq(rule.owner_of(snapshot), first,
			"同一帧多人达标时归属 peer 必须恒定（按 peer_id 升序，不能随遍历顺序分叉）")
	check_eq(first, 3, "按 peer_id 升序应取最小者 3")
	# 归属 peer 必须**真的是达标者**，不能随便挑一个
	check_true(MatchRule.kills_of(snapshot, first) >= 5, "归属 peer 必须确实达到了目标杀数")


## `MatchRule.NO_PEER` 必须与 `ScoreManager.WINNER_UNSET` 同值（-1）。
##   ⚠ 这两个类互相引用 `class_name` 会形成循环依赖，故只能由测试锁住同值。
func test_unset_peer_value_matches_score_manager_constant() -> void:
	check_eq(MatchRule.NO_PEER, ScoreManager.WINNER_UNSET,
		"规则层的无归属 peer 语义值必须与 ScoreManager 的 WINNER_UNSET 一致")
	check_eq(MatchRule.NO_PEER, -1, "语义值应为 -1")


## A.6 铁律：胜负判定的**唯一口径**仍在 `ScoreManager`（规格 §7.4）。
##   规则集只产出「该不该结束」，**不产出胜者** —— 胜者仍由 `_evaluate_winner()` 决定。
func test_winner_selection_stays_in_score_manager() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 1, "deaths": 0}, 2: {"kills": 0, "deaths": 0}}
	# 规则层不该有任何"选出胜者"的能力
	var rs_obj := mgr.active_ruleset()
	check_true(rs_obj.rule_set != null, "规则集应可用")
	check_false(rs_obj.rule_set.has_method("evaluate_winner"),
		"规则层不得实现胜者判定（A.6：唯一口径在 ScoreManager._evaluate_winner）")
	# 超时结束时 decisive_peer 无归属，但 winner_id 仍是击杀最多者 —— 两者不可混用（规格 §4.3）
	mgr.time_remaining = 0.0
	mgr._end_match()
	check_eq(mgr.winner_id, 1, "超时结束时 winner_id 应按击杀数选出（与 decisive_peer 是两件事）")
	mgr.queue_free()


## 客户端**不求值**：即使本地持有配置也不判定（规格 §7.4 第 1 条）。
##   这是三条防分叉条件之一 —— 客户端路径里根本没有 evaluate 调用点。
func test_client_does_not_evaluate_rules() -> void:
	var code := _read_code(SCORE_MANAGER_SRC)
	# 求值调用点必须都在 `_tick_live` 链路上，而 `_tick_live` 开头就判 `is_authority()`
	var tick_start := code.find("func _tick_live")
	check_true(tick_start >= 0, "应有 _tick_live")
	if tick_start < 0:
		return
	var tick_end := code.find("\nfunc ", tick_start + 1)
	var tick_body := code.substr(tick_start, (tick_end - tick_start) if tick_end > tick_start else -1)
	check_true(tick_body.find("is_authority") >= 0,
		"_tick_live 必须先判 is_authority() —— 客户端不得推进判定（规格 §7.4）")
	check_true(tick_body.find("_check_end_condition") >= 0,
		"_tick_live 仍应通过 _check_end_condition 判定（保持唯一口径）")


## A.4 契约增量性：新增 `sync_ruleset` **不得**改动既有 RPC 的方向/模式。
func test_sync_ruleset_is_pure_addition_to_contract() -> void:
	var code := _read_code(SCORE_MANAGER_SRC)
	# 既有 5 条 RPC 的注解必须原样保留
	for rpc_name: String in ["report_kill", "sync_scores", "net_match_ended", "net_match_reset"]:
		check_true(code.find("func %s(" % rpc_name) >= 0,
			"既有 RPC %s 必须保留" % rpc_name)
	# 新增的那条
	check_true(code.find("func net_sync_ruleset(") >= 0, "应新增 net_sync_ruleset")
	# 方向：房主 → 全端（authority / call_remote / reliable）
	var idx := code.find("func net_sync_ruleset(")
	var rpc_block := ""
	if idx >= 0:
		var prev := code.rfind("@rpc", idx)
		rpc_block = code.substr(prev, idx - prev) if prev >= 0 else ""
	check_true(rpc_block.contains("authority"),
		"sync_ruleset 必须是 authority → 全端（房主下发）")
	check_true(rpc_block.contains("call_remote") and rpc_block.contains("reliable"),
		"sync_ruleset 应为 call_remote + reliable")


## A.5 铁律：既有 5 条信号签名**零改动**（规格 §10「A.5 全部信号签名零改动」）。
func test_existing_signal_signatures_unchanged() -> void:
	var code := _read_code(SCORE_MANAGER_SRC)
	for sig: String in [
		"signal score_changed(scores: Dictionary, time_remaining: float)",
		"signal match_state_changed(state: int)",
		"signal match_ended(winner_id: int, final_scores: Dictionary)",
		"signal countdown_updated(remaining: float)",
		"signal match_reset",
	]:
		check_true(code.contains(sig), "既有信号签名必须逐字不变：%s" % sig)


## UI 只绑信号、不碰 RPC（A.5 铁律，`control_checklist §0`）。
func test_ui_does_not_call_rpcs() -> void:
	for path: String in ["res://scripts/ui/scoreboard.gd"]:
		var code := _read_code(path)
		check_false(code.contains(".rpc(") or code.contains(".rpc_id("),
			"UI 不得直接调 RPC（A.5 铁律：UI 只绑信号，跨端由 RPC → _apply_* → signal）")


## 注册表恰好登记 2 真 + 4 占位 = 6 个类型（不多不少）。
func test_registry_registers_exactly_six_types() -> void:
	var types := ConditionRegistry.registered_types()
	check_eq(types.size(), 6, "本期应恰好注册 6 个条件类型（2 真实现 + 4 占位）")
	for t: Variant in AVAILABLE_TYPES:
		check_true(types.has(t), "真实现类型「%s」应已注册" % str(t))
		check_true(ConditionRegistry.is_judgeable(str(t)),
			"「%s」应是可判定的" % str(t))
	for t: Variant in UNAVAILABLE_TYPES:
		check_true(types.has(t), "占位类型「%s」应在注册表里留位" % str(t))
		check_false(ConditionRegistry.is_judgeable(str(t)),
			"占位类型「%s」必须标注为不可判定" % str(t))


## 占位类型与真实现类型**互不重叠**（防止占位把真实现覆盖掉）。
func test_placeholders_do_not_shadow_real_conditions() -> void:
	var placeholders := UnavailableRule.placeholder_types()
	check_eq(placeholders.size(), 4, "应有 4 个占位类型")
	for p: Variant in placeholders:
		check_false(AVAILABLE_TYPES.has(str(p)),
			"占位类型「%s」不得与真实现类型同名" % str(p))
	# 真实现必须真的能判（防止占位注册顺序把真工厂覆盖掉）
	check_true(ConditionRegistry.is_judgeable("kill_target"),
		"kill_target 必须仍是可判定的真实现（不得被占位覆盖）")


## 扩展点验证：新增一个条件类型 = **不改判定函数本体**（开闭原则）。
##   证明方式：注册一个测试替身类型，它立刻可被 `compile` +参与 `RuleSet` 求值，
##   全程没碰 `RuleSet` / `MatchRuleset` 的任何代码。
func test_new_condition_needs_only_registration() -> void:
	ConditionRegistry.register("test_probe_type",
		func(params: Dictionary) -> MatchRule: return _CountingRule.new("test_probe_type", true),
		{"required": [], "optional": {}, "numeric_positive": []})
	check_true(ConditionRegistry.has_type("test_probe_type"), "新类型应注册成功")
	var rule := ConditionRegistry.compile("test_probe_type", {})
	check_true(rule.judgeable, "新类型应可判定")
	# 直接进 RuleSet 求值，不需改 RuleSet 一行代码
	var rs := RuleSet.new("ANY_OF", [rule])
	var result := rs.evaluate(_snap({1: {"kills": 0, "deaths": 0}}, 300.0))
	check_true(result.should_end, "新类型应能参与判定（证明扩展点是开放的）")
	# 复原注册表，避免污染其它用例
	ConditionRegistry.reset_for_test()


## 重复注册要**覆盖并告警**（规格 §3.1：便于测试用替身做白盒验证）。
func test_duplicate_register_overwrites_and_warns() -> void:
	ConditionRegistry.reset_for_test()
	# 先触发自举（把内置类型注册进去），再重复注册其中一个 → 应告警 + 覆盖
	ConditionRegistry.registered_types()
	var before := ConditionRegistry.duplicate_register_warnings
	ConditionRegistry.register("kill_target",
		func(params: Dictionary) -> MatchRule: return _CountingRule.new("kill_target", true),
		{"required": [], "optional": {}, "numeric_positive": []})
	check_true(ConditionRegistry.duplicate_register_warnings > before,
		"重复注册必须告警（否则测试替身会静默顶掉生产实现）")
	var compiled := ConditionRegistry.compile("kill_target", {"target_kills": 1})
	# 替身与真实现的**可观测差异**：真实现会真判（返回 OK_FALSE/OK_TRUE），
	# 替身被设为恒成立 —— 用这个差异证明「覆盖真的生效」，而不是去比较类名。
	check_true(compiled is _CountingRule,
		"重复注册应真的覆盖成替身（否则「用替身做白盒验证」这个用途不成立）")
	check_eq(compiled.evaluate(_snap({1: {"kills": 0, "deaths": 0}}, 300.0)),
		MatchRule.EVAL_OK_TRUE,
		"覆盖后的求值行为应是替身的行为（恒成立），而不是 kill_target 的行为")
	ConditionRegistry.reset_for_test()


# ══════════════════════════════════════════════════════════════════════
#  ⑪ 客户端属性应用通道（`ruleset_applied` → `main.gd`）—— 本suite 的最后一处零覆盖
# ══════════════════════════════════════════════════════════════════════
## ## 为什么这一组优先级最高（比任何单条功能用例都高）
##   `scripts/main.gd` 里那两行
##     `_score.ruleset_applied.connect(_on_ruleset_applied)`
##     `func _on_ruleset_applied(...)` → `PlayerStats.apply_player_stats(...)`
##   是**客户端把规则配置变成实际玩家属性的唯一通道**。
##   删掉后的失效形态与 C-18「比分永远 0」**同构**（日志全正常、只有规则没生效）：
##     ① 客户端 `max_health` 停在场景默认 100（房主若配 200）；
##② ADR-008 守卫（`player.gd:355`）把房主广播的 200 血判为**协议污染整条丢弃**；
##     ③ 客户端血条**永远不动，且不报任何错**。
##   ⚠ `test_health_sync.gd` 测的是「血量广播的 clamp / 越界守卫」，
##     **测不到「配置有没有到达客户端应用层」** —— 两件事长得像，
##     极易被误认为「已有测试守着」。这是本组存在的唯一理由。
##
## ── 判定方法（照`test_unavailable_warning_actually_emits_a_warning` 的正面范例）──
##   · 按 §4-13 **先剥注释**再搜（否则搜到的是自己的注释文本）；
##   · 断言**函数体内的真实调用**，而不是「某状态被置位」；
##   · 变异体验证：① 删 connect → 必须转红；② 清空 handler 函数体 → 必须转红
##     （守恒对照组见 `tools/mutation_rule_config.py` 的 m7 / g4）。

## 抽出 `main.gd` / `score_manager.gd` 里某个函数的**函数体**（剥注释后的源码）。
##   ⚠ 不能只找 `\nfunc `：`main.gd::_ready` 后面紧跟的是注释块，
##     而 `_on_ruleset_applied` 后面跟的是别的函数 —— 必须按
##     「下一个**顶层**声明」切，且顶层声明包含 `var`（如 `score_manager.gd`
##     里 `_build_snapshot` 后面紧跟的是 `var _ruleset_warned := false`）。
func _main_func_body(code: String, header: String) -> String:
	var start := code.find(header)
	if start < 0:
		return ""
	var stop := _next_toplevel_decl(code, start + header.length())
	return code.substr(start, (stop - start) if stop > start else -1)


## 从 `from` 起找下一个**顶层**声明（行首无缩进）的起点。
##   ⚠ 顶层声明种类要列全（func / static func / class / signal / const / enum / var），
##     漏掉 `var` 会让上一个函数体把下一个顶层变量连同其后所有代码一起吞进去。
func _next_toplevel_decl(code: String, from: int) -> int:
	var idx := from
	while idx < code.length():
		var nl := code.find("\n", idx)
		if nl < 0:
			return code.length()
		var line_start := nl + 1
		var nl2 := code.find("\n", line_start)
		var line := code.substr(line_start,
			(nl2 - line_start) if nl2 > line_start else code.length() - line_start)
		if not line.begins_with(" ") and not line.begins_with("\t"):
			for prefix: String in ["func ", "static func ", "class ", "signal ",
					"const ", "enum ", "var "]:
				if line.begins_with(prefix):
					return line_start
		idx = line_start
	return code.length()


## 本文件里定义的全部顶层函数名（用于调用链可达性分析）。
func _main_func_names(code: String) -> Array[String]:
	var names: Array[String] = []
	for raw: String in code.split("\n"):
		var line := raw.strip_edges()
		for prefix: String in ["static func ", "func "]:
			if line.begins_with(prefix):
				var rest := line.substr(prefix.length())
				var open := rest.find("(")
				if open > 0:
					names.append(rest.substr(0, open).strip_edges())
				break
	return names


## 从 `start_func` 出发，沿**本文件内的局部函数调用**能否（有限深度地）触达 `needle`。
##
## ## 为什么要「可达性」而不是「体内有没有这个 token」
##   §4-16 要求断言按**语义**写。若锁成「handler 体内必须出现
##   `PlayerStats.apply_player_stats(`」这个字面量，那么一次**语义完全等价**的重构
##   ——把handler 改成「一行转发到 `_apply_stats_to_existing_players()` 助手」——
##   就会假红（误杀）。反之，若只锁「connect 那行存在」又是弱断言（只断言了状态）。
##   → 故本函数判的是行为语义：**这条处理链最终会不会真的调用属性应用入口**。
##   这同时满足两个变异体验证：
##     · handler 体清空成 `pass` → 无任何调用 → 不可达 → **转红**（杀）
##     · handler 改为转发到助手   → 仍可达     → **仍全绿**（守恒）
func _main_reaches(code: String, start_func: String, needle: String,
		max_depth: int = 4) -> bool:
	var names := _main_func_names(code)
	var seen: Array[String] = []
	var queue: Array = [[start_func, 0]]
	while not queue.is_empty():
		var item: Array = queue.pop_front()
		var fname: String = item[0]
		var depth: int = item[1]
		if seen.has(fname) or depth > max_depth:
			continue
		seen.append(fname)
		var body := _main_func_body(code, "func %s(" % fname)
		if body.is_empty():
			continue
		if body.find(needle) >= 0:
			return true
		for other: String in names:
			if not seen.has(other) and body.find(other + "(") >= 0:
				queue.append([other, depth + 1])
	return false


## `main.gd::_ready` 必须把 `ruleset_applied` 连到 `_on_ruleset_applied`。
##   ⚠ 这是**源码纪律锁**：headless 下无法起`main.tscn` 走真实信号链
##   （`_ready` 依赖 Players / SpawnPoints / NetworkManager 全套场景态），
##   故按「语义」判——查 `_ready` 体内是否有 `ruleset_applied.connect(`，
##   且实参指向 `_on_ruleset_applied` 这个**可调用对象**（不是别的同名 token）。
func test_main_ready_connects_ruleset_applied_signal() -> void:
	var code := _read_code(MAIN_SRC)
	if code.strip_edges() == "":
		fail("无法读取 main.gd 源码（纪律锁前提失效）")
		return
	var ready_body := _main_func_body(code, "func _ready()")
	check_false(ready_body.is_empty(), "main.gd 应有 _ready()")
	if ready_body.is_empty():
		return
	var at := ready_body.find("ruleset_applied.connect(")
	check_true(at >= 0,
		"⛔ _ready 内必须 connect ruleset_applied —— 这是**客户端应用属性的唯一通道**。"
		+ "缺失后：客户端 max_health 停在场景默认 100，房主配 200 时 ADR-008 守卫"
		+ "会把 200 血判成协议污染整条丢弃 → 血条永远不动且不报任何错（形态同 C-18）")
	if at < 0:
		return
	# 实参必须真的是 `_on_ruleset_applied`（防「connect 到同名但不同职责的函数」）
	var arg := ready_body.substr(at + "ruleset_applied.connect(".length())
	arg = arg.substr(0, arg.find(")"))
	check_true(arg.strip_edges() == "_on_ruleset_applied",
		"ruleset_applied 必须连到 _on_ruleset_applied（实际连到「%s」）"
		% arg.strip_edges())
	# 且该 handler 必须真实存在于本文件（防 connect 到一个不存在的方法 → 运行时报错）
	check_true(code.find("func _on_ruleset_applied(") >= 0,
		"_on_ruleset_applied 必须真实定义在 main.gd 里（否则 connect 到不存在的方法）")


## `_on_ruleset_applied` 这条处理链**真的调用**了 `PlayerStats` 的应用入口。
##   ⚠ 这条是上一条「断言了状态 ≠ 断言了行为」的同款补强：
##     上一条只证明「连了线」，本条证明「线那头真的在干活」。
##     若把 handler 体清空成 `pass`（保留 connect），上一条仍绿 —— 唯有本条转红。
##   ⚠ 判据是**可达性**（这条链最终会不会调到应用入口），不是「体内有没有这个 token」：
##     只 print / 只 emit / 只置位都不可达；改成转发到助手仍可达（语义等价，不该误杀）。
func test_ruleset_applied_handler_really_applies_player_stats() -> void:
	var code := _read_code(MAIN_SRC)
	var body := _main_func_body(code, "func _on_ruleset_applied(")
	check_false(body.is_empty(), "main.gd 应有 _on_ruleset_applied handler")
	if body.is_empty():
		return
	check_true(_main_reaches(code, "_on_ruleset_applied", "PlayerStats.apply_player_stats("),
		"⛔ _on_ruleset_applied 这条处理链必须真的调到 PlayerStats.apply_player_stats( —— "
		+ "只 print / 只 emit / 只置位都不算「属性已应用」。"
		+ "handler 体被清空时，客户端属性永远不会被补应用"
		+ "（入树前那条路覆盖不到已入树的客户端玩家节点）")
	# ── 守恒对照（负向）：可达性分析本身不得恒真 ──
	#   若 `_main_reaches` 写错成「永远 true」，上面那条就成了假绿。
	#   故拿一条**确实不碰**属性应用的函数做反向对照。
	check_false(_main_reaches(code, "_ordered_peer_ids", "PlayerStats.apply_player_stats("),
		"⛔ 可达性分析必须能区分「会调用」与「不会调用」—— "
		+ "_ordered_peer_ids 是纯出生点排序，绝不该触达属性应用入口")


## handler 必须作用于**`_players` 下已存在的玩家节点**（补上「入树前应用」覆盖不到的路径）。
##   ⚠ 规格 §6.3：`main.gd::_make_player()` 的入树前应用只覆盖「创建时就有配置」的情况；
##     客户端是COUNTDOWN 前才收到 `sync_ruleset`，玩家节点**早已入树**，
##     只能靠这条补应用路径。若 handler 遍历的是别的东西，客户端属性同样不生效。
##   ⚠ 同样按**可达性**判（与上一条同一把尺子），否则一次语义等价的抽取就被误杀。
func test_ruleset_applied_handler_iterates_existing_player_nodes() -> void:
	var code := _read_code(MAIN_SRC)
	if _main_func_body(code, "func _on_ruleset_applied(").is_empty():
		fail("main.gd 应有 _on_ruleset_applied handler")
		return
	check_true(_main_reaches(code, "_on_ruleset_applied", "_players"),
		"⛔ handler 必须作用于 _players 下的**已存在**玩家节点 —— "
		+ "客户端玩家在收到 sync_ruleset 之前就已入树，只有补应用这条路径能救回 ADR-008 冲突 1")
	check_true(_main_reaches(code, "_on_ruleset_applied", "get_children()"),
		"⛔ handler 必须遍历 _players 的子节点（逐个应用），而不是只处理某一个固定节点")
	# 公平性：补应用也必须走同一道闸门（客户端不得自选战斗属性，规格 §6.2）
	check_true(_main_reaches(code, "_on_ruleset_applied", "_can_configure_stats()"),
		"⛔ handler 必须经 _can_configure_stats() 取得本端配置权，"
		+ "不得绕过 ADR-006 P2P 下的战斗属性写入闸门")



# ══════════════════════════════════════════════════════════════════════
#  ⑫ 「配置下发后两端求值结果相同」—— 双端探针关键断言的 headless 化
# ══════════════════════════════════════════════════════════════════════
## ## 背景：主理人已决定双端探针**不纳入常设回归**
##   多进程集成要占端口、拉两个 Godot 进程，在本项目当前（无 CI）环境里不可靠。
##   但探针里的三条关键断言是**纯逻辑性质**，可以且应该常态化：
##     ① 两端阈值一致② 比分板文案一致  ③ ENDED 时 `scores` 逐字一致
##   → 下面用「构造相同 ruleset + 相同 scores，在**两个独立实例**上求值」覆盖。
## ## 覆盖的是**性质**不是**传输**
##   跨端传输本身（RPC 真跑一趟）由探针人工证明一次即可；
##   本组覆盖的是「给定同一份配置与同一份比分，两端算出的结果必须相同」——
##   传输丢失/错乱会在两端产生**不同输入**，那属于传输层的职责，已由探针覆盖。

## 性质 ①：**两个独立规则集实例**对同一份比分求值 → 结果逐字相同。
##   ⚠ 这是「配置跨端一致 ⇒ 判定跨端一致」的核心：
##     规则对象**不跨端传输**，两端各自从同一份 Dictionary 编译（规格 §3.4）。
##     若编译过程有任何依赖本端状态/遍历顺序的成分，两端就会分叉。
func test_two_independent_rulesets_agree_on_every_snapshot() -> void:
	var cfg := _custom_config(3)
	# 两端各自从**同一份 Dictionary** 独立编译（规格 §3.4：传配置，不传规则对象）
	var end_a := MatchRuleset.load_ruleset(cfg.duplicate(true), 15, 300.0)
	var end_b := MatchRuleset.load_ruleset(cfg.duplicate(true), 15, 300.0)
	check_false(end_a.rule_set == end_b.rule_set,
		"两端必须是**各自独立编译**的规则对象（若共享同一实例，本用例就是假绿）")
	check_eq(end_b.ruleset_id(), end_a.ruleset_id(), "两端 ruleset_id 必须一致")
	check_eq(end_b.effective_kill_target(), end_a.effective_kill_target(),
		"两端生效阈值必须一致（这是「两端都显示先到 3 杀」的根因）")
	# 覆盖一组**跨端可能出现的比分快照**：未达标 / 恰好达标 / 超时 / 两者同时成立 / 平局
	var cases: Array = [
		[{}, 300.0],                # 空表，谁都没达标
		[{1: {"kills": 2, "deaths": 0}}, 300.0],       # 差1 杀
		[{1: {"kills": 3, "deaths": 1}}, 300.0],       # 恰好达标
		[{1: {"kills": 0, "deaths": 0}}, 0.0],         # 超时
		[{1: {"kills": 5, "deaths": 0}}, 0.0],         # 两者同时成立
		[{7: {"kills": 3, "deaths": 2}, 3: {"kills": 3, "deaths": 0}}, 300.0], # 多人同时达标
	]
	for i in cases.size():
		var scores: Dictionary = cases[i][0]
		var snap := _snap(scores, float(cases[i][1]))
		var ra := end_a.rule_set.evaluate(snap)
		var rb := end_b.rule_set.evaluate(snap)
		check_eq(rb.should_end, ra.should_end,
			"第 %d 例：两端 should_end 必须相同（比分 %s）" % [i, str(scores)])
		check_eq(rb.decisive_type, ra.decisive_type,
			"第 %d 例：两端 decisive_type 必须相同（比分 %s）" % [i, str(scores)])
		check_eq(rb.decisive_peer, ra.decisive_peer,
			"第 %d 例：两端 decisive_peer 必须相同（比分 %s）" % [i, str(scores)])
	# ⛔ 反向护栏：不能两组快照全部「都不结束」—— 那样「结果相同」是空洞的。
	#   必须至少有一例真的结束，否则本用例退化成「两个都返回 false」的假绿。
	var ended_cases := 0
	for i in cases.size():
		var snap2 := _snap(cases[i][0], float(cases[i][1]))
		if end_a.rule_set.evaluate(snap2).should_end:
			ended_cases += 1
	check_ge(float(ended_cases), 3.0,
		"⛔ 快照组里至少要有 3 例真的结束对局 —— 否则「两端结果相同」只是「两端都没判」")


## 性质 ②：两端比分板**目标文案逐字相同**（探针「比分板文案一致」的 headless 版）。
##   ⚠ 这里刻意用**两个真实 Scoreboard 节点**而不是比字符串常量：
##     断言的是「玩家在两块屏幕上看到的那句话相同」，不是「某个函数返回了同一个值」。
func test_two_ends_render_identical_objective_text() -> void:
	var cfg := _custom_config(3)
	# 房主端：走生产入口 `set_ruleset`（权威端设置）
	var host := _new_manager()
	var ok := host.set_ruleset(cfg)
	check_true(ok, "前置：房主端应能设置自定义规则集")
	# 客户端端：走 `sync_ruleset` 的接收核心 `_apply_ruleset`（下发后本地应用）
	var client := _new_manager()
	client._apply_ruleset(cfg.duplicate(true), "custom_3")
	# 两端的生效阈值
	check_eq(client.effective_kill_target(), 3, "客户端收到配置后生效阈值应为 3")
	check_eq(client.effective_kill_target(), host.effective_kill_target(),
		"⛔ 两端 effective_kill_target 必须一致（不一致 = 配置没送达客户端）")
	# 两块真实比分板
	var sb_host := _new_scoreboard()
	var sb_client := _new_scoreboard()
	sb_host.bind(host)
	sb_client.bind(client)
	var text_host := _objective_text(sb_host)
	var text_client := _objective_text(sb_client)
	check_eq(text_client, text_host,
		"⛔ 两端比分板目标文案必须逐字相同（房主「%s」/ 客户端「%s」）"
		% [text_host, text_client])
	# 且那句话必须真的反映了配置（防「两端一致但一起错」—— 都显示 15 也是「一致」）
	check_true(text_client.contains("3"), "文案应显示配置值 3，实际「%s」" % text_client)
	check_false(text_client.contains("15"),
		"⛔ 配3 杀时文案不得仍显示硬编码 15（实际「%s」）" % text_client)
	sb_host.queue_free()
	sb_client.queue_free()
	host.queue_free()
	client.queue_free()


## 性质 ③：两端 `ENDED` 时的 `scores` **逐字一致**（探针「打完 3 杀两端 scores 一致」）。
##   ⚠ 「逐字一致」比「数值相等」更强：`_freeze_scores()` 重建了条目，
##     若某端多留了一个键（如某个临时字段），数值可能仍「相等」但字面不同。
##   这里让两端走**各自真实的记分 → 判定 → 结算**路径（不是手工塞同一个字典），
##   再比对 `_freeze_scores()` 的产物。
func test_both_ends_freeze_identical_scores_at_end() -> void:
	var cfg := _custom_config(3)
	# ── 房主端：完整走 生产记分入口 → _tick_live 判定 → _end_match ──
	var host := _new_manager()
	host.set_ruleset(cfg)
	host.start_match()
	host._drive_countdown(ScoreManager.COUNTDOWN_SECONDS + 0.01)
	check_eq(host.match_state, ScoreManager.MatchState.LIVE, "前置：房主端应已进 LIVE")
	var killer := host.local_peer_id()
	for i in 3:
		check_true(host._apply_kill(killer, 100 + i), "第 %d 杀应被采纳" % (i + 1))
	host._tick_live(0.016)
	check_eq(host.match_state, ScoreManager.MatchState.ENDED,
		"⛔ 前置：房主打到配置阈值（3 杀）后应结算 —— 这条不通则本用例无意义")
	# ── 客户端端：**不判定**，只收结算广播（规格 §7.4：只有权威端求值）──
	var client := _new_manager()
	client._apply_ruleset(cfg.duplicate(true), "custom_3")
	check_true(client.match_state != ScoreManager.MatchState.ENDED,
		"⛔ 前置：客户端不得自行结算（它不判定，只等广播）")
	client._apply_sync(host.scores.duplicate(true), host.time_remaining)
	client._apply_ended(host.winner_id, host.scores)
	check_eq(client.match_state, ScoreManager.MatchState.ENDED, "客户端应经结算广播进 ENDED")
	# ── 比对：结算后的 `scores` 与胜者必须两端逐字相同 ──
	check_eq(str(client.scores), str(host.scores),
		"⛔ 两端 ENDED 时的 scores 必须逐字一致（房主 %s / 客户端 %s）"
		% [str(host.scores), str(client.scores)])
	check_eq(client.winner_id, host.winner_id, "两端 winner_id 必须一致")
	check_eq(host.winner_id, killer, "胜者应是打到阈值的那一方")
	# 逐条 peer 复核（让失败信息可定位到具体 peer，而不是只看到两坨字典）
	for peer: Variant in host.scores:
		check_true(client.scores.has(peer), "客户端 scores 应含 peer %s" % str(peer))
		if client.scores.has(peer):
			check_eq(str(client.scores[peer]), str(host.scores[peer]),
				"peer %s 的条目两端应逐字一致" % str(peer))
	host.queue_free()
	client.queue_free()


## 跨端一致性的**前提**：`snapshot` 只含数据 → 两端求值输入相同则结果必相同。
##   ⚠ 这条守的是规格 §3.2 的设计约束本身：若snapshot 里混进了节点引用，
##     「两端输入相同」这个前提就悄悄失效了 —— 而上面两条用例**仍然会绿**
##     （因为它们显式构造了相同的 Dictionary）。
##   → 所以必须单独钉死「快照构造器不碰场景树/ 节点」。
func test_snapshot_is_pure_data_so_cross_end_equality_is_meaningful() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 2, "deaths": 1}}
	var snap := mgr._build_snapshot()
	check_eq(str(snap["scores"]), str(mgr.scores), "快照 scores 应与本端一致")
	for key: Variant in snap:
		var v: Variant = snap[key]
		check_false(v is Node or v is Object or v is Callable or v is Signal,
			"⛔ 快照字段「%s」不得是节点/对象/可调用体 —— 跨端传输的是纯数据，"
			% str(key) + "混进引用会让「两端输入相同」的前提悄悄失效")
	# 构建函数本身不得读场景树（否则两端快照会不同）
	var code := _read_code(SCORE_MANAGER_SRC)
	var body := _main_func_body(code, "func _build_snapshot(")
	if body.is_empty():
		fail("ScoreManager 应有 _build_snapshot")
		return
	for forbidden: String in ["get_tree", "get_node", "$", "multiplayer"]:
		check_false(body.find(forbidden) >= 0,
			"_build_snapshot 不得触碰「%s」—— 快照必须是纯数据（规格 §3.2）" % forbidden)
	mgr.queue_free()


# ══════════════════════════════════════════════════════════════════════
#  测试替身（不是用例）
# ══════════════════════════════════════════════════════════════════════

## 求值计数探针：用 `calls` 观察「短路真的省掉了求值」，而不是只看结果一样。
class _CountingRule extends MatchRule:
	var calls := 0
	var _verdict := false

	func _init(type_id_: String, satisfied_: bool) -> void:
		super({})
		type_id = type_id_
		judgeable = true
		_verdict = satisfied_

	func evaluate(_snapshot: Dictionary) -> int:
		calls += 1
		return EVAL_OK_TRUE if _verdict else EVAL_OK_FALSE