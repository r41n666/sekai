extends Node
## S1 临时调试观测层（G4 双人联机实测用）——**对生产行为零副作用的纯旁路**
##
## ══════════════════════════════════════════════════════════════════════
##  ⚠ 这是 S1 的**临时**观测层。S2 的 EP-4 HUD（比分板 / 结算面板 / 倒计时 UI）
##     落地后，本文件应**整体删除**（连同 `main.tscn` 里挂的 MatchDebugProbe 节点）。
## ══════════════════════════════════════════════════════════════════════
##
## 目的：EP-4 未落地前，`ScoreManager` 的 5 条信号与玩家血量/死亡信号**全工程零消费者**，
##   双端实测时「跨端比分一致 / 15 杀触发 match_ended / 伤害只在受害端结算」**没有任何可观测出口**。
##   本节点只做一件事：把这些信号转成**带角色标记**的 stdout 日志，供人工对照判定 G4。
##
## ── 硬约束（为什么本文件不碰任何既有逻辑）──
## 1. **不改** `score_manager.gd` / `player.gd` / `weapon.gd` / `knife.gd` 的任何逻辑、字段默认值、
##    信号签名、RPC 签名（测试已锁定，改动直接打红）。
## 2. 只**新增**文件 + 在 `main.tscn` 挂一个节点；不删不移动现有节点。
## 3. 「伤害只在受害端结算」这条**不碰 player.gd** —— 改为在观测层连接每个玩家节点的
##    `health_changed` 信号，并用 `get_multiplayer_authority()` 标注这是哪个 peer 的血条。
##    远端玩家掉血不会在本端触发 health_changed（伤害走 `apply_network_damage.rpc_id(受害者 authority)`），
##    因此「哪一端的日志里出现掉血」就是「伤害结算在哪一端」的直接证据。
##
## ── 开关 ──
## **默认关闭**（不污染正常游戏 stdout）。仅在设了环境变量 `MBDBG=1` 时启用。
##   启用：`MBDBG=1 godot --headless --path . res://scenes/main.tscn`
##   （Windows/Git Bash 下此前缀同样可用；PowerShell 用 `$env:MBDBG=1`）
## 环境变量被读取一次并缓存；`MBDBG` 为空 / "0" / "false" 均视为关闭。
##
## ── 日志格式 ──
## `[MBDBG][<ROLE>] <event> <payload>`
##   <ROLE> ∈ `HOST`（房主）/ `CLIENT id=<n>`（客户机）/ `OFFLINE`（未联机）
##   角色标记是**跨端对照的前提**——双端日志混在一起时，靠它区分「本端是房主还是客户机」。
##
## ── 本观测层能 / 不能观测什么（见交付报告）──
##   能：score_changed / match_state_changed / countdown_updated / match_ended / 每端血量变化 / 每端死亡
##   不能：`sync_scores` 与 `sync_match_state` 的**网络到达时刻**（无到达回调钩子，除非改 score_manager）

## 玩家容器节点名（`main.gd` 里固定为 "Players"）。
const PLAYERS_NODE := "Players"
## ScoreManager 节点名（`main.tscn` 里固定为 "ScoreManager"）。
const SCORE_MANAGER_NODE := "ScoreManager"

## 环境变量开关（默认关闭）。缓存一次，避免每帧读 env。
var _enabled := false
## 本端角色标记（"HOST" / "CLIENT id=N" / "OFFLINE"），日志前缀用。
var _role := "OFFLINE"
## 已连接 health_changed / died 的玩家节点（按节点实例 id 去重，防重复连接）。
var _hooked_players: Dictionary = {}
## ScoreManager 引用（延迟解析，容忍 _ready 时序）。
var _score: Node = null


func _ready() -> void:
	_enabled = _read_enabled()
	if not _enabled:
		# 默认路径：什么都不做、不连信号、不打日志 → 对生产零影响。
		return

	_role = _resolve_role()

	# ScoreManager 在 main.tscn 里是 _ready 前就已存在的兄弟节点；但为稳妥仍用 deferred 解析。
	_score = _find_score_manager()
	if _score == null:
		_log("probe_error", "未找到 %s 节点（观测层失效，不影响游戏）" % SCORE_MANAGER_NODE)
		return

	_connect_score_signals()
	_hook_all_players()
	_log("probe_ready", "观测层已挂载（role=%s）" % _role)


func _process(_delta: float) -> void:
	if not _enabled:
		return
	# 玩家节点可能在对局中动态增删（迟到加入 / leave_game）→ 每帧做一次低成本补齐。
	# 仅在「有新增/离开」时才真正动作：先按已 hook 表修剪失效节点，再 hook 新出现的。
	_refresh_player_hooks()


# ══════════════════════════════════════════════════════════════════════
#  角色判定 / 开关
# ══════════════════════════════════════════════════════════════════════

func _read_enabled() -> bool:
	var v := OS.get_environment("MBDBG").strip_edges().to_lower()
	if v == "" or v == "0" or v == "false":
		return false
	return true


## 判定本端角色：房主 / 客户机 / 未联机。
##   依据 `NetworkManager.is_server`（房主）+ `is_online`（是否联机）+ `multiplayer.get_unique_id()`。
func _resolve_role() -> String:
	if not NetworkManager.is_online:
		return "OFFLINE"
	if NetworkManager.is_server:
		return "HOST"
	return "CLIENT id=%d" % multiplayer.get_unique_id()


# ══════════════════════════════════════════════════════════════════════
#  ScoreManager 信号接线（5 条）
# ══════════════════════════════════════════════════════════════════════

func _connect_score_signals() -> void:
	# 逐条连接并对每条的「是否存在」做防御（信号名是契约面，若未来改名，这里会明确报错而不是静默）
	_safe_connect("score_changed", _on_score_changed)
	_safe_connect("match_state_changed", _on_match_state_changed)
	_safe_connect("countdown_updated", _on_countdown_updated)
	_safe_connect("match_ended", _on_match_ended)


func _safe_connect(sig_name: String, handler: Callable) -> void:
	if not _score.has_signal(sig_name):
		_log("probe_error", "ScoreManager 无信号 %s（契约面变化？观测缺口）" % sig_name)
		return
	_score.connect(sig_name, handler)


func _on_score_changed(scores: Dictionary, time_remaining: float) -> void:
	# _sync_received 计数在 score_manager 内维护，用于区分「房主本地计分」vs「客户端收到 sync」
	var sync_hint := ""
	if not NetworkManager.is_server and NetworkManager.is_online:
		sync_hint = " (via sync_scores)"
	_log("score_changed", "scores=%s t=%.1f%s" % [_fmt_scores(scores), time_remaining, sync_hint])


func _on_match_state_changed(state: int) -> void:
	_log("match_state_changed", "%s" % _state_name(state))


func _on_countdown_updated(remaining: float) -> void:
	_log("countdown_updated", "%.2f" % remaining)


func _on_match_ended(winner_id: int, final_scores: Dictionary) -> void:
	_log("match_ended", "winner=%d final=%s" % [winner_id, _fmt_scores(final_scores)])


# ══════════════════════════════════════════════════════════════════════
#  玩家信号接线（health_changed / died）—— 证明「伤害只在受害端结算」
# ══════════════════════════════════════════════════════════════════════

func _hook_all_players() -> void:
	var container := _find_players_container()
	if container == null:
		return
	for child in container.get_children():
		_hook_player(child)


## 修剪已失效的 hook + 补齐新出现的玩家节点（不每帧打日志，只在变化时动作）。
func _refresh_player_hooks() -> void:
	var container := _find_players_container()
	if container == null:
		return
	# 1) 清理已被 free 的节点。
	#    ⚠ 必须先取 key 快照再删：在遍历 `keys()` 的同时 `erase()` 会改动底层字典，
	#    且把「已 free 的实例」从 Dictionary 取出赋给变量时，Godot 会抛
	#    "Trying to assign invalid previously freed instance"（用户双端实测中已复现）。
	#    改用 `duplicate()` 快照，并把值取进 Variant 后再判空，即可避免。
	for iid: Variant in _hooked_players.keys().duplicate():
		var node: Variant = _hooked_players.get(iid)
		if node == null or not is_instance_valid(node):
			_hooked_players.erase(iid)
	# 2) 补齐新节点
	for child in container.get_children():
		_hook_player(child)


func _hook_player(node: Node) -> void:
	if node == null:
		return
	var iid := node.get_instance_id()
	if _hooked_players.has(iid):
		return
	# 只有带 health_changed / died 的节点（玩家）才需观测；bot / 靶子无这两个信号 → 跳过。
	if not (node.has_signal("health_changed") and node.has_signal("died")):
		return
	_hooked_players[iid] = node
	var authority := node.get_multiplayer_authority()
	var peer_name := String(node.name)
	node.connect("health_changed", _on_player_health_changed.bind(peer_name, authority))
	node.connect("died", _on_player_died.bind(peer_name, authority))
	# 击杀确认回传（G4 关键路径）：没有这条线时，「扣血正常但比分恒为 0」这类
	# 「伤害结算对了、归因丢了」的缺陷在日志里完全不可见（2026-10-06 G4 实测踩过）。
	if node.has_signal("remote_kill_confirmed"):
		node.connect("remote_kill_confirmed", _on_remote_kill_confirmed)
	_log("player_hooked", "node=%s authority=%d" % [peer_name, authority])


## 射手端收到「你把我打死了」的确认 → **这是联机击杀真正被计分的唯一入口**。
##   `victim` = 被击倒者节点名（= 其 peer id）。角色前缀（HOST / CLIENT id=N）标明是哪一端确认的。
##   读法：
##     · 有 `kill_confirmed` 且下一条 `score_changed` 比分 +1 → 归因链路通 ✔
##     · 有 `kill_confirmed` 但比分不动 → 断裂在 ScoreManager（房主未收到 report_kill / 已 ENDED）
##     · 完全没有 `kill_confirmed` → 根本没打到人（命中判定问题，不是计分问题）
func _on_remote_kill_confirmed(victim_peer_name: String) -> void:
	_log("kill_confirmed", "victim=%s" % victim_peer_name)


## 玩家血量变化 —— **只有本端触发的结算会打这条**。
##   远端玩家的伤害走 `apply_network_damage.rpc_id(受害者 authority)`，在**受害者本端**才扣血；
##   因此「哪一端的日志出现掉血」= 「伤害结算在哪一端」。
func _on_player_health_changed(current: float, maximum: float, peer_name: String, authority: int) -> void:
	_log("player_health_changed",
		"peer=%s authority=%d hp=%.1f/%.1f" % [peer_name, authority, current, maximum])


func _on_player_died(peer_name: String, authority: int) -> void:
	_log("player_died", "peer=%s authority=%d" % [peer_name, authority])


# ══════════════════════════════════════════════════════════════════════
#  查找 / 格式化 / 打印
# ══════════════════════════════════════════════════════════════════════

func _find_score_manager() -> Node:
	var scene := get_tree().current_scene
	if scene != null:
		var n := scene.get_node_or_null(SCORE_MANAGER_NODE)
		if n != null:
			return n
	# 兜底：全场景深搜（仅当它不是 current_scene 的直接子节点时）
	return _deep_find(SCORE_MANAGER_NODE)


func _find_players_container() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null(PLAYERS_NODE)


func _deep_find(node_name: String) -> Node:
	var root := get_tree().current_scene
	if root == null:
		return null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if String(n.name) == node_name:
			return n
		for c in n.get_children():
			stack.append(c)
	return null


func _state_name(state: int) -> String:
	match state:
		ScoreManager.MatchState.IDLE: return "IDLE"
		ScoreManager.MatchState.COUNTDOWN: return "COUNTDOWN"
		ScoreManager.MatchState.LIVE: return "LIVE"
		ScoreManager.MatchState.ENDED: return "ENDED"
		_: return "UNKNOWN(%d)" % state


func _fmt_scores(scores: Dictionary) -> String:
	if scores.is_empty():
		return "{}"
	var keys: Array = scores.keys()
	keys.sort()
	var parts: Array[String] = []
	for k in keys:
		var e: Dictionary = scores[k]
		parts.append("%s:{kills:%d,deaths:%d}" % [str(k), int(e.get("kills", 0)), int(e.get("deaths", 0))])
	return "{" + ", ".join(parts) + "}"


func _log(event: String, payload: String) -> void:
	print("[MBDBG][%s] %s %s" % [_role, event, payload])
