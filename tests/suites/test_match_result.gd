extends TestSuite
## EP-4 · ES-4.2 结算面板回归基线（`04_ux_flow §3.2`）
##
## 与 `test_scoreboard.gd` 同一取舍：**把易错逻辑抽成静态纯函数再断言**，
## headless 就能钉死胜者行 / 时长格式 / 按钮权限 / 互斥契约，不用开窗口截图肉眼看。
##
## 重点防守的六个易错点：
##① 胜者行三种来源（本人 / 他人 / 平局 `WINNER_TIE=-2` / 未定 `-1`）文案不能混；
##   ⚠ 平局**绝不能**显示任何玩家名（否则会误导成「某某赢了」）；
##② `format_duration` 与 `Scoreboard.format_clock` 的分工：单局上限 5 分钟 → **不显示小时**；
##   且必须**复用** `format_clock`，不能另写一套（两套时间格式会在同一屏打架）；
##③ 面板**不暂停**：`get_tree().paused` 全程为 false（§3.2 + §1 现状约束）；
##④ `game_ui` 组登记 + `open_ui/close_ui` 契约锁（§3.2 互斥）；
##  ⑤ 客户端 `[再来一局]` 文案是「等待房主…」且**不可点**（客户端无重置权限，A.1）；
##  ⑥ **不得自行重算胜负** —— 胜负唯一口径是 `ScoreManager._evaluate_winner()`（附录 A.6）。

const MATCH_RESULT_SRC := "res://scripts/ui/match_result.gd"
const MATCH_RESULT_SCENE := "res://scenes/ui/match_result.tscn"
const HUD_SRC := "res://scripts/ui/hud.gd"
const SCORE_MANAGER_SRC := "res://scripts/game/score_manager.gd"

## `ScoreManager` 的两个语义值（附录 A.3）——此处刻意**不**引用 ScoreManager 类，
## 改为写死字面量 + 断言 ScoreManager 侧确实是这两个值：
## 避免「测试与实现引用同一个常量 → 一起错」这种共谋式假绿。
const TIE := -2
const UNSET := -1

var _mr: GDScript


func _ready() -> void:
	_mr = load(MATCH_RESULT_SRC) as GDScript


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


## 读源码并**剥掉所有注释**，只留可执行代码。
##
## ## 为什么必须剥注释（本轮真实踩到的坑）
## 纪律锁用 `find("kills >")` 之类的**字面量**去搜源码。问题在于：
## 「不得出现 `kills >`」这件事本身就得在注释里写清楚（说明纪律 + 来历），
## 于是 `match_result.gd` 的**注释**里出现了 `kills >` / `_evaluate_winner` /
## `net_match_ended` 这些字样 → 纪律锁搜到的是**自己的注释**，用例无端转红。
## 这是「用字面量搜索做架构纪律锁」的固有缺陷：
##**注释越是把纪律写清楚，纪律锁越会误报**。
## ⚠ 危险之处：若有人为了让用例变绿而去删注释，就等于**把纪律说明也删了**——
##   变成「为了让测试通过而破坏可维护性」，这正是本项目反复吃亏的那类假绿。
## → 故所有架构纪律锁一律走本helper（只搜代码，不搜注释）。
## 实现说明：逐行只保留 `#` **之前**的代码部分。
##   ⚠ 这里有个容易写反的坑：不能写成「有 `#` 就整行丢」——
##   那样会把 `xxx(true) # 注释` 这种「代码 + 行尾注释」的**代码部分也一起丢掉**，
##   导致纪律锁在代码明明存在时误报「没调用 xxx」。
##   （本轮真实踩到：`open_ui()` 里的 `_set_input_blocked(true) # §4-1 …`
##     被整行丢掉 → `test_open_ui_blocks_player_input` 无端转红。）
##   GDScript 无块注释，故只需处理行注释；字符串字面量里含 `#` 的极端情况
##   本项目不存在，注释此说明避免过度设计。
func _read_code(path: String) -> String:
	var out: Array[String] = []
	for line in _read_source(path).split("\n"):
		var hash := line.find("#")
		out.append(line if hash < 0 else line.substr(0, hash))
	return "\n".join(out)


## 便捷：造一个已入树的结算面板实例（headless 可用）。
func _make_panel() -> Node:
	var packed: PackedScene = load(MATCH_RESULT_SCENE) as PackedScene
	if packed == null:
		fail("无法加载 %s" % MATCH_RESULT_SCENE)
		return null
	var node: Node = packed.instantiate()
	if node == null:
		fail("match_result.tscn 实例化失败")
		return null
	add_child(node)
	return node


# ══════════════════════════════════════════════════════════════════════
#  ① 胜者行文案
# ══════════════════════════════════════════════════════════════════════

## 本人获胜 → 「🏆 你 获胜」（房主视角：winner == local == 1）。
func test_winner_text_self() -> void:
	check_eq(_mr.winner_text(1, 1, {}), "🏆 你 获胜", "本端即胜者应显示「你」")


## 他人获胜 → 「🏆 {名字} 获胜」（客户端视角：winner=1，本端=2）。
func test_winner_text_other_uses_name() -> void:
	var s: String = _mr.winner_text(1, 2, {1: "阿强"})
	check_eq(s, "🏆 阿强 获胜", "他人获胜应显示其昵称")


## 昵称缺失时退回「玩家{id}」，不能留白（复用Scoreboard.display_name_for 口径）。
func test_winner_text_other_falls_back_to_generic_name() -> void:
	check_eq(_mr.winner_text(7, 2, {}), "🏆 玩家7 获胜", "缺昵称应退回「玩家7」")


## ⚠ 平局（WINNER_TIE）→ 「🏆 平局」，且**绝不能**出现任何玩家名。
## 这是最容易写错的一条：若平局时还显示「🏆 阿强 获胜」，就是**误导**——
## 明明是并列却告诉玩家阿强赢了。
func test_winner_text_tie_shows_no_player_name() -> void:
	var s: String = _mr.winner_text(TIE, 1, {1: "阿强", 2: "小明"})
	check_eq(s, "🏆 平局", "平局应显示「🏆 平局」")
	check_false(s.contains("阿强"), "平局文案绝不能包含任何玩家名（会误导成某方获胜）")
	check_false(s.contains("小明"), "平局文案绝不能包含任何玩家名（会误导成某方获胜）")


## 未定（WINNER_UNSET，空表）→「🏆 无胜者」，同样不得出现玩家名。
func test_winner_text_unset() -> void:
	var s: String = _mr.winner_text(UNSET, 1, {1: "阿强"})
	check_eq(s, "🏆 无胜者", "未定应显示「🏆 无胜者」")
	check_false(s.contains("阿强"), "未定文案不得包含玩家名")


## 胜者语义值与 ScoreManager 侧一致（防两边各自写死不同数字）。
func test_winner_semantics_match_score_manager() -> void:
	var sm_src := _read_source(SCORE_MANAGER_SRC)
	check_true(sm_src.find("const WINNER_TIE := %d" % TIE) >= 0,
		"ScoreManager.WINNER_TIE 应为 %d（测试里的 TIE 常量须与之对齐）" % TIE)
	check_true(sm_src.find("const WINNER_UNSET := %d" % UNSET) >= 0,
		"ScoreManager.WINNER_UNSET 应为 %d（测试里的 UNSET 常量须与之对齐）" % UNSET)


## 标题**恒为**「对局结束」，且不随胜者/视角变化（胜者信息由下一行承载，文案分层）。
func test_title_is_constant_regardless_of_winner_or_viewpoint() -> void:
	check_eq(_mr.title_for(1, 1), "对局结束", "房主视角标题")
	check_eq(_mr.title_for(1, 2), "对局结束", "客户端视角标题应与房主一致")
	check_eq(_mr.title_for(TIE, 1), "对局结束", "平局时标题不变")
	check_eq(_mr.title_for(UNSET, 1), "对局结束", "未定时标题不变")


# ══════════════════════════════════════════════════════════════════════
#  ② 本局时长
# ══════════════════════════════════════════════════════════════════════

## 本局时长 = 上限 - 剩余。赢在 15 杀时提前结束，直接显示上限会谎报时长。
func test_elapsed_seconds_subtracts_remaining() -> void:
	check_eq(_mr.elapsed_seconds(300.0, 120.0), 180.0, "300 上限剩 120 → 本局打了 180 秒")
	check_eq(_mr.elapsed_seconds(300.0, 0.0), 300.0, "时间耗尽 → 打满 300 秒")
	check_eq(_mr.elapsed_seconds(300.0, 400.0), 0.0, "剩余超过上限应夹到 0（不得为负）")


## 时长格式化边界（§3.2）。
## ⚠ **不显示小时**的依据：`04_ux_flow §3.2` 只写「本局时长」未要求 HH:MM:SS；
##   而 `ScoreManager.match_duration` 默认 300 s（5 分钟）→ 小时位永不可达。
##   故与 ES-4.1 的剩余计时同为 MM:SS，同屏不出现两种单位。
func test_format_duration_boundaries() -> void:
	check_eq(_mr.format_duration(0.0), "00:00", "0 秒 → 00:00")
	check_eq(_mr.format_duration(59.0), "00:59", "59 秒 → 00:59")
	check_eq(_mr.format_duration(60.0), "01:00", "60 秒 → 01:00（分钟进位）")
	check_eq(_mr.format_duration(3599.0), "59:59", "3599 秒 → 59:59")
	# 3600 s → "60:00"（分钟位进位到 60）是「不显示小时」的直接推论；
	#   当前 300 s 上限下不可达，此处钉死以防将来有人悄悄改成 01:00:00 造成两套口径。
	check_eq(_mr.format_duration(3600.0), "60:00", "3600 秒 → 60:00（不显示小时，分钟位进位）")


## 时长格式必须**复用** Scoreboard.format_clock，不能另写一套
## （同一屏里「剩余 03:24」与「本局时长 02:15」必须是同一种格式）。
func test_format_duration_reuses_scoreboard_clock() -> void:
	var sb: GDScript = load("res://scripts/ui/scoreboard.gd") as GDScript
	for t in [0.0, 59.0, 60.0, 204.0, 3599.0]:
		check_eq(_mr.format_duration(t), sb.format_clock(t),
			"%s 秒：结算面板时长格式必须与比分板剩余计时一致（不得两套口径）" % str(t))


# ══════════════════════════════════════════════════════════════════════
#  ③ 完整比分表（排序口径必须复用 Scoreboard）
# ══════════════════════════════════════════════════════════════════════

## 排序：击杀降序 → 死亡升序 → peer_id 升序（与比分板逐字同口径）。
func test_standings_sorted_like_scoreboard() -> void:
	var scores := {
		1: {"kills": 5, "deaths": 8},
		2: {"kills": 5, "deaths": 2},
		9: {"kills": 9, "deaths": 3},
	}
	var rows: Array = _mr.build_standings(scores, 1, {})
	check_eq(rows.size(), 3, "应产出 3 行")
	check_eq(int(rows[0]["peer_id"]), 9, "击杀 9 者排第一")
	check_eq(int(rows[1]["peer_id"]), 2, "击杀相同按死亡升序（死亡 2 在前）")
	check_eq(int(rows[2]["peer_id"]), 1, "击杀 death 8 者最后")


## 跨端一致性：同一份 final_scores，房主视角与客户端视角必须排出**完全相同**的顺序。
## ⚠ 这是结算面板特有的风险 —— 两端同时弹出结算面板，顺序若不同会显得「比分不一致」。
func test_standings_order_identical_on_both_endpoints() -> void:
	var scores := {3: {"kills": 4, "deaths": 4}, 9: {"kills": 4, "deaths": 4}}
	var host: Array = _mr.build_standings(scores, 1, {})
	var client: Array = _mr.build_standings(scores, 2, {})
	check_eq(int(host[0]["peer_id"]), int(client[0]["peer_id"]),
		"同一 final_scores 在两端必须排出相同顺序（否则结算面板两端看起来不一致）")
	check_eq(int(host[1]["peer_id"]), int(client[1]["peer_id"]),
		"第二行顺序也必须两端一致")


## ⚠️ AC-A4（QA 审计要求）：排序口径必须与 `Scoreboard.build_rows` **逐行完全相等**。
## 这里刻意**不**重写一套期望顺序，而是把同一份 `scores` 同时喂给两个函数、
## 逐行比对 `peer_id` 序列 —— 只要结算面板哪天自己排一套序，这条立刻转红。
## ≥3 组数据：含并列、同分、0:0、全不同。
func test_standings_sequence_identical_to_scoreboard_across_datasets() -> void:
	var sb: GDScript = load("res://scripts/ui/scoreboard.gd") as GDScript
	var datasets := [
		# ① 普通局：击杀各不相同
		{1: {"kills": 5, "deaths": 8}, 2: {"kills": 9, "deaths": 3}, 3: {"kills": 7, "deaths": 4}},
		# ② 并列领先：击杀相同 → 死亡升序
		{1: {"kills": 6, "deaths": 2}, 2: {"kills": 6, "deaths": 0}, 3: {"kills": 6, "deaths": 5}},
		# ③ 0:0 开局：无人领先，顺序应按 peer_id 升序
		{1: {"kills": 0, "deaths": 0}, 2: {"kills": 0, "deaths": 0}, 3: {"kills": 0, "deaths": 0}},
		# ④ 完全同分：只能靠 peer_id 破平（跨端不抖动）
		{5: {"kills": 4, "deaths": 4}, 2: {"kills": 4, "deaths": 4}, 9: {"kills": 4, "deaths": 4}},
		# ⑤ 单人
		{7: {"kills": 1, "deaths": 0}},
	]
	for idx in datasets.size():
		var scores: Dictionary = datasets[idx]
		for viewpoint in [1, 7]:# 两个不同本端视角都必须与比分板同序
			var mine: Array = _mr.build_standings(scores, viewpoint, {})
			var theirs: Array = sb.build_rows(scores, viewpoint, {})
			check_eq(mine.size(), theirs.size(),
				"数据集 #%d：结算面板与比分板行数必须相同" % (idx + 1))
			var n: int = mini(mine.size(), theirs.size())
			var mismatch := -1
			for i in n:
				if int(mine[i]["peer_id"]) != int(theirs[i]["peer_id"]):
					mismatch = i
					break
			check_true(mismatch < 0,
				"数据集 #%d（视角 %d）：第 %d 行 peer_id 不一致（结算面板 %s vs 比分板 %s）"
				% [idx + 1, viewpoint, mismatch + 1,
				str(mine[mismatch]["peer_id"]) if mismatch >= 0 else "-",
				str(theirs[mismatch]["peer_id"]) if mismatch >= 0 else "-"])


## 行文案含 5 列，且 KD 走Scoreboard.kd_text 的真实契约
## （`kd_text(15,0) == "15.0"` 而非 "—"；`kd_text(0,0) == "—"` —— §4-12 提醒过别想当然）。
func test_row_text_columns_and_kd_contract() -> void:
	var winner_row := {"name": "阿强", "kills": 15, "deaths": 0}
	var s: String = _mr.row_text(1, winner_row)
	check_true(s.contains("阿强"), "行文案应含名字（防空串回归，§4-12）")
	check_true(s.contains("15"), "行文案应含击杀数")
	check_true(s.contains("15.0"), "0 死时 KD 显示击杀数（kd_text 真实契约，不是「—」）")
	check_false(s.is_empty(), "行文案不得为空串")
	var zero_row := {"name": "小明", "kills": 0, "deaths": 0}
	check_true(_mr.row_text(2, zero_row).contains("—"), "0 杀 0 死时 KD 才是占位符「—」")


# ══════════════════════════════════════════════════════════════════════
#  ④ 「不暂停」+ game_ui 组契约
# ══════════════════════════════════════════════════════════════════════

## ⚠️ 核心锁：面板打开时 `get_tree().paused` 必须**仍为 false**。
## 若有人为了「冻结结算」在 open_ui() 里加了 `get_tree().paused = true`，
## 后果是 `ScoreManager._process` 停摆（倒计时/计时都冻住），且与 §1 现状约束冲突。
func test_open_ui_does_not_pause_the_tree() -> void:
	var panel := _make_panel()
	if panel == null:
		return
	get_tree().paused = false
	# 直接触发结算（等价于ScoreManager.match_ended 广播后的路径）
	panel._on_match_ended(1, {1: {"kills": 15, "deaths": 0}})
	check_true(panel.is_open(), "收到 match_ended 后面板应已打开")
	check_false(get_tree().paused,
		"结算面板是覆盖层不是暂停态，open 后 get_tree().paused 必须仍为 false（§3.2）")
	get_tree().paused = false # 收尾复原，避免污染后续用例
	panel.queue_free()


## 源码级纪律锁：整个文件不得出现 `paused = true` / `paused=true`。
func test_source_never_pauses_the_tree() -> void:
	var src := _read_code(MATCH_RESULT_SRC) # ⚠ 剥注释，见 _read_code 的说明
	check_true(src.find("paused = true") < 0 and src.find("paused=true") < 0,
		"match_result.gd 不得设置 get_tree().paused = true（§3.2「不暂停」）")


## 面板必须加入 game_ui 组（§3.2 互斥：打开时关掉Esc 菜单 / 死亡界面 / 人机面板）。
func test_panel_joins_game_ui_group() -> void:
	var panel := _make_panel()
	if panel == null:
		return
	check_true(panel.is_in_group("game_ui"), "结算面板必须加入 game_ui 组（§3.2 互斥）")
	panel.queue_free()


## `open_ui` / `close_ui` / `is_open` 三个契约方法必须齐备
## —— `game_menu.gd::_close_other_uis()` 正是靠 `has_method("close_ui")+is_open()` 遍历关别的。
func test_open_close_contract_methods_exist() -> void:
	var panel := _make_panel()
	if panel == null:
		return
	for m in ["open_ui", "close_ui", "is_open"]:
		check_true(panel.has_method(m), "结算面板必须实现 %s()（game_ui 互斥契约）" % m)
	check_false(panel.is_open(), "初始应为关闭态（场景里 visible=false）")
	panel.open_ui()
	check_false(panel.is_open(), "未收到 match_ended 时 open_ui 不应展示空面板")
	panel._on_match_ended(1, {1: {"kills": 3, "deaths": 1}})
	check_true(panel.is_open(), "收到结算后应打开")
	panel.close_ui()
	check_false(panel.is_open(), "close_ui 应关闭面板")
	panel.queue_free()


## 互斥实测：结算面板打开时，组内其它已开界面应被关闭。
## 这里用一个「长得像 game_ui 成员」的假界面（实现 close_ui/is_open）代替真面板，
## 验证的是 `_close_other_uis()` 的遍历逻辑本身，不依赖其它 UI 场景是否加载。
func test_opening_closes_other_group_members() -> void:
	var panel := _make_panel()
	if panel == null:
		return

	var other := Node.new()
	other.name = "FakeOtherUi"
	other.set_script(load("res://tests/framework/fake_game_ui_member.gd"))
	add_child(other)
	other.call("open_ui")
	check_true(bool(other.call("is_open")), "前置条件：假界面已打开")

	panel._on_match_ended(1, {1: {"kills": 3, "deaths": 1}})
	check_true(panel.is_open(), "前置条件：结算面板已打开")
	check_false(bool(other.call("is_open")),
		"结算面板打开时必须关闭 game_ui 组内其它已开界面（§3.2 互斥）")

	other.queue_free()
	panel.queue_free()


## 结算面板场景的 @onready 节点路径必须与脚本逐字对齐（否则运行期空引用 → 整面板空白）。
func test_scene_node_paths_match_script() -> void:
	var panel := _make_panel()
	if panel == null:
		return
	for path in ["Panel", "Panel/VBox", "Panel/VBox/Title", "Panel/VBox/Winner",
			"Panel/VBox/Table", "Panel/VBox/Duration", "Panel/VBox/Buttons",
			"Panel/VBox/Buttons/AgainButton", "Panel/VBox/Buttons/LobbyButton"]:
		check_true(panel.get_node_or_null(path) != null,
			"match_result.tscn 应存在节点 %s（与 @onready 路径对齐）" % path)
	panel.queue_free()


## ⚠️ §4-1 双闸门：面板**要**屏蔽玩家输入（释放鼠标才能点按钮）。
## 这是「不暂停」之外的独立判断 —— paused 是场景树开关，input_blocked 是玩家输入开关。
## 源码级钉住：open_ui 调set_input_blocked(true)、close_ui 调 set_input_blocked(false)。
func test_open_ui_blocks_player_input() -> void:
	var src := _read_code(MATCH_RESULT_SRC) # ⚠ 剥注释，见 _read_code 的说明
	check_true(src.find("_set_input_blocked(true)") >= 0,
		"open_ui 应调 set_input_blocked(true)（§4-1：释放鼠标才能点按钮，且要连带关武器触发器）")
	check_true(src.find("_set_input_blocked(false)") >= 0,
		"close_ui 应调 set_input_blocked(false) 并恢复鼠标")


# ══════════════════════════════════════════════════════════════════════
#  ④b Tab 榜互斥（B2 / AC-B7 —— QA 审计列为 ES-4.2 阻塞项）
# ══════════════════════════════════════════════════════════════════════

## ⚠️ B2 / AC-B7：结算面板打开时，按住 Tab **不得**弹出完整榜。
##
## 依据 `04_ux_flow §3.1.1`：「死亡界面 / 结算面板打开时 `Tab` 榜**不响应**」。
## 机制：`Scoreboard.show_full()` 开头有 `_blocked_by_other_ui()`，它遍历 `game_ui` 组
## 查`is_open()`。本面板既 `add_to_group("game_ui")` 又实现 `is_open()` → 天然被识别。
## ⚠ 不能靠「读一眼代码觉得会拦」就算过 —— ES-4.2 面板一上线它就从假想变成真实场景，
## 两个全屏面板叠加会直接盖住结算比分表。故用真实 `scoreboard.tscn` 端到端实测。
func test_tab_scoreboard_blocked_while_panel_open() -> void:
	var panel := _make_panel()
	if panel == null:
		return
	var sb_node: Node = (load("res://scenes/ui/scoreboard.tscn") as PackedScene).instantiate()
	add_child(sb_node)

	# ⚠ 隔离性处理：Runner 按**方法名排序**跑用例，同一帧里可能残留**上一个用例**
	 # 遗留的面板实例（`queue_free()` 是延迟的，不当帧生效）——
	 # 它仍在 `game_ui` 组且 `is_open()==true`，会让下面的前置断言「莫名被拦」。
	# → 先清掉所有**非本实例**的 game_ui 阻塞源，再验前置。
	for other in get_tree().get_nodes_in_group("game_ui"):
		if other != panel and other.has_method("close_ui") and other.has_method("is_open") \
				and bool(other.call("is_open")):
			other.call("close_ui")

	# 前置：结算面板未打开时 Tab 榜**可以**弹出（排除「本来就弹不出来」的假绿）
	sb_node.call("show_full")
	check_true(bool(sb_node.call("is_full_visible")),
		"前置条件：结算面板未打开时 Tab 榜应能正常显示")

	# 打开结算面板 → 再按 Tab，必须**被拦下**
	panel._on_match_ended(1, {1: {"kills": 15, "deaths": 0}})
	check_true(panel.is_open(), "前置条件：结算面板已打开")
	sb_node.call("hide_full")
	sb_node.call("show_full")
	check_false(bool(sb_node.call("is_full_visible")),
		"结算面板打开时 Tab 完整榜必须不响应（§3.1.1 / AC-B7，否则两个全屏面板叠加）")

	sb_node.queue_free()
	panel.queue_free()


## 本面板必须同时满足「进 game_ui 组」+「实现 is_open()」——
## `Scoreboard._blocked_by_other_ui()` 正是靠这两点识别阻塞源的，缺一即失效。
func test_panel_is_detectable_as_blocking_source() -> void:
	var panel := _make_panel()
	if panel == null:
		return
	check_true(panel.is_in_group("game_ui"),
		"必须在 game_ui 组内，否则比分板 _blocked_by_other_ui() 遍历不到")
	check_true(panel.has_method("is_open"),
		"必须实现 is_open()，否则比分板无法判断其是否已打开")
	panel._on_match_ended(1, {1: {"kills": 3, "deaths": 1}})
	check_true(panel.is_open(), "已结算时 is_open() 必须为 true（这是被识别的关键）")
	panel.queue_free()


# ══════════════════════════════════════════════════════════════════════
#  ⑤ 客户端按钮：文案 + 可点性
# ══════════════════════════════════════════════════════════════════════

## 权威端（含离线本端）→「再来一局」，可点。
func test_button_caption_authority() -> void:
	check_eq(_mr.button_caption(true), "再来一局", "权威端按钮应为「再来一局」")
	check_true(_mr.can_request_reset(true), "权威端应可点")


## 客户端→「等待房主…」且**不可点**。
## ⚠ 客户端若也显示「再来一局」，玩家点了什么都不会发生
##   （`ScoreManager.request_reset()` 开头 `if not is_authority(): return`）—— 最坏的 UX。
func test_button_caption_client_waits_for_host() -> void:
	check_eq(_mr.button_caption(false), "等待房主…", "客户端按钮应显示「等待房主…」")
	check_false(_mr.can_request_reset(false), "客户端按钮必须不可点（无重置权限，A.1）")


## 文案与可点性必须同源：凡是「等待房主…」的按钮一定是 disabled，反之亦然。
## （两处口径若各写各的，会出现「写着等待房主却能点」或「房主点不动」的矛盾态。）
func test_caption_and_enabled_state_never_disagree() -> void:
	for authority in [true, false]:
		var caption: String = _mr.button_caption(authority)
		var enabled: bool = _mr.can_request_reset(authority)
		if caption == "等待房主…":
			check_false(enabled, "显示「等待房主…」时按钮必须不可点")
		else:
			check_true(enabled, "显示「再来一局」时按钮必须可点")


## 渲染层实测：客户端视角下按钮真的是 disabled 且文案是「等待房主…」。
func test_rendered_button_is_disabled_for_client() -> void:
	var panel := _make_panel()
	if panel == null:
		return
	panel.bind(null) # 未绑定 → _is_authority() 走「离线即权威」兜底
	panel._on_match_ended(1, {1: {"kills": 15, "deaths": 0}})
	var again: Button = panel.get_node_or_null("Panel/VBox/Buttons/AgainButton")
	if again == null:
		fail("AgainButton 节点缺失")
		panel.queue_free()
		return
	# 离线兜底 = 权威 → 应可点
	check_eq(again.text, "再来一局", "离线（本端即权威）应显示「再来一局」")
	check_false(again.disabled, "离线（本端即权威）按钮应可点")

	# 强行切成「联机客户端」：_is_authority() 读 NetworkManager.is_online
	var old_online: bool = NetworkManager.is_online
	NetworkManager.is_online = true
	NetworkManager.is_server = false
	panel.call("_render")
	check_eq(again.text, "等待房主…", "联机客户端应显示「等待房主…」")
	check_true(again.disabled, "联机客户端按钮必须真的 disabled")
	NetworkManager.is_online = old_online # 复原
	panel.queue_free()


# ══════════════════════════════════════════════════════════════════════
#  ⑥ 纪律锁：不得自行重算胜负 + 架构铁律（UI 只绑信号不碰 RPC）
# ══════════════════════════════════════════════════════════════════════

## ⚠️ 核心纪律锁：结算面板**不得**自行判定胜负。
## 胜负唯一口径是 `ScoreManager._evaluate_winner()`（附录 A.6）。
## 本面板只消费 `match_ended` 传来的 `winner_id`。
## 若这里自己读 kills/deaths 比大小，就会出现「面板说 A 赢、权威说 B 赢」的两套口径。
func test_does_not_reimplement_winner_evaluation() -> void:
	var src := _read_code(MATCH_RESULT_SRC) # ⚠ 剥注释，见 _read_code 的说明
	check_true(src.find("func _evaluate_winner") < 0,
		"结算面板不得自行实现胜负判定（唯一口径是 ScoreManager._evaluate_winner）")
	check_true(src.find("_max_kills") < 0,
		"结算面板不得自行统计最高击杀（那是 ScoreManager 的职责）")
	# 不得出现「按 kills/deaths 做大小比较」的表达式。
	# ⚠ 这里刻意**同时**钉死 `kills` / `deaths` 与比较运算符的**任意组合**
	#   （而不是只搜"kills >"这一条）：变异测试 M3 正是用
	#   `int(__e.get("kills", 0)) > 0` 这种**换一种写法**绕过了单条字面量锁，
	#   导致「UI 自行重算胜负」这个最严重的架构违纪一度'通过'变异测试。
	#   → 改为「代码里根本不出现 kills / deaths 的比较运算」这一**语义级**约束。
	for field in ["kills", "deaths"]:
		for op in [">", "<", ">=", "<="]:
			for pat in [
				"%s %s" % [field, op],
				"%s%s" % [op, field],
				"%s\\\") %s" % [field, op],   # get("kills", 0) > 0
				"%s %s " % [field, op],
			]:
				check_true(src.find(pat) < 0,
					"结算面板不得出现按 %s 的比较运算（发现 %s）—— 会与权威判定打架"
					% [field, pat])
	# 正向锁：胜者行必须**只**用传进来的 winner_id（不得出现遍历比分求最值的痕迹）。
	# ⚠ 断言必须区分「成员字段存值」与「形参被改写」：
	#   `_winner_id = winner_id`（把信号载荷存进成员）是**正常**的，
	#   而 `winner_id = ...`（改写形参）才是重算征兆。
	#   这里用行首精确匹配 `winner_id =`，避免 `_winner_id =` 被子串误伤。
	for line in src.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("winner_id =") or stripped.begins_with("winner_id +="):
			fail("winner_id 形参不得被重新赋值（发现：%s）—— 胜负只能由 ScoreManager 决定"
				% stripped)


##⚠ 补充纪律锁：`_final_scores` 只允许出现在**渲染**路径（build_standings），
##   不得被用来反推胜者。若将来有人写「从 final_scores 找 kills 最高的那个」，
##   上面的比较运算锁能兜住；这条额外锁住「赋值给 winner_id」这一类改写。
func test_winner_id_is_only_consumed_never_recomputed() -> void:
	var src := _read_code(MATCH_RESULT_SRC)
	var assign_count := 0
	for line in src.split("\n"):
		var stripped := line.strip_edges()
		# 形参声明那一行不算改写
		if stripped.begins_with("func winner_text("):
			continue
		if stripped.begins_with("winner_id =") or stripped.begins_with("winner_id +="):
			assign_count += 1
	check_eq(assign_count, 0,
		"winner_id 形参不得被重新赋值（发现 %d 处）——胜负只能由 ScoreManager 决定" % assign_count)


## 架构铁律：UI 只绑信号，不碰 RPC（不得调用任何 net_* / *.rpc）。
func test_ui_does_not_call_rpc() -> void:
	var src := _read_code(MATCH_RESULT_SRC) # ⚠ 剥注释，见 _read_code 的说明
	for pat in ["net_match_ended", ".rpc(", ".rpc_id("]:
		check_true(src.find(pat) < 0,
			"UI 不得发 RPC（发现 %s）—— 架构铁律：UI 只绑 ScoreManager 的本地信号" % pat)
	# 必须确实绑了 match_ended 信号（正向锁）
	check_true(_read_source(MATCH_RESULT_SRC).find("match_ended.is_connected") >= 0,
		"结算面板必须绑定 ScoreManager.match_ended 信号（附录 A.5 绑定面）")


## 只允许通过 `ScoreManager.request_reset()` 走复位，不得自造复位路径。
func test_reset_goes_through_score_manager() -> void:
	var src := _read_code(MATCH_RESULT_SRC) # ⚠ 剥注释，见 _read_code 的说明
	check_true(src.find("request_reset") >= 0,
		"「再来一局」应调 ScoreManager.request_reset()（A.8 既有契约）")
	check_true(src.find("net_match_reset") < 0,
		"结算面板不得自己发 net_match_reset（应由 ScoreManager 内部广播）")


## 按钮回调不得直接切场景回大厅而不走 NetworkManager（联机时必须先 leave_game）。
func test_lobby_button_goes_through_network_manager_when_online() -> void:
	var src := _read_source(MATCH_RESULT_SRC)
	check_true(src.find("NetworkManager.leave_game()") >= 0,
		"「返回大厅」联机时应走 NetworkManager.leave_game()（与 hud.gd 同口径）")
	check_true(src.find("NetworkManager.HUB_SCENE") >= 0,
		"离线「返回大厅」应切 NetworkManager.HUB_SCENE")


# ══════════════════════════════════════════════════════════════════════
#  ⑦ 接线（契约锁）：HUD 必须真的把 ScoreManager 接到结算面板
# ══════════════════════════════════════════════════════════════════════

## ES-4.2 验收要求「由 match_ended 触发」→ hud.gd 必须调 bind。
func test_hud_connects_match_result() -> void:
	var src := _read_source(HUD_SRC)
	check_true(src.find("_bind_match_result") >= 0,
		"hud.gd 应把 ScoreManager 接到结算面板（_bind_match_result）")
	check_true(src.find("_match_result.bind") >= 0,
		"hud.gd 应调用 _match_result.bind(score)")


## 结算面板必须挂在 hud.tscn 上（否则 _ready 里 $MatchResult 空引用）。
func test_match_result_mounted_in_hud_scene() -> void:
	var src := _read_source("res://scenes/ui/hud.tscn")
	check_true(src.find("match_result.tscn") >= 0, "hud.tscn 应引用 match_result.tscn")
	check_true(src.find("MatchResult\" parent=\".\" instance=") >= 0 or
		src.find("name=\"MatchResult\"") >= 0,
		"hud.tscn 应实例化 MatchResult 节点（_ready 的 $MatchResult 才非空）")


## §3.1 可访问性：字号 ≥ 16。
func test_font_size_floor_is_16() -> void:
	var src := _read_source(MATCH_RESULT_SRC)
	check_true(src.find("maxi(size, 16)") >= 0,
		"结算面板字号应下限钳到 16（§3.1：字号 ≥ 16，Standard 基准线）")


## 领先者用**明度对比 + 加粗**双通道，而非仅颜色（§6 Standard）。
func test_leader_uses_bold_not_only_color() -> void:
	var src := _read_source(MATCH_RESULT_SRC)
	check_true(src.find("font_shadow_color") >= 0,
		"领先者应加粗（阴影/加粗通道），不能只靠换颜色区分（§6 Standard）")
