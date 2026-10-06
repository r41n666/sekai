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

## ── A.3 字段（默认值必须与契约完全一致，测试断言）──
## 当前状态机状态（见 MatchState）
var match_state: int = MatchState.IDLE
## 击杀目标（上限，达到即结束）
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
func _check_end_condition() -> bool:
	if time_remaining <= 0.0:
		return true
	return _max_kills() >= kill_target


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
## ⚠ 客户端状态机推断（诚实说明）：附录 A.4 的消息清单里**没有**专门的「状态迁移 RPC」，
##   只有 `sync_scores` / `match_ended` / `match_reset`。因此客户端无法被精确告知
##   「现在进 COUNTDOWN 了 / 进 LIVE 了」。本实现的做法：
##     · 收到 sync 且本地仍是 IDLE → 推断对局已在跑，置 LIVE（客户端的权威状态由房主隐含驱动）；
##     · 收到 `net_match_ended` → ENDED；收到 `net_match_reset` → IDLE。
##   这样客户端不会停在 IDLE 导致 `report_kill` 时期待的状态不一致，也不会自行递减计时
##   （客户端 `is_authority() == false` → `_tick_live` 早退，时间只被 sync 覆盖）。
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
func _apply_reset() -> void:
	scores.clear()
	winner_id = WINNER_UNSET
	time_remaining = match_duration
	_countdown_remaining = COUNTDOWN_SECONDS
	_sync_accum = 0.0
	_set_state(MatchState.IDLE)
	score_changed.emit(scores, time_remaining)


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
