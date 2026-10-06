extends TestSuite
## EP-3 / ES-3.1 · ScoreManager 数据契约与胜负判定回归基线
##
## 需求出处：
##   design/gdd/01_core_loop.md 附录 A（ScoreManager 数据契约）A.1 / A.3 / A.5 / A.6 / A.8 / A.9
##   production/epics/EP-3-score-and-match-flow.md · ES-3.1 / ES-3.5
##
## 判定方法：
##   ScoreManager 的关键逻辑（`_evaluate_winner` / `_check_end_condition` / `_apply_kill` / `_end_match`）
##   都是**无副作用、不依赖网络/场景树/帧循环**的纯逻辑，故本 suite 直接 `new()` 出实例、
##   直接调用这些方法验证结果——无需建立真实 ENet 连接，headless 下确定性可重复。
##
## 说明：`_evaluate_winner` 等虽带 `_` 前缀，但 GDScript 的 `_` 只是命名约定（非访问修饰符），
##   测试可以直接调用；这正是把关键逻辑设计成纯函数的目的（见 EP-3 / ADR 测试策略）。

const FIELD_DEFAULT_KILL_TARGET := 15
const FIELD_DEFAULT_DURATION := 300.0
const FIELD_DEFAULT_TIE := -2
const FIELD_DEFAULT_UNSET := -1


func _new_manager() -> ScoreManager:
	var mgr := ScoreManager.new()
	add_child(mgr) # 触发 _ready → 置 IDLE
	return mgr


## ── 1. 字段默认值（附录 A.3；默认值必须完全一致）──
func test_field_defaults() -> void:
	var mgr := _new_manager()
	check_eq(mgr.kill_target, FIELD_DEFAULT_KILL_TARGET, "kill_target 默认应为 15")
	check_eq(mgr.match_duration, FIELD_DEFAULT_DURATION, "match_duration 默认应为 300.0")
	check_eq(mgr.time_remaining, FIELD_DEFAULT_DURATION, "time_remaining 默认应为 300.0")
	check_eq(mgr.winner_id, FIELD_DEFAULT_UNSET, "winner_id 默认应为 -1（未定）")
	check_eq(mgr.match_state, ScoreManager.MatchState.IDLE, "match_state 默认应为 IDLE")
	check_true(mgr.scores.is_empty(), "scores 默认应为空字典")
	mgr.queue_free()


## ── 2. 15 杀触发（附录 A.6）──
func test_kill_target_triggers_end() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 15, "deaths": 3}, 2: {"kills": 5, "deaths": 6}}
	mgr.time_remaining = 120.0
	check_true(mgr._check_end_condition(), "有人达到 15 杀时结束条件应为真")
	check_eq(mgr._evaluate_winner(), 1, "15 杀者（peer 1）应为胜者")
	mgr.queue_free()


## ── 3. 5 分钟超时（附录 A.6）：比击杀数而非「谁先到」──
func test_timeout_triggers_end_and_picks_max_kills() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 7, "deaths": 3}, 2: {"kills": 9, "deaths": 8}}
	mgr.time_remaining = 0.0
	check_true(mgr._check_end_condition(), "时间耗尽时结束条件应为真")
	check_eq(mgr._evaluate_winner(), 2, "超时结算应比击杀数：9 杀者（peer 2）胜出，而非 peer 1")
	mgr.queue_free()


## ── 4. 平分比 deaths（附录 A.6）──
func test_tie_break_by_fewer_deaths() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 10, "deaths": 2}, 2: {"kills": 10, "deaths": 5}}
	check_eq(mgr._evaluate_winner(), 1, "击杀同为 10 时应比 deaths：deaths 少者（peer 1）胜出")
	mgr.queue_free()


## ── 5. 仍平 → 并列（附录 A.3 / A.6）──
func test_still_tied_returns_tie() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 10, "deaths": 3}, 2: {"kills": 10, "deaths": 3}}
	check_eq(mgr._evaluate_winner(), FIELD_DEFAULT_TIE, "kills 与 deaths 全同时应返回 -2（并列）")
	mgr.queue_free()


## ── 6. match_ended 信号触发 + 结算终态（附录 A.5 / A.6）──
func test_match_ended_signal_fires_once_with_frozen_state() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 15, "deaths": 2}, 2: {"kills": 4, "deaths": 9}}
	# 记录回调次数与载荷
	var cb := {"count": 0, "winner": -999, "final": {}}
	var handler := func(winner: int, final_scores: Dictionary) -> void:
		cb["count"] = int(cb["count"]) + 1
		cb["winner"] = winner
		cb["final"] = final_scores
	mgr.match_ended.connect(handler)
	mgr._end_match()
	check_eq(int(cb["count"]), 1, "match_ended 回调应被调用恰好 1 次")
	check_eq(int(cb["winner"]), 1, "match_ended 载荷 winner_id 应为 1")
	check_eq(mgr.match_state, ScoreManager.MatchState.ENDED, "_end_match 后 match_state 应为 ENDED")
	check_eq(mgr.winner_id, 1, "_end_match 后 winner_id 应固化为 1")
	# 冻结：结算后再来一条击杀不得改写终态
	var total_before := int((cb["final"] as Dictionary)[1]["kills"])
	mgr._apply_kill(1, 2)
	check_eq(int(mgr.scores[1]["kills"]), total_before, "结算后比分应冻结，_apply_kill 不得改写")
	mgr.queue_free()


## ── 7. 死亡计分（附录 A.8）：一条消息同时记击杀 +1 与死亡 +1 ──
func test_apply_kill_records_kill_and_death() -> void:
	var mgr := _new_manager()
	mgr._apply_kill(1, 2)
	check_eq(int(mgr.scores[1]["kills"]), 1, "击杀者 kills 应 +1")
	check_eq(int(mgr.scores[2]["deaths"]), 1, "受害者 deaths 应 +1")
	check_true(mgr.scores[1].has("deaths") and int(mgr.scores[1]["deaths"]) == 0,
		"击杀者条目应初始化 deaths=0")
	check_true(mgr.scores[2].has("kills") and int(mgr.scores[2]["kills"]) == 0,
		"受害者条目应初始化 kills=0")
	mgr.queue_free()


## ── 8. 边界：自杀不记击杀、不扣分（附录 A.9）──
func test_suicide_is_ignored() -> void:
	var mgr := _new_manager()
	var accepted: bool = mgr._apply_kill(3, 3)
	check_false(accepted, "自杀上报应被拒绝（返回 false）")
	check_true(mgr.scores.is_empty(), "自杀不应产生任何计分条目")
	mgr.queue_free()


## ── 9. 边界：迟到加入初始化条目（附录 A.9）──
func test_register_player_late_join_defaults() -> void:
	var mgr := _new_manager()
	mgr.register_player(42)
	check_true(mgr.scores.has(42), "迟到加入的 peer 应被登记")
	check_eq(int(mgr.scores[42]["kills"]), 0, "迟到加入 kills 应为 0")
	check_eq(int(mgr.scores[42]["deaths"]), 0, "迟到加入 deaths 应为 0")
	mgr.register_player(42) # 幂等：重复登记不覆盖已有计分
	mgr._apply_kill(42, 1)
	mgr.register_player(42)
	check_eq(int(mgr.scores[42]["kills"]), 1, "重复登记不得清零已有计分")
	mgr.queue_free()


## ── 10. 边界：中途离开移除条目（附录 A.9，MVP 简化）──
func test_unregister_player_removes_entry() -> void:
	var mgr := _new_manager()
	mgr.register_player(7)
	mgr.unregister_player(7)
	check_false(mgr.scores.has(7), "离开的 peer 条目应被移除")
	mgr.queue_free()


## ── 11. 边界：同一帧多人达成 → 先到者为准（幂等，不重复发信号）──
func test_same_frame_multiple_reach_target_first_wins() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 15, "deaths": 3}, 2: {"kills": 16, "deaths": 2}}
	mgr._end_match() # 第一次：以先到者（此快照）结算
	var first_winner: int = mgr.winner_id
	var cb_count := {"n": 0}
	mgr.match_ended.connect(func(_w: int, _f: Dictionary) -> void: cb_count["n"] = int(cb_count["n"]) + 1)
	mgr._end_match() # 第二次调用：ENDED 幂等，不应再发信号
	check_eq(int(cb_count["n"]), 0, "ENDED 状态下重复 _end_match 不应重复广播 match_ended")
	check_eq(mgr.winner_id, first_winner, "重复 _end_match 不应改写已固化的 winner_id")
	mgr.queue_free()


## ── 12. 权威口径（附录 A.1）：收口在 is_authority() ──
func test_is_authority_offline_is_local() -> void:
	var mgr := _new_manager()
	# headless 测试环境未建房 → NetworkManager.is_online == false → 本端即权威
	check_false(NetworkManager.is_online, "测试环境应处于离线（未建房）状态")
	check_true(mgr.is_authority(), "离线时本端应为权威（is_authority() == true）")
	mgr.queue_free()
