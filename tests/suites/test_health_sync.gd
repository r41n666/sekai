extends TestSuite
## Task #10 ·远程血量同步（射手端能看到对手的真实血量与掉血过程）—— 回归基线
##
## ## 缺陷背景（C-18 的遗留缺口）
## `apply_network_damage` 是 `@rpc("any_peer","call_remote","reliable")` → 伤害**只在受害端结算，从不回传射手端**。
## C-18 已把「致死判定」移到受害端权威解决（`net_confirm_kill.rpc_id(射手)`），
## 但**射手端看到的 `collider.health` 恒为初始值 100** —— 打空了血对手照样满血，命中反馈失真。
##
## ## 本 Story 的口径（三条不可越界的边界）
##   ① **权威只在受害端**。射手端**不因远端掉血而本地扣血**（不写 `health`、不调`take_damage`）。
##      本端另开一个**显示副本** `_display_health`，由 `net_player_state`（30Hz 广播）刷新。
##   ② **显示态不驱动本地死亡流程**（不发 `died`、不进 `_enter_dead_state`）——
##      死亡/重生是受害端的权威流程，射手端不替它决定。
##   ③ **血量是纯显示态**，不参与任何胜负/计分判定（胜负唯一口径 = `ScoreManager._evaluate_winner`）。
##
## ## 通道选择：复用已有的 30Hz `net_player_state`（ADR-008）
## 位置已经在 30Hz 广播 → **复用同一条包不增加广播次数**（带宽不翻倍）；30Hz 对血条足够；
## 另开一条 reliable RPC 会在每次受击时多发一包，且与 `unreliable_ordered` 混用要额外处理顺序。
## ⚠ 代价：**RPC 签名是破坏性变更** —— `net_player_state` 与 `apply_network_state` 都改成3 参，
##   两处必须同步改，否则实参个数不匹配、**运行时才炸**。`test_send_and_receive_arity_matches` 钉死这条。

const PLAYER_SRC := "res://scripts/player.gd"
const NETWORK_SRC := "res://scripts/network/network_manager.gd"
const HUD_SRC := "res://scripts/ui/hud.gd"
const BARS_SRC := "res://scripts/ui/enemy_health_bars.gd"
const BARS_SCENE_PARENT := "res://scenes/ui/hud.tscn"
const PLAYER_SCENE := "res://scenes/player.tscn"
const ADR_008 := "res://docs/architecture/adr/ADR-008-remote-health-display.md"
const OVERVIEW := "res://docs/architecture/00_overview.md"

const PLAYER_SCRIPT := preload("res://scripts/player.gd")

## 本端（headless 单peer）id默认为 1；远端节点要设成别的 id 才会走 `_setup_remote_player()`
const REMOTE_AUTHORITY := 2

var _health_changed_hits := 0
var _died_hits := 0
var _remote_health_events: Array = []


func before_each() -> void:
	_health_changed_hits = 0
	_died_hits = 0
	_remote_health_events.clear()


func _on_health_changed(_current: float, _maximum: float) -> void:
	_health_changed_hits += 1


func _on_died() -> void:
	_died_hits += 1


func _on_remote_health_changed(current: float, maximum: float) -> void:
	_remote_health_events.append([current, maximum])


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## 剥注释（`control_checklist §4-13`）：逐行**只保留 `#` 之前的部分**。
##⚠ 不能「有 `#` 就整行丢」—— 那会把 `xxx(true) # 注释` 的代码部分也丢掉，
##   导致代码明明在、纪律锁却报「没调用」（ES-4.2 实测踩过）。
func _strip_comments(src: String) -> String:
	var out: Array[String] = []
	for line in src.split("\n"):
		var hash := line.find("#")
		out.append(line if hash < 0 else line.substr(0, hash))
	return "\n".join(out)


## 取某个 `func xxx` 的函数体（到下一个顶层 `func ` 为止），只做结构断言。
func _func_body(src: String, header: String) -> String:
	var i := src.find(header)
	if i < 0:
		return ""
	var j := src.find("\nfunc ", i + 1)
	if j < 0:
		return src.substr(i)
	return src.substr(i, j - i)


## 实例化一个「远端玩家」节点（authority != 本端 → 走`_setup_remote_player()`）。
func _make_remote_player() -> Node:
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	if scene == null:
		fail("无法加载 %s" % PLAYER_SCENE)
		return null
	var remote := scene.instantiate()
	remote.set_multiplayer_authority(REMOTE_AUTHORITY)
	add_child(remote)
	return remote


func _free(node: Node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.free()


# ══════════════════════════════════════════════════════════════════════
#  ① RPC 签名一致性（防「运行期才炸」—— 本Story 最大的机械性风险）
# ══════════════════════════════════════════════════════════════════════

## 用**运行时反射**取方法元数（不是数源码字符串）：数错字符串顶多误报，
## 而真实的元数不一致只有引擎在派发时才会炸 —— 所以必须问引擎本身。
func test_send_and_receive_arity_matches() -> void:
	var recv_args := _method_arg_count(NetworkManager, "net_player_state")
	var apply_args := _method_arg_count(PLAYER_SCRIPT, "apply_network_state")
	check_eq(recv_args, 3, "network_manager.gd::net_player_state 应收 3 个广播载荷（pos / yaw / health）")
	check_eq(apply_args, 3, "player.gd::apply_network_state 应收 3 个形参（与广播端实参个数一一对应）")
	check_eq(recv_args, apply_args, "广播端形参个数必须与接收端转发给apply_network_state 的实参个数一致")


## 发送端与转发端的**实参个数**（反射拿不到调用点，只能查源码，但必须查）：
## `rpc(...)` 少传一个 → 接收端形参不匹配 → 运行时才炸。
func test_rpc_call_sites_pass_three_arguments() -> void:
	var player_body := _strip_comments(_read_source(PLAYER_SRC))
	var i_rpc := player_body.find("NetworkManager.net_player_state.rpc(")
	check_true(i_rpc >= 0, "player.gd 应通过 NetworkManager.net_player_state.rpc(...) 广播")
	if i_rpc >= 0:
		var call := player_body.substr(i_rpc, 120)
		var open := call.find("rpc(")
		var close := call.find(")", open)
		var args := call.substr(open + 4, close - open - 4)
		check_eq(_count_top_level_args(args), 3,
			"net_player_state.rpc(...) 应传 3 个实参（global_position / rotation.y / health）")

	var net_body := _strip_comments(_read_source(NETWORK_SRC))
	var i_apply := net_body.find("node.apply_network_state(")
	check_true(i_apply >= 0, "network_manager.gd 应把载荷转发给 node.apply_network_state(...)")
	if i_apply >= 0:
		var call2 := net_body.substr(i_apply, 120)
		var open2 := call2.find("(")
		var close2 := call2.find(")", open2)
		var args2 := call2.substr(open2 + 1, close2 - open2 - 1)
		check_eq(_count_top_level_args(args2), 3,
			"转发给 apply_network_state 的实参个数必须与形参个数一致（否则运行期才炸）")


## 广播出去的第三个实参必须是**权威端的真值 `health`**（不是显示副本 `_display_health`）——
## 射手端转手再传给别人的时候，那一端的显示副本可能还没初始化。
func test_broadcast_sends_authoritative_health_not_display_copy() -> void:
	var body := _strip_comments(_read_source(PLAYER_SRC))
	var i_rpc := body.find("NetworkManager.net_player_state.rpc(")
	check_true(i_rpc >= 0, "player.gd 应广播状态")
	if i_rpc < 0:
		return
	var call := body.substr(i_rpc, 120)
	check_true(call.find(", health)") > 0 or call.find(", health,") > 0,
		"广播的第三个实参应是权威端真值 `health`（不是显示副本 `_display_health`）")
	check_true(call.find("_display_health") < 0,
		"不得把显示副本 `_display_health` 当作权威值广播出去")


func _method_arg_count(target: Object, method_name: String) -> int:
	# GDScript 资源要用 `get_script_method_list()`（`get_method_list()` 是 Node/Object 的接口，
	# 脚本资源上没有 → 会返回 -1 让断言假红）。
	var list: Array = []
	if target is GDScript:
		list = (target as GDScript).get_script_method_list()
	else:
		list = target.get_method_list()
	for m in list:
		if str(m.get("name", "")) == method_name:
			var args: Array = m.get("args", [])
			return args.size()
	return -1


## 顶层实参个数（忽略被圆括号包住的嵌套调用，如 `rpc(global_position, f(x), y)`）。
func _count_top_level_args(text: String) -> int:
	var depth := 0
	var count := 0
	var has_token := false
	for i in range(text.length()):
		var ch := text[i]
		if ch == "(":
			depth += 1
			if depth == 1:
				continue
		elif ch == ")":
			depth -= 1
			if depth == 0:
				break
		if depth == 0 and ch == ",":
			count += 1
		elif depth == 0 and ch.strip_edges() != "":
			has_token = true
	if has_token:
		count += 1
	return count


# ══════════════════════════════════════════════════════════════════════
#  ② 射手端不因远端扣血而本地扣血（C-18 教训的核心防线）
# ══════════════════════════════════════════════════════════════════════

## 收到远端血量 25 时：**本端 `health` 必须纹丝不动**，只有显示副本变。
func test_remote_health_does_not_deduct_local_health() -> void:
	var remote := _make_remote_player()
	if remote == null:
		return
	var before: float = remote.get_health()
	check_eq(before, remote.get_max_health(), "前置：远端节点在本端的 health 应仍是初始满血")

	remote.apply_network_state(Vector3(1.0, 0.0, 2.0), 0.5, 25.0)

	check_eq(remote.get_health(), before,
		"射手端收到远端掉血后，本地 `health` 绝不能变（受害端才是唯一真值）")
	check_eq(remote.get_display_health(), 25.0,
		"远端血量应写进**显示副本** `get_display_health()`")


## 即便远端血量归零，本端`health` 也不得变成 0（否则射手端会误判自己已死）。
func test_remote_health_reaching_zero_does_not_zero_local_health() -> void:
	var remote := _make_remote_player()
	if remote == null:
		return
	remote.apply_network_state(Vector3.ZERO, 0.0, 0.0)
	check_gt_f(remote.get_health(), 0.0,
		"远端血量归零不得让射手端本地 health 归零")
	check_eq(remote.get_display_health(), 0.0,
		"远端归零应如实显示为 0（射手端要看见「我把他打死了」）")


func check_gt_f(actual: float, minimum: float, message: String) -> void:
	assert_count += 1
	if not (actual > minimum):
		fail("%s（要求 > %s，实际 %s）" % [message, str(minimum), str(actual)])


# ══════════════════════════════════════════════════════════════════════
#  ③ 显示态不驱动本地死亡流程
# ══════════════════════════════════════════════════════════════════════

## 远端血量归零时：**不发 `died`、不进死亡状态（不屏蔽输入）**。
func test_remote_health_zero_does_not_emit_died() -> void:
	var remote := _make_remote_player()
	if remote == null:
		return
	remote.health_changed.connect(_on_health_changed)
	remote.died.connect(_on_died)
	remote.remote_health_changed.connect(_on_remote_health_changed)

	remote.apply_network_state(Vector3.ZERO, 0.0, 0.0)

	check_eq(_died_hits, 0, "远端掉血**不得**在射手端触发本地 `died` 信号（死亡流程是受害端权威）")
	check_eq(remote.input_blocked, false,
		"远端掉血**不得**让射手端进入死亡状态（`input_blocked` 必须仍为 false）")
	check_eq(_health_changed_hits, 0,
		"远端掉血**不得**复用 `health_changed`（它的语义是「本地权威血量真值变了」）")
	check_eq(_remote_health_events.size(), 1,
		"远端掉血应通过**独立的** `remote_health_changed` 信号通知（来源在类型上不可混淆）")
	if _remote_health_events.size() == 1:
		check_eq(float(_remote_health_events[0][0]), 0.0, "remote_health_changed 载荷应为收到的显示值")


## 独立信号这条不能被「优化」掉：合并回 `health_changed` 会让观测层把显示态误读成本端结算。
func test_remote_health_uses_a_separate_signal_from_health_changed() -> void:
	var remote := _make_remote_player()
	if remote == null:
		return
	var has_display_signal := false
	for s in remote.get_signal_list():
		if str(s.get("name", "")) == "remote_health_changed":
			has_display_signal = true
	check_true(has_display_signal, "player.gd 应声明独立的 `remote_health_changed` 显示信号")
	var body := _strip_comments(_read_source(PLAYER_SRC))
	var apply_body := _func_body(body, "func _apply_display_health")
	check_true(apply_body.find("remote_health_changed.emit") >= 0,
		"显示值变化应 emit `remote_health_changed`")
	# ⚠ 子串陷阱：`remote_health_changed.emit` **本身包含** `health_changed.emit`。
	#   直接 `find("health_changed.emit")` 会把自己判红（ES-4.2 踩过同款「锁搜到自己的注释/名字」）。
	#   正解：先把合法的 `remote_health_changed.emit` 全部剔除，再搜裸的 `health_changed.emit`。
	var without_display_signal := apply_body.replace("remote_health_changed.emit", "")
	check_true(without_display_signal.find("health_changed.emit") < 0,
		"显示值变化路径**不得** emit `health_changed`（那是本地权威血量真值的信号）")


## 本地玩家的 HUD 血条不得被远端显示态驱动。
## （运行时端到端：真 HUD 场景 + 本地玩家 + 远端玩家，驱动远端显示值后本地血条必须不动）
func test_local_hud_bar_is_not_driven_by_remote_display_health() -> void:
	var hud_scene: PackedScene = load(BARS_SCENE_PARENT) as PackedScene
	if hud_scene == null:
		fail("无法加载 %s" % BARS_SCENE_PARENT)
		return
	var player_scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	if player_scene == null:
		fail("无法加载 %s" % PLAYER_SCENE)
		return

	var local := player_scene.instantiate()
	local.name = "LocalPlayerForHealthSync"
	add_child(local) # authority == 本端 → 进 `player` 组，HUD 会绑它
	var remote := player_scene.instantiate()
	remote.name = "RemotePlayerForHealthSync"
	remote.set_multiplayer_authority(REMOTE_AUTHORITY)
	add_child(remote)

	var hud := hud_scene.instantiate()
	add_child(hud) # HUD._ready() → _bind() → 连本地 player 的 health_changed

	var bar: ProgressBar = hud.get_node_or_null("HealthRoot/HealthBar") as ProgressBar
	if bar == null:
		fail("HUD 场景缺少 HealthRoot/HealthBar")
		_free(hud); _free(remote); _free(local)
		return
	# 前置自证：HUD 确实绑上了本地玩家并读到了本地血量（否则下面的「没变」是假绿）
	check_near(bar.value, local.get_health(), 0.01,
		"前置：HUD 本地血条应已显示本地玩家的真实血量")

	remote.apply_network_state(Vector3.ZERO, 0.0, 10.0)

	check_near(bar.value, local.get_health(), 0.01,
		"远端显示态变化**不得**改动本地玩家的血条（HUD 血条只由本地权威血量驱动）")
	check_gt_f(local.get_health(), 0.0, "远端掉血不得改本地玩家血量")

	_free(hud)
	_free(remote)
	_free(local)


# ══════════════════════════════════════════════════════════════════════
#  ④⑤ 非法值丢弃 + clamp
# ══════════════════════════════════════════════════════════════════════

## NaN / ±INF / 负数 / 超 `max_health` → **整个丢弃并保持上一有效值**。
## ⚠ 用例逐个独立验证「保持上一有效值」，而不是只看「没变成 NaN」。
func test_invalid_display_health_is_discarded_keeping_last_valid() -> void:
	var remote := _make_remote_player()
	if remote == null:
		return
	remote.remote_health_changed.connect(_on_remote_health_changed)
	remote.apply_network_state(Vector3.ZERO, 0.0, 40.0)
	check_eq(remote.get_display_health(), 40.0, "前置：先收到一个合法值 40")

	var cases := {
		"负数": -5.0,
		"NaN": NAN,
		"+INF": INF,
		"-INF": -INF,
		"超max_health": 10000.0,
		"刚好超max_health": 100.5,
	}
	for label in cases.keys():
		_remote_health_events.clear()
		remote.apply_network_state(Vector3.ZERO, 0.0, float(cases[label]))
		check_eq(remote.get_display_health(), 40.0,
			"非法显示值（%s）应被丢弃并**保持上一有效值 40**" % label)
		check_eq(_remote_health_events.size(), 0,
			"非法显示值（%s）不应发 `remote_health_changed`（值没变，UI 不该被刷新）" % label)


## 合法边界值必须被接受（守卫不能过严，把 0 与满分也当非法）。
func test_valid_boundary_display_health_is_accepted() -> void:
	var remote := _make_remote_player()
	if remote == null:
		return
	remote.apply_network_state(Vector3.ZERO, 0.0, 0.0)
	check_eq(remote.get_display_health(), 0.0, "0 是合法显示值（对手被打到空血必须显示得出来）")
	remote.apply_network_state(Vector3.ZERO, 0.0, 100.0)
	check_eq(remote.get_display_health(), 100.0, "满血（== max_health）是合法显示值")


## clamp 是纵深防御：静态纯函数直接断言，且不依赖上游守卫是否被绕过。
func test_clamp_display_health_clamps_into_range() -> void:
	check_eq(PLAYER_SCRIPT.clamp_display_health(-5.0, 100.0), 0.0, "clamp 应把负数夹到 0")
	check_eq(PLAYER_SCRIPT.clamp_display_health(0.0, 100.0), 0.0, "clamp 应保持 0")
	check_eq(PLAYER_SCRIPT.clamp_display_health(55.5, 100.0), 55.5, "clamp 不应改动区间内的值")
	check_eq(PLAYER_SCRIPT.clamp_display_health(100.0, 100.0), 100.0, "clamp 应保持等于上限的值")
	check_eq(PLAYER_SCRIPT.clamp_display_health(1e9, 100.0), 100.0, "clamp 应把超上限值夹到上限")
	check_eq(PLAYER_SCRIPT.clamp_display_health(50.0, 0.0), 0.0,
		"上限为 0 时不得除零/爆值，应夹到 0")
	check_eq(PLAYER_SCRIPT.clamp_display_health(50.0, -10.0), 0.0,
		"上限为负数时 clamp 结果仍须落在 [0, 上限] 的合法域内（不得为负）")


## 不变式：无论收到什么值，写进显示副本的永远落在 `[0, max]`。
func test_display_health_always_stays_within_range() -> void:
	var remote := _make_remote_player()
	if remote == null:
		return
	var feed := [0.0, 1.0, 33.3, 99.9, 100.0, -1.0, 1e9, NAN, INF, -INF]
	for v in feed:
		remote.apply_network_state(Vector3.ZERO, 0.0, float(v))
		var shown: float = remote.get_display_health()
		check_true(shown >= 0.0 and shown <= remote.get_display_max_health(),
			"显示值必须恒在 [0, max] 内（收到 %s 时得到 %s）" % [str(v), str(shown)])


## 「未收到过广播」用负值表示 —— HUD 据此不画血条（宁可没有，不要先显示一条假血）。
func test_display_health_starts_unknown() -> void:
	var remote := _make_remote_player()
	if remote == null:
		return
	check_lt_f(remote.get_display_health(), 0.0,
		"尚未收到广播时显示值应为负（=未知），HUD 不应据此画血条")


func check_lt_f(actual: float, maximum: float, message: String) -> void:
	assert_count += 1
	if not (actual < maximum):
		fail("%s（要求 < %s，实际 %s）" % [message, str(maximum), str(actual)])


# ══════════════════════════════════════════════════════════════════════
#  ⑥ 纪律锁：显示态不参与任何胜负 / 计分判定
# ══════════════════════════════════════════════════════════════════════

## 按**语义**锁（字段 × 比较运算符组合枚举），不是搜单条字面量
## ——否则 `get("kills",0) > 0` 就能绕过（ES-4.2 变异 M3 首轮即存活）。
## 且必须**先剥注释**，否则本文件自己的纪律注释会把它自己判红。
func test_display_health_never_touches_scoring_or_death_flow() -> void:
	var src_bars := _strip_comments(_read_source(BARS_SRC))
	var src_player := _strip_comments(_read_source(PLAYER_SRC))

	var banned_fields := ["kills", "deaths", "_evaluate_winner", "score", "winner"]
	var operators := [" > ", " < ", ">=", "<=", "==", "!=", " >", " <"]
	for field in banned_fields:
		for op in operators:
			check_false(src_bars.find(field + op) >= 0,
				"enemy_health_bars.gd 不得出现 `%s%s`（显示态不参与计分判定）" % [field, op])
			check_false(src_player.find(field + op) >= 0,
				"player.gd 不得出现 `%s%s`（血量显示不参与胜负判定）" % [field, op])
	# 语义等价写法也要挡住：变量名可以换，字段名不能换
	for field in ["kills", "deaths", "winner_id"]:
		check_false(src_bars.find(field) >= 0,
			"enemy_health_bars.gd 不得提及 `%s`（纯显示控件不碰计分字段）" % field)


## 显示路径不得调用本地扣血 / 死亡流程。
func test_display_health_path_does_not_settle_or_kill_locally() -> void:
	var body := _strip_comments(_read_source(PLAYER_SRC))
	var apply_body := _func_body(body, "func _apply_display_health")
	var net_body := _func_body(body, "func apply_network_state")
	check_true(apply_body.find("take_damage") < 0,
		"_apply_display_health 不得调用 take_damage（射手端不本地扣血）")
	check_true(apply_body.find("_enter_dead_state") < 0,
		"_apply_display_health 不得调用 _enter_dead_state（死亡流程是受害端权威）")
	check_true(apply_body.find("died.emit") < 0,
		"_apply_display_health 不得 emit `died`")
	check_true(apply_body.find("set_input_blocked") < 0,
		"_apply_display_health 不得改 `input_blocked`（不得替受害端决定死亡界面）")
	for bad in ["take_damage", "_enter_dead_state", "died.emit", "respawn", "health -=", "health ="]:
		check_false(net_body.find(bad) >= 0,
			"apply_network_state 不得出现 `%s`（它只该更新显示副本）" % bad)
	# 唯一允许的写入口是显示副本本身
	check_true(apply_body.find("_display_health =") >= 0,
		"_apply_display_health 应把合法值写进显示副本 `_display_health`")
	# 守卫必须真的被调用（否则「非法值丢弃」这条只是注释）
	check_true(apply_body.find("_is_valid_display_health") >= 0,
		"_apply_display_health 必须先过合法性守卫再写显示值")
	# ⚠ clamp 必须**在调用路径上**，不只是「有个 clamp 函数存在」。
	#   变异测试 M1实测：把 `clamp_display_health(value, maximum)` 换成裸 `value`
	#   （静态函数仍在、纯函数用例照样全绿）→ 只测静态函数的断言是弱的。
	#   这里断言的是**调用点**，不是 token 存在。
	check_true(apply_body.find("clamp_display_health(") >= 0,
		"_apply_display_health 的写入路径必须真的经过 `clamp_display_health(...)`"
		+ "（只定义函数而不调用 = 没有纵深防御；变异 M1 曾因此存活）")
	# 且clamp 的结果才是被写进显示副本的那个值（不是clamp 完又用原值）
	var i_clamp := apply_body.find("clamp_display_health(")
	var i_assign := apply_body.find("_display_health =")
	if i_clamp >= 0 and i_assign >= 0:
		check_true(i_clamp < i_assign,
			"clamp 必须发生在写入显示副本**之前**（clamp 完又写原值等于没clamp）")
		var lhs := apply_body.substr(maxi(i_assign - 40, 0), 40)
		check_true(lhs.find("clamped") >= 0 or lhs.find("clamp") >= 0,
			"写进显示副本的应是 clamp 的结果（当前左侧：%s）" % lhs.strip_edges())


# ══════════════════════════════════════════════════════════════════════
#  ⑦ 30Hz 通道复用：加血量不得提高广播频率（带宽）
# ══════════════════════════════════════════════════════════════════════

## `NET_SYNC_INTERVAL` 仍是 0.033（≈30Hz），且广播仍被累加器门控。
## ⚠ 断言的是**顺序**：门控 `if` 必须在 `rpc(` 之前、累加器清零必须在两者之间——
##   只断言「常量还在」挡不住有人把 rpc 挪到门控外面（那就变成每帧广播）。
func test_sync_interval_unchanged_and_still_gated() -> void:
	check_near(PLAYER_SCRIPT.NET_SYNC_INTERVAL, 0.033, 0.0001,
		"NET_SYNC_INTERVAL 必须仍是 0.033 s（≈30Hz）——加血量不得提高广播频率")
	var body := _strip_comments(_read_source(PLAYER_SRC))
	var gate := body.find("if _net_accum >= NET_SYNC_INTERVAL")
	var rpc_call := body.find("NetworkManager.net_player_state.rpc(")
	var reset := body.find("_net_accum = 0.0")
	check_true(gate >= 0, "广播必须仍受 `if _net_accum >= NET_SYNC_INTERVAL` 门控（不能改成每帧广播）")
	check_true(rpc_call >= 0, "应存在广播调用点")
	if gate >= 0 and rpc_call >= 0:
		check_true(gate < rpc_call, "门控 if 必须在 rpc 调用**之前**（否则等于每帧广播）")
		check_true(reset > gate and reset < rpc_call,
			"累加器清零必须在门控与 rpc 之间（否则广播间隔会漂移）")


## 血量必须**搭��车**在既有广播里，不得新开一条 RPC（另开一条 = 每次受击多发一包 + 顺序混用）。
func test_health_rides_the_existing_broadcast_no_new_rpc() -> void:
	var net_body := _strip_comments(_read_source(NETWORK_SRC))
	var rpc_defs := 0
	var i := 0
	while true:
		var at := net_body.find("@rpc(", i)
		if at < 0:
			break
		rpc_defs += 1
		i = at + 5
	# 新增一条 RPC 会让这个数字 +1；当前 network_manager 共有 **7** 条
	#   （00_overview §7.2 表里列了 9 行，但 `net_fire_effects` 在 `weapon.gd`，不在本文件）。
	check_eq(rpc_defs, 7,
		"network_manager.gd 的 RPC 条数应仍为 7（血量搭既有广播的便车，未新开 RPC）")
	check_true(net_body.find("net_health") < 0,
		"不得新增独立的血量 RPC（ADR-008：复用 30Hz `net_player_state`）")
	# 且必须是 unreliable_ordered（ADR-002 的既有语义），不能顺手改成 reliable
	var head := net_body.substr(maxi(net_body.find("func net_player_state") - 200, 0), 200)
	check_true(head.find("unreliable_ordered") >= 0,
		"net_player_state 应保持 `unreliable_ordered`（ADR-002 既有语义，不因加血量而改）")


# ══════════════════════════════════════════════════════════════════════
#  ⑧ 契约锁：实现与文档一致
# ══════════════════════════════════════════════════════════════════════

## ADR-008 必须存在并写明「为什么合并进 30Hz 广播」+「受害端权威」两条口径。
func test_adr_008_records_the_channel_decision() -> void:
	var adr := _read_source(ADR_008)
	if adr.is_empty():
		fail("缺少 ADR-008（远程血量显示的通道选择必须留决策记录）")
		return
	check_true(adr.find("net_player_state") >= 0, "ADR-008 必须点名复用 `net_player_state`")
	check_true(adr.find("受害端") >= 0, "ADR-008 必须写明「受害端权威」口径")
	check_true(adr.find("unreliable_ordered") >= 0, "ADR-008 必须写明沿用 `unreliable_ordered` 语义")
	check_true(adr.find("Alternatives") >= 0 or adr.find("备选") >= 0,
		"ADR-008 必须给出备选方案（独立 reliable RPC 等）")
	check_true(adr.find("显示态") >= 0, "ADR-008 必须写明「显示态不驱动本地死亡流程」")


## 架构总览的 RPC 清单必须与实现一致（文档漂移是本项目已登记的主要失效模式）。
func test_overview_rpc_table_matches_implementation() -> void:
	var overview := _read_source(OVERVIEW)
	if overview.is_empty():
		fail("缺少 %s" % OVERVIEW)
		return
	var i := overview.find("`net_player_state`")
	check_true(i >= 0, "00_overview §7.2 的 RPC 清单必须列出 net_player_state")
	if i >= 0:
		var row := overview.substr(i, 260)
		check_true(row.find("unreliable_ordered") >= 0,
			"总览里 net_player_state 的注解应与实现一致（unreliable_ordered）")
		check_true(row.find("血量") >= 0,
			"总览里 net_player_state 的说明应已包含「血量」（否则文档漂移）")


## 敌方血条必须接在 HUD 上，且**只**读显示值。
func test_enemy_health_bars_wired_into_hud_and_read_only() -> void:
	var tscn := _read_source(BARS_SCENE_PARENT)
	check_true(tscn.find("enemy_health_bars.gd") >= 0, "hud.tscn 必须引用 enemy_health_bars.gd")
	check_true(tscn.find("EnemyHealthBars") >= 0, "hud.tscn 必须有 EnemyHealthBars 节点")
	var src := _strip_comments(_read_source(BARS_SRC))
	check_true(src.find("get_display_health") >= 0, "敌方血条必须读`get_display_health()`")
	check_true(src.find("take_damage") < 0, "敌方血条不得调用 take_damage（纯显示）")
	check_true(src.find("remote_health_changed.connect") < 0,
		"敌方血条按帧轮询显示值即可，不需要连信号（少一处生命周期耦合）")


# ══════════════════════════════════════════════════════════════════════
#  ⑨ 可见性保证：近距离时头顶锚点会被投影到屏幕之外（双端窗口实测发现的真实缺陷）
# ══════════════════════════════════════════════════════════════════════

const BARS_SCRIPT := preload("res://scripts/ui/enemy_health_bars.gd")

## ⚠ 本组用例的由来：双端窗口实测里探针打出`血条绘制矩形 pos=(926,-14)` ——
##   近距离（≈5 m）时头顶锚点 `head + 2.15 m` 投影到了**屏幕上方之外**，
##   **整条血条画在屏幕外、玩家完全看不见**，而数据层一切正常（血量确实在同步）。
##   ⇒ 这类缺陷 headless 必然测不出（`§4-10`），但**必须在headless 有锁**，
##     否则下一次调 `height_offset` / 相机 FOV 又会静默回归。
func test_bar_rect_is_clamped_into_viewport_when_anchor_is_above_screen() -> void:
	var viewport := Vector2(1920.0, 1080.0)
	var bar := Vector2(68.0, 7.0)
	# 复现实测值：anchor.y = -7（头顶投影已在屏幕上方之外）
	var rect: Rect2 = BARS_SCRIPT.bar_rect_for(Vector2(960.0, -7.0), viewport, bar)
	check_true(rect.size != Vector2.ZERO, "近距离锚点越界时仍应画出（只是夹到屏幕内），不能整个不画")
	check_ge(rect.position.y, 0.0, "血条顶边必须夹到屏幕内（实测缺陷：pos.y=-14 完全看不见）")
	check_le(rect.end.y, viewport.y, "血条底边不得超出屏幕下沿")
	check_ge(rect.position.x, 0.0, "血条左边不得超出屏幕")
	check_le(rect.end.x, viewport.x, "血条右边不得超出屏幕")


## 四个方向都要夹（不只上方）。
func test_bar_rect_clamps_on_all_four_sides() -> void:
	var viewport := Vector2(1920.0, 1080.0)
	var bar := Vector2(68.0, 7.0)
	var cases := {
		"左上越界": Vector2(-30.0, -30.0),
		"右上越界": Vector2(2000.0, -30.0),
		"左下越界": Vector2(-30.0, 1200.0),
		"右下越界": Vector2(2000.0, 1200.0),
	}
	for label in cases.keys():
		var rect: Rect2 = BARS_SCRIPT.bar_rect_for(cases[label], viewport, bar)
		check_true(rect.size != Vector2.ZERO, "%s：仍应画出（夹进视口）" % label)
		check_true(rect.position.x >= 0.0 and rect.position.y >= 0.0 \
				and rect.end.x <= viewport.x and rect.end.y <= viewport.y,
			"%s：血条必须完整落在视口内（实际 %s）" % [label, str(rect)])


## 视口内正常位置**不被夹取挪动**（夹取不能把居中的条推到角落）。
func test_bar_rect_not_moved_when_anchor_is_inside_viewport() -> void:
	var viewport := Vector2(1920.0, 1080.0)
	var bar := Vector2(68.0, 7.0)
	var anchor := Vector2(960.0, 500.0)
	var rect: Rect2 = BARS_SCRIPT.bar_rect_for(anchor, viewport, bar)
	check_eq(rect.position, Vector2(926.0, 493.0), "视口内的锚点应按原公式定位，不被夹取挪动")
	check_eq(rect.size, bar, "条的尺寸不应被夹取改变")


## 关掉夹取时应恢复「原公式」（证明夹取确实是这个函数做的，不是别处顺手补的）。
func test_bar_rect_without_clamping_keeps_raw_formula() -> void:
	var viewport := Vector2(1920.0, 1080.0)
	var bar := Vector2(68.0, 7.0)
	var raw: Rect2 = BARS_SCRIPT.bar_rect_for(Vector2(960.0, -7.0), viewport, bar, false)
	check_eq(raw.position.y, -14.0, "clamp_to_viewport=false 时应保留原公式（实测值 -14）")
	var clamped: Rect2 = BARS_SCRIPT.bar_rect_for(Vector2(960.0, -7.0), viewport, bar, true)
	check_true(clamped.position.y != raw.position.y,
		"clamp_to_viewport=true 时必须与原公式不同（否则夹取没生效）")


## 越界太远（远超一屏）时不画 —— 与「近处夹进来」区分开。
func test_bar_rect_empty_when_anchor_far_outside_viewport() -> void:
	var viewport := Vector2(1920.0, 1080.0)
	var bar := Vector2(68.0, 7.0)
	check_true(BARS_SCRIPT.bar_rect_for(Vector2(99999.0, 540.0), viewport, bar).size == Vector2.ZERO,
		"锚点远超一屏时应整个不画（而不是夹到屏幕角落误导玩家）")
	check_true(BARS_SCRIPT.bar_rect_for(Vector2(960.0, -99999.0), viewport, bar).size == Vector2.ZERO,
		"锚点远超一屏（纵向）时应整个不画")


## 生产代码的 `_draw()` 必须真的用这个纯函数（否则改了纯函数、实际绘制仍是老逻辑）。
func test_draw_uses_the_shared_rect_function() -> void:
	var src := _strip_comments(_read_source(BARS_SRC))
	check_true(src.find("bar_rect_for(") >= 0,
		"_draw() 必须调用 bar_rect_for(...)（夹取逻辑集中在纯函数里，别在_draw 里另写一份）")
	var draw_body := _func_body(src, "func _draw()")
	check_true(draw_body.find("bar_rect_for") >= 0,
		"绘制路径必须走 bar_rect_for（否则纯函数被改、实际绘制不变 = 假守护）")


## 可读性（`04_ux_flow §6` Standard）：明度对比为主 + 非颜色第二线索。
func test_enemy_health_bars_has_brightness_and_non_color_cues() -> void:
	var src := _read_source(BARS_SRC)
	# 明度对比：底衬与填充的明度差必须够大（AC-F4 的口径）
	check_true(src.find("back_color") >= 0 and src.find("fill_color") >= 0,
		"必须同时定义底衬色与填充色（明度对比是主要可读性来源）")
	# 非颜色线索：刻度缺口 + 数字读数
	check_true(src.find("draw_string") >= 0, "必须有数字读数（第二线索）")
	check_true(src.find("low_health_ratio") >= 0,
		"低血必须有独立呈现（但不得只靠颜色）")

	# ⚠ 语义锁（不是 token 存在）：`notch_width` 在文件里出现两次 ——
	#   ① 顶部 `@export` **声明**、② `_draw_one_bar` 里**真的拿它画缺口**。
	#   只搜① 的话，变异 M9（删掉整个绘制循环）照样全绿 —— 实测存活过一次。
	#   正解：断言**绘制函数体内**用到了 notch_width，且刻度循环还在。
	var body := _strip_comments(_func_body(src, "func _draw_one_bar"))
	check_true(body.find("notch_width") >= 0,
		"刻度缺口必须真的在`_draw_one_bar` 里被画出来（只在 @export 声明 = 没有刻度）")
	check_true(body.find("range(1, 4)") >= 0,
		"`_draw_one_bar` 必须保留每25% 一道的刻度循环（血量越低露出越多 = 形状线索）")
	# 缺口必须画成矩形（真形状），而不是只改个颜色
	check_true(body.find("draw_rect") >= 0 and body.find("Vector2(notch_width") >= 0,
		"刻度缺口应以`notch_width` 为宽度画成矩形（形状线索，不是纯颜色变化）")
