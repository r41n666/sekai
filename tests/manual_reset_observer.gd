extends Node
## 对局复位闭环 · 双端窗口实测的**观察者**（挂在 `get_tree().root` 下，活过场景切换）
##
## ## 观测目标（用户报的那个缺陷，逐条对应）
##  1. 打完 → 结算面板在**两端**都打开（前置：证明结算广播跨端到了）
##  2. 房主点「再来一局」→ **客户端面板 `is_open()` 由 true → false**（核心！）
##  3. 两端 `ScoreManager.scores` 都清空、`match_state` 回 `IDLE`
##  4. 两端玩家 `input_blocked` 都回到 false（能重新操作）
##  5. 客户端**不会**自己复位（点不动的「等待房主…」按钮；且复位只由房主广播触发）
##
## ## ⚠ 只观察 + 施加**合法**输入，不改任何生产逻辑
##与 `manual_health_sync_observer.gd` 同款纪律：探针失败要能分清是「产品坏了」
## 还是「探针自己坏了」。
##
## ## ⚠ 全程**不用 await**（本项目纪律：探针里 await 不可靠），一律用帧计数推进状态机。
##
## ##为什么**不**靠真实鼠标点击「再来一局」
## 双端探针里自动发鼠标事件需要焦点/坐标对齐，跨窗口不可靠且易被分辨率差异坑到。
## 本探针改为直接调 `MatchResult._on_again_pressed()` —— 它**就是**按钮 `pressed`
## 信号绑的那个函数（`match_result.gd::_ready` 里 `_again_button.pressed.connect(_on_again_pressed)`），
## 与真实点击走**同一条代码路径**，只跳过了「操作系统把鼠标事件送到控件」这一步。
## 顺带也能顺带验证「客户端点那个 disabled 按钮不会触发」（见 P_CLIENT_PRESS 阶段）。

const GAME_SCENE := "Main"
const ROLE_HOST := "host"

const FRAMES_WAIT_PLAYERS := 30
const FRAMES_SCENE_SETTLE := 90
const FRAMES_AFTER_END := 40# 等结算面板在本端渲染完
## ⚠ 房主点完「再来一局」后，要等**足够久**让 RPC 往返 + 客户端处理完。
##   60Hz 下 60 帧 ≈ 1s；给 120 帧 ≈ 2s 留足余量（ENet 本机实测毫秒级，但要覆盖两帧渲染 + 处理）。
const FRAMES_AFTER_RESET := 120
const TOTAL_FRAMES_LIMIT := 5400# 兜底退出（防挂死）
const CONNECT_WAIT_SECONDS := 40.0

const P_WAIT_HOST := 0
const P_WAIT_SCENE := 1
const P_WAIT_LIVE := 2## 等 LIVE（才能触发结束，见 _wait_live 的坑说明）
const P_WAIT_END := 3
const P_AFTER_END := 4
const P_CLIENT_PRESS := 5## 客户端：验证 disabled 按钮点不动
const P_WAIT_RESET := 6## 客户端：等房主广播复位
const P_DONE := 7

var _role := "host"
var _phase := P_WAIT_HOST
var _frames := 0
var _phase_frames := 0
var _elapsed := 0.0
var _wait_seconds := 0.0
var _failures: Array[String] = []

## 观测快照
var _score_mgr: Node = null
var _panel: Node = null
var _local_player: Node = null
## 结算时是否看到面板打开（前置条件）
var _saw_panel_open := false
## 结算时面板按钮文案（用来证明客户端确实显示「等待房主…」）
var _again_caption_at_end := ""
var _again_disabled_at_end := false
## 复位前后的关键量
var _scores_size_before := -1
var _state_before := -1
var _panel_open_before := false
var _input_blocked_before := false
var _client_press_triggered := false
var _client_press_panel_open_after := false


func setup(role: String) -> void:
	_role = role


func _process(delta: float) -> void:
	_frames += 1
	_phase_frames += 1
	_elapsed += delta
	_wait_seconds += delta
	if _elapsed > 120.0:
		_fail("超过 120 秒上限仍未完成（phase=%d）" % _phase)
		_finish()
		return
	match _phase:
		P_WAIT_HOST:
			_wait_host()
		P_WAIT_SCENE:
			_wait_scene()
		P_WAIT_LIVE:
			_wait_live()
		P_WAIT_END:
			_wait_end()
		P_AFTER_END:
			_after_end()
		P_CLIENT_PRESS:
			_client_press()
		P_WAIT_RESET:
			_wait_reset()
		P_DONE:
			pass


func _say(line: String) -> void:
	print("[RS]%s %s" % [_role, line])


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[RS]%s   ✗ %s" % [_role, msg])


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
		if _wait_seconds > CONNECT_WAIT_SECONDS:
			_fail("房主在 %.0f 秒内没等到客户端加入" % CONNECT_WAIT_SECONDS)
			_finish()
		return
	_say("已集齐 %d 名玩家（%s），开始对战…" % [ids.size(), str(ids)])
	NetworkManager.host_start_match()
	_goto(P_WAIT_SCENE)


# ── 等对局场景 + ScoreManager / HUD / 玩家就绪 ──────────────────────────
func _wait_scene() -> void:
	if _phase_frames < FRAMES_WAIT_PLAYERS and _role == ROLE_HOST:
		return
	var scene := get_tree().current_scene
	if scene == null or scene.name != GAME_SCENE:
		if _wait_seconds > CONNECT_WAIT_SECONDS:
			_fail("对局场景未加载（current_scene=%s）"
				% ("null" if scene == null else str(scene.name)))
			_finish()
		return
	if _phase_frames < FRAMES_SCENE_SETTLE:
		return
	_score_mgr = scene.get_node_or_null("ScoreManager")
	_panel = scene.get_node_or_null("HUD/MatchResult")
	_local_player = get_tree().get_first_node_in_group("player")
	if _score_mgr == null:
		_fail("对局场景里找不到 ScoreManager")
		_finish()
		return
	if _panel == null:
		_fail("HUD 下找不到 MatchResult 节点（结算面板没挂上）")
		_finish()
		return
	#关键前置：面板必须**真的连上**了ScoreManager 的复位信号。
	# 只查源码/信号存在是不够的 —— 这里查运行期的连接状态。
	var connected := false
	if _score_mgr.has_signal("match_reset"):
		connected = _score_mgr.match_reset.is_connected(
			Callable(_panel, "_on_match_reset"))
	_say("对局就绪：本端 peer=%d｜MatchResult 已连 match_reset=%s"
		% [int(NetworkManager.multiplayer.get_unique_id()), str(connected)])
	if not connected:
		_fail("MatchResult 未连接 ScoreManager.match_reset —— 复位后面板不会关（本轮缺陷形态）")
		_finish()
		return
	# 让房主把比分打到 kill_target，走**真实**的 15 杀结束路径（不改产品逻辑）
	if _role == ROLE_HOST:
		_say("房主端：等进入 LIVE 后把击杀数推到 kill_target，走真实 _tick_live → _end_match 路径")
	_goto(P_WAIT_LIVE)


## 等本端进入 LIVE —— ⚠ 必须先等 LIVE 才能触发结束。
##
## ##踩过的坑（探针 bug，不是产品 bug）
## 第一版直接在「对局就绪」时设`time_remaining = 0.01`，结果**20 秒都没进 ENDED**。
## 原因：那一刻状态还是 **COUNTDOWN(1)**，而 `_drive_countdown()` 归零时会执行
##   `time_remaining = match_duration`（A.2 规定LIVE 启动时复位计时）
##   → **把我设的 0.01 直接覆盖回 300**，于是永远打不到时间耗尽。
## → 故拆成两步：先等 LIVE，再在 LIVE 里用「击杀数达标」触发（与计时无关，最稳）。
func _wait_live() -> void:
	var state := int(_score_mgr.get("match_state"))
	if state != 2: # MatchState.LIVE == 2
		if _wait_seconds > 30.0:
			_fail("30 秒内未进入 LIVE（match_state=%d）" % state)
			_finish()
		return
	if _role == ROLE_HOST:
		var mine := int(NetworkManager.multiplayer.get_unique_id())
		# ⚠ 循环 `kill_target` 次（**不是 kill_target-1**）：结束条件是
		#   `_max_kills() >= kill_target`，从 0 开始就得正好加满 kill_target 次。
		#   第一版写了 `kill_target - 1` → 只到 14 杀 → 永远差一点、20 秒超时。
		#   这与 C-18 同款教训：**差一格的阈值判断看起来完全正常**，只是永远不触发。
		var target := int(_score_mgr.get("kill_target"))
		_say("已进入 LIVE（match_state=2），把本端击杀推到 kill_target=%d" % target)
		# 走权威端**真实**的记分入口（`_report_local_kill` → `_apply_kill`），
		# 而不是直接改 `scores` —— 这样 `_check_end_condition` 与结算广播都是真的。
		for i in target:
			_score_mgr.call("_report_local_kill", mine + 1000 + i)
		_say("  ↳ 推送后本端 scores=%s（max_kills 应 ≥ %d）"
			% [str(_score_mgr.get("scores")), target])
	_goto(P_WAIT_END)


# ── 等结算（ENDED） ─────────────────────────────────────────────────────
func _wait_end() -> void:
	if int(_score_mgr.get("match_state")) != 3: # MatchState.ENDED == 3
		if _wait_seconds > 20.0:
			_fail("对局未在20 秒内进入 ENDED（match_state=%s）"
				% str(int(_score_mgr.get("match_state"))))
			_finish()
		return
	_say("本端已进入 ENDED（winner_id=%s，scores=%s）"
		% [str(int(_score_mgr.get("winner_id"))), str(_score_mgr.get("scores"))])
	_goto(P_AFTER_END)


# ── 结算后：确认面板已打开，记录按钮文案与权限 ───────────────────────────
func _after_end() -> void:
	if _phase_frames < FRAMES_AFTER_END:
		return
	var open_before: bool = bool(_panel.call("is_open"))
	_say("结算面板 is_open=%s｜按钮文案=「%s」disabled=%s"
		% [str(open_before), _caption(), str(_again_disabled())])
	if not open_before:
		_fail("结算面板未打开（is_open=false）—— 前置条件不满足，无法验证复位")
		_finish()
		return
	_saw_panel_open = true
	# 记下复位前的量，供复位后对比
	_panel_open_before = true
	_scores_size_before = (_score_mgr.get("scores") as Dictionary).size()
	_state_before = int(_score_mgr.get("match_state"))
	_input_blocked_before = _input_blocked()
	_again_caption_at_end = _caption()
	_again_disabled_at_end = _again_disabled()
	_say("复位前基线：scores条目=%d｜match_state=%d(ENDED)｜input_blocked=%s"
		% [_scores_size_before, _state_before, str(_input_blocked_before)])

	if _role == ROLE_HOST:
		_say("房主端：点「再来一局」（调 _on_again_pressed，与按钮 pressed 同一条路径）")
		_panel.call("_on_again_pressed")
		_say("房主端：已调用，本端面板 is_open=%s（应立即为 false）"
			% str(bool(_panel.call("is_open"))))
		_goto(P_WAIT_RESET)
	else:
		_goto(P_CLIENT_PRESS)


# ── 客户端：验证「等待房主…」那个按钮**点不动**（disabled 真的拦得住）──
func _client_press() -> void:
	if _phase_frames < 2:
		return
	# 先确认客户端按钮确实是 disabled + 文案是「等待房主…」
	if not _again_disabled():
		_fail("客户端的[再来一局] 按钮竟不是 disabled（文案=「%s」）—— 客户端不该能点复位"
			% _again_caption_at_end)
	if _again_caption_at_end != "等待房主…":
		_fail("客户端按钮文案应为「等待房主…」，实际「%s」" % _again_caption_at_end)
	# 直接调回调（绕过控件的 disabled 拦截），验证**第二道防线**：
	# `request_reset()` 的权威校验必须挡住客户端自复位。
	var before_scores: int = (_score_mgr.get("scores") as Dictionary).size()
	_panel.call("_on_again_pressed")
	var after_scores: int = (_score_mgr.get("scores") as Dictionary).size()
	_client_press_triggered = true
	_client_press_panel_open_after = bool(_panel.call("is_open"))
	_say("客户端强行调用 _on_again_pressed：scores %d → %d（应**不变**，客户端无复位权限）"
		% [before_scores, after_scores])
	if after_scores != before_scores:
		_fail("客户端竟能自行复位比分（%d → %d）—— 违反 A.1 权威归属"
			% [before_scores, after_scores])
	_goto(P_WAIT_RESET)


# ── 等复位生效（房主广播 → 客户端 net_match_reset → _apply_reset）──────
func _wait_reset() -> void:
	if _phase_frames < FRAMES_AFTER_RESET:
		return
	var scores: Dictionary = _score_mgr.get("scores")
	var state := int(_score_mgr.get("match_state"))
	var panel_open: bool = bool(_panel.call("is_open"))
	var input_blocked := _input_blocked()
	_say("复位后：面板 is_open=%s｜scores=%s(条目=%d)｜match_state=%d｜input_blocked=%s"
		% [str(panel_open), str(scores), scores.size(), state, str(input_blocked)])

	# ── 断言 1（核心）：面板必须关闭 ──
	if panel_open:
		_fail("⚠ 复位后结算面板**仍然打开**（is_open=true）—— 这就是用户报的缺陷！")
	# ── 断言 2：陈旧态已清（面板内部的 _has_result 也复位了）──
	if bool(_panel.get("_has_result")):
		_fail("复位后 _has_result 仍为 true（下次结算会被陈旧态污染）")
	# ── 断言 3：比分清空 ──
	if not scores.is_empty():
		_fail("复位后 scores 未清空（%s）" % str(scores))
	# ── 断言 4：状态回IDLE ──
	if state != 0:
		_fail("复位后 match_state 应回 IDLE(0)，实际 %d" % state)
	# ── 断言 5：输入屏蔽恢复 ──
	if input_blocked:
		_fail("复位后玩家 input_blocked 仍为 true（面板消失了但玩家不能动）")
	# ── 断言 6（客户端专属）：面板按钮权限复位后仍是客户端身份 ──
	if _role != ROLE_HOST and not _again_disabled():
		_fail("客户端复位后按钮竟变成可点了（文案=「%s」）" % _caption())
	_finish()


# ── 小工具 ──────────────────────────────────────────────────────────────
func _caption() -> String:
	var b: Button = _panel.get_node_or_null("Panel/VBox/Buttons/AgainButton")
	return "" if b == null else b.text


func _again_disabled() -> bool:
	var b: Button = _panel.get_node_or_null("Panel/VBox/Buttons/AgainButton")
	return true if b == null else b.disabled


func _input_blocked() -> bool:
	if _local_player != null and is_instance_valid(_local_player):
		return bool(_local_player.get("input_blocked"))
	return false


func _finish() -> void:
	if _phase == P_DONE:
		return
	_phase = P_DONE
	_say("==== 本端观测小结 ====")
	_say("  结算时面板打开过=%s｜按钮文案=「%s」disabled=%s"
		% [str(_saw_panel_open), _again_caption_at_end, str(_again_disabled_at_end)])
	_say("  复位前：面板=%s scores条目=%d state=%d input_blocked=%s"
		% [str(_panel_open_before), _scores_size_before, _state_before,
		str(_input_blocked_before)])
	var panel_open: bool = bool(_panel.call("is_open")) if _panel != null else false
	_say("  复位后：面板=%s（核心：客户端必须为 false）" % str(panel_open))
	if _role != ROLE_HOST:
		_say("  客户端越权点击防线：调用后比分是否被改动=%s"
			% str(not _client_press_triggered or (_score_mgr != null
				and (_score_mgr.get("scores") as Dictionary).is_empty())))
	if _failures.is_empty():
		_say("RESULT PASS（面板已关闭 /陈旧态已清 / 比分已空 / 状态回 IDLE / 输入已恢复）")
	else:
		print("[RS]%s RESULT FAIL（%d 条）" % [_role, _failures.size()])
	get_tree().quit(1 if not _failures.is_empty() else 0)
