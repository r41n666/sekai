extends TestSuite
## 关键不变量回归（阶段 4 回归基线）
##
## 覆盖 4 条「改代码时必须保持」的不变量（control_checklist.md §4 / ADR-003 / README §8.1）：
##   1. 换弹计时在输入屏蔽期间继续走（weapon.gd:166-168）
##   2. input_blocked「双闸门」同步（player.gd:375-378 → release_mouse → set_trigger_enabled(false)）
##   3. 三层后坐力 / 相机摇晃各自只写自己的 transform（recoil_system.gd / camera_sway.gd）
##   4. apply_to() 重建网格后必须重套皮肤（weapon_variant.gd:227-229）
##
## 实现分两类：
##   · **行为断言**：能独立实例化、无外部依赖的节点（RecoilSystem / CameraSway / WeaponSkin.apply_to）
##     直接跑真逻辑、验真结果。
##   · **契约锁（源码结构断言）**：耦合过重（weapon / player 需完整场景 + 相机/音频/网格）的不变量，
##     改为断言「守卫调用在源码里仍存在」。契约锁仅防「误删守卫」，不验运行时行为——
##     每处都注明"为什么不用行为断言"。

const WEAPON_SRC := "res://scripts/shooting/weapon.gd"
const PLAYER_SRC := "res://scripts/player.gd"
const WEAPON_VARIANT_SRC := "res://scripts/shooting/weapon_variant.gd"


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## ── 不变量 1：换弹计时在输入屏蔽期间继续（weapon.gd:166-168）──
## 契约锁原因：weapon.tscn 的 _process 会访问 camera / audio / muzzle 等外部节点，
## 在 headless 里独立实例化会空引用崩；故锁「屏蔽分支里仍调用 _update_reload」这一结构事实。
func test_reload_tick_survives_trigger_block() -> void:
	var src := _read_source(WEAPON_SRC)
	var idx := src.find("if not _trigger_enabled:")
	check_true(idx >= 0, "weapon.gd 应保留 _trigger_enabled 早退分支（菜单/死亡屏蔽）")
	if idx >= 0:
		var seg := src.substr(idx, 220)
		check_true(seg.find("_update_reload(delta)") >= 0,
			"屏蔽期间仍须调用 _update_reload（换弹计时继续走 → README §8.1）")
		check_true(seg.find("return") >= 0,
			"屏蔽分支应在推进换弹后早退（不响应射击/开镜/换弹）")


## ── 不变量 2：input_blocked 双闸门同步 ──
## 契约锁原因：player.tscn 需武器/相机/模型齐全，headless 实例化代价高。
func test_input_blocked_double_gate() -> void:
	var src := _read_source(PLAYER_SRC)
	var i := src.find("func set_input_blocked")
	check_true(i >= 0, "player.gd 应有 set_input_blocked()")
	if i >= 0:
		var body := src.substr(i, 200)
		check_true(body.find("input_blocked = blocked") >= 0,
			"set_input_blocked 必须写 player.input_blocked（第一道闸门）")
		check_true(body.find("release_mouse()") >= 0,
			"set_input_blocked(true) 必须连带 release_mouse()（第二道闸门）")
	var j := src.find("func release_mouse")
	check_true(j >= 0, "player.gd 应有 release_mouse()")
	if j >= 0:
		var rbody := src.substr(j, 320)
		check_true(rbody.find("set_trigger_enabled(false)") >= 0,
			"release_mouse 必须关闭武器开火闸门 set_trigger_enabled(false)")
	var k := src.find("func capture_mouse")
	check_true(k >= 0, "player.gd 应有 capture_mouse()")
	if k >= 0:
		var cbody := src.substr(k, 320)
		check_true(cbody.find("set_trigger_enabled(true)") >= 0,
			"capture_mouse 必须打开武器开火闸门 set_trigger_enabled(true)")


## ── 不变量 3a：RecoilSystem 只写自己的 rotation（x/y，从不写 roll）+ 三层各司其职 ──
func test_recoil_writes_only_own_rotation_axes() -> void:
	var recoil := RecoilSystem.new()
	check_true(recoil != null, "recoil_system.gd 应可实例化")
	if recoil == null:
		return
	add_child(recoil)
	recoil.set_process(false) # 手动驱动，保证确定性
	recoil.fire_shot()
	recoil._process(0.0) # 应用 rotation = 三层偏移之和
	var offsets: Vector3 = recoil.get_debug_offsets_deg()
	check_true(offsets.x > 0.0, "第 1 层：开火后应上抬（pitch > 0），实际 %.4f°" % offsets.x)
	check_near(recoil.rotation.x, deg_to_rad(offsets.x), 0.001,
		"rotation.x 必须等于三层 pitch 偏移之和（每帧只写自己的 rotation）")
	check_near(recoil.rotation.z, 0.0, 0.0001, "后坐力系统不应写 roll（rotation.z 恒为 0）")
	check_ge(recoil.get_spread(), 0.0, "第 3 层：扩散值应在 [0,1] 内")
	recoil.queue_free()


## ── 不变量 3b：第 3 层开镜（ADS）时扩散增量更小 ──
func test_recoil_ads_reduces_spread_gain() -> void:
	var hip := RecoilSystem.new()
	var ads := RecoilSystem.new()
	if hip == null or ads == null:
		fail("recoil_system.gd 应可实例化两次")
		return
	add_child(hip)
	add_child(ads)
	hip.set_process(false)
	ads.set_process(false)
	ads.set_aiming(true)
	for _i in 6:
		hip.fire_shot()
		ads.fire_shot()
	check_true(ads.get_spread() < hip.get_spread(),
		"开镜连射的扩散应小于腰射（ads %.3f vs hip %.3f）" % [ads.get_spread(), hip.get_spread()])
	hip.queue_free()
	ads.queue_free()


## ── 不变量 3c：CameraSway 只写自己的 rotation + position.y（不动 x/z）──
func test_sway_writes_only_own_transform() -> void:
	var sway := CameraSway.new()
	check_true(sway != null, "camera_sway.gd 应可实例化")
	if sway == null:
		return
	sway.position = Vector3(0.1, 2.0, 0.3)
	add_child(sway) # _ready 记录 _base_position
	sway.set_process(false)
	var base_before: Vector3 = sway.position
	sway.add_look_delta(Vector2(40.0, 25.0))
	sway._process(0.016)
	check_true(absf(sway.rotation.x) + absf(sway.rotation.y) > 0.0,
		"鼠标增量应产生摇摆 rotation（滞后）")
	check_near(sway.position.x, base_before.x, 0.0001, "摇晃不应改 position.x")
	check_near(sway.position.z, base_before.z, 0.0001, "摇晃不应改 position.z")
	sway.set_motion(1.0, Vector3(0.0, 0.0, 6.0))
	sway._process(0.05)
	check_true(absf(sway.position.y - base_before.y) > 0.0, "移动时 y 方向应有行走晃动（bob）")
	sway.queue_free()


## ── 不变量 4a：apply_to() 重建网格后必须重套皮肤（结构）──
func test_skin_reapplied_after_model_rebuild() -> void:
	var src := _read_source(WEAPON_VARIANT_SRC)
	var add_idx := src.find("weapon.add_child(model)")
	var skin_idx := src.find("apply_skin")
	check_true(add_idx >= 0, "weapon_variant.gd 应把重建后的 Model 挂回武器（add_child(model)）")
	check_true(skin_idx >= 0, "weapon_variant.gd 应在重建网格后调用 apply_skin")
	check_true(add_idx >= 0 and skin_idx > add_idx,
		"apply_skin 必须在 add_child(model) 之后调用（新网格无材质覆盖 → 必须重套）")


## ── 不变量 4b：WeaponSkin.apply_to 确实遍历 Model 子树（行为）──
func test_skin_apply_to_traverses_model_subtree() -> void:
	var weapon := Node3D.new()
	var model := Node3D.new()
	model.name = "Model"
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.material_override = StandardMaterial3D.new() # 先弄脏，验证确实被清
	model.add_child(mesh)
	weapon.add_child(model)
	# 原版皮肤（""）应清空 Model 子树的 material_override —— 证明 apply_to 遍历到 Model 网格
	WeaponSkin.apply_to(weapon, "")
	check_true(mesh.material_override == null,
		"apply_to(\"\") 应把 Model 网格的 material_override 清空（原版）")
	weapon.free()
