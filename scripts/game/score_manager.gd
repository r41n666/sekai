class_name ScoreManager
extends Node
## FFA「15 杀 / 5 分钟」权威计分 + 胜负判定（EP-3 · ES-3.1 骨架 + 数据契约）
##
## 需求出处：`design/gdd/01_core_loop.md §4/§5/§6 + 附录 A（ScoreManager 数据契约）`、
##           `production/epics/EP-3-score-and-match-flow.md · ES-3.1`。
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
## ── 本轮（ES-3.1）范围 ──
##   落地：字段 / 信号 / 权威口径 / 状态机枚举 / 胜负判定纯逻辑（可本地无网络跑通）。
##   留到后续批次：
##     · ES-3.2 `report_kill` / `sync_scores` / `match_ended` / `match_reset` 的 RPC 收发
##     · ES-3.3 对局驱动（进程计时、每帧检查结束条件、COUNTDOWN 冻结输入的接线）
##     · ES-3.4 HUD 信号总线接线
##     · ES-3.5 完整回归（本轮已建基线用例）
##   标记 `TODO(EP-3/ES-3.x)` 处即为上述缺口。

## ── A.2 状态机 ──
enum MatchState { IDLE, COUNTDOWN, LIVE, ENDED }

## 倒计时时长（`04_ux_flow` §3.2：3-2-1）
const COUNTDOWN_SECONDS := 3.0
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
signal match_ended(winner_id: int, final_scores: Dictionary)

## ── A.3 字段（默认值必须与契约完全一致，测试断言）──
## 当前状态机状态（见 MatchState）
var match_state: int = MatchState.IDLE
## 击杀目标（上限，达到即结束）
var kill_target: int = 15
## 对局时长上限（秒）
var match_duration: float = 300.0
## 剩余时间（秒），LIVE 期间由 ES-3.3 驱动递减
var time_remaining: float = 300.0
## peer_id → {kills:int, deaths:int}（原地维护，避免每帧重建）
var scores: Dictionary = {}
## 胜者 peer id：-1=未定；-2=并列（平局）
var winner_id: int = WINNER_UNSET


func _ready() -> void:
	# 场景就绪 → 进入 IDLE（等待外部触发 COUNTDOWN；对局驱动接线属 ES-3.3）
	_set_state(MatchState.IDLE)


## ── A.1 权威归属（唯一收口点）──
## 房主（peer_id==1 / is_server）或离线本端为权威；其余为客户端（只上报意图、接收同步）。
func is_authority() -> bool:
	if not NetworkManager.is_online:
		return true # 离线 / 训练模式：本端即权威
	return NetworkManager.is_server


# ══════════════════════════════════════════════════════════════════════
#  纯逻辑（无副作用，供测试直接调用；不依赖网络 / 场景树 / 帧循环）
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


## A.6 结束对局：固化 winner_id、冻结 scores、置 ENDED、广播 match_ended。
##   仅权威调用（ES-3.3 会在 LIVE 每帧检查后触发；本轮已可被测试直接调用）。
func _end_match() -> void:
	if match_state == MatchState.ENDED:
		return # 幂等：同一帧多人达成时，以先到者为准（不会重复发信号）
	winner_id = _evaluate_winner()
	# 冻结比分：深拷贝，阻断后续（迟到 RPC）对结算结果的改写
	var final_scores := _freeze_scores()
	scores = final_scores
	match_state = MatchState.ENDED
	match_state_changed.emit(match_state)
	match_ended.emit(winner_id, final_scores)


## A.8 死亡计分：一条消息同时记「击杀 +1」与「受害者死亡 +1」。
##   自杀（killer_id == victim_id）→ 不记击杀、不扣分（附录 A.9）。
##   本轮实现本地逻辑；RPC 外壳（`report_kill.rpc_id(1, ...)`）留到 ES-3.2。
##   返回 true 表示本次计分被采纳。
func _apply_kill(killer_id: int, victim_id: int) -> bool:
	if match_state == MatchState.ENDED:
		return false # 结算后不再计分（比分已冻结）
	if killer_id == victim_id:
		return false # 自杀：不记击杀、不扣分
	var killer: Dictionary = _ensure_entry(killer_id)
	killer["kills"] = int(killer.get("kills", 0)) + 1
	if victim_id >= 0:
		var victim: Dictionary = _ensure_entry(victim_id)
		victim["deaths"] = int(victim.get("deaths", 0)) + 1
	score_changed.emit(scores, time_remaining)
	return true


# ══════════════════════════════════════════════════════════════════════
#  A.9 边界处理
# ══════════════════════════════════════════════════════════════════════

## 迟到加入：为新 peer 初始化条目 {kills:0, deaths:0}（幂等，已存在则不覆盖）。
func register_player(peer_id: int) -> void:
	_ensure_entry(peer_id)
	score_changed.emit(scores, time_remaining)


## 中途离开：房主移除其条目（MVP 简化，附录 A.9）。
func unregister_player(peer_id: int) -> void:
	if scores.erase(peer_id):
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
