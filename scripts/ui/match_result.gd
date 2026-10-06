extends CanvasLayer
class_name MatchResult
## EP-4 · ES-4.2 结算面板 MatchResult（终态）
##
## 需求出处：`design/gdd/04_ux_flow.md §3.2`、`production/epics/EP-4-hud-and-ux.md · ES-4.2`。
## 数据来源：`ScoreManager.match_ended(winner_id, final_scores)`（附录 A.5）—— **UI 只绑信号，不绑 RPC**。
##
## ── 结构（§3.2 逐项落地）──
##   全屏面板：`对局结束` → `🏆 {名字} 获胜` → 完整比分表（排名/名字/击杀/死亡/KD）
##            → `本局时长 MM:SS` → `[再来一局]`（仅房主）｜`[返回大厅]`
##
## ── 为什么要「纯逻辑 + 渲染分离」（沿用 ES-4.1 的取舍）──
## 与 `Scoreboard` / `ScoreManager` 同一取舍：本文件把所有
##   「数据 → 该显示什么 / 该显示什么按钮」的推导抽成**静态纯函数**
##   （`title_for` / `winner_text` / `format_duration` / `build_standings` /
##    `row_text` / `button_caption` / `can_request_reset` / `elapsed_seconds`），
##   headless 可直接断言、零副作用；节点树只负责把输出贴到 Label。
## → 于是「平局怎么显示」「客户端按钮文案」「时长要不要显示小时」这些易错点能被单测钉死，
##   而不用开窗口截图肉眼看。
##
## ── ⚠ 排序/文案口径一律复用 `Scoreboard`，不另写一套 ──
## 完整比分表的**排序**（击杀降序 → 死亡升序 → peer_id 升序）与 **KD 文案**
## 直接转调 `Scoreboard.build_rows()` / `Scoreboard.full_row_text()` /
## `Scoreboard.kd_text()` / `Scoreboard.display_name_for()`。
## 理由：本项目已登记过「两套排序口径打架」的风险（见 `scoreboard.gd` 注释
## 与 `tests/suites/test_scoreboard.gd`）。结算面板与比分板若各排一次，
## 会出现「比分板显示 A 第一、结算面板显示 B 第一」的自相矛盾。
##
## ── ⚠⚠ 严禁在这里重算胜负（架构铁律）──
## 胜负判定只有一个权威口径：`ScoreManager._evaluate_winner()`（附录 A.6）。
## 本文件**只消费** `match_ended(winner_id, ...)` 传来的 `winner_id`，
## 绝不读 `kills`/`deaths` 自己去比大小。因此本文件里
## **不存在** `kills >` / `deaths <` / `func _evaluate_winner` 之类的比较逻辑
## （由 `tests/suites/test_match_result.gd::test_does_not_reimplement_winner_evaluation` 钉死）。
##
## ── 「不暂停」vs「屏蔽输入」是两件事（§3.2 暂停行 + control_checklist §4-1）──
## · **不暂停**：`get_tree().paused` 全程**不动**（§1 现状约束：界面是覆盖层不是暂停态；
##   且 `ScoreManager` 靠 `_process` 驱动倒计时/计时，暂停树会让它停摆）。
## · **要屏蔽输入**：面板是全屏终态覆盖层，两个理由→
##     (1) 鼠标必须**可见**才能点 `[再来一局]` / `[返回大厅]`，而释放鼠标的唯一入口
##         就是 `player.set_input_blocked(true)`（内部连带 `release_mouse`）；
##     (2) 对局已 ENDED、比分已冻结，玩家继续跑动/开火没有意义，且武器触发器
##         应随之关闭（§4-1 的「双闸门」：不要只调 `release_mouse` 一半）。
##   故本面板**属于**「需屏蔽输入」类别，`open_ui()` 调 `set_input_blocked(true)`、
##   `close_ui()` 调 `set_input_blocked(false)` + `capture_mouse()`
##   ——与 `game_menu.gd` / `bot_panel.gd` 的既有写法完全一致。
##   ⚠ 这与「不暂停」不冲突：`paused` 是**场景树**开关，`input_blocked` 是**玩家输入**开关。

const UI_GROUP := "game_ui"
## §3.2 固定标题（**不随胜者变化**——胜者信息在下一行，文案分层不要混）
const TITLE := "对局结束"
## 面板层级（高于 death_screen 的 3，保证终态盖在死亡界面之上）
const PANEL_LAYER := 4
## 底衬（沿用 §3.1 规格：`#050F1A @ 0.45`）
const COL_BG := Color(0.02, 0.06, 0.1, 0.45)
const COL_NORMAL := Color(0.82, 0.9, 0.96, 0.92)
const COL_LEADER := Color(1.0, 1.0, 1.0, 1.0)
const COL_SELF := Color(0.62, 0.86, 1.0, 1.0)

@onready var _title_label: Label = $Panel/VBox/Title
@onready var _winner_label: Label = $Panel/VBox/Winner
@onready var _table_box: VBoxContainer = $Panel/VBox/Table
@onready var _duration_label: Label = $Panel/VBox/Duration
@onready var _again_button: Button = $Panel/VBox/Buttons/AgainButton
@onready var _lobby_button: Button = $Panel/VBox/Buttons/LobbyButton

## 本端 peer id（决定胜者行是否显示「你」）
var _local_peer_id := 1
## peer_id → 昵称（联机时从 NetworkManager 取，离线用「玩家{id}」）
var _names: Dictionary = {}
## 最近一次 `match_ended` 的载荷（重开面板时复用，不重新问ScoreManager）
var _winner_id: int = -1
var _final_scores: Dictionary = {}
var _duration_seconds := 0.0
## 是否已经收到过结算（false 时 open_ui 不展示，避免空面板）
var _has_result := false
## ScoreManager 引用（只为读 match_duration / local_peer_id，不调任何 RPC）
var _score_manager: Node = null


func _ready() -> void:
	layer = PANEL_LAYER
	add_to_group(UI_GROUP) # §3.2 互斥：加入 game_ui 组，打开时关掉其它界面
	visible = false
	_again_button.pressed.connect(_on_again_pressed)
	_lobby_button.pressed.connect(_on_lobby_pressed)


# ══════════════════════════════════════════════════════════════════════
#  纯逻辑（静态，headless 可直接断言）
# ══════════════════════════════════════════════════════════════════════

## 面板标题。**恒为**「对局结束」，与胜者无关。
##
## 签名带 `winner_id` / `local_peer_id` 但**故意不使用**，是为了把
## 「标题不得泄露胜者信息」这条契约显式钉住：房主视角、客户端视角、平局
## 三种情况下标题都必须完全一致（胜者信息由 `winner_text` 单独一行承载）。
static func title_for(_winner_id: int = -1, _local_peer_id: int = -1) -> String:
	return TITLE


## 胜者行文案（§3.2「🏆 {名字} 获胜」）。
##
## 三种来源：
## · `winner_id == WINNER_TIE(-2)` → 「🏆 平局」   —— 注意**不能**显示任何玩家名；
## · `winner_id == WINNER_UNSET(-1)` → 「🏆 无胜者」（空表时`_evaluate_winner` 的返回值）；
## · 否则 → 「🏆 {名字} 获胜」，其中 `winner_id == local_peer_id` 时显示「你」。
##
## ⚠ 这里只做「**显示谁**」的映射，不做「**谁赢**」的判定 —— 判定在
##   `ScoreManager._evaluate_winner()`，本函数对它传来的 `winner_id` 无异议。
static func winner_text(winner_id: int, local_peer_id: int, names: Dictionary = {}) -> String:
	if winner_id == ScoreManager.WINNER_TIE:
		return "🏆 平局"
	if winner_id == ScoreManager.WINNER_UNSET:
		return "🏆 无胜者"
	if winner_id == local_peer_id:
		return "🏆 你 获胜"
	return "🏆 %s 获胜" % Scoreboard.display_name_for(winner_id, names)


## 本局已打时长（秒）：`match_duration - time_remaining`，夹到 ≥ 0。
##
## 为什么要减而不是直接用 `match_duration`：赢在 15 杀时对局**提前结束**，
## `time_remaining` 还剩一截，直接显示上限会谎报「本局打了 5 分 00 秒」。
static func elapsed_seconds(match_duration: float, time_remaining: float) -> float:
	return maxf(match_duration - time_remaining, 0.0)


## 本局时长文案。
##
## ## 为什么不显示小时（决策依据）
## · `04_ux_flow §3.2` 只写「本局时长」，**没有**要求 `HH:MM:SS`；
## · `ScoreManager.match_duration` 默认 300 s（`01_core_loop §4`「15 杀 / 5 分钟」），
##   单局上限 5 分钟 → 「小时」这一位在**当前玩法下永远不可能出现**，
##   加上去是永不触发的死代码；
## · ES-4.1 的剩余计时已经是 `MM:SS`（`Scoreboard.format_clock`，§3.1 示例「剩余 03:24」）。
##   同一屏里两个时间用**同一种格式**，玩家不需要做单位换算。
## → 故直接**复用** `Scoreboard.format_clock`，不另写一套格式化（§4-12 占位符风险也一并规避）。
## 边界：3600 s → `"60:00"`（分钟位进位到 60）。这是「不显示小时」的直接推论，
##   当前 300 s 上限下不可达；一旦玩法改成超长局，本函数需要重新评估（已在此备注）。
static func format_duration(seconds: float) -> String:
	return Scoreboard.format_clock(seconds)


## 完整比分表行数据 —— **直接转调 `Scoreboard.build_rows`**。
##
## 刻意不在本文件重写排序：口径（击杀降序 → 死亡升序 → peer_id 升序）必须与
## 比分板、与 `ScoreManager._evaluate_winner()` 的平局判据三者一致，
## 否则会出现「榜一和结算第一名不是同一个人」。见文件头「⚠ 排序/文案口径一律复用」。
static func build_standings(final_scores: Dictionary, local_peer_id: int,
		names: Dictionary = {}) -> Array:
	return Scoreboard.build_rows(final_scores, local_peer_id, names)


## 比分表行文案（排名/名字/击杀/死亡/KD）—— **直接转调 `Scoreboard.full_row_text`**。
static func row_text(rank: int, row: Dictionary) -> String:
	return Scoreboard.full_row_text(rank, row)


## `[再来一局]` 按钮文案。
##
## 客户端显示「等待房主…」而非可点击的「再来一局」：客户端**没有**重置权限
## （`ScoreManager.request_reset()` 开头就是 `if not is_authority(): return`，
##  A.1：权威 = 房主 `peer_id==1` 或离线本端）。若客户端也显示「再来一局」，
##  玩家点了**什么都不会发生** —— 这是最坏的 UX（按钮看起来能用但无效）。
static func button_caption(is_authority: bool) -> String:
	return "再来一局" if is_authority else "等待房主…"


## `[再来一局]` 是否可点。与 `button_caption` 同源，避免两处口径打架：
##  凡是文案显示「等待房主…」的，按钮一定是 disabled。
static func can_request_reset(is_authority: bool) -> bool:
	return is_authority


# ══════════════════════════════════════════════════════════════════════
#  绑定（UI 只绑信号，不碰 RPC —— 架构铁律）
# ══════════════════════════════════════════════════════════════════════

## 绑 ScoreManager。由 hud.gd 调用（hud 是唯一持有 ScoreManager 引用的地方）。
##   与 `Scoreboard.bind()` 同构：连 `match_ended` 信号，不碰 `net_match_ended`。
func bind(score_manager: Node) -> void:
	if score_manager == null or not score_manager.has_signal("match_ended"):
		return
	_score_manager = score_manager
	if not score_manager.match_ended.is_connected(_on_match_ended):
		score_manager.match_ended.connect(_on_match_ended)
	if score_manager.has_method("local_peer_id"):
		_local_peer_id = score_manager.local_peer_id()
	_refresh_names()


func _on_match_ended(winner_id: int, final_scores: Dictionary) -> void:
	_winner_id = winner_id
	_final_scores = final_scores
	_has_result = true
	# 本局时长：从 ScoreManager 读「上限 - 剩余」两个**状态量**（不重算、不推导胜负）
	if _score_manager != null:
		_duration_seconds = elapsed_seconds(
			float(_score_manager.get("match_duration")),
			float(_score_manager.get("time_remaining")))
	_refresh_names()
	open_ui()


## 每帧同步昵称表（联机昵称可能后到）。由 hud.gd 在已绑定后调用（同 Scoreboard）。
func refresh_names() -> void:
	_refresh_names()


func _refresh_names() -> void:
	if NetworkManager.is_online:
		_names = NetworkManager.get_players()


# ══════════════════════════════════════════════════════════════════════
#  界面开关（game_ui 组互斥契约，§3.2）
# ══════════════════════════════════════════════════════════════════════

func is_open() -> bool:
	return visible


## 打开面板：关掉其它 `game_ui` 成员 → 渲染 → 屏蔽玩家输入（释放鼠标以便点按钮）。
##
##⚠ **不**碰 `get_tree().paused`：§3.2「暂停：不暂停（对齐现状）」。
##   面板是覆盖层而非暂停态，`ScoreManager` 仍靠 `_process` 驱动。
func open_ui() -> void:
	if not _has_result:
		return # 还没收到 match_ended：不开空面板
	_close_other_uis()
	visible = true
	_render()
	_set_input_blocked(true) # §4-1 双闸门：内部连带 release_mouse + 武器 set_trigger_enabled(false)


func close_ui() -> void:
	if not visible:
		return
	visible = false
	_set_input_blocked(false)
	_capture_mouse()


## 打开结算面板时自动关闭其它界面（Esc 菜单 / 死亡界面 / 人机面板）。
## 与 `game_menu.gd::_close_other_uis()` / `bot_panel.gd` 逐字同构。
func _close_other_uis() -> void:
	for ui in get_tree().get_nodes_in_group(UI_GROUP):
		if ui != self and ui.has_method("close_ui") and ui.has_method("is_open") and ui.is_open():
			ui.close_ui()


# ══════════════════════════════════════════════════════════════════════
#  渲染（把纯函数输出贴到节点上）
# ══════════════════════════════════════════════════════════════════════

func _render() -> void:
	_title_label.text = title_for(_winner_id, _local_peer_id)
	_winner_label.text = winner_text(_winner_id, _local_peer_id, _names)
	_duration_label.text = "本局时长 %s" % format_duration(_duration_seconds)

	var is_authority := _is_authority()
	_again_button.text = button_caption(is_authority)
	_again_button.disabled = not can_request_reset(is_authority) # 客户端「等待房主…」且不可点

	for child in _table_box.get_children():
		_table_box.remove_child(child)
		child.queue_free()

	_table_box.add_child(_make_label("排名　名字　击杀　死亡　KD", 18, COL_LEADER, true))
	_table_box.add_child(_make_label("────────────────────", 16, Color(0.5, 0.65, 0.8, 0.6), false))
	var rows := build_standings(_final_scores, _local_peer_id, _names)
	for i in rows.size():
		var row: Dictionary = rows[i]
		_table_box.add_child(_make_label(row_text(i + 1, row), 18, _row_color(row),
			bool(row.get("is_leader", false))))


func _make_label(text: String, size: int, color: Color, bold: bool) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", maxi(size, 16)) # §3.1 字号 ≥ 16
	label.add_theme_color_override("font_color", color)
	# 「加亮 = 明度 + 加粗」双通道（§6 Standard：不只换色）
	if bold:
		label.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.45))
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 3)
	return label


func _row_color(row: Dictionary) -> Color:
	if bool(row.get("is_leader", false)):
		return COL_LEADER
	if bool(row.get("is_self", false)):
		return COL_SELF
	return COL_NORMAL


# ══════════════════════════════════════════════════════════════════════
#  按钮
# ══════════════════════════════════════════════════════════════════════

## 本端是否有重置权限。收口在 `ScoreManager.is_authority()`（A.1），不重复判定条件。
func _is_authority() -> bool:
	if _score_manager != null and _score_manager.has_method("is_authority"):
		return bool(_score_manager.call("is_authority"))
	# 未绑定时按「离线本端即权威」兜底（与ScoreManager._force_offline_for_test 之外的默认一致）
	return not NetworkManager.is_online


## `[再来一局]` → 权威端复位对局。
##   只调 `ScoreManager.request_reset()`（A.8 既有契约，**不自造RPC**）；
##   客户端按钮是 disabled，走到这里也依然会被 `request_reset` 的权威校验挡掉（双保险）。
func _on_again_pressed() -> void:
	if _score_manager != null and _score_manager.has_method("request_reset"):
		_score_manager.call("request_reset")
	close_ui()


## `[返回大厅]`：联机先退出对局（`leave_game` 内部会切hub 场景），离线直接切场景。
##   与 `hud.gd::_on_leave_pressed()` 同口径。
func _on_lobby_pressed() -> void:
	if NetworkManager.is_online:
		NetworkManager.leave_game()
	else:
		get_tree().change_scene_to_file(NetworkManager.HUB_SCENE)


# ══════════════════════════════════════════════════════════════════════
#  内部
# ══════════════════════════════════════════════════════════════════════

func _get_player() -> Node:
	return get_tree().get_first_node_in_group("player")


## §4-1：调`set_input_blocked` 即可，它内部连带 `release_mouse` → 武器 `set_trigger_enabled(false)`。
##   **不要只调一半**。player 不存在时静默跳过（与 ScoreManager._set_players_input_blocked 同策略）。
func _set_input_blocked(blocked: bool) -> void:
	var player := _get_player()
	if player != null and player.has_method("set_input_blocked"):
		player.set_input_blocked(blocked)


func _capture_mouse() -> void:
	var player := _get_player()
	if player != null and player.has_method("capture_mouse"):
		player.capture_mouse()
