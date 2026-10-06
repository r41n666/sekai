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


# ---------------------------------------------------------------------------
# ③ 观测层必须能看到这条链路（否则同一个缺陷还会再隐身一次）
# ---------------------------------------------------------------------------

## 观测层要打印 `kill_confirmed`，否则「扣血正常但比分恒 0」在日志里完全不可见。
func test_probe_observes_kill_confirmation() -> void:
	var f: FileAccess = FileAccess.open("res://scripts/debug/match_debug_probe.gd", FileAccess.READ)
	if f == null:
		pending("观测层文件不存在（EP-4 落地后已按设计删除）")
		return
	var src := f.get_as_text()
	check_true(src.find("remote_kill_confirmed") >= 0,
		"观测层应监听 remote_kill_confirmed（G4 判定「击杀是否被计分」的唯一出口）")
	check_true(src.find("kill_confirmed") >= 0,
		"观测层应打印 kill_confirmed 事件，供双端日志对照")
