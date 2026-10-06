extends TestSuite
## C-18 · 联机击杀归因链路回归基线（G4「比分一致 / 15 杀结算」的前置闸门）
##
## 缺陷出处：2026-10-06 第二次 G4 双人联机实测——两端都在正常扣血、正常阵亡
##   （`player_health_changed hp=75→50→25→0` + `player_died` 反复出现），
##   但 `score_changed scores={1:{kills:0,deaths:0}, <peer>:{kills:0,deaths:0}}` **永远不变**。
##
## 根因：`weapon.gd::_deal_damage()` 用**射手端本地的 `collider.health`** 判定是否击杀：
##   ```gdscript
##   var killed := hp_before != null and float(hp_before) - damage <= 0.0
##   ```
##   而远程玩家的血量**只在受害端结算**（`apply_network_damage` 是 `call_remote`，血量不回传
##   射手端）→ 射手端持有的对方血量恒为满值 100 → `100 - 25 <= 0` 恒为 false →
##   `killed` 恒假 → `_report_kill_if_player()` 从不执行 → 比分恒 0、15 杀永不触发结算。
##
## 修复口径（权威端判定 + 回传确认，A.4 契约不变）：
##   受害端 `player.gd::apply_network_damage()` 是全场唯一知道血量真值的地方，
##   归零时 `net_confirm_kill.rpc_id(射手 peer id)` 回传；射手端 `net_confirm_kill()`
##   再走既有 `_report_local_kill()` → A.4 `report_kill` 上报房主。
##   ⚠ 绕一跳而不是让受害端直接上报：A.4 语义是「**击杀者**上报，房主用
##     `get_remote_sender_id()` 反查击杀者」；若受害端上报，归因会反成「受害者是击杀者」。
##
## 本 suite 锁三条不变量（源码结构断言 + 纯逻辑断言）：
##   ① 射手端**不得**拿自己那份远端血量判生死（`killed` 对远程玩家恒假是**已知且正确**的）；
##   ② 受害端必须在归零时回传确认，且一个死亡周期只回传一次（否则重复计分）；
##   ③ 回传后仍走 A.4 原路径（房主信任模型 / 归因方向都不变）。
##
## 断言口径（ES-4 收尾时按变异测试结果加固，见下）：
##   ②③ 两条不变量**必须锁到「表达式 / 守卫语义」一级**，不能只锁「token 存在」或「求值顺序」——
##   顺序正确的 `var was_alive := false`、以及被摘掉的 `if victim_id < 0:` 都曾让本 suite 全绿，
##   而两者都会让 C-18 原缺陷复发。`_line_with` / `_has_cmp_zero` / `_strip_comment` 是为此加的
##   语义级工具（§4-13：先剥注释、按语义锁，而不是搜单条字面量）。
##   长期回归：`tools/mutation_c18_probe.py`（15 变异体：13 杀伤 + 2 守恒对照 / 0 存活0 误杀）。
##
## 曾有的第4 条「观测层必须能看到这条链路」已随 `scripts/debug/match_debug_probe.gd`
##   一并删除（EP-4 落地收尾）：该临时旁路的立项条件写明「EP-4 HUD 落地后须整体删除」。
##   它的观测职责现由 HUD 承担（比分板 ← `score_changed`、结算面板 ← `match_ended`、
##   击杀日志 / 死亡界面 ← `died`）。⚠ **不要因为「想看日志」而把它加回来**——
##   临时 `print` 旁路会让 G4 的判据重新依赖「人肉看stdout」，而 UI 已经是更可靠的出口。
##   ⚠ 若将来给 `remote_kill_confirmed` 补消费者，优先补**玩家可见的击杀日志**（UI 侧），
##   而非新的调试 print。

const WEAPON_SRC := "res://scripts/shooting/weapon.gd"
const KNIFE_SRC := "res://scripts/shooting/knife.gd"
const PLAYER_SRC := "res://scripts/player.gd"


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## 找 func 体的近似区间（从 `func xxx` 到下一个顶层 `func `/`## ` 段首），只做结构断言。
func _func_body(src: String, header: String) -> String:
	var i := src.find(header)
	if i < 0:
		return ""
	var j := src.find("\nfunc ", i + 1)
	if j < 0:
		return src.substr(i)
	return src.substr(i, j - i)


## 剥掉**行尾注释**，只保留 `#` 之前的代码部分（§4-13(a)）。
## ⚠ 不能「有 `#` 就整行丢」——那会把 `xxx(true) # 注释` 的代码也丢掉，
##   导致代码明明在、纪律锁却报「没调用」（ES-4.2 实测）。
##已知局限：字符串字面量里的 `#` 会被误当注释起点（本suite 断言的两个函数体内无此写法）。
func _strip_comment(line: String) -> String:
	var i := line.find("#")
	if i < 0:
		return line
	return line.substr(0, i)


## 返回**第一条**（已剥注释的）含 `token` 的单行代码；找不到返回 ""。
func _line_with(src: String, token: String) -> String:
	for raw in src.split("\n"):
		var code := _strip_comment(raw)
		if code.find(token) >= 0:
			return code
	return ""


## 该行是否是「`health` 与 `0` 的比较」（**两侧顺序无关**）。
## ⚠ **不能只搜字面量 `> 0`**：那会把等价改写 `0.0 < health` 误杀（守恒对照实测）。
##   口径：正反两个方向都认`health <op> 0` 与 `0 <op> health`（`<op>` ∈ 6 种比较符）。
##   → `health > 0.0` / `0.0 < health` / `health >= 0` 全部通过；
##     而 `false` / `true`（无 health）/ `health > 100.0`（右侧不是 0）仍转红。
## 该行是否是「`var_name` 与 `0` 的比较」（**两侧顺序无关**）。
## ⚠ 三个正则陷阱（均由单元测试/守恒对照实测捕获，改动前务必保留这些约束）：
##   ① 写成 `0` 会匹配 `0.5` 的前缀 → 「阈值改成 0.5」的变异会逃过；
##      故用 `0(?:\.0+)?(?![\d.])` 断尾。
##   ② 只搜 `> 0` 单一字面量会误杀等价改写 `0.0 < health`（守恒对照实测）。
##   ③ **被比较的变量名必须参数化**：早期版本把 `health` 写死在函数里，
##      又拿它去校验 `victim_id < 0` 守卫 → 该断言恒假、verify 直接转红。
##      故此处按「字段 × 运算符 × 方向」枚举，而非针对某个变量硬编码。
func _has_cmp_zero(code: String, var_name: String = "health") -> bool:
	var zero := "0(?:\\.0+)?(?![\\d.])"
	var ops := "(?:>=|<=|==|!=|>|<)"
	var re := RegEx.new()
	# 方向一：变量在左；方向二：0 在左（两侧顺序无关）
	re.compile(var_name + "\\s*" + ops + "\\s*" + zero)
	if re.search(code) != null:
		return true
	re.compile(zero + "\\s*" + ops + "\\s*" + var_name)
	return re.search(code) != null


# ---------------------------------------------------------------------------
# ① 射手端不得用本地（陈旧）血量判生死
# ---------------------------------------------------------------------------

## `_deal_damage` 的文档必须写明「联机下 killed 对远程玩家恒假」，否则下一个人会重蹈覆辙。
func test_deal_damage_documents_that_killed_is_unreliable_online() -> void:
	var body := _func_body(_read_source(WEAPON_SRC), "func _deal_damage")
	check_true(body.find("_report_kill") < 0 or body.find("恒为 false") >= 0 or body.find("恒假") >= 0
		or body.find("别把 `killed`") >= 0 or body.find("killed` 当成") >= 0,
		"weapon.gd::_deal_damage 必须注释说明：联机下 killed 对远程玩家恒假（不可当致死判据）")


## 结构性防线：`_hitscan` 里的上报调用必须**在 `_deal_damage` 之外**（即由确认回传驱动），
##   且远程玩家分支不得再走 `take_damage` 本地扣血。
func test_shooter_does_not_settle_remote_health_locally() -> void:
	var src := _read_source(WEAPON_SRC)
	var body := _func_body(src, "func _deal_damage")
	check_true(body.find("apply_network_damage.rpc_id") >= 0,
		"远程玩家伤害必须走 apply_network_damage.rpc_id（受害端结算）")
	check_true(body.find("_shooter_peer_id()") >= 0,
		"apply_network_damage 的第二实参应为射手 peer id（受害端据此回传致死确认）")


## knife.gd 必须与 weapon.gd 同一口径（否则近战在联机下同样不计分）。
func test_knife_passes_shooter_peer_id() -> void:
	var src := _read_source(KNIFE_SRC)
	var i := src.find("func _perform_hit")
	if i < 0:
		i = src.find("apply_network_damage.rpc_id")
	check_true(src.find("get_multiplayer_authority(), damage") >= 0,
		"knife.gd 调用 apply_network_damage 时也应传开火者 peer id")


# ---------------------------------------------------------------------------
# ② 受害端权威判定 + 只回传一次
# ---------------------------------------------------------------------------

## `apply_network_damage` 签名必须收 shooter peer id（不再是只用来显示的 _shooter: String）。
func test_apply_network_damage_takes_shooter_peer_id() -> void:
	var src := _read_source(PLAYER_SRC)
	var i := src.find("func apply_network_damage")
	check_true(i >= 0, "player.gd 应有 apply_network_damage（玩家身份契约方法，ADR-007）")
	if i < 0:
		return
	var sig := src.substr(i, 120)
	check_true(sig.find("shooter_peer_id: int") >= 0,
		"apply_network_damage 第二形参应为 shooter_peer_id: int（int 才能定位回传目标）")


## 致死确认：受害端必须在 `health <= 0` 时回传，且用「本轮是否还活着」保证只发一次。
## ⚠ 断言的是**顺序**而非「有没有 was_alive 这个词」：`var was_alive` 必须在 `take_damage`
##   **之前**求值（= 挨枪前的血量），否则取到的是扣血后的值 → 恒为 false → 确认永不回传。
##   这正是本次缺陷的形态：变量在、确认代码在，但求值时机错了 → 比分恒 0。
##   （用「token 存在」断言的版本已被变异测试证伪：把 was_alive 改成恒 false 仍全绿。）
func test_victim_confirms_kill_once_on_death() -> void:
	var src := _read_source(PLAYER_SRC)
	var body := _func_body(src, "func apply_network_damage")
	check_true(body.find("net_confirm_kill.rpc_id") >= 0,
		"受害端归零后必须 net_confirm_kill.rpc_id 回传射手端（射手端本地血量不可信）")
	var i_snapshot := body.find("var was_alive")
	var i_damage := body.find("take_damage(amount)")
	check_true(i_snapshot >= 0, "apply_network_damage 应在扣血前记录 was_alive（死亡瞬间守卫）")
	check_true(i_damage >= 0, "apply_network_damage 应调用 take_damage")
	if i_snapshot >= 0 and i_damage >= 0:
		check_true(i_snapshot < i_damage,
			"var was_alive 必须在 take_damage 之前求值（取挨枪前的血量），否则确认永不回传")
	# ── 表达式本身（不止顺序）：`var was_alive` 的**右边**必须真的是「本轮是否还活着」──
	# ⚠ 上一条顺序断言单独用时**不足**：`var was_alive := false`（顺序完全正确）曾让本用例全绿，
	#   因为顺序断言与「token 存在」都只认`var was_alive` 这个词，不看它被赋成什么。
	#   而恒false 会让守卫 `was_alive and health <= 0.0` 恒假 → 确认永不回传 → 比分恒 0（= C-18 复发）。
	# 口径：按语义锁「health 与 0 的比较」，而非字面量 `health > 0.0`，
	#   这样 `0.0 < health` 等价改写仍通过、但 `false` / `true` / 改阈值（`> 100.0`）都会转红。
	var decl := _line_with(body, "var was_alive")
	check_true(decl.find("health") >= 0,
		"was_alive 必须由 health 求值（`var was_alive := false` 会让死亡瞬间守卫恒假、确认永不回传）")
	check_true(_has_cmp_zero(decl),
		"was_alive 的求值必须是「health 与 0 的比较」（如 `health > 0.0`），不能是常量或改过的阈值")
	# 回传条件必须真的依赖 was_alive（而不是恒假 / 恒真的死表达式）
	var cond := ""
	var i_cond := body.find("if was_alive")
	if i_cond >= 0:
		cond = body.substr(i_cond, 60)
	check_true(cond.find("health <= 0.0") >= 0,
		"回传守卫应为 `was_alive and health <= 0.0`（仅死亡瞬间回传一次，避免重复计分）")


## 回传确认的接收端必须转调 A.4 原路径（不得自行改写归因口径）。
func test_confirm_routes_through_score_manager_report() -> void:
	var src := _read_source(PLAYER_SRC)
	var body := _func_body(src, "func net_confirm_kill")
	check_true(body.find("_report_local_kill") >= 0,
		"net_confirm_kill 必须转调 ScoreManager._report_local_kill（复用 A.4 权威端直调 / 客户端 rpc_id(1,…) 两条既有路径）")
	check_true(body.find("resolve_victim_id") >= 0,
		"net_confirm_kill 必须用 ScoreManager.resolve_victim_id 解析被击倒者（节点名 = peer id）")


## ⚠ 上一条只锁「用到了 resolve_victim_id」，**没锁它的失败分支**——
##   把 `if victim_id < 0:` 改成 `if false:` 曾让本用例全绿（ES-4收尾变异测试实测）。
##   后果不是「少上报」而是**上报错人**：`resolve_victim_id` 对非玩家节点返回 `-1`，
##   守卫一旦失效，`_report_local_kill(-1)` 会把这次击杀算到房主id=-1 的假账上，
##   而 A.4 的信任模型（`get_remote_sender_id()` 反查击杀者）**不会**拦下它。
##   → 因此这里必须按语义锁「`victim_id` 与负数比较 + 守卫成立时 return」。
func test_net_confirm_kill_guards_invalid_victim_id() -> void:
	var src := _read_source(PLAYER_SRC)
	var body := _func_body(src, "func net_confirm_kill")
	check_true(body.find("resolve_victim_id") >= 0,
		"net_confirm_kill 应先解析 victim_id（否则本用例的守卫无从谈起）")
	# 守卫条件行：含 `victim_id` 且与 0 比较（允许 `< 0` / `<= 0`）。
	# ⚠ 不能只 `find("victim_id < 0")`：那是字面量锁，`victim_id <= 0` 这类等价写法会被误杀。
	var guard := _line_with(body, "if victim_id")
	check_true(guard.find("victim_id") >= 0 and _has_cmp_zero(guard, "victim_id"),
		"net_confirm_kill 必须校验 `victim_id < 0`（非玩家节点 resolve 出 -1，不校验会把击杀算到假账上）")
	# 守卫成立必须 `return` 早退，不能继续往下调 _report_local_kill。
	# 取守卫行之后的一小段（到下一个 func / 段末），要求其首个非空行是 return。
	var after := ""
	var gi := body.find("if victim_id")
	if gi >= 0:
		after = body.substr(gi, 160)
	var first_stmt := ""
	for raw in after.split("\n"):
		var code := _strip_comment(raw).strip_edges()
		if code == "" or code.begins_with("if victim_id"):
			continue
		first_stmt = code
		break
	check_true(first_stmt.begins_with("return"),
		"victim_id 非法时应`return` 早退（否则 _report_local_kill(-1) 会把击杀记到假账上）")


## net_confirm_kill 必须是 RPC（否则跨端收不到），且带 authority 语义。
func test_net_confirm_kill_is_an_rpc() -> void:
	var src := _read_source(PLAYER_SRC)
	var i := src.find("func net_confirm_kill")
	check_true(i >= 0, "player.gd 应有 net_confirm_kill")
	if i < 0:
		return
	# RPC 注解在 func 上一行；取 i 之前的一小段
	var head := src.substr(maxi(i - 200, 0), 200)
	check_true(head.find("@rpc") >= 0,
		"net_confirm_kill 必须是 @rpc 方法（受害端 → 射手端的跨端确认）")
	check_true(head.find("\"authority\"") >= 0 or head.find("call_remote") >= 0,
		"net_confirm_kill 应为 call_remote（受害端本地不重复执行计分）")
