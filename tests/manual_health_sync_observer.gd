extends Node
## Task #10 · 双端窗口实测的**观察者**（挂在 `get_tree().root` 下，活过场景切换）
##
## 职责：等对局场景起来 → 把远端玩家摆到本端相机视野内 → 沿**真实伤害路径**打4 枪
## → **读回本端看到的敌方血条数值** → 打印对照表 + 存截图 + 断言。
##
## ⚠ 只做「观察 + 施加伤害 + 摆位」，**不改任何生产逻辑**。
##
## ⚠⚠ **只有房主开火，客户端只观察** —— 这条是本探针的**关键设计**，第一版让两端同时开火，
##   结果**断言全红但代码是对的**：两端互射 → 各自端「本地权威血量下降」是**真实 incoming 伤害**
##   （完全正确的行为），却被「射手端不该本地扣血」这条断言误判为污染。
##   ⇒ 单向开火才能把两件事分开：
##     · 房主端 = **射手**：本地权威血量必须**恒为满**（若下降 = 远端掉血污染了本地，正是 C-18 反面）
##     · 客户端 = **受害端**：本地权威血量应真实下降，且**射手端那边**的显示值同步下降
## ⚠ 全程**不用 await**（`control_checklist`：本项目 TestSuite/探针里 `await` 不可靠），
##   一律用帧计数推进状态机。

const GAME_SCENE := "Main"
## 与 `enemy_health_bars.gd` 的默认值保持一致（改一处必须同步改另一处）
const BAR_HEIGHT_OFFSET := 2.15
const BAR_WIDTH := 68.0
const BAR_HEIGHT := 7.0
const CAMERA_GROUP := "camera"
const PREVIEW_DIR := "res://_healthsync_tmp"
const ROLE_HOST := "host"
const ROUNDS := 4#打 4 枪（每枪 25 伤害 → 100/75/50/25/0）
const DAMAGE := 25.0
const FRAMES_WAIT_PLAYERS := 30# 等 NetworkManager 拿到 2 人
const FRAMES_SCENE_SETTLE := 60# 等对局场景与玩家节点就绪
const FRAMES_AIM_MAX := 240# 等远端进入画面的上限
const FRAMES_PER_SHOT := 24# 每枪间隔（> 30Hz 广播周期 0.033 s，留足余量）
const FRAMES_SETTLE_AFTER_SHOT := 12# 命中后等血量回传
## 最后一枪后的**收尾等待**（帧）：受害端扣血后要等它的下一次 ~30Hz 广播传回射手端才拿得到 0。
## 12 帧 ≈0.2 s 有时刚好卡在广播间隙 → 最后一枪读数采不到（实测「仍显示 25.0，未看到归零」）。
const FRAMES_SETTLE_FINAL := 120## ≈2 s，足够覆盖 6+ 个广播周期（轮询式等待，留足余量）
const TOTAL_FRAMES_LIMIT := 3600# 兜底退出（防挂死，按帧）
## 兜底**秒数**上限。⚠ 为什么要按秒而不是按帧：headless 与窗口模式的帧率差异很大，
##   用「帧数当超时」会误判（本项目已踩：房主 180 帧 ≈3 s 就退了，客户端 3 s 后才启动
##   → 必然连不上，看起来像「网络不通」，实际是探针自己的竞态）。
const TOTAL_SECONDS_LIMIT := 90.0
## 等对手加入 / 等连上服务器的秒数上限（ENet 建联实测 ≈0.1 s，这里给足余量）
const CONNECT_WAIT_SECONDS := 40.0

## 状态机
const P_WAIT_HOST := 0##房主：等人到齐 → 开局
const P_WAIT_SCENE := 1## 等 main.tscn
const P_AIM := 2## 摆位直到远端进画面
const P_FIRE := 3## 开火
const P_OBSERVE := 4## 受害端：只观察（不开火）
const P_DONE := 5

var _role := "host"
var _preview_dir := PREVIEW_DIR
var _phase := P_WAIT_HOST
var _frames := 0
var _phase_frames := 0
var _round := 0
var _local = null  ## PlayerController（duck-typing，故意不加类型标注）
var _remote = null  ## 远端 PlayerController（duck-typing）
var _failures: Array[String] = []
var _display_readings: Array[float] = []
var _shot_pending := false
var _elapsed := 0.0
var _wait_host_seconds := 0.0
## 受害端记录的本地权威血量下降序列
var _victim_readings: Array[float] = []
var _last_own_health := 100.0
## 最后一枪后的收尾等待计数（-1 = 未进入收尾）
var _final_wait := -1
## 各次截图对应的血条绘制矩形（截图时按它精确裁剪）
var _bar_rects: Dictionary = {}
## 本枪开火前的本端权威血量（跨函数传递：_fire_step 采样、_after_shot 断言）
var _before_local := -1.0


func setup(role: String, preview_dir: String) -> void:
	_role = role
	_preview_dir = preview_dir


func _process(delta: float) -> void:
	_frames += 1
	_phase_frames += 1
	_elapsed += delta
	_wait_host_seconds += delta
	if _elapsed > TOTAL_SECONDS_LIMIT:
		_fail("超过 %.0f 秒上限仍未完成（phase=%d）" % [TOTAL_SECONDS_LIMIT, _phase])
		_finish()
		return
	match _phase:
		P_WAIT_HOST:
			_wait_host()
		P_WAIT_SCENE:
			_wait_scene()
		P_AIM:
			_aim_step()
		P_FIRE:
			_fire_step()
		P_OBSERVE:
			_observe_step()
		P_DONE:
			pass


func _say(line: String) -> void:
	print("[HS]%s %s" % [_role, line])


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[HS]%s   ✗ %s" % [_role, msg])


# ── 房主：等客户端到齐后开局 ────────────────────────────────────────────
func _wait_host() -> void:
	if _role != ROLE_HOST:
		# 客户端：`_start_match` RPC 会把本端切到 main.tscn（NetworkManager 内部做的）。
		# 所以这里**直接进入 P_WAIT_SCENE 等场景切换** —— 早期版本留在 P_WAIT_HOST 里干等，
		# 结果永远不去检查场景 → 40 秒后误报「连接失败」（探针 bug，不是被测代码的问题）。
		_phase = P_WAIT_SCENE
		_phase_frames = 0
		_wait_host_seconds = 0.0
		return
	var ids: Array = NetworkManager.get_players().keys()
	if ids.size() < 2:
		if _wait_host_seconds > CONNECT_WAIT_SECONDS:
			_fail("房主在 %.0f 秒内没等到客户端加入" % CONNECT_WAIT_SECONDS)
			_finish()
		return
	_say("已集齐 %d 名玩家（%s），开始对战…" % [ids.size(), str(ids)])
	NetworkManager.host_start_match()
	_phase = P_WAIT_SCENE
	_phase_frames = 0
	_wait_host_seconds = 0.0


# ── 等对局场景 + 玩家节点就绪 ──────────────────────────────────────────
func _wait_scene() -> void:
	if _phase_frames < FRAMES_WAIT_PLAYERS and _role == ROLE_HOST:
		return
	var scene := get_tree().current_scene
	if scene == null or scene.name != GAME_SCENE:
		if _wait_host_seconds > CONNECT_WAIT_SECONDS:
			_fail("对局场景未加载（current_scene=%s）"
				% ("null" if scene == null else str(scene.name)))
			_finish()
		return
	if _phase_frames < FRAMES_SCENE_SETTLE:
		return
	if not _bind_players():
		return
	var mine := int(NetworkManager.multiplayer.get_unique_id())
	_say("对局就绪：本端 peer=%d，远端 peer=%s" % [mine, str(_remote.name)])
	_last_own_health = float(_local.get_health())
	_say("远端显示血量初始值=%.1f（<0 = 尚未收到广播），本端权威血量=%.1f（角色=%s）"
		% [_display(), _last_own_health, "射手·开火方" if _role == ROLE_HOST else "受害端·只观察"])
	if _role == ROLE_HOST and not is_equal_approx(_last_own_health, _local.get_max_health()):
		_say("  （注：本端起始血量非满 —— 场景里的 bot 先打过本端一枪，属真实 incoming 伤害，不影响本Story 判定）")
	_phase = P_AIM
	_phase_frames = 0


func _bind_players() -> bool:
	var scene := get_tree().current_scene
	var players: Node = scene.get_node_or_null("Players")
	if players == null:
		return false
	var mine := int(NetworkManager.multiplayer.get_unique_id())
	_local = null
	_remote = null
	for child in players.get_children():
		if int(child.name) == mine:
			_local = child
		else:
			_remote = child
	if _local == null or _remote == null:
		return false
	if not _remote.has_method("get_display_health"):
		_fail("远端玩家节点缺少 get_display_health()")
		_finish()
		return false
	if scene.get_node_or_null("HUD/EnemyHealthBars") == null:
		_fail("HUD 下未找到 EnemyHealthBars 节点")
		_finish()
		return false
	return true


func _display_max() -> float:
	if _remote != null and _remote.has_method("get_display_max_health"):
		return float(_remote.call("get_display_max_health"))
	return 100.0


func _display() -> float:
	if _remote == null or not _remote.has_method("get_display_health"):
		return -1.0
	return float(_remote.call("get_display_health"))


# ── 摆位：远端玩家由 30Hz 广播驱动（本端改不动）→ 改本端相机与站位 ──────
func _aim_step() -> void:
	var cam: Camera3D = get_tree().get_first_node_in_group("camera") as Camera3D
	if cam == null or _remote == null:
		return
	var flat: Vector3 = _remote.global_position - _local.global_position
	flat.y = 0.0
	if flat.length() < 0.01:
		return
	var away: Vector3 = flat.normalized()
	# 本端是权威 → global_position 每帧被本地物理覆盖，必须每帧重摆
	_local.global_position = _remote.global_position - away * 5.0 + Vector3(0.0, 0.3, 0.0)
	var pivot: Node3D = _local.get_node_or_null("CameraPivot")
	if pivot != null:
		pivot.rotation.y = atan2(-flat.x, -flat.z)
	if _phase_frames % 15 != 0:
		return
	var head: Vector3 = _remote.global_position + Vector3.UP * 1.6
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var in_view: bool = not cam.is_position_behind(head) \
		and cam.unproject_position(head).x > 0.0 and cam.unproject_position(head).y > 0.0 \
		and cam.unproject_position(head).x < vs.x and cam.unproject_position(head).y < vs.y
	if in_view:
		# 房主 = 射手（开火）；客户端 = 受害端（只观察，见文件头「只有房主开火」）
		if _role == ROLE_HOST:
			_say("远端玩家已进入画面（head 屏幕坐标=%s，视口=%s），开始开火"
				% [str(cam.unproject_position(head)), str(vs)])
			_phase = P_FIRE
		else:
			_say("远端玩家已进入画面（head 屏幕坐标=%s，视口=%s），本端为受害端·只观察"
				% [str(cam.unproject_position(head)), str(vs)])
			_phase = P_OBSERVE
		_phase_frames = 0
	elif _phase_frames > FRAMES_AIM_MAX:
		_fail("远端玩家始终不在画面内（head=%s 相机=%s）→ 无法验证血条可见性"
			% [str(head), str(cam.global_position)])
		_finish()


# ── 受害端：只摆位 + 观察本地权威血量是否真被扣掉────────────────────
func _observe_step() -> void:
	if _remote == null or _local == null:
		return
	var away: Vector3 = (_remote.global_position - _local.global_position).normalized()
	if away.length() > 0.01:
		_local.global_position = _remote.global_position - away * 5.0 + Vector3.UP * 0.3
	var mine: float = float(_local.get_health())
	if mine < _last_own_health:
		_say("  ↳ 本端（受害端）权威血量 %.1f → %.1f（真实 incoming 伤害，本端就该扣）"
			% [_last_own_health, mine])
		_victim_readings.append(mine)
		_verify_bar_visible("shot%d" % _victim_readings.size())
		_save_screenshot(_victim_readings.size())
	_last_own_health = mine
	if _victim_readings.size() >= ROUNDS:
		_finish()


# ── 开火：与 weapon.gd::_deal_damage() 同一条路径 ──────────────────────
func _fire_step() -> void:
	# ⚠ 顺序要紧：`_shot_pending` 必须在 `_round >= ROUNDS` **之前**判断。
	#   反过来的话最后一枪的结果永远等不到（下一帧就 _finish() 了）→ 读数少一条。
	if _shot_pending:
		if _phase_frames < FRAMES_SETTLE_AFTER_SHOT:
			return
		_after_shot()
		return
	if _round >= ROUNDS:
		# 最后一枪已发出 → 进入收尾轮询，等受害端扣血的广播真正传回来
		_poll_final_display()
		return
	if _phase_frames % FRAMES_PER_SHOT != 0:
		return
	# 站位保持（权威端每帧物理会覆盖位置）
	var away: Vector3 = (_remote.global_position - _local.global_position).normalized()
	if away.length() > 0.01:
		_local.global_position = _remote.global_position - away * 5.0 + Vector3.UP * 0.3
	_round += 1
	var before_display := _display()
	_before_local = float(_local.get_health())
	# ⚠ 与 weapon.gd 对远程玩家的分支完全同形：受害端 authority + 射手 peer id
	_remote.rpc_id(
		_remote.get_multiplayer_authority(), "apply_network_damage",
		DAMAGE, NetworkManager.multiplayer.get_unique_id()
	)
	print("[HS]%s SHOT %d 已向受害端(peer=%s)发出 %.0f 伤害｜发枪前：本端看到敌方血量=%.1f，本端权威血量=%.1f"
		% [_role, _round, str(_remote.name), DAMAGE, before_display, _before_local])
	_shot_pending = true
	_phase_frames = 0
	if _round >= ROUNDS:
		_final_wait = FRAMES_SETTLE_FINAL


func _after_shot() -> void:
	_shot_pending = false
	var after_display: float = _display()
	var after_local: float = float(_local.get_health())
	_display_readings.append(after_display)
	_say("  ↳ 结果：射手端看到敌方血量 %.1f，本端权威血量 %.1f" % [after_display, after_local])
	# 断言 1：射手端**不得**因为远端掉血而本地扣血。
	# ⚠ 判据是「**本端权威血量在两次采样之间没有变化**」，**不是**「等于满血」——
	#   场景里有 `Bots` 会主动开枪（实测本端常在开打前就被 bot 打过一枪 → 起始 75），
	#   那是**真实的 incoming 伤害**，完全正确。若断言「必须满血」会把正确行为判成失败
	#   （探针第一版就踩了：断言全红但被测代码是对的）。
	#   真正要锁的是 C-18 那条性质：**远端掉血的广播不会让本端权威血量发生任何变化**。
	if not is_equal_approx(after_local, _before_local):
		_fail("第 %d 枪后本端权威血量从 %.1f 变成 %.1f —— 远端掉血的广播污染了本地血量"
			% [_round, _before_local, after_local])
	_verify_bar_visible("shot%d" % _round)
	_save_screenshot(_round)
	_phase_frames = 0


## 收尾轮询：等「受害端扣血 → 它下一次 30Hz 广播 → 射手端收到」这条链路走完。
##
## ⚠ 为什么必须**轮询到值变了**而不是「等固定帧数后采一次」：
##   受害端扣血的时刻与它下一次广播的时机**不同步**（取决于 RPC 到达落在广播周期哪一格），
##   所以固定 12 帧后采一次，读到的是**上一枪**的结果（实测每一枪都落后一枪：
##   受害端已 100→75→50→25→0，射手端读数却是 100→75→50→25，末尾还重复一条 25.0）。
##   ⇒ 改为「轮询直到显示值真的变了，或超时」——这才是对「掉血过程可见」的**正确**观测方式。
func _poll_final_display() -> void:
	var now: float = _display()
	if _display_readings.is_empty():
		_display_readings.append(now)
		_say("  ↳ 收尾读到敌方血量 %.1f" % now)
		_finish()
		return
	if not is_equal_approx(now, _display_readings[_display_readings.size() - 1]):
		_display_readings.append(now)
		_say("  ↳ 收尾轮询到敌方血量变为 %.1f（掉血过程确实可见）" % now)
		_verify_bar_visible("shot%d" % (ROUNDS + 1))
		_save_screenshot(ROUNDS + 1)
		_finish()
		return
	_final_wait -= 1
	if _final_wait <= 0:
		_fail("收尾轮询超时：%.0f 帧内敌方血量始终停在 %.1f（未看到最后的下降）"
			% [FRAMES_SETTLE_FINAL, now])
		_finish()


## 受害端收尾：本地权威血量应被真实扣光（证明伤害确实结算在这一端 = ADR-007 期望行为）
func _finish_victim() -> void:
	if _phase == P_DONE:
		return
	_phase = P_DONE
	_say("==== 本端（受害端）本地权威血量下降序列：%s ====" % str(_victim_readings))
	_say("==== 本端看到的敌方（射手）血量：%.1f（射手没掉血，应为满）====" % _display())
	if _victim_readings.size() < ROUNDS:
		_fail("受害端只记录到 %d/%d 次掉血（读到 %s）"
			% [_victim_readings.size(), ROUNDS, str(_victim_readings)])
	if _victim_readings.is_empty() or _victim_readings[0] > 75.0:
		_fail("受害端第一次掉血后血量应为 75（读到 %.1f）——伤害没有结算在受害端"
			% (_victim_readings[0] if not _victim_readings.is_empty() else -1.0))
	if not _victim_readings.is_empty() and _victim_readings[_victim_readings.size() - 1] > 0.0:
		_fail("受害端挨完 4 枪后血量应为 0（读到 %.1f）"
			% _victim_readings[_victim_readings.size() - 1])
	if _failures.is_empty():
		_say("RESULT PASS（受害端本地血量 100→75→50→25→0 真实下降；射手端血量未被污染）")
	else:
		print("[HS]%s RESULT FAIL（%d 条）" % [_role, _failures.size()])
	get_tree().quit(1 if not _failures.is_empty() else 0)


## 血条绘制矩形（**与 `enemy_health_bars.gd::_draw()` 完全同一套公式**）。
## 返回 null = 这一帧不该画（相机背后/ 出画/ 未收到广播）。
func _bar_rect() -> Rect2:
	var cam: Camera3D = get_tree().get_first_node_in_group(CAMERA_GROUP) as Camera3D
	if cam == null or _remote == null:
		return Rect2()
	var world: Vector3 = _remote.global_position + Vector3.UP * BAR_HEIGHT_OFFSET
	if cam.is_position_behind(world):
		return Rect2()
	var anchor := cam.unproject_position(world)
	var vs: Vector2 = get_viewport().get_visible_rect().size
	# 直接复用生产代码的纯函数（含视口夹取）→ 探针与实际绘制**不可能不一致**
	var bars_script: GDScript = load("res://scripts/ui/enemy_health_bars.gd")
	return bars_script.bar_rect_for(anchor, vs, Vector2(BAR_WIDTH, BAR_HEIGHT))


## 校验「血条这一帧真的落在视口内」并打印 —— 这是「用户看得见」的可核对证据。
func _verify_bar_visible(tag: String) -> void:
	var rect := _bar_rect()
	if rect.size == Vector2.ZERO:
		_fail("[%s] 血条矩形为空（相机背后/出画/未收到广播）—— 用户看不见" % tag)
		return
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var inside := rect.position.x >= 0.0 and rect.position.y >= 0.0 \
		and rect.end.x <= vs.x and rect.end.y <= vs.y
	_say("[%s] 血条绘制矩形 pos=(%.0f,%.0f) size=(%.0f,%.0f)，视口=%s，完全在视口内=%s"
		% [tag, rect.position.x, rect.position.y, rect.size.x, rect.size.y, str(vs), inside])
	if not inside:
		_fail("[%s] 血条矩形超出视口%s" % [tag, str(vs)])
	_bar_rects[tag] = rect


func _save_screenshot(index: int) -> void:
	var tex := get_viewport().get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img == null:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_preview_dir))
	var path := "%s/%s_shot%d.png" % [_preview_dir, _role, index]
	img.save_png(path)
	# 精确裁剪：按算出的血条矩形向外扩一点（把条+ 右侧数字都框进来），放大 6 倍
	var rect: Rect2 = _bar_rects.get("shot%d" % index, Rect2())
	if rect.size != Vector2.ZERO:
		var pad := 10.0
		var box := Rect2(rect.position - Vector2(pad, pad), rect.size + Vector2(pad * 3.0, pad * 2.0))
		box = box.intersection(Rect2(Vector2.ZERO, Vector2(img.get_width(), img.get_height())))
		if box.size.x > 4.0 and box.size.y > 4.0:
			var crop := img.get_region(box)
			crop.resize(crop.get_width() * 6, crop.get_height() * 6, Image.INTERPOLATE_NEAREST)
			crop.save_png("%s/%s_bar%d.png" % [_preview_dir, _role, index])
			_say("血条放大图已存 %s/%s_bar%d.png（条=%.0fx%.0f px，填充占比=%.0f%%）"
				% [_preview_dir, _role, index, rect.size.x, rect.size.y,
					100.0 * clampf(_display() / maxf(_display_max(), 1.0), 0.0, 1.0)])
	_say("截图已存%s" % path)


# ── 收尾 ────────────────────────────────────────────────────────────────
func _finish() -> void:
	if _phase == P_DONE:
		return
	_phase = P_DONE
	if _role != ROLE_HOST:
		_finish_victim()
		return
	_say("==== 本端（射手端）看到的敌方血量序列：%s ====" % str(_display_readings))
	# 断言 0（最重要）：每一枪的血条矩形都必须**完整落在视口内** = 用户真的看得见
	if _bar_rects.size() < ROUNDS:
		_fail("只有 %d/%d 次记录到血条矩形（%s）" % [_bar_rects.size(), ROUNDS, str(_bar_rects.keys())])
	# 断言 3：看到的敌方血量必须随受击**单调下降**（看得见掉血过程）
	if _display_readings.size() >= ROUNDS:
		for i in range(1, _display_readings.size()):
			if _display_readings[i] > _display_readings[i - 1]:
				_fail("敌方显示血量第 %d 枪后反而上升（%.1f→%.1f）"
					% [i, _display_readings[i - 1], _display_readings[i]])
	# 断言 4：读数条数 = 每枪一条 + 收尾一条（打空了血才看得到最终值）
	var expected := ROUNDS + 1
	if _display_readings.size() < expected:
		_fail("射手端只采到 %d 条读数（期望 ≥%d 条 = %d 枪 + 收尾），序列=%s"
			% [_display_readings.size(), expected, ROUNDS, str(_display_readings)])
	elif _display_readings[_display_readings.size() - 1] > 0.0:
		_fail("最后读到敌方血量 %.1f，未看到归零" % _display_readings[_display_readings.size() - 1])
	if _failures.is_empty():
		_say("RESULT PASS（4 组断言全过：敌方血条可见、随受击变化、本端血量不受污染、能打到 0）")
	else:
		print("[HS]%s RESULT FAIL（%d 条）" % [_role, _failures.size()])
	get_tree().quit(1 if not _failures.is_empty() else 0)
