extends TestSuite
## EP-4 · ES-4.1 比分板回归基线（`04_ux_flow §3.1 / §3.1.1`）
##
## 与 `test_kill_attribution.gd` 同一取舍：**把易错逻辑抽成静态纯函数再断言**，
## headless 就能钉死排序 / KD / 倒计时 / 临界判定，不用开窗口截图肉眼看。
##
## 重点防守的四个易错点：
##   ① 排序口径必须与 `ScoreManager._evaluate_winner()` 的平局判据一致
##      （击杀降序 → 死亡升序），否则「榜」与「胜负」会打架；
##   ② KD 在 deaths=0 时**不能**显示 inf/nan（刺眼字形），要有真值兜底；
##   ③ 「还差 1 杀」在**已达目标**时必须为 false（那已经赢了，不该再闪）；
##   ④ 各端对同一 `scores` 必须排出**完全相同**的顺序（跨端不抖动）。

const SCOREBOARD_SRC := "res://scripts/ui/scoreboard.gd"
const HUD_SRC := "res://scripts/ui/hud.gd"
const PROJECT_GODOT := "res://project.godot"
const SCOREBOARD_SCENE := "res://scenes/ui/scoreboard.tscn"

var _sb: GDScript


func _ready() -> void:
	_sb = load(SCOREBOARD_SRC) as GDScript


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


# ---------------------------------------------------------------------------
# ① 排序口径
# ---------------------------------------------------------------------------

## 击杀降序。
func test_rows_sorted_by_kills_desc() -> void:
	var rows: Array = _sb.build_rows({
		1: {"kills": 3, "deaths": 5},
		7: {"kills": 9, "deaths": 2},
	}, 1)
	check_eq(rows.size(), 2, "应产出2 行")
	check_eq(int(rows[0]["peer_id"]), 7, "击杀 9 者应排第一")
	check_eq(int(rows[1]["peer_id"]), 1, "击杀 3 者应排第二")


## 击杀相同 → 死亡**升序**（死得少的排前面），与 ScoreManager 平局判据同口径。
func test_ties_broken_by_deaths_asc() -> void:
	var rows: Array = _sb.build_rows({
		1: {"kills": 5, "deaths": 8},
		2: {"kills": 5, "deaths": 2},
	}, 1)
	check_eq(int(rows[0]["peer_id"]), 2, "击杀相同应按死亡升序（死亡 2 者在前）")


## 完全相同 → 按 peer_id 升序，保证**各端顺序一致**（否则榜会在两端抖动）。
func test_full_tie_broken_by_peer_id_for_cross_end_stability() -> void:
	var scores := {9: {"kills": 4, "deaths": 4}, 3: {"kills": 4, "deaths": 4}}
	var a: Array = _sb.build_rows(scores, 1)
	var b: Array = _sb.build_rows(scores, 2)
	check_eq(int(a[0]["peer_id"]), 3, "全并列应按 peer_id 升序（3 在前）")
	check_eq(int(a[0]["peer_id"]), int(b[0]["peer_id"]),
		"同一 scores 在不同本端视角下必须排出相同顺序（跨端不抖动）")


## 本人 / 领先者标记。
func test_self_and_leader_flags() -> void:
	var rows: Array = _sb.build_rows({
		1: {"kills": 4, "deaths": 1},
		2: {"kills": 7, "deaths": 3},
	}, 1)
	check_true(bool(rows[0]["is_leader"]), "击杀最高者应标 is_leader")
	check_false(bool(rows[0]["is_self"]), "peer 2 不是本端视角的本人")
	check_true(bool(rows[1]["is_self"]), "本端 peer 1 应标 is_self")

## 并列第一时**两行都**标领先（不是只标第一行）。
func test_tied_leaders_both_flagged() -> void:
	var rows: Array = _sb.build_rows({
		1: {"kills": 6, "deaths": 0},
		2: {"kills": 6, "deaths": 2},
	}, 3)
	check_true(bool(rows[0]["is_leader"]), "并列第一的行 0 应标领先")
	check_true(bool(rows[1]["is_leader"]), "并列第一的行 1 也应标领先")


## 开局 0:0 → **无人领先**。全高亮等于没高亮，必须一个都不标。
func test_zero_zero_has_no_leader() -> void:
	var rows: Array = _sb.build_rows({
		1: {"kills": 0, "deaths": 0},
		2: {"kills": 0, "deaths": 0},
	}, 1)
	check_false(bool(rows[0]["is_leader"]), "0 杀时不应有人被标领先")
	check_false(bool(rows[1]["is_leader"]), "0 杀时不应有人被标领先")


# ---------------------------------------------------------------------------
# ② KD 显示
# ---------------------------------------------------------------------------

func test_kd_text_normal() -> void:
	check_eq(_sb.kd_text(8, 4), "2.0", "8/4 的 KD 应为 2.0")


## deaths=0 且 kills=0 → 显示占位符，**不能**是 "nan"/"inf"。
func test_kd_text_zero_zero_is_placeholder() -> void:
	var s: String = _sb.kd_text(0, 0)
	check_eq(s, "—", "0杀0死应显示占位符「—」")
	check_true(not s.contains("inf") and not s.contains("nan"), "KD 不得出现 inf/nan 字形")


## deaths=0 且 kills>0 → 直接显示击杀数（常见于碾压局），仍是有限值。
func test_kd_text_zero_deaths_uses_kills() -> void:
	check_eq(_sb.kd_text(15, 0), "15.0", "0 死时应以击杀数作为 KD")


# ---------------------------------------------------------------------------
# ③ 倒计时格式与临界提示
# ---------------------------------------------------------------------------

func test_format_clock() -> void:
	check_eq(_sb.format_clock(204.0), "03:24", "204 秒应格式化为 03:24（§3.1 示例）")
	check_eq(_sb.format_clock(300.0), "05:00", "300 秒应为 05:00")
	check_eq(_sb.format_clock(59.0), "00:59", "不足 1 分钟应只显示秒")
	check_eq(_sb.format_clock(-5.0), "00:00", "负数应夹到 00:00，不得显示负分")


## 14 杀 → 临界闪烁；15 杀 → 已达成，**不再**闪。
func test_is_near_target_boundary() -> void:
	check_true(_sb.is_near_target(14), "14 杀应处于「还差 1 杀」临界")
	check_false(_sb.is_near_target(15), "15 杀已达目标，不该再判临界")
	check_false(_sb.is_near_target(3), "3 杀不临界")
	check_false(_sb.is_near_target(0), "0 杀不临界")


## 条目文案：本人带 ▶、领先者带 ★（形状 + 颜色双通道，不只靠色，§6）。
func test_compact_row_text_markers() -> void:
	var self_leader := {"name": "房主", "kills": 9, "is_self": true, "is_leader": true}
	check_true(_sb.compact_row_text(self_leader).begins_with("▶ "), "本人条目应有 ▶ 前缀")
	check_true(_sb.compact_row_text(self_leader).contains("★"), "领先者应有 ★ 标记")
	var plain := {"name": "客机", "kills": 2, "is_self": false, "is_leader": false}
	check_false(_sb.compact_row_text(plain).begins_with("▶ "), "他人条目不应有 ▶")


## ⚠ 防「占位符与参数个数不匹配」回归。
## 曾经把格式串写成 `"%s%s  %d"`（3 占位符）却传 4 个参数，GDScript 运行期报
## "too many arguments" 并返回**空串**——编译期不报错，UI 上表现为「整条条目空白」。
## 这里钉死：名字与击杀数必须真的出现在输出里。
func test_compact_row_text_contains_name_and_kills() -> void:
	var s: String = _sb.compact_row_text(
		{"name": "房主", "kills": 9, "is_self": true, "is_leader": true})
	check_true(s.contains("房主"), "条目文案应含名字（防空串回归）")
	check_true(s.contains("9"), "条目文案应含击杀数（防空串回归）")
	check_false(s.is_empty(), "条目文案不得为空串")


## 完整榜行含 5 列（排名/名字/击杀/死亡/KD）。
## ⚠ KD 列的期望值要按 `kd_text` 的真实契约来写，不能想当然：
##   `kd_text(15, 0) == "15.0"`（0 死时以击杀数作 KD，**不是** "—"），
##   `kd_text(0, 0) == "—"`。这里两种各钉一次，防止有人把 0 死误当占位符。
func test_full_row_text_has_five_columns() -> void:
	var s: String = _sb.full_row_text(1, {"name": "房主", "kills": 15, "deaths": 0})
	check_true(s.contains("15"), "应含击杀数")
	check_true(s.contains("15.0"), "0 死时 KD 列显示击杀数（kd_text 契约）")
	check_true(s.begins_with("1"), "应以排名开头")
	var z: String = _sb.full_row_text(2, {"name": "客机", "kills": 0, "deaths": 0})
	check_true(z.contains("—"), "0 杀 0 死时 KD 列才显示占位符")


## 昵称缺失时退回「玩家{id}」，空串也要退回（不能显示空白条目）。
func test_display_name_fallback() -> void:
	check_eq(_sb.display_name_for(7, {}), "玩家7", "无昵称表应退回「玩家7」")
	check_eq(_sb.display_name_for(7, {7: ""}), "玩家7", "空昵称应退回占位，不能留白")
	check_eq(_sb.display_name_for(7, {7: "  阿强  "}), "阿强", "昵称应去首尾空格")


# ---------------------------------------------------------------------------
# ④ 接线（契约锁）：HUD 必须真的绑上score_changed
# ---------------------------------------------------------------------------

## ES-4.1 验收要求「断言 hud.gd 连接了 score_changed」。
func test_hud_connects_score_changed() -> void:
	var src := _read_source(HUD_SRC)
	check_true(src.find("score_changed") >= 0 || src.find("_scoreboard.bind") >= 0,
		"hud.gd 应把 ScoreManager 接到比分板（bind / score_changed）")
	check_true(src.find("ScoreManager") >= 0, "hud.gd 应按节点名取 ScoreManager")


## 「按住 Tab 展开完整榜」需要新增输入动作 scoreboard（§3.1.1）。
func test_scoreboard_input_action_registered() -> void:
	var src := _read_source(PROJECT_GODOT)
	check_true(src.find("scoreboard={") >= 0, "project.godot 应注册 scoreboard 输入动作（默认 Tab）")
	check_true(src.find("4194306") >= 0, "scoreboard 应绑定 Tab 物理键码 4194306（KEY_TAB）")


## 比分板场景必须可加载（节点名与 @onready 路径对得上，否则运行期空引用）。
func test_scoreboard_scene_loadable() -> void:
	var packed: PackedScene = load(SCOREBOARD_SCENE) as PackedScene
	if packed == null:
		fail("无法加载 %s" % SCOREBOARD_SCENE)
		return
	var node: Node = packed.instantiate()
	if node == null:
		fail("scoreboard.tscn 实例化失败")
		return
	add_child(node)
	# @onready 路径：Compact/Box/Row/{Objective,Time}、Compact/Box/{Hint,Rows}、Full/FullTable
	#   ⚠ 路径要和 scoreboard.gd 的 @onready 逐字对齐。Compact 是 PanelContainer
	#   （只能挂一个子节点），所以中间**必然**有一层 Box VBoxContainer。
	for path in ["Compact", "Compact/Box/Row/Objective", "Compact/Box/Row/Time",
			"Compact/Box/Hint", "Compact/Box/Rows", "Full", "Full/FullTable"]:
		check_true(node.get_node_or_null(path) != null, "scoreboard 应存在节点 %s" % path)
	node.queue_free()


## ⚠️ 纪律锁：本文件**不得**自行判定胜负（否则与 ScoreManager._evaluate_winner 两套口径打架）。
func test_does_not_reimplement_winner_evaluation() -> void:
	var src := _read_source(SCOREBOARD_SRC)
	check_true(src.find("func _evaluate_winner") < 0,
		"比分板不得自行实现胜负判定（唯一口径是 ScoreManager._evaluate_winner）")
	check_true(src.find("match_ended") < 0,
		"比分板只读比分，不该消费 match_ended（那是结算面板 ES-4.2 的职责）")


## 数字字号 ≥ 16（§3.1 可访问性硬指标）。
func test_font_size_floor_is_16() -> void:
	var src := _read_source(SCOREBOARD_SRC)
	check_true(src.find("maxi(size, 16)") >= 0,
		"比分板字号应下限钳到 16（§3.1：字号 ≥ 16，Standard 基准线）")