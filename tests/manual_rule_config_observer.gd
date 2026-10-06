extends Node
## D2-04 规则配置化 · 双端窗口实测的**观察者**（挂在 `get_tree().root` 下，活过场景切换）
##
## ## 观测目标（逐条对应用户需求「规则可配置 + 两端一致」）
##  1. 房主配 3 杀 → **两端比分板都显示「先到 3 杀」**（不是硬编码的 15）
##  2. 两端 `effective_kill_target()` 相等且== 3（配置跨端送达的直接证据）
##  3. 房主打到 3 杀 → **两端都进 ENDED**（判定用配置阈值 + 结算广播跨端）
##  4. 客户端**不判定**：即使本地持有配置也不自行 `_end_match`
##     （证明 §7.4「只有权威端求值」—— 靠「客户端在房主推送前不自行结束」观察）
##
## ## ⚠ 只观察 + 施加**合法**输入，不改任何生产逻辑
## 与 `manual_reset_observer.gd` 同款纪律：探针失败要能分清是「产品坏了」
## 还是「探针自己坏了」。
##
## ## ⚠ 全程**不用 await**（本项目纪律：探针里 await 不可靠），一律用帧计数推进状态机。

const GAME_SCENE := "Main"
const ROLE_HOST := "host"

const FRAMES_SCENE_SETTLE := 90
## 打完 N 杀后等结算在**两端**都落地（60Hz 下 120 帧 ≈ 2s，够 RPC 往返 + 渲染）
const FRAMES_AFTER_END := 120
const TOTAL_SECONDS_LIMIT := 120.0

const P_WAIT_HOST := 0
const P_WAIT_SCENE := 1
const P_CONFIGURE := 2## 房主：配规则 + 等下发
const P_WAIT_LIVE := 3
const P_CHECK_TEXT := 4## 校验两端比分板文案
const P_WAIT_END := 5
const P_DONE := 6

var _role := "host"
var _target := 3
var _phase := P_WAIT_HOST
var _frames := 0
var _phase_frames := 0
var _elapsed := 0.0
var _wait_seconds := 0.0
var _failures: Array[String] = []

var _score_mgr: Node = null
var _scoreboard: Node = null
## 客户端：记录「拿到配置」的时刻，用于证明是**下发**来的而不是本地默认值
var _saw_synced_ruleset := false
var _target_seen := -1


func setup(role: String, target_kills: int) -> void:
	_role = role
	_target = target_kills


func _process(delta: float) -> void:
	_frames += 1
	_phase_frames += 1
	_elapsed += delta
	_wait_seconds += delta
	if _elapsed > TOTAL_SECONDS_LIMIT:
		_fail("超过 %.0f 秒上限仍未完成（phase=%d）" % [TOTAL_SECONDS_LIMIT, _phase])
		_finish()
		return
	match _phase:
		P_WAIT_HOST:
			_wait_host()
		P_WAIT_SCENE:
			_wait_scene()
		P_CONFIGURE:
			_configure()
		P_WAIT_LIVE:
			_wait_live()
		P_CHECK_TEXT:
			_check_text()
		P_WAIT_END:
			_wait_end()
		P_DONE:
			pass


func _say(line: String) -> void:
	print("[RC]%s %s" % [_role, line])


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[RC]%s   ✗ %s" % [_role, msg])


func _goto(p: int) -> void:
	_phase = p
	_phase_frames = 0
	_wait_seconds = 0.0


# ── 房主：等客户端到齐后开局 ────────────────────────────────────────────
func _wait_host() -> void:
	if _role != ROLE_HOST:
		# 客户端：`_start_match` RPC 会把本端切到 main.tscn（NetworkManager 内部做的）
		_goto(P_WAIT_SCENE)
		return
	var ids: Array = NetworkManager.get_players().keys()
	if ids.size() < 2:
		if _wait_seconds > 40.0:
			_fail("房主在 40 秒内没等到客户端加入")
			_finish()
		return
	_say("已集齐 %d 名玩家（%s），开始对战…" % [ids.size(), str(ids)])
	NetworkManager.host_start_match()
	_goto(P_WAIT_SCENE)


## 等对局场景 + ScoreManager / HUD / 比分板就绪
func _wait_scene() -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.name != GAME_SCENE:
		if _wait_seconds > 40.0:
			_fail("对局场景未加载（current_scene=%s）"
				% ("null" if scene == null else str(scene.name)))
			_finish()
		return
	if _phase_frames < FRAMES_SCENE_SETTLE:
		return
	_score_mgr = scene.get_node_or_null("ScoreManager")
	_scoreboard = scene.get_node_or_null("HUD/Scoreboard")
	if _score_mgr == null:
		_fail("对局场景里找不到 ScoreManager")
		_finish()
		return
	if _scoreboard == null:
		_fail("HUD 下找不到 Scoreboard 节点")
		_finish()
		return
	#关键前置：`sync_ruleset` 的接收端必须真的接上（只看源码/信号存在是不够的）。
	var connected := false
	if _score_mgr.has_signal("ruleset_applied"):
		connected = _score_mgr.ruleset_applied.is_connected(
			Callable(get_tree().root.get_node_or_null("Main"), "_on_ruleset_applied")) \
			if get_tree().root.has_node("Main") else false
	_say("对局就绪：peer=%d｜ScoreManager=%s｜Scoreboard=%s｜main 侧 ruleset_applied 已连=%s"
		% [int(NetworkManager.multiplayer.get_unique_id()),
			str(_score_mgr != null), str(_scoreboard != null), str(connected)])
	_goto(P_CONFIGURE)


## 房主：把规则配成「先到 %d 杀」（**默认是 15，配成 3 才能证明配置生效**）。
## 客户端：等配置下发到手。
func _configure() -> void:
	if _role == ROLE_HOST:
		if int(_score_mgr.call("effective_kill_target")) == _target:
			_goto(P_WAIT_LIVE)
			return
		var cfg := {
			"schema_version": 1,
			"ruleset_id": "probe_kill%d" % _target,
			"label": "实测 · 先到 %d 杀" % _target,
			"combine": "ANY_OF",
			"winner_policy": "MAX_KILLS",
			"duration_limit": 300.0,
			"conditions": [
				{"type": "kill_target", "enabled": true,
					"params": {"target_kills": _target}},
				{"type": "time_limit", "enabled": true, "params": {}},
			],
			"fail_conditions": [],
			"player_defaults": {},
		}
		# 走**生产入口**（未来配置面板调的就是它：设置 + `sync_ruleset` 下发）
		var ok: bool = bool(_score_mgr.call("set_ruleset", cfg))
		_say("房主端：set_ruleset(先到 %d 杀) 返回 %s｜本地生效阈值=%d"
			% [_target, str(ok), int(_score_mgr.call("effective_kill_target"))])
		if not ok:
			_fail("房主端设置规则集失败（配置被判非法？）")
			_finish()
			return
		_goto(P_WAIT_LIVE)
		return
	# 客户端：等 `sync_ruleset` 到达（配置是从房主**下发**来的，不是本地默认值 —— 默认是 15）
	if _wait_seconds > 10.0:
		_fail("客户端 10 秒内没收到规则集下发（生效阈值=%s，应为 %d）"
			% [str(int(_score_mgr.call("effective_kill_target"))), _target])
		_finish()
		return
	if int(_score_mgr.call("effective_kill_target")) == _target:
		_saw_synced_ruleset = true
		_say("客户端端：已收到规则集下发，生效阈值=%d（默认是 15，故这条证明是下发来的）"
			% _target)
		_goto(P_WAIT_LIVE)


## 等本端进入 LIVE
func _wait_live() -> void:
	var state := int(_score_mgr.get("match_state"))
	if state != 2: # MatchState.LIVE == 2
		if _wait_seconds > 30.0:
			_fail("30 秒内未进入 LIVE（match_state=%d）" % state)
			_finish()
		return
	# ── 核心观测 1：两端生效阈值一致 + 比分板文案读实际值 ──
	_target_seen = int(_score_mgr.call("effective_kill_target"))
	_say("已进入 LIVE｜本端 effective_kill_target=%d｜比分板文案=「%s」"
		% [_target_seen, _objective_text()])
	if _target_seen != _target:
		_fail("本端生效阈值应为 %d，实际 %d —— 配置未生效" % [_target, _target_seen])
		_finish()
		return
	_goto(P_CHECK_TEXT)


## 校验比分板目标文案（**这是「配置下发链路」的端到端证据**）
func _check_text() -> void:
	if _phase_frames < 20:
		return
	var text := _objective_text()
	_say("比分板目标文案=「%s」（应含 %d，不应含 15）" % [text, _target])
	if not text.contains(str(_target)):
		_fail("比分板目标文案未反映配置目标：期望含「%d」，实际「%s」" % [_target, text])
	if text.contains("15"):
		_fail("比分板仍在显示硬编码的 15（实际「%s」）—— 目标文案没读实际生效值" % text)
	# 房主：推到目标杀数，走**真实**的 `_report_local_kill` → `_apply_kill` 路径
	if _role == ROLE_HOST:
		var mine := int(NetworkManager.multiplayer.get_unique_id())
		_say("房主端：把击杀推到配置目标 %d 杀（走权威端真实记分入口）" % _target)
		for i in _target:
			_score_mgr.call("_report_local_kill", mine + 1000 + i)
		_say("  ↳ 推送后本端 scores=%s" % str(_score_mgr.get("scores")))
	_goto(P_WAIT_END)


## 等结算（ENDED）—— **两端都要进**
func _wait_end() -> void:
	var state := int(_score_mgr.get("match_state"))
	if state != 3: # MatchState.ENDED == 3
		if _wait_seconds > 20.0:
			_fail("对局未在 20 秒内进入 ENDED（match_state=%s）"
				% str(int(_score_mgr.get("match_state"))))
			_finish()
		return
	# ⚠ 只在**首次**进入 ENDED 时打印一次（这段要等120 帧让结算落地，
	#   每帧都打会把日志刷成几百行、真正的证据反而看不见 —— 本项目已在探针上栽过：
	#   首次实测时这里刷了 132 行才输出 RESULT）。
	if _phase_frames == 1:
		_say("本端已进入 ENDED（winner_id=%s，scores=%s）"
			% [str(int(_score_mgr.get("winner_id"))), str(_score_mgr.get("scores"))])
	if _phase_frames < FRAMES_AFTER_END:
		return
	_finish()


func _objective_text() -> String:
	if _scoreboard == null:
		return ""
	var label := _scoreboard.get_node_or_null("Compact/Box/Row/Objective")
	return "<无节点>" if label == null else str((label as Label).text)


func _finish() -> void:
	if _phase == P_DONE:
		return
	_phase = P_DONE
	_say("==== 本端观测小结 ====")
	_say("  生效阈值=%d｜比分板文案=「%s」｜是否收到下发=%s"
		% [_target_seen, _objective_text(), str(_saw_synced_ruleset)])
	if _failures.is_empty():
		_say("RESULT PASS（配置跨端送达 / 文案读实际值 / 两端都结算）")
	else:
		print("[RC]%s RESULT FAIL（%d 条）" % [_role, _failures.size()])
	get_tree().quit(1 if not _failures.is_empty() else 0)