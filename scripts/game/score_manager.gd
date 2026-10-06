class_name ScoreManager
extends Node
## FFA「15 杀 / 5 分钟」权威计分 + 胜负判定（EP-3 · ES-3.1 骨架 + ES-3.2/3.3/3.4 落地）
##
## 需求出处：`design/gdd/01_core_loop.md §4/§5/§6 + 附录 A（ScoreManager 数据契约）`、
##           `production/epics/EP-3-score-and-match-flow.md · ES-3.1~3.4`。
##
## 部署（附录 A.1）：挂在 `scenes/main.tscn` 下（每局随场景创建/销毁 → **天然复位**，**不用 Autoload**）。
##
## 权威（附录 A.1）：房主 `peer_id == 1`（`NetworkManager.is_server`）唯一权威；
##   离线（`NetworkManager.is_online == false`，含训练模式）本端即权威。
##   收口在 `is_authority()` —— 不要在别处重复这两个条件。
##
## 状态机（附录 A.2）：
##   IDLE ──(对局加载完成)──▶ COUNTDOWN(3s) ──▶ LIVE ──(胜利条件)──▶ ENDED
##     ▲                                                              │
##     └────────────────── match_reset()（再来一局）──────────────────┘
##
## ══════════════════════════════════════════════════════════════════════
##  设计约束（本文件最重要的部分）
## ══════════════════════════════════════════════════════════════════════
## 1. **可单测核心逻辑 与 RPC 外壳彻底分离**（EP-3/ES-3.2 的硬约束）：
##    所有 `@rpc` 方法（`report_kill` / `sync_scores` / `match_ended` / `match_reset`）**只做三件事**：
##      (a) 权威/身份校验；(b) 取载荷；(c) 转调一个纯逻辑方法（无 `@rpc`）。
##    纯逻辑方法以 `_apply_*` / `_drive_*` 命名，不触碰 `multiplayer.*`，headless 下可直接调用断言。
##    → `report_kill` 依赖 `multiplayer.get_remote_sender_id()`（headless 拿不到真实 sender），
##      因此它**不能**被测试直接调；测试改为直接调 `_apply_kill(...)`（同一个逻辑入口）。
## 2. **RPC / signal 命名冲突**（附录 A.4 vs A.5）：
##    GDScript 里 signal 与 func 分属不同命名空间、**可以同名共存**，但极易混淆调用点。
##    本文件的取舍见下方 `_rpc_*` 命名块注释：**RPC 一律加 `net_` 前缀**，signal 保持契约原名。
## 3. **作弊面（附录 A.11.1，显式记录、不要默默带过）**：
##    客户端上报击杀，房主**不做二次校验**（不本地复算该击杀）——局域网熟人局 MVP 接受「信任客户端」。
## 4. **A.4 契约已定稿但尚未实现的消息**（注意"契约已定 / 实现未到"）：
##    `sync_match_state(state: int, countdown_remaining: float)`（房主 → 全端）——**附录 A.4 第 5 条，
##    已由设计侧裁定定稿**，是客户端精确跟随 `match_state` 与倒计时 UI（`countdown_updated`）的唯一信息来源。
##    **实际实现排在 S2（随 EP-4 ES-4.4）**，本文件当前**尚未实现**该 RPC。
##    → 在它落地前，客户端状态仍靠 `_apply_sync()` 的临时兜底分支（见该函数注释）。
##    ⚠ 风险：恶意客户端可伪造 `report_kill` 刷分。缓解留待后续（见 A.11.1 与 EP-3 报告）。

## ── A.2 状态机 ──
enum MatchState { IDLE, COUNTDOWN, LIVE, ENDED }

## 倒计时时长（`04_ux_flow` §3.2：3-2-1）
const COUNTDOWN_SECONDS := 3.0
## 同步心跳间隔（附录 A.4：`sync_scores` 变更时 + 每 1 s 心跳）
const SYNC_HEARTBEAT_SECONDS := 1.0
## 并列（平局）语义值（附录 A.3）
const WINNER_TIE := -2
## 未定语义值（附录 A.3）
const WINNER_UNSET := -1

## ── A.5 信号（供 HUD 绑定；签名严格按契约）──
## 比分 / 剩余时间变更时广播（房主 → 本地 → HUD）
signal score_changed(scores: Dictionary, time_remaining: float)
## 状态机迁移时广播（IDLE→COUNTDOWN→LIVE→ENDED）
signal match_state_changed(state: int)
## 对局结束时广播（携带固化后的 winner_id 与冻结后的最终比分）
##
## ⚠ 命名冲突说明：附录 A.4 要求一个**同名 RPC** `match_ended`。本文件把 RPC 改名为
##   `net_match_ended`（见"RPC 命名块"），signal 保持契约原名 `match_ended` 不动 —— HUD / 结算面板
##   按 A.5 绑定的就是这个名字，改名会波及 EP-4。
signal match_ended(winner_id: int, final_scores: Dictionary)
## COUNTDOWN 期间倒计时剩余秒数广播（3.0 → 0.0），供倒计时 UI（3-2-1）绑定。
##
## 为什么单列一条 signal（而不扩 `match_state_changed` 的签名，见 A.5 变更记录）：
##   · 语义分离：`match_state_changed` 回答「状态变了没」（稀疏事件，最多 4 次/局）；
##     `countdown_updated` 回答「还剩几秒」（高频，每帧/每秒）。
##   · 纯增量：保持 A.5 既有 3 条签名不变 → 不破坏任何 HUD 绑定面。
## 契约来源：A.4 `sync_match_state` 定稿后发现 A.5 绑定面缺口，裁定 team-lead（游承峰）2026-10-06。
## 载荷语义与 A.4 `sync_match_state` 的 `countdown_remaining` 一致。
## ⚠ 仅在 COUNTDOWN 期间有意义；离开 COUNTDOWN（进 LIVE / ENDED / IDLE）后**停止 emit**。
signal countdown_updated(remaining: float)
##
## ── A.5 增补（2026-10-06，EP-3 范围内的**增补**，非契约变更）──
## 对局已复位（`END → IDLE` 那一跳的「对局结束」侧事件），广播给 UI 消费。
##
## ## 为什么必须单列一条（这是**实测缺陷**逼出来的，不是预想）
## `_apply_reset()` 复位时只 emit 了 `score_changed`（那是**比分板**的绑定面）。
## 结算面板 `MatchResult` 监听的是 `match_ended`，复位时**没有任何信号通知它** ⇒
##   房主点「再来一局」→ 房主本端靠 `close_ui()` 关了面板，
##   **客户端执行了 `_apply_reset()` 却什么也没收到 → 结算面板永远停在打开状态**。
## 这正是「A.5 绑定面缺口」的第二次发生（第一次是 `countdown_updated`）。
##
## ## emit 时机：`_apply_reset()` **末尾**，两端都发
## `net_match_reset()`（客户端）也走 `_apply_reset()`，故房主与客户端**各发一次**，
## 两端面板都能关。**幂等**：关闭操作本身幂等（`close_ui()` 对已关闭面板是no-op），
## 房主自己不会收到两次（`net_match_reset` 是 `call_remote` + `if is_authority(): return` 双保险）。
##
## ## 为什么不复用 `match_state_changed(IDLE)`
## ① 语义不对等：复位回IDLE 与开局进IDLE 是两件事，UI 无法区分「开赛前」与「重开中」；
## ② `match_state_changed` 只在**状态真的变了**时 emit（`_set_state` 内有同值早退），
##   而 `match_ended → 复位` 这条路径上 ENDED→IDLE 确实会变，语义上虽能凑合，
##   但会让 UI 必须**记住自己上次看到的状态**才能推断（隐式状态机 = 本项目明令避免）。
## → 结论：**显式事件**，不靠状态差分推断（与 `countdown_updated` 的取舍同源）。
signal match_reset

## ── D2-04 增补（2026-10-06，**纯增量**，不改任何既有信号签名）──
## 本局规则集已生效（权威端 `set_ruleset` / 客户端收到 `sync_ruleset`）。
##
## ## 为什么必须单列一条（不是"加个字段让 UI 轮询"）
##   ① `main.gd` 需要在**规则集到手后**把玩家属性补应用一遍：
##      客户端的玩家节点在场景 `_ready()` 阶段就建好了，而 `sync_ruleset`
##      是 COUNTDOWN 前才到的 —— 只靠 `main.gd::_make_player()` 的
##      "入树前应用"覆盖不到这条路径。
##      → 不补这一条，客户端 `max_health` 停留在场景默认值，
##       房主配 200 血时客户端会**永久丢弃**血量广播（ADR-008 守卫，
##        `value > max_health` 判协议污染）→ **血条永远不动且不报错**。
##   ② 比分板需要据此刷新目标文案（配置成 3 杀时显示「先到 3 杀」）。
##      否则只能等下一次比分变更（≤1 s 心跳）才更新 —— 能用但不该拖。
##
## ## 载荷：`ruleset_id: String`（跨端一致性核对用）
##   与 A.4 `sync_ruleset` 的 `ruleset_id` 同名字段、同一取值。
## ## 契约增量性
##   **既有 5 条信号签名一律未动** —— 与 A.5 已有裁定先例一致
##   （`countdown_updated` / `match_reset` 都是这样加的：新增独立信号 = 纯增量、零外溢）。
signal ruleset_applied(ruleset_id: String)

## ── A.3 字段（默认值必须与契约完全一致，测试断言）──
## 当前状态机状态（见 MatchState）
var match_state: int = MatchState.IDLE
## 击杀目标（上限，达到即结束）
##   ⚠ D2-04 纪律：**这是内置默认规则集阈值的唯一真值来源**（规格 §7.1）。
##     既有测试直接写它（`mgr.kill_target = 3`），因此规则集**不得**在配置里
##     另写一份 15 —— 那样改字段就不会改判定。
##   ⚠ 若本局下发了自定义规则集（`_ruleset != null`），**生效值以规则集为准**，
##     本字段退化为「内置默认的阈值」。见 `effective_kill_target()`。
var kill_target: int = 15
## 对局时长上限（秒）
var match_duration: float = 300.0
## 剩余时间（秒），LIVE 期间由 `_process` 驱动递减（仅权威端）
var time_remaining: float = 300.0
## peer_id → {kills:int, deaths:int}（原地维护，避免每帧重建）
var scores: Dictionary = {}
## 胜者 peer id：-1=未定；-2=并列（平局）
var winner_id: int = WINNER_UNSET

## COUNTDOWN 剩余秒数（仅权威端在推进；客户端由 sync 覆盖，不自行递减）
var _countdown_remaining: float = COUNTDOWN_SECONDS
## `sync_scores` 心跳累加器（仅权威端）
var _sync_accum: float = 0.0
## 计数：本端收到过多少次远端同步（供调试 / 未来 HUD「已同步」指示）
var _sync_received := 0
## 计数：本端收到过多少次结算广播（调试用）
var _ended_received := 0

## ── D2-04 规则配置化（A.4 新增 `sync_ruleset`）──
## 本局生效的自定义规则集（`null` = 用内置默认 `ffa_kill15`）。
##   · 权威端：由 `set_ruleset()` 设置（未来的房主配置面板入口）。
##   · 客户端：由 `net_sync_ruleset` 收到房主下发后写入（**只用于显示，不判定**）。
## ⚠ 客户端**不求值**：判定只在权威端（规格 §7.4）。客户端持有配置只为
##   ① HUD 目标文案② 玩家属性两端一致（`max_health` 见 ADR-008 冲突 1）。
var _ruleset: MatchRuleset = null
## 已下发/已收到的规则集 id（跨端一致性核对；不一致要 `push_warning`）。
var _ruleset_id_synced := ""

## ── 测试可调开关（**不得**改变契约默认值）──
## 由测试置 false 关闭 `_process` 自动驱动，改为手工调 `_drive_countdown` / `_tick_live`
## 以避免「真等 3 秒」或与测试时序耦合。生产路径恒为 true。
var auto_drive := true
## 由测试置 true 时跳过 `NetworkManager` 状态读取（离线测试环境已足够，此项为冗余保险）
var _force_offline_for_test := false


func _ready() -> void:
	# 场景就绪 → 进入 IDLE（等待 `match_started` / 玩家入树触发 COUNTDOWN，ES-3.3）
	_set_state(MatchState.IDLE)
	if NetworkManager.is_online:
		NetworkManager.room_changed.connect(_on_room_changed)


func _exit_tree() -> void:
	if NetworkManager.room_changed.is_connected(_on_room_changed):
		NetworkManager.room_changed.disconnect(_on_room_changed)


## ── A.1 权威归属（唯一收口点）──
## 房主（peer_id==1 / is_server）或离线本端为权威；其余为客户端（只上报意图、接收同步）。
func is_authority() -> bool:
	if _force_offline_for_test:
		return true
	if not NetworkManager.is_online:
		return true # 离线 / 训练模式：本端即权威
	return NetworkManager.is_server


## 本端 peer id（离线 / 测试环境下 `get_unique_id()` 返回 1，与 `main.gd` 离线创建的玩家节点名一致）
func local_peer_id() -> int:
	return multiplayer.get_unique_id()


# ══════════════════════════════════════════════════════════════════════
#  纯逻辑（无副作用、不触碰 multiplayer / 不依赖帧循环；供测试直接调用）
# ══════════════════════════════════════════════════════════════════════

## A.6 胜负判定：返回 kills 最高者的 peer id。
##   平局 → 比 deaths 少者；仍平 → 返回 -2（并列）。
##   空表 → 返回 -1（未定，无人可判）。
## 纯读 `scores`，不写任何状态 → 可单测、可重复调用。
func _evaluate_winner() -> int:
	if scores.is_empty():
		return WINNER_UNSET
	var best_id: int = WINNER_UNSET
	var best_kills: int = -1
	var best_deaths: int = 1 << 30
	for key: Variant in scores:
		var entry: Dictionary = scores[key]
		var id: int = int(key)
		var kills: int = int(entry.get("kills", 0))
		var deaths: int = int(entry.get("deaths", 0))
		var better := false
		if kills > best_kills:
			better = true
		elif kills == best_kills and deaths < best_deaths:
			better = true
		if better:
			best_id = id
			best_kills = kills
			best_deaths = deaths
	# 再扫一遍：确认是否真并列（最高 kills 且最低 deaths 有两个及以上）
	if best_id != WINNER_UNSET:
		var tied := 0
		for key: Variant in scores:
			var entry: Dictionary = scores[key]
			if int(entry.get("kills", 0)) == best_kills and int(entry.get("deaths", 0)) == best_deaths:
				tied += 1
		if tied > 1:
			return WINNER_TIE
	return best_id


## A.6 结束条件：有人达到 kill_target，或时间耗尽。
##   纯读状态，不写任何状态 → 可单测。
##
## ## D2-04：内部已换实现（规格 §5.1/ §7.2 M3）
##   原来是两条写死判断，现在求值 `RuleSet`（规则配置化）。
##   ⚠ **签名与语义均未变** —— 既有 30 条计分测试多处直接调用本方法。
##   ⚠ 判定**逐位等价**：默认规则集 `ffa_kill15` 的两个阈值
##     **读本对象的 `kill_target` / `match_duration` 字段**（规格 §7.1），
##     不是配置里另写一份 15 / 300.0。否则 `mgr.kill_target = 3`
##     （`test_score_manager.gd:348`）与 `mgr.match_duration = 10.0`（`:329`）会当场失效。
##   ⚠ `RuleSet.evaluate()` 是纯函数（不碰 multiplayer / 场景树 / 时间），
##     headless 可直接断言 —— 见 `tests/suites/test_rule_config.gd`。
func _check_end_condition() -> bool:
	return _rule_set_evaluate().should_end


## 取当前生效的规则集（每帧一次求值，故**按需重建**而非缓存）。
##
## ##⚠ 为什么每次重建（这是规格 §7.1 的直接后果，不是偷懒）
##   `kill_target` / `match_duration` 是**公开可写字段**，既有测试直接写它们。
##   若规则集只在初始化时编译一次，改字段就不会改判定 → 当场转红。
##   重建成本：2 次字典字面量 + 2 次对象构造 ≈ 几十 ns，
##   相对本方法每帧都要做的 `_max_kills()` 遍历可忽略。
##   ⚠ 真要省这几次构造也不能改成"缓存 + 字段变更时失效"，因为字段可写性
##     是既有测试的**契约**；这里保持"读字段即真值来源"这条唯一口径。
func _active_ruleset() -> MatchRuleset:
	#自定义规则集（房主配置 / `sync_ruleset` 下发）优先；没有则用内置默认。
	return _ruleset if _ruleset != null \
		else MatchRuleset.builtin_default(kill_target, match_duration)


## 求值规则集（**唯一**的规则求值入口）。
##   `_check_end_condition` 与诊断都走这里，保证「判定口径只有一处」（A.6）。
func _rule_set_evaluate() -> RuleSet.RuleEvaluation:
	var ruleset := _active_ruleset()
	var result := ruleset.rule_set.evaluate(_build_snapshot())
	# ⛔ 不可用条件 → **不结束对局** + 一次 push_warning（规格 §8.4）
	#   「配了 5 个条件只跑通 1 个」若表现成「另外 4 个没达成」，
	#   排查成本极高（形态同 C-18「比分永远 0」：日志全正常、只有规则没生效）。
	#   一局只警告一次（`_ruleset_warned`），不刷屏。
	if result.should_end == false and ruleset.rule_set.blocked_by_unavailable():
		_warn_unavailable_once(ruleset)
	return result


## 构造求值快照（**纯数据、不含节点引用**，规格 §3.2）。
##   ⚠ 字段来源必须是本对象的**权威**状态：远端玩家的血量真值在受害端（C-18），
##     但比分真值在权威端，这里读的是权威端自己维护的 `scores`。
func _build_snapshot() -> Dictionary:
	return {
		"scores": scores,
		"time_remaining": time_remaining,
		"match_state": match_state,
		"elapsed": maxf(match_duration - time_remaining, 0.0),
	}


## 本局是否已就「不可用条件」警告过（保证一次/局，不刷屏）。
var _ruleset_warned := false


## 「不可用条件」的一次性告警（规格 §8.4）。
func _warn_unavailable_once(ruleset: MatchRuleset) -> void:
	if _ruleset_warned:
		return
	_ruleset_warned = true
	push_warning("ScoreManager: 本局规则集含**不可用**条件（%s）→ 判定不可信，"
		% str(ruleset.rule_set.last_unavailable_types())
		+ "按规格 §8.4 **不结束对局**。请改用 kill_target / time_limit，"
		+ "或先在项目里实现该条件类型的支撑系统。")


# ══════════════════════════════════════════════════════════════════════
#  D2-04 规则配置化 · 对外接口
# ══════════════════════════════════════════════════════════════════════

## 本局生效的击杀目标（**HUD「先到 N 杀」文案的唯一真值来源**，规格 §1.2.1/ M4）。
##   房主配 3 杀 → 这里返回 3 → 比分板显示「先到 3 杀」。
##   ⚠ 之前 `scoreboard.gd` 有一处 `const KILL_TARGET := 15` 硬编码，
##     那是**第二处**硬编码耦合（`is_near_target` 的默认参数 15 作为兜底保留）。
func effective_kill_target() -> int:
	return _active_ruleset().effective_kill_target(kill_target)


## 本局生效的规则集（诊断 / 工具页 / 测试）。
func active_ruleset() -> MatchRuleset:
	return _active_ruleset()


## 权威端设置本局规则集（未来的房主配置面板入口；本期 UI 不做，规格 §9 Q4）。
##   ⚠ 配置非法时**回落内置默认并 `push_warning`**（规格 §3.3），不静默接受半份配置。
##   ⚠ 只允许权威端设置 —— 客户端改规则等于自己定胜负（规格 §6.2 同款公平性）。
##   `cfg == null` → 恢复内置默认（清空自定义规则集）。
func set_ruleset(cfg: Dictionary) -> bool:
	if not is_authority():
		push_warning("ScoreManager: 非权威端不得设置规则集（客户端改规则= 自己定胜负）")
		return false
	_ruleset_warned = false
	if cfg == null:
		_ruleset = null
		_ruleset_id_synced = ""
		return true
	var loaded := MatchRuleset.load_ruleset(cfg, kill_target, match_duration)
	_ruleset = loaded
	_ruleset_id_synced = loaded.ruleset_id()
	ruleset_applied.emit(_ruleset_id_synced)
	if not loaded.load_errors.is_empty():
		# load_ruleset 已 push_warning；这里不再重复刷屏，只把回落后的 id 记下来。
		return false
	# 下发给全端（COUNTDOWN 之前，属性要在**入树前**应用完，规格 §6.3）
	net_sync_ruleset.rpc(loaded.to_dict(), loaded.ruleset_id())
	return true


## A.4 `sync_ruleset` 核心逻辑（纯逻辑，headless 可直接调）。
##   客户端收到房主下发的配置 → 应用到本地（**只用于显示**，不参与判定）。
##   ⚠ `ruleset_id` 不一致要 `push_warning`（规格 §7.4 第 2 条：配置跨端一致是前提）。
##   ⚠ 校验失败 → 回落内置默认，但仍**以本地收到的为准**（反正客户端不判定）。
func _apply_ruleset(remote_config: Dictionary, remote_ruleset_id: String) -> void:
	if remote_ruleset_id.strip_edges() != "" and _ruleset_id_synced != "" \
			and remote_ruleset_id != _ruleset_id_synced:
		push_warning("ScoreManager: 收到的规则集 id「%s」与本地已同步的「%s」不一致"
			% [remote_ruleset_id, _ruleset_id_synced])
	_ruleset_warned = false
	var loaded := MatchRuleset.load_ruleset(remote_config, kill_target, match_duration)
	_ruleset = loaded
	_ruleset_id_synced = remote_ruleset_id if remote_ruleset_id.strip_edges() != "" \
		else loaded.ruleset_id()
	ruleset_applied.emit(_ruleset_id_synced)


## A.4 规则集下发：**房主 → 全端**。
##   ⚠ 时机：`start_match()` 里随`sync_match_state` 一同下发，**COUNTDOWN 之前**
##     —— 因为 `max_health` 等属性必须在玩家**入树前**应用完（规格 §6.3），
##     而玩家节点在 `main.gd::_ready()` 就已建好。
##   ⚠ 契约：这是 A.4 的**纯增量**新增条目，既有 5 条 RPC 的方向/模式/载荷**一律未改**，
##     A.5 全部信号签名亦未动（与 A.5 已有裁定先例一致）。
@rpc("authority", "call_remote", "reliable")
func net_sync_ruleset(remote_config: Dictionary, remote_ruleset_id: String) -> void:
	if is_authority():
		return # 权威端不接受覆盖（防自发自收/ 防客户端伪造）
	_apply_ruleset(remote_config, remote_ruleset_id)


## A.6 结束对局：固化 winner_id、冻结 scores、置 ENDED、广播 match_ended + net_match_ended。
##   仅权威调用（`_tick_live` 在 LIVE 每帧检查后触发；也可被测试直接调用）。
##   幂等：ENDED 后重复调用不再计分、不再广播（同一帧多人达成 → 先到者为准）。
func _end_match() -> void:
	if match_state == MatchState.ENDED:
		return # 幂等：同一帧多人达成时，以先到者为准（不会重复发信号）
	winner_id = _evaluate_winner()
	# 冻结比分：深拷贝，阻断后续（迟到 RPC）对结算结果的改写
	var final_scores := _freeze_scores()
	scores = final_scores
	_set_state(MatchState.ENDED)
	# 本地广播（HUD / 结算面板）
	match_ended.emit(winner_id, final_scores)
	# 远端广播（RPC 名 `net_match_ended`，见命名块说明）
	if is_authority():
		net_match_ended.rpc(winner_id, final_scores)


## A.8 死亡计分：一条消息同时记「击杀 +1」与「受害者死亡 +1」。
##   自杀（killer_id == victim_id）→ 不记击杀、不扣分（附录 A.9）。
##   本方法是 `report_kill` RPC 的**核心逻辑入口**（分离后 headless 可直接调）。
##   返回 true 表示本次计分被采纳。
func _apply_kill(killer_id: int, victim_id: int) -> bool:
	if match_state == MatchState.ENDED:
		return false # 结算后不再计分（比分已冻结）
	if killer_id == victim_id:
		return false # 自杀：不记击杀、不扣分
	if killer_id < 0 or victim_id < 0:
		return false # 非法 id（无归属伤害，例如未知来源）
	var killer: Dictionary = _ensure_entry(killer_id)
	killer["kills"] = int(killer.get("kills", 0)) + 1
	var victim: Dictionary = _ensure_entry(victim_id)
	victim["deaths"] = int(victim.get("deaths", 0)) + 1
	score_changed.emit(scores, time_remaining)
	return true


## A.7 + A.9 人机击杀：**纯本地计分**（不生成 deaths 条目，人机不是 peer）。
##
## 仅离线 / 训练模式调用（联机局人机不计入，见 `weapon.gd::_report_kill_if_player`）。
## 与玩家击杀共用同一 `scores` 表与 `score_changed` 信号 → HUD 口径统一。
func _apply_bot_kill(killer_id: int) -> bool:
	if match_state == MatchState.ENDED:
		return false
	if killer_id < 0:
		return false
	var killer: Dictionary = _ensure_entry(killer_id)
	killer["kills"] = int(killer.get("kills", 0)) + 1
	score_changed.emit(scores, time_remaining)
	return true


# ══════════════════════════════════════════════════════════════════════
#  状态机驱动（ES-3.3）—— 只有权威端推进；客户端由 sync RPC 覆盖
# ══════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if not auto_drive:
		return
	match match_state:
		MatchState.COUNTDOWN:
			_drive_countdown(delta)
		MatchState.LIVE:
			_tick_live(delta)


## IDLE → COUNTDOWN。触发点见 `_on_room_changed` / `start_match()`。
func start_match() -> void:
	if not is_authority():
		return # 客户端不自行开局，只等房主广播
	if match_state != MatchState.IDLE:
		return # 已在倒计时 / 对局中 / 已结束：幂等忽略
	_countdown_remaining = COUNTDOWN_SECONDS
	_set_state(MatchState.COUNTDOWN)
	# D2-04：规则集**必须在 COUNTDOWN 之前**下发（规格 §6.3）——
	#   玩家属性要在**入树前**应用完，而玩家节点在场景 `_ready()` 阶段就建好了。
	#   → 每局开头重置「不可用条件」的一次性告警计数。
	_ruleset_warned = false
	net_sync_ruleset.rpc(_active_ruleset().to_dict(), _active_ruleset().ruleset_id())
	_set_players_input_blocked(true) # A.2：COUNTDOWN 期间冻结输入


## 推进倒计时（仅权威端）。delta 可被测试直接喂入。
##   倒计时归零 → LIVE，`time_remaining` 复位为 `match_duration`。
func _drive_countdown(delta: float) -> void:
	if match_state != MatchState.COUNTDOWN:
		return
	if not is_authority():
		return
	_countdown_remaining -= delta
	if _countdown_remaining > 0.0:
		return
	_countdown_remaining = 0.0
	time_remaining = match_duration # LIVE 启动时复位计时（A.2）
	_set_state(MatchState.LIVE)
	_set_players_input_blocked(false)
	_broadcast_scores()


## LIVE 每帧推进：递减 `time_remaining`，到点 / 达标 → `_end_match()`。
##   ⚠ 仅权威端递减与结算（附录 A.1）；客户端只收 sync 覆盖。
func _tick_live(delta: float) -> void:
	if match_state != MatchState.LIVE:
		return
	if not is_authority():
		return
	time_remaining = maxf(time_remaining - delta, 0.0)
	# 1 s 心跳（A.4：变更时 + 每秒）
	_sync_accum += delta
	if _sync_accum >= SYNC_HEARTBEAT_SECONDS:
		_sync_accum = 0.0
		_broadcast_scores()
	if _check_end_condition():
		_end_match()


# ══════════════════════════════════════════════════════════════════════
#  RPC 外壳（ES-3.2 / ES-3.4）
#
#  ── 命名块（RPC / signal 命名冲突的解决办法）──
#  附录 A.4 的 RPC 清单里有一个 `match_ended`，而附录 A.5 的 signal 里也有一个 `match_ended`。
#  GDScript **允许** signal 与 func 同名共存（不同命名空间），但两种「看起来一样」的调用
#  （`mgr.match_ended.emit(...)` vs `mgr.match_ended.rpc(...)`）会让人极易读错、改错。
#  本项目的取舍：**RPC 一律加 `net_` 前缀，signal 保持契约原名**。
#    · `net_match_ended` ← 附录 A.4 的 `match_ended` RPC
#    · `net_match_reset` ← 附录 A.4 的 `match_reset` RPC
#    · `sync_scores` / `report_kill` 无 signal 同名 → 保持原名（与契约一致）
#  理由：signal 名是 EP-4（HUD / 结算面板）的绑定面（A.5 明写「供 HUD 绑定」），改名会波及下游；
#        RPC 名只在 ScoreManager 内部与 NetworkManager 的对端解析里出现，改名零外溢。
#  ⚠ 若未来有其它模块要按契约名 `match_ended` 调用 RPC，请改为 `net_match_ended`，不要新增同名 func。
# ══════════════════════════════════════════════════════════════════════

## A.4 击杀上报：**客户端 → 房主**。载荷只有 `victim_id`；击杀者由 sender 解出。
##
## 为什么是 `any_peer`：房主需要 `get_remote_sender_id()` 反查「谁上报的」——这正是击杀者的 peer id。
## 为什么**不带** `call_local`：本端击杀走 `_report_local_kill()` 直调，见那里的取舍说明。
##
## ⚠ 作弊面（A.11.1）：房主**不二次校验**，直接信任上报 → 恶意端可伪造刷分。局域网熟人局 MVP 接受。
@rpc("any_peer", "call_remote", "reliable")
func report_kill(victim_id: int) -> void:
	if not is_authority():
		return
	var killer_id := multiplayer.get_remote_sender_id()
	_apply_kill(killer_id, victim_id)


## A.4 比分同步：**房主 → 全端**。变更时 + 每秒心跳。
@rpc("authority", "call_remote", "reliable")
func sync_scores(remote_scores: Dictionary, remote_time_remaining: float) -> void:
	if is_authority():
		return # 权威端不接受覆盖（防自发自收 / 防客户端伪造）
	_apply_sync(remote_scores, remote_time_remaining)


## A.4 结算广播：**房主 → 全端**（RPC 名加 `net_` 前缀避免与 signal 同名，见命名块）。
@rpc("authority", "call_remote", "reliable")
func net_match_ended(remote_winner_id: int, final_scores: Dictionary) -> void:
	if is_authority():
		return
	_apply_ended(remote_winner_id, final_scores)


## A.4 复位广播：**房主 → 全端**（「再来一局」）。RPC 名加 `net_` 前缀。
@rpc("authority", "call_remote", "reliable")
func net_match_reset() -> void:
	if is_authority():
		return
	_apply_reset()


# ══════════════════════════════════════════════════════════════════════
#  远端数据应用（纯逻辑，供测试直接调用；headless 下不依赖真实 RPC 收发）
# ══════════════════════════════════════════════════════════════════════

## 应用远端同步（`sync_scores` 核心）：覆盖本地 `scores` / `time_remaining` 并广播 `score_changed`。
##
## 客户端状态来源（附录 A.4 / A.9.1 已定稿）：客户端的 `match_state` 由 **`sync_match_state`**
##   精确跟随（房主 → 全端，随 ES-4.4 实现）——`sync_scores` **不再承担状态推断职责**，只管比分与剩余时间。
##
## ⚠ 临时兜底（S2 落地 `sync_match_state` 后应移除或降级为超时保护）：在 `sync_match_state` 实现之前，
##   客户端收不到任何状态迁移消息，会一直停在 `IDLE`，导致 `report_kill` 时期待的状态不一致。
##   故此处暂以「收到 sync 且本地仍为 IDLE → 置 LIVE」作为过渡近似解。
##   → 该分支是 **A.9.1 已作废的「客户端收 sync 推断 LIVE」** 的残留实现，仅为过渡期不卡死而保留。
func _apply_sync(remote_scores: Dictionary, remote_time_remaining: float) -> void:
	scores = remote_scores.duplicate(true)
	time_remaining = remote_time_remaining
	_sync_received += 1
	if match_state == MatchState.IDLE:
		_set_state(MatchState.LIVE) # 客户端推断：收到同步 = 对局进行中
	score_changed.emit(scores, time_remaining)


## 应用远端结算（`net_match_ended` 核心）：固化 `winner_id` / 冻结比分 / 置 ENDED，并广播 signal。
func _apply_ended(remote_winner_id: int, final_scores: Dictionary) -> void:
	if match_state == MatchState.ENDED:
		return # 幂等：已结算则不重复广播
	winner_id = remote_winner_id
	scores = final_scores.duplicate(true)
	_set_state(MatchState.ENDED)
	_ended_received += 1
	match_ended.emit(winner_id, scores)


## 应用远端复位（`net_match_reset` 核心）：回 IDLE、清比分、复位计时与 winner。
##
## ⚠ **末尾必须 emit `match_reset`** —— 这是结算面板能关闭的唯一通知来源。
##   房主走 `request_reset()` →本方法；客户端走 `net_match_reset()` → 本方法 ⇒ **两端都 emit**。
##   （曾经只 emit `score_changed`，那是比分板的绑定面 → 客户端面板永远不关，实测缺陷。）
##   顺序放在 `score_changed` **之后**：先让比分板清空、再关结算面板，
##   避免面板消失的瞬间比分板还残留上一局的数字（同一帧内的可见顺序）。
func _apply_reset() -> void:
	scores.clear()
	winner_id = WINNER_UNSET
	time_remaining = match_duration
	_countdown_remaining = COUNTDOWN_SECONDS
	_sync_accum = 0.0
	_ruleset_warned = false # 新的一局：允许再警告一次「不可用条件」
	_set_state(MatchState.IDLE)
	score_changed.emit(scores, time_remaining)
	match_reset.emit()


## 本端「再来一局」：权威走 `_apply_reset()` + 广播；客户端**不自行复位**，等房主广播。
func request_reset() -> void:
	if not is_authority():
		return
	_apply_reset()
	net_match_reset.rpc()


# ══════════════════════════════════════════════════════════════════════
#  本端击杀上报入口（ES-3.2）—— 供 weapon.gd / knife.gd 调用
# ══════════════════════════════════════════════════════════════════════

## A.7 本端击杀：权威端直调 `_apply_kill`；客户端 `report_kill.rpc_id(1, ...)`。
##
## 取舍（回答附录 A.11.3「是否用 call_local 让房主自己也走同一路径」）：
##   **不采用 call_local**。理由：
##   (1) `call_local` 会让 `report_kill` 在**客机本地也执行一次**——但客机本地不是权威，
##       要么得再加 `is_authority()` 早退（则该次本地执行纯属空转），要么会污染客机本地比分
##       （随后被 sync 覆盖，徒增一帧错误显示）。
##   (2) 房主自身击杀的「权威性」是**本端即时**的：直调 `_apply_kill` 无需网络往返，手感与延迟最优。
##   (3) 幂等性：`_apply_kill` 本身就在 `ENDED` 时早退，重复上报不会重复计分；
##       直调路径与 RPC 路径**共用同一个逻辑入口**，不存在「两条计分实现」的分叉风险。
##   → 故：`report_kill` 保持 `call_remote`（不带 `call_local`），房主自己走直调。
func _report_local_kill(victim_id: int) -> bool:
	if victim_id < 0:
		return false
	if is_authority():
		return _apply_kill(local_peer_id(), victim_id)
	# 客户端：只上报意图，本地不预测比分（等房主 sync 回来）
	report_kill.rpc_id(1, victim_id)
	return true


## A.7 击杀归因：从被击杀的碰撞体解析 `victim_id`。
##
## 依据：`main.gd::_make_player()` 设 `player.name = str(id)`（节点名 = peer id，也见 ADR-002）。
## ⚠ 防御（A.7 现状缺口）：bot / 训练靶 / 场景物件**不是玩家**，其节点名不是数字
##   （如 `Bot`、`TrainingTarget`、`@CharacterBody3D@123`）——直接 `int(name)` 会得 0，
##   而 0 在 ENet 里是「无 peer」的保留值，一旦被当成 victim_id 会造成脏数据。
##   → 用 `String.is_valid_int()` 严格判定；非法（非玩家 / 名字非数字 / id <= 0）一律返回 -1，
##     调用方据此跳过上报（-1 在 `_apply_kill` / `_report_local_kill` 也会被再次拒绝，双保险）。
##
## 本方法是 **static 纯函数**，不依赖 tree / multiplayer → 测试可直接断言各种边界名字。
static func resolve_victim_id(collider: Object) -> int:
	if collider == null or not (collider is Node):
		return -1
	var node := collider as Node
	var raw := String(node.name)
	if not raw.is_valid_int():
		return -1 # bot / 训练靶 / 场景物件：名字不是数字
	var id := raw.to_int()
	if id <= 0:
		return -1 # 0 是 ENet「无 peer」保留值，不作为合法玩家 id
	return id


# ══════════════════════════════════════════════════════════════════════
#  A.9 边界处理
# ══════════════════════════════════════════════════════════════════════

## 迟到加入：为新 peer 初始化条目 {kills:0, deaths:0}（幂等，已存在则不覆盖）。
##   同时：若对局进行中，把当前 `time_remaining` 一并同步给他（附录 A.9）。
func register_player(peer_id: int) -> void:
	_ensure_entry(peer_id)
	score_changed.emit(scores, time_remaining)
	# 对局进行中迟到加入：权威端把当前比分 / 剩余时间推给他
	if is_authority() and _in_active_match():
		sync_scores.rpc_id(peer_id, scores, time_remaining)


## 中途离开：房主移除其条目（MVP 简化，附录 A.9）。
func unregister_player(peer_id: int) -> void:
	if scores.erase(peer_id):
		score_changed.emit(scores, time_remaining)


## 房间玩家列表变化 → 同步增删计分条目（A.9：迟到加入 / 中途离开）。
##   接在 `NetworkManager.room_changed` 上，是 A.9 两类边界的**实际数据流入口**。
func _on_room_changed() -> void:
	if not is_authority():
		return # 客户端等 sync，不自行增删（避免与房主口径分叉）
	for key: Variant in NetworkManager.get_players().keys():
		_ensure_entry(int(key))
	# 移除已不在房间中的 peer
	for key: Variant in scores.keys():
		if not NetworkManager.get_players().has(int(key)):
			scores.erase(key)
	score_changed.emit(scores, time_remaining)


# ══════════════════════════════════════════════════════════════════════
#  内部辅助
# ══════════════════════════════════════════════════════════════════════

## 确保 peer_id 有计分条目；返回其引用（原地维护，调用方直接改 kills/deaths）。
func _ensure_entry(peer_id: int) -> Dictionary:
	if not scores.has(peer_id):
		scores[peer_id] = {"kills": 0, "deaths": 0}
	return scores[peer_id]


## 当前最高击杀数（空表 → 0）。
func _max_kills() -> int:
	var best := 0
	for key: Variant in scores:
		var entry: Dictionary = scores[key]
		best = maxi(best, int(entry.get("kills", 0)))
	return best


## 深拷贝比分（结算冻结用；条目 Dictionary 也复制，避免外部别名改写终态）。
func _freeze_scores() -> Dictionary:
	var frozen: Dictionary = {}
	for key: Variant in scores:
		var entry: Dictionary = scores[key]
		frozen[int(key)] = {"kills": int(entry.get("kills", 0)), "deaths": int(entry.get("deaths", 0))}
	return frozen


## 状态迁移 + 广播（只在真正变化时广播）。
func _set_state(state: int) -> void:
	if match_state == state:
		return
	match_state = state
	match_state_changed.emit(match_state)


## 权威端把当前比分 / 剩余时间广播给全端（变更时 / 每秒心跳 / 阶段切换共用）。
func _broadcast_scores() -> void:
	if not is_authority():
		return
	sync_scores.rpc(scores, time_remaining)


## 是否处于「对局进行中」（COUNTDOWN / LIVE）。
func _in_active_match() -> bool:
	return match_state == MatchState.COUNTDOWN or match_state == MatchState.LIVE


## A.2 COUNTDOWN 期间冻结输入。
##   ⚠ 本端与远端玩家都覆盖：本端玩家的 `_physics_process` 读 `input_blocked`；
##   远端玩家本就由广播状态驱动（`_follow_network_state`），冻结其输入无副作用。
##   若 player.gd 无 `set_input_blocked`（历史版本），静默跳过、不报错（见 EP-3 报告「待接项」）。
func _set_players_input_blocked(blocked: bool) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null or not scene.has_node("Players"):
		return
	for child in scene.get_node("Players").get_children():
		if child.has_method("set_input_blocked"):
			(child as Node).call("set_input_blocked", blocked)
