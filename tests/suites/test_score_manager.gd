extends TestSuite
## EP-3 / ES-3.1~3.4 · ScoreManager 数据契约 / 击杀上报 / 状态机 / 同步总线回归基线
##
## 需求出处：
##   design/gdd/01_core_loop.md 附录 A（ScoreManager 数据契约）
##     A.1 权威 / A.2 状态机 / A.3 字段 / A.4 RPC 清单 / A.5 信号 / A.6 结算判定
##     A.7 击杀归因 / A.8 死亡计分 / A.9 边界 / A.11 待评估项
##   production/epics/EP-3-score-and-match-flow.md · ES-3.1 / ES-3.2 / ES-3.3 / ES-3.4 / ES-3.5
##
## 判定方法（本框架的核心设计约束）：
##   ScoreManager 把「可单测核心逻辑」与「RPC 外壳」**显式分离**——
##     · `@rpc` 方法（`report_kill` / `sync_scores` / `net_match_ended` / `net_match_reset`）
##       只做身份校验 + 转调纯逻辑，内部依赖 `multiplayer.get_remote_sender_id()` / 网络收发，
##       **headless 下不可测**（见文件末「无法验证的部分」说明）。
##     · 纯逻辑（`_evaluate_winner` / `_check_end_condition` / `_apply_kill` / `_apply_bot_kill` /
##       `_end_match` / `_drive_countdown` / `_tick_live` / `_apply_sync` / `_apply_ended` /
##       `_apply_reset` / `resolve_victim_id`）无副作用、不触碰 `multiplayer.*`，
##       故本 suite 直接 `new()` 出实例、直接调用这些方法验证结果 —— 无需真实 ENet 连接。
##
## 说明：带 `_` 前缀只是 GDScript 命名约定（非访问修饰符），测试可直接调用；
##   这正是把关键逻辑设计成纯函数的目的（EP-3 / ADR 测试策略）。
##
## ── HEADLESS 下**无法**验证的部分（诚实标注，不粉饰）──
##   1. `report_kill` / `sync_scores` / `net_match_ended` / `net_match_reset` 的**真实 RPC 收发**
##      （需要两进程 + ENet 连接）。本 suite 只验证它们的「本地应用逻辑」（`_apply_*`）。
##   2. `multiplayer.get_remote_sender_id()` 在 headless 单进程下永远返回 0 →
##      `report_kill` 的「从 sender 解出 killer_id」这一步**只在代码审查层面正确**，未被运行时验证。
##   3. `_report_local_kill()` 的客户端分支（`report_kill.rpc_id(1, ...)`）在离线环境下走不到，
##      只验证了权威分支。

const FIELD_DEFAULT_KILL_TARGET := 15
const FIELD_DEFAULT_DURATION := 300.0
const FIELD_DEFAULT_TIE := -2
const FIELD_DEFAULT_UNSET := -1
const COUNTDOWN_SECONDS := 3.0


## 造一个「手工驱动」的 manager：关闭 `_process` 自动驱动，避免测试真等 3 秒 / 与帧时序耦合。
func _new_manager() -> ScoreManager:
	var mgr := ScoreManager.new()
	mgr.auto_drive = false # 关键：测试自己喂 delta（见文件头「设计约束」）
	add_child(mgr) # 触发 _ready → 置 IDLE
	return mgr


## 造一个默认 manager（保留 `_process` 自动驱动），用于验证默认值不受测试开关影响。
func _new_auto_manager() -> ScoreManager:
	var mgr := ScoreManager.new()
	add_child(mgr)
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


# ══════════════════════════════════════════════════════════════════════
#  13~  ES-3.2 击杀上报 / 死亡计分 / 归因解析
# ══════════════════════════════════════════════════════════════════════

## ── 13. 击杀上报核心逻辑：模拟权威端收到上报 → 击杀 +1 / 死亡 +1（附录 A.8）──
##   `report_kill` RPC 依赖 `get_remote_sender_id()`（headless 拿不到），故直接测其核心入口
##   `_apply_kill`（RPC 外壳转调的就是它）。这里再额外走一次 `_report_local_kill`（权威分支）。
func test_report_kill_core_updates_scores() -> void:
	var mgr := _new_manager()
	# 权威端：本端击杀者 = local_peer_id（离线/测试环境 = 1）
	var killer: int = mgr.local_peer_id()
	var accepted: bool = mgr._report_local_kill(7)
	check_true(accepted, "权威端本端击杀应被采纳")
	check_eq(int(mgr.scores[killer]["kills"]), 1, "击杀者 kills 应 +1")
	check_eq(int(mgr.scores[7]["deaths"]), 1, "受害者 deaths 应 +1（一条消息同时记击杀与死亡）")
	# 再杀一次：累加
	mgr._report_local_kill(7)
	check_eq(int(mgr.scores[killer]["kills"]), 2, "第二次击杀应累加到 2")
	check_eq(int(mgr.scores[7]["deaths"]), 2, "第二次死亡应累加到 2")
	# 记录 score_changed 广播次数（每次有效计分应发一次）
	var cb := {"n": 0}
	mgr.score_changed.connect(func(_s: Dictionary, _t: float) -> void: cb["n"] = int(cb["n"]) + 1)
	mgr._report_local_kill(7)
	check_eq(int(cb["n"]), 1, "每次有效击杀应广播恰好 1 次 score_changed")
	mgr.queue_free()


## ── 14. 归因安全解析：节点名 = peer id；非数字名（bot/靶子）不产生脏 id（附录 A.7）──
func test_resolve_victim_id_safe_parsing() -> void:
	# 玩家节点：节点名 = peer id（main.gd::_make_player 设 player.name = str(id)）
	var player := Node.new()
	player.name = "12345"
	check_eq(ScoreManager.resolve_victim_id(player), 12345, "数字节点名应解析为对应 peer id")
	player.queue_free()

	# bot / 训练靶：节点名不是数字 → 必须拒绝（否则 int() → 0，会污染计分）
	var bot := Node.new()
	bot.name = "Bot"
	check_eq(ScoreManager.resolve_victim_id(bot), -1, "非数字节点名（bot）应返回 -1，不产生脏 id")
	bot.queue_free()

	var target := Node.new()
	target.name = "TrainingTarget"
	check_eq(ScoreManager.resolve_victim_id(target), -1, "非数字节点名（训练靶）应返回 -1")
	target.queue_free()

	# Godot 自动命名（@Xxx@NNN）也非数字 → 拒绝
	var auto_named := Node.new()
	check_eq(ScoreManager.resolve_victim_id(auto_named), -1, "自动命名节点应返回 -1")
	auto_named.queue_free()

	# 0 是 ENet「无 peer」保留值 → 拒绝
	var zero := Node.new()
	zero.name = "0"
	check_eq(ScoreManager.resolve_victim_id(zero), -1, "peer id 0 应被拒绝（ENet 保留值）")
	zero.queue_free()

	# 负 id → 拒绝
	var neg := Node.new()
	neg.name = "-5"
	check_eq(ScoreManager.resolve_victim_id(neg), -1, "负 peer id 应被拒绝")
	neg.queue_free()

	# null / 非 Node → 拒绝（不崩）
	check_eq(ScoreManager.resolve_victim_id(null), -1, "null collider 应返回 -1 且不报错")


## ── 15. 非法 victim_id 不产生计分（附录 A.7 防御）──
func test_invalid_victim_id_rejected() -> void:
	var mgr := _new_manager()
	var killer: int = mgr.local_peer_id()
	check_false(mgr._report_local_kill(-1), "victim_id = -1（无主伤害）应被拒绝")
	check_true(mgr.scores.is_empty(), "非法 victim_id 不应产生任何计分条目")
	check_false(mgr._apply_kill(killer, -1), "_apply_kill(-1) 应被拒绝")
	check_true(mgr.scores.is_empty(), "非法 _apply_kill 不应产生条目")
	mgr.queue_free()


## ── 16. 人机击杀：离线本地 +1、不生成 deaths 条目（附录 A.7 / A.9）──
func test_bot_kill_offline_local_only() -> void:
	var mgr := _new_manager()
	var killer: int = mgr.local_peer_id()
	check_true(mgr._apply_bot_kill(killer), "离线人机击杀应被采纳")
	check_eq(int(mgr.scores[killer]["kills"]), 1, "人机击杀应给玩家 kills +1")
	check_eq(mgr.scores.size(), 1, "人机不是 peer → 不应生成第二条（deaths）条目")
	check_eq(int(mgr.scores[killer]["deaths"]), 0, "人机击杀不应给玩家自己记死亡")
	mgr.queue_free()


# ══════════════════════════════════════════════════════════════════════
#  17~  ES-3.3 状态机驱动 + 计时 + 结算
# ══════════════════════════════════════════════════════════════════════

## ── 17. 状态机推进：IDLE → COUNTDOWN → LIVE（附录 A.2）──
func test_state_machine_idle_countdown_live() -> void:
	var mgr := _new_manager()
	check_eq(mgr.match_state, ScoreManager.MatchState.IDLE, "初始应为 IDLE")
	# 记录状态迁移广播序列
	var states: Array = []
	mgr.match_state_changed.connect(func(s: int) -> void: states.append(s))
	mgr.start_match()
	check_eq(mgr.match_state, ScoreManager.MatchState.COUNTDOWN, "start_match 后应进 COUNTDOWN")
	check_eq(states, [ScoreManager.MatchState.COUNTDOWN], "应广播一次 COUNTDOWN 迁移")
	# 倒计时未走完：仍停在 COUNTDOWN
	mgr._drive_countdown(COUNTDOWN_SECONDS - 0.1)
	check_eq(mgr.match_state, ScoreManager.MatchState.COUNTDOWN, "倒计时未走完应仍为 COUNTDOWN")
	check_near(mgr.time_remaining, FIELD_DEFAULT_DURATION, 0.001,
		"COUNTDOWN 期间 time_remaining 应冻结在 match_duration（不得递减）")
	# 走完倒计时 → LIVE
	mgr._drive_countdown(0.2)
	check_eq(mgr.match_state, ScoreManager.MatchState.LIVE, "倒计时结束应进 LIVE")
	check_near(mgr.time_remaining, FIELD_DEFAULT_DURATION, 0.001, "LIVE 启动时 time_remaining 应复位为 match_duration")
	check_eq(states, [ScoreManager.MatchState.COUNTDOWN, ScoreManager.MatchState.LIVE],
		"状态迁移广播序列应为 COUNTDOWN → LIVE")
	mgr.queue_free()


## ── 18. 开局幂等 + 客户端不得自行开局（附录 A.1 / A.2）──
func test_start_match_idempotent_and_authority_gated() -> void:
	var mgr := _new_manager()
	mgr.start_match()
	mgr.start_match() # 第二次：已在 COUNTDOWN → 幂等忽略
	check_eq(mgr.match_state, ScoreManager.MatchState.COUNTDOWN, "重复 start_match 不应重复推进状态")
	# 已进 LIVE 后再 start_match 也不应回退
	mgr._drive_countdown(COUNTDOWN_SECONDS + 0.01)
	check_eq(mgr.match_state, ScoreManager.MatchState.LIVE, "应已进 LIVE")
	mgr.start_match()
	check_eq(mgr.match_state, ScoreManager.MatchState.LIVE, "LIVE 中重复 start_match 不应回退到 COUNTDOWN")
	mgr.queue_free()


## ── 19. LIVE 计时递减 + 到 0 触发结算（附录 A.6）──
func test_live_tick_ends_on_timeout() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 3, "deaths": 1}, 2: {"kills": 5, "deaths": 4}}
	mgr.start_match()
	mgr._drive_countdown(COUNTDOWN_SECONDS + 0.01) # 进 LIVE
	mgr.match_duration = 10.0
	mgr.time_remaining = 10.0
	# 递减：喂 4 秒 → 剩 6 秒，不结算
	mgr._tick_live(4.0)
	check_near(mgr.time_remaining, 6.0, 0.001, "LIVE 期间 time_remaining 应递减")
	check_eq(mgr.match_state, ScoreManager.MatchState.LIVE, "未到 0 不应结算")
	# 喂过头的 delta → 夹到 0 并结算
	mgr._tick_live(7.0)
	check_near(mgr.time_remaining, 0.0, 0.001, "time_remaining 应夹在 0（不得为负）")
	check_eq(mgr.match_state, ScoreManager.MatchState.ENDED, "时间耗尽应触发 _end_match → ENDED")
	check_eq(mgr.winner_id, 2, "超时结算应比击杀数：5 杀者（peer 2）胜出")
	mgr.queue_free()


## ── 20. LIVE 中达到击杀目标立即结算（附录 A.6）──
func test_live_tick_ends_on_kill_target() -> void:
	var mgr := _new_manager()
	mgr.start_match()
	mgr._drive_countdown(COUNTDOWN_SECONDS + 0.01)
	mgr.kill_target = 3
	mgr._apply_kill(1, 2)
	mgr._apply_kill(1, 2)
	mgr._apply_kill(1, 2) # 3 杀 → 达标
	mgr._tick_live(0.016) # 一帧
	check_eq(mgr.match_state, ScoreManager.MatchState.ENDED, "达到 kill_target 应触发结算")
	check_eq(mgr.winner_id, 1, "达标者（peer 1）应为胜者")
	mgr.queue_free()


## ── 21. `_set_players_input_blocked` 对缺失场景树安全（COUNTDOWN 冻结输入，附录 A.2）──
##   测试环境没有 main.tscn 的 Players 节点 → 该调用必须静默跳过而非崩溃。
##   这验证了「COUNTDOWN 冻结输入」的接线是防御式的（见 EP-3 报告：player.gd 已有 set_input_blocked）。
func test_countdown_input_block_is_safe_without_players() -> void:
	var mgr := _new_manager()
	mgr.start_match() # 内部会调 _set_players_input_blocked(true)
	check_eq(mgr.match_state, ScoreManager.MatchState.COUNTDOWN,
		"无 Players 节点时 start_match 仍应正常进 COUNTDOWN（冻结输入静默跳过）")
	mgr._drive_countdown(COUNTDOWN_SECONDS + 0.01) # 內部会调 _set_players_input_blocked(false)
	check_eq(mgr.match_state, ScoreManager.MatchState.LIVE, "解冻输入不得阻断状态推进")
	mgr.queue_free()


# ══════════════════════════════════════════════════════════════════════
#  22~  ES-3.4 同步 RPC 的本地应用逻辑 + 信号总线
# ══════════════════════════════════════════════════════════════════════

## ── 22. `sync_scores` 本地应用：覆盖比分/时间 + 广播 score_changed（附录 A.4 / A.5）──
func test_apply_sync_updates_and_emits() -> void:
	var mgr := _new_manager()
	var payload: Dictionary = {1: {"kills": 4, "deaths": 2}, 9: {"kills": 7, "deaths": 1}}
	var cb := {"n": 0, "scores": {}, "time": -1.0}
	mgr.score_changed.connect(func(s: Dictionary, t: float) -> void:
		cb["n"] = int(cb["n"]) + 1
		cb["scores"] = s
		cb["time"] = t)
	mgr._apply_sync(payload, 123.5)
	check_eq(int(cb["n"]), 1, "应用同步应广播 1 次 score_changed")
	check_eq(int(mgr.scores[9]["kills"]), 7, "本地 scores 应被远端数据覆盖")
	check_near(mgr.time_remaining, 123.5, 0.001, "本地 time_remaining 应被远端覆盖")
	check_near(float(cb["time"]), 123.5, 0.001, "score_changed 载荷应携带远端 time_remaining")
	check_eq(int(mgr._sync_received), 1, "应记录收到 1 次同步")
	# 深拷贝：外部改 payload 不得影响本地
	payload[1]["kills"] = 999
	check_eq(int(mgr.scores[1]["kills"]), 4, "同步应深拷贝，外部别名不得改写本地比分")
	mgr.queue_free()


## ── 23. `net_match_ended` 本地应用：固化 winner + 广播 match_ended（幂等）──
func test_apply_ended_signal_and_idempotent() -> void:
	var mgr := _new_manager()
	var final: Dictionary = {1: {"kills": 15, "deaths": 3}, 2: {"kills": 2, "deaths": 15}}
	var cb := {"n": 0, "winner": -999}
	mgr.match_ended.connect(func(w: int, _f: Dictionary) -> void:
		cb["n"] = int(cb["n"]) + 1
		cb["winner"] = w)
	mgr._apply_ended(1, final)
	check_eq(int(cb["n"]), 1, "应用结算应广播 1 次 match_ended")
	check_eq(int(cb["winner"]), 1, "match_ended 载荷 winner_id 应为 1")
	check_eq(mgr.match_state, ScoreManager.MatchState.ENDED, "应用结算后应为 ENDED")
	check_eq(mgr.winner_id, 1, "winner_id 应固化为远端值")
	check_eq(int(mgr._ended_received), 1, "应记录收到 1 次结算广播")
	# 幂等：重复收到不重复广播
	mgr._apply_ended(2, {})
	check_eq(int(cb["n"]), 1, "ENDED 后重复应用结算不应重复广播")
	check_eq(mgr.winner_id, 1, "重复应用不得改写已固化的 winner_id")
	mgr.queue_free()


## ── 24. `match_reset` 本地应用：回 IDLE / 清比分 / 复位计时（附录 A.2 / A.4）──
func test_apply_reset_returns_to_idle() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 15, "deaths": 3}}
	mgr.time_remaining = 12.0
	mgr.match_duration = 300.0
	mgr.start_match()
	mgr._drive_countdown(COUNTDOWN_SECONDS + 0.01)
	mgr._end_match()
	check_eq(mgr.match_state, ScoreManager.MatchState.ENDED, "前置：应已结算")
	var cb := {"n": 0}
	mgr.score_changed.connect(func(_s: Dictionary, _t: float) -> void: cb["n"] = int(cb["n"]) + 1)
	mgr._apply_reset()
	check_eq(mgr.match_state, ScoreManager.MatchState.IDLE, "复位后应回 IDLE（再来一局从加载开始）")
	check_eq(mgr.winner_id, FIELD_DEFAULT_UNSET, "复位后 winner_id 应回 -1")
	check_near(mgr.time_remaining, 300.0, 0.001, "复位后 time_remaining 应回 match_duration")
	check_true(mgr.scores.is_empty(), "复位后比分应清空")
	check_eq(int(cb["n"]), 1, "复位应广播 1 次 score_changed")
	# 复位后可重新开局
	mgr.start_match()
	check_eq(mgr.match_state, ScoreManager.MatchState.COUNTDOWN, "复位后应能重新进 COUNTDOWN")
	mgr.queue_free()


## ── 25. 权威端不自行复位（客户端只等广播）（附录 A.1）──
##   离线环境下本端即权威，故 `request_reset()` 会执行；这里验证的是「权威路径」的本地效果。
func test_request_reset_authority_path() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 2, "deaths": 0}}
	mgr.request_reset()
	check_eq(mgr.match_state, ScoreManager.MatchState.IDLE, "权威端 request_reset 应本地生效")
	check_true(mgr.scores.is_empty(), "权威端 request_reset 应清空比分")
	mgr.queue_free()


## ── 26. 信号总线：本地路径与远端路径都 emit（供 HUD 绑定，附录 A.5）──
##   三条 signal 必须都能被外部 connect 到，且本地改 / 远端收到两条路径行为一致。
func test_signal_bus_local_and_remote_paths() -> void:
	var mgr := _new_manager()
	var score_cb := {"local": 0, "remote": 0}
	var state_cb := {"n": 0}
	var ended_cb := {"n": 0}
	mgr.score_changed.connect(func(_s: Dictionary, _t: float) -> void: score_cb["local"] = int(score_cb["local"]) + 1)
	mgr.match_state_changed.connect(func(_s: int) -> void: state_cb["n"] = int(state_cb["n"]) + 1)
	mgr.match_ended.connect(func(_w: int, _f: Dictionary) -> void: ended_cb["n"] = int(ended_cb["n"]) + 1)
	# 本地路径：本端计分 / 状态迁移
	mgr.start_match()
	mgr._drive_countdown(COUNTDOWN_SECONDS + 0.01)
	mgr._apply_kill(1, 2)
	check_ge(float(score_cb["local"]), 1.0, "本地计分应触发 score_changed")
	check_ge(float(state_cb["n"]), 2.0, "状态迁移应触发 match_state_changed（COUNTDOWN + LIVE）")
	mgr._end_match()
	check_eq(int(ended_cb["n"]), 1, "本地结算应触发 match_ended")
	# 远端路径：收到 sync / ended 后同样 emit
	var remote_mgr := _new_manager()
	remote_mgr.auto_drive = false
	var remote_score_cb := {"n": 0}
	var remote_ended_cb := {"n": 0}
	remote_mgr.score_changed.connect(func(_s: Dictionary, _t: float) -> void: remote_score_cb["n"] = int(remote_score_cb["n"]) + 1)
	remote_mgr.match_ended.connect(func(_w: int, _f: Dictionary) -> void: remote_ended_cb["n"] = int(remote_ended_cb["n"]) + 1)
	remote_mgr._apply_sync({1: {"kills": 3, "deaths": 1}}, 88.0)
	remote_mgr._apply_ended(1, {1: {"kills": 3, "deaths": 1}})
	check_eq(int(remote_score_cb["n"]), 1, "远端同步应触发 score_changed（HUD 绑定同一信号）")
	check_eq(int(remote_ended_cb["n"]), 1, "远端结算应触发 match_ended")
	remote_mgr.queue_free()
	mgr.queue_free()


## ── 27. 违约保护：`sync_scores` 的本地应用不得在权威端被调用（防自发自收覆盖）──
##   这里验证的是「纯逻辑与 RPC 外壳分离」后的可测点：`_apply_sync` 本身不检查权威，
##   检查交给 RPC 外壳 `sync_scores()`（headless 无法调）。故本用例只锁定**契约文档化**：
##   权威端调用 `_apply_sync` 会覆盖本地 —— 这是**外壳必须早退**的原因，不是纯逻辑的职责。
func test_apply_sync_is_unconditional_pure_logic() -> void:
	var mgr := _new_manager()
	mgr.scores = {1: {"kills": 10, "deaths": 0}}
	mgr._apply_sync({1: {"kills": 1, "deaths": 0}}, 50.0)
	check_eq(int(mgr.scores[1]["kills"]), 1,
		"纯逻辑 _apply_sync 不检查权威（无条件覆盖）——权威保护由 RPC 外壳 sync_scores() 早退承担")
	mgr.queue_free()


## ── 28. 房间列表变化：权威端增删计分条目（A.9 迟到加入 / 中途离开的实际数据入口）──
##   `_on_room_changed` 读 `NetworkManager.get_players()`；离线测试环境下该表为空，
##   故这里直接验证「增删语义」——用 register/unregister 模拟同一数据流。
func test_room_change_register_unregister_flow() -> void:
	var mgr := _new_manager()
	# 模拟房主房间列表：peer 1 + 迟到加入的 peer 42
	mgr.register_player(1)
	mgr.register_player(42)
	check_true(mgr.scores.has(1) and mgr.scores.has(42), "房间成员应各有条目")
	check_eq(int(mgr.scores[42]["kills"]), 0, "迟到加入应初始化为 {0,0}")
	# peer 42 离开 → 移除条目，但已有计分的 peer 1 保留
	mgr._apply_kill(1, 42)
	mgr.unregister_player(42)
	check_false(mgr.scores.has(42), "离开的 peer 应被移除")
	check_true(mgr.scores.has(1), "仍在房间的 peer 应保留")
	check_eq(int(mgr.scores[1]["kills"]), 1, "移除他人不应清零自己的计分")
	mgr.queue_free()


## ── 29. 默认值不受测试开关影响（契约默认值必须严格一致，附录 A.3）──
func test_auto_drive_default_true_and_defaults_intact() -> void:
	var mgr := _new_auto_manager()
	check_true(mgr.auto_drive, "生产路径 auto_drive 默认应为 true（测试手动关闭不影响默认值）")
	check_eq(mgr.match_state, ScoreManager.MatchState.IDLE, "默认状态应为 IDLE")
	check_eq(mgr.kill_target, FIELD_DEFAULT_KILL_TARGET, "kill_target 默认仍应为 15")
	check_eq(mgr.match_duration, FIELD_DEFAULT_DURATION, "match_duration 默认仍应为 300.0")
	check_eq(mgr.winner_id, FIELD_DEFAULT_UNSET, "winner_id 默认仍应为 -1")
	mgr.queue_free()


## ── 30. 客户端状态推断：收到 sync 从 IDLE → LIVE（附录 A.4 无专门状态 RPC）──
##   ⚠ 本用例**只**验证「IDLE 推断为 LIVE」与「重复 sync 幂等」两点。
##       「客户端不自行递减计时」依赖 `_tick_live` 的 `is_authority()` 早退，而 headless 单进程
##       下 `is_authority()` 恒为 true（离线即权威），**无法在此覆盖**——列入未验证项（见文件头）。
func test_client_infers_live_from_sync() -> void:
	var mgr := _new_manager()
	check_eq(mgr.match_state, ScoreManager.MatchState.IDLE, "前置：初始 IDLE")
	mgr._apply_sync({1: {"kills": 1, "deaths": 0}}, 222.0)
	check_eq(mgr.match_state, ScoreManager.MatchState.LIVE, "收到同步且本地 IDLE → 客户端应推断为 LIVE")
	mgr._apply_sync({1: {"kills": 2, "deaths": 1}}, 200.0)
	check_near(mgr.time_remaining, 200.0, 0.001, "后续 sync 应持续覆盖 time_remaining")
	check_eq(mgr.match_state, ScoreManager.MatchState.LIVE, "已在 LIVE 时重复 sync 不应重复迁移状态")
	mgr.queue_free()
