extends Control
class_name Scoreboard
## EP-4 · ES-4.1 比分板（常驻紧凑条 + 按住 Tab 完整榜）
##
## 需求出处：`design/gdd/04_ux_flow.md §3.1 / §3.1.1`、`production/epics/EP-4-hud-and-ux.md · ES-4.1`。
## 数据来源：`ScoreManager.score_changed(scores, time_remaining)`（附录 A.5）—— **UI 只绑信号，不绑 RPC**。
##
## ── 为什么要「纯逻辑 + 渲染分离」──
## 与 `ScoreManager` 同一取舍（见该文件「设计约束」§1）：本文件把所有
##   「分数表 → 该显示什么」的推导抽成**静态纯函数**（`build_rows` / `format_clock` /
##   `should_flash` / `kd_text`），headless 可直接断言、零副作用；
##   节点树只负责把纯函数的输出贴到 Label 上。
## → 于是「排序规则」「KD 分母为 0 怎么办」「还差几杀」这些易错点都能被单测钉死，
##   而不用开窗口截图肉眼看。
##
## ── 视觉规格（§3.1，不可改）──
##   · 位置：顶部中央（指南针下方），底衬 `#050F1A @ 0.45`
##   · 布局：`[先到 15 杀]  剩余 03:24` 一行 + 下方玩家条目一行
##   · 排序：击杀降序；领先者**加亮 + 加粗**（不只换色，§6 Standard）；本人加 `▶`
##   · 临界：14 杀 → 条目闪烁 + 「还差 1 杀」；剩余 ≤30 s → 计时器变亮 + 「终局冲刺」
##   · 字号 ≥ 16；数字用**明度对比**而非仅颜色
##
## ── ⚠ 不要在这里算胜负 ──
## 胜负判定只有一个权威口径：`ScoreManager._evaluate_winner()`（附录 A.6）。
## 本文件**只读** `scores`，绝不自行判定「谁赢了」——否则会出现两套口径打架。

const UI_GROUP := "game_ui"
## 目标击杀数 —— **兜底默认值，不是真值来源**（D2-04）。
##⚠ 这曾是「第二处硬编码耦合」（主理人初查遗漏、设计侧勘察发现）：配置成 3 杀时
##   比分板仍显示「先到 15 杀」→ **目标文案与实际判定不一致**，且不报任何错。
##   → 真值改读 `ScoreManager.effective_kill_target()`（见 `_refresh_objective`）。
##   本常量保留有两个用途：① `_effective_kill_target` 的兜底（拿不到ScoreManager 时）
##   ② `is_near_target()` 的**默认参数 15** —— 既有测试
##   `test_scoreboard.gd::test_is_near_target_boundary` 依赖该默认值，不得改。
const KILL_TARGET := 15
## 剩余时间 ≤ 该秒数 → 「终局冲刺」（§3.1 临界提示 ②）
const SPRINT_THRESHOLD := 30.0
## 击杀数 ≥ 目标-1 → 「还差 1 杀」闪烁（§3.1 临界提示 ①）
const NEARLY_THRESHOLD := 1
## 闪烁周期（秒）
const FLASH_INTERVAL := 0.5
## Tab 完整榜条目数上限（FFA 最多 4 人，留余量）
const MAX_ROWS := 8

## 底衬 / 常规 / 领先 / 本人 的颜色（明度差异是主要区分手段，§6）
const COL_BG := Color(0.02, 0.06, 0.1, 0.45)
const COL_NORMAL := Color(0.82, 0.9, 0.96, 0.92)
const COL_LEADER := Color(1.0, 1.0, 1.0, 1.0)
const COL_SELF := Color(0.62, 0.86, 1.0, 1.0)

@onready var _compact: Control = $Compact
@onready var _objective_label: Label = $Compact/Box/Row/Objective
@onready var _time_label: Label = $Compact/Box/Row/Time
@onready var _hint_label: Label = $Compact/Box/Hint
@onready var _rows_box: VBoxContainer = $Compact/Box/Rows
@onready var _full: Control = $Full
@onready var _full_box: VBoxContainer = $Full/FullTable

## 本端 peer id（决定「本人条目」加 ▶）
var _local_peer_id := 1
## peer_id → 昵称（联机时从 NetworkManager 取；离线用「玩家{id}」）
var _names: Dictionary = {}
## 最近一次 `score_changed` 的载荷，供 Tab 榜 / 复算复用
var _scores: Dictionary = {}
var _time_remaining := 0.0
var _flash_phase := 0.0
## Tab 完整榜是否按住显示（§3.1.1）
var _full_visible := false
## D2-04：本局生效的击杀目标（**从 ScoreManager 读真值**，不再用硬编码常量）。
##   拿不到 ScoreManager 时回落到 `KILL_TARGET`（离线路径 / 早期帧）。
var _kill_target := KILL_TARGET
## D2-04：绑定的 ScoreManager 弱引用，**只用于读**（`effective_kill_target()`）。
##   ⚠ UI 只绑信号、不碰 RPC（A.5 铁律）；这里存节点引用是为了响应
##     `ruleset_applied` 时能重读真值，**不缓存任何游戏状态**。
var _score_manager_ref: Node = null


func _ready() -> void:
	# 不进 game_ui 组：Tab 榜是**非模态**覆盖层（§3.1.1），要能边看边打
	_full.visible = false
	_full_box.visible = false
	_refresh_objective()


func _process(delta: float) -> void:
	if not visible:
		return
	_flash_phase = fmod(_flash_phase + delta, FLASH_INTERVAL * 2.0)
	_apply_critical_flashing()


func set_local_peer_id(id: int) -> void:
	_local_peer_id = id


## 绑 ScoreManager。由 hud.gd 调用（hud 是唯一持有 ScoreManager 引用的地方）。
func bind(score_manager: Node) -> void:
	if score_manager == null or not score_manager.has_signal("score_changed"):
		return
	_score_manager_ref = score_manager
	if not score_manager.score_changed.is_connected(_on_score_changed):
		score_manager.score_changed.connect(_on_score_changed)
	# D2-04：开局就把「实际生效的击杀目标」读回来（配置成 3 杀时文案要显示 3）。
	_pull_effective_kill_target(score_manager)
	# 规则集到手（含客户端收到 `sync_ruleset` 之后）→ 目标文案按实际值刷新，
	#   不必等下一次比分变更（≤1 s 心跳）才更新。
	if score_manager.has_signal("ruleset_applied") \
			and not score_manager.ruleset_applied.is_connected(_on_ruleset_applied):
		score_manager.ruleset_applied.connect(_on_ruleset_applied)
	# 首次绑定立即拉一次当前值（避免开局 1 s 内空白）
	_on_score_changed(score_manager.scores, score_manager.time_remaining)


## D2-04：规则集生效 → 立刻按新的生效目标刷新文案（**只读不改**，UI 不持有游戏状态）。
func _on_ruleset_applied(_ruleset_id: String) -> void:
	_pull_effective_kill_target(_score_manager_ref)
	_refresh_objective()


## D2-04：从 ScoreManager 拉取本局生效的击杀目标（规则配置化的真值）。
##   ⚠ **只读不改**（UI 不持有游戏状态，`control_checklist §0` 的铁律延伸）。
##   ⚠ 用 `has_method` 判兼容：`effective_kill_target()` 是 D2-04 新增的，
##     若换回旧版 ScoreManager 节点则静默回落常量，不崩。
func _pull_effective_kill_target(score_manager: Node) -> void:
	if score_manager == null or not score_manager.has_method("effective_kill_target"):
		return
	_kill_target = maxi(int(score_manager.call("effective_kill_target")), 1)


func _on_score_changed(scores: Dictionary, time_remaining: float) -> void:
	_scores = scores
	_time_remaining = time_remaining
	_refresh_objective()
	_rebuild_compact_rows()
	_rebuild_full_rows()


# ══════════════════════════════════════════════════════════════════════
#  纯逻辑（静态，headless 可直接断言）
# ══════════════════════════════════════════════════════════════════════

## 把 `scores` 字典转成**已排序**的行数据。
##   排序规则（§3.1）：击杀降序；击杀相同则**死亡升序**（死得少排前面，与
##   `ScoreManager._evaluate_winner()` 的平局判据一致，避免「榜与胜负口径打架」）；
##   再相同则按 peer_id 升序（保证各端顺序完全一致，跨端不抖动）。
## 返回：`[{peer_id:int, name:String, kills:int, deaths:int, is_self:bool, is_leader:bool}]`
static func build_rows(scores: Dictionary, local_peer_id: int, names: Dictionary = {}) -> Array:
	var rows: Array = []
	for key: Variant in scores:
		var entry: Dictionary = scores[key]
		var pid := int(key)
		rows.append({
			"peer_id": pid,
			"name": display_name_for(pid, names),
			"kills": int(entry.get("kills", 0)),
			"deaths": int(entry.get("deaths", 0)),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["kills"] != b["kills"]:
			return int(a["kills"]) > int(b["kills"])
		if a["deaths"] != b["deaths"]:
			return int(a["deaths"]) < int(b["deaths"])
		return int(a["peer_id"]) < int(b["peer_id"]))
	# 领先者 = 击杀数**并列最高**的所有行（不是只标排序后第 0 行）。
	#   ⚠ 早期实现只取 rows[0] 的 peer_id 去比对，导致 6:6 并列时第二行不高亮
	#   ——视觉上就是「两个人并列领先，只有一个被加亮」，自相矛盾。
	#   注意口径：只看**击杀数**，不看死亡数。与 `_evaluate_winner()` 的区别是
	#   后者还要用死亡数**决出唯一胜者**（UI 高亮可以并列，胜负判定不能并列）。
	var top_kills := -1
	for r: Dictionary in rows:
		top_kills = maxi(top_kills, int(r["kills"]))
	for r: Dictionary in rows:
		r["is_self"] = int(r["peer_id"]) == local_peer_id
		# 开局 0:0 时**无人领先**——否则整张榜全高亮，等于没有高亮
		r["is_leader"] = top_kills > 0 and int(r["kills"]) == top_kills
	return rows


## 昵称：优先用房间昵称表，缺失时退回「玩家{id}」（与 NetworkManager.get_player_name 同口径）。
static func display_name_for(peer_id: int, names: Dictionary) -> String:
	if names.has(peer_id):
		var n := str(names[peer_id]).strip_edges()
		if n != "":
			return n
	return "玩家%d" % peer_id


## 秒 → `MM:SS`（不足 1 分钟只显示秒；`§3.1` 示例「剩余 03:24」）。
static func format_clock(seconds: float) -> String:
	var total := maxi(int(ceil(maxf(seconds, 0.0))), 0)
	return "%02d:%02d" % [total / 60, total % 60]


## KD 显示：分母为 0 时显示 `"—"`（**不要显示 inf / nan**，那是刺眼的字形）。
static func kd_text(kills: int, deaths: int) -> String:
	if deaths <= 0:
		return "—" if kills <= 0 else "%.1f" % float(kills)
	return "%.1f" % (float(kills) / float(deaths))


## 某人是否处于「还差 N 杀」临界（含已达目标的情况返回 false —— 那已经赢了）。
## ⚠ 默认参数 `KILL_TARGET`（15）是**兜底、不是真值**：D2-04 之后本局目标由
##   规则配置决定，调用方应显式传入实际生效值（见 `_apply_critical_flashing`）。
##   默认参数保留是为向后兼容既有测试（`test_is_near_target_boundary` 依赖它）。
static func is_near_target(kills: int, target: int = KILL_TARGET) -> bool:
	return kills < target and target - kills <= NEARLY_THRESHOLD


## 条目文案：`▶ 名字  K`（本人带 ▶，领先者加「★」——形状 + 颜色双通道，不只靠色）。
##
## ⚠ 格式串必须**逐个对齐占位符与参数**：`▶ ` / `★ ` / 名字 / 击杀数 共 4 段，
##   所以是 `"%s%s%s  %d"`。曾经写成 `"%s%s  %d"`（漏了名字那个 `%s`），
##   4 个参数喂 3 个占位符 → GDScript 报 "too many arguments" 并返回空串，
##   表现为「▶/★ 标记全都不显示」。这类错误编译期不报、运行期静默变空串。
static func compact_row_text(row: Dictionary) -> String:
	return "%s%s%s  %d" % [
		"▶ " if bool(row.get("is_self", false)) else "",
		"★ " if bool(row.get("is_leader", false)) else "",
		String(row.get("name", "?")),
		int(row.get("kills", 0)),
	]


## 完整榜行文案：`排名 名字 击杀 死亡 KD`（列宽固定，避免数字跳动导致抖动）。
static func full_row_text(rank: int, row: Dictionary) -> String:
	return "%d　%s　%d　%d　%s" % [
		rank,
		String(row.get("name", "?")),
		int(row.get("kills", 0)),
		int(row.get("deaths", 0)),
		kd_text(int(row.get("kills", 0)), int(row.get("deaths", 0))),
	]


# ══════════════════════════════════════════════════════════════════════
#  渲染（把纯函数输出贴到节点上）
# ══════════════════════════════════════════════════════════════════════

func _refresh_objective() -> void:
	# D2-04：读**实际生效**的击杀目标（配置化后可能是 3，不是硬编码 15）。
	_objective_label.text = "先到 %d 杀" % _kill_target
	_time_label.text = "剩余 %s" % format_clock(_time_remaining)
	var sprinting := _time_remaining > 0.0 and _time_remaining <= SPRINT_THRESHOLD
	# 明度差异为主（§6），不只换色
	_time_label.add_theme_color_override("font_color",
		Color(1.0, 0.86, 0.45) if sprinting else COL_NORMAL)
	_hint_label.text = "终局冲刺" if sprinting else ""
	_hint_label.visible = sprinting


func _rebuild_compact_rows() -> void:
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.queue_free()
	var rows := build_rows(_scores, _local_peer_id, _names)
	for i in rows.size():
		if i >= MAX_ROWS:
			break
		var row: Dictionary = rows[i]
		_rows_box.add_child(_make_label(compact_row_text(row), 18,
			_row_color(row), bool(row.get("is_leader", false))))


func _rebuild_full_rows() -> void:
	for child in _full_box.get_children():
		_full_box.remove_child(child)
		child.queue_free()
	_full_box.add_child(_make_label("排名　名字　击杀　死亡　KD", 18, COL_LEADER, true))
	_full_box.add_child(_make_label("────────────────────", 16, Color(0.5, 0.65, 0.8, 0.6), false))
	var rows := build_rows(_scores, _local_peer_id, _names)
	for i in rows.size():
		var row: Dictionary = rows[i]
		_full_box.add_child(_make_label(full_row_text(i + 1, row), 18, _row_color(row),
			bool(row.get("is_leader", false))))


func _make_label(text: String, size: int, color: Color, bold: bool) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", maxi(size, 16)) # §3.1 字号 ≥ 16
	label.add_theme_color_override("font_color", color)
	# 「加亮 = 亮度 + 加粗」双通道（§6 Standard：不只换色）
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


## 「还差 1 杀」闪烁：仅对临界条目做明暗呼吸（§3.1 临界提示 ①）。
## 只算一次 `build_rows`（复用），不为每个 Label 重算。
func _apply_critical_flashing() -> void:
	var rows := build_rows(_scores, _local_peer_id, _names)
	var on := _flash_phase < FLASH_INTERVAL
	for i in _rows_box.get_child_count():
		var label := _rows_box.get_child(i) as Label
		if label == null:
			continue
		var near := i < rows.size() and is_near_target(int(rows[i].get("kills", 0)), _kill_target)
		label.modulate = (Color(1, 1, 1, 1) if on else Color(0.62, 0.68, 0.74, 1)) if near \
			else Color(1, 1, 1, 1)


# ══════════════════════════════════════════════════════════════════════
#  Tab 完整榜（§3.1.1 · 非模态覆盖层）
# ══════════════════════════════════════════════════════════════════════

## 按下 Tab：显示。死亡界面 / 结算面板打开时**不响应**（§3.1.1 互斥）。
func show_full() -> void:
	if _blocked_by_other_ui():
		return
	_full.visible = true
	_full_box.visible = true
	_rebuild_full_rows()


## 松开 Tab：隐藏。
func hide_full() -> void:
	_full.visible = false
	_full_box.visible = false


func is_full_visible() -> bool:
	return _full.visible


func _blocked_by_other_ui() -> bool:
	for ui in get_tree().get_nodes_in_group(UI_GROUP):
		if ui == self:
			continue
		if ui.has_method("is_open") and ui.is_open():
			return true
	return false


## 每帧同步昵称表（联机昵称可能后到）。
func refresh_names() -> void:
	if not NetworkManager.is_online:
		return
	_names = NetworkManager.get_players()