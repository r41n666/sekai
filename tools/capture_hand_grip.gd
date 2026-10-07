extends Node3D
## 手指抓握 —— 目视验证截图工具（走**真实** MikuModel / WeaponHoldIK / HandGrip 代码路径）。
##
## ⚠ 必须窗口跑：`SkeletonModifier3D`（IK 与手指抓握都是）在 headless 下不触发、形变被丢弃。
##
## 用法：
##   godot --path . --rendering-driver vulkan --resolution 900x760 res://tools/capture_hand_grip.tscn
## 产物（tmp_spike/）：
##   grip_0_front_off.png    全身正 3/4，抓握**关**（对照：手指大张「拍」在枪上）
##   grip_1_front_on.png     全身正 3/4，抓握**开**
##   grip_2_rh_on.png        右手特写，抓握**开**（看手指环握）
##   grip_3_rh_off.png       右手特写，抓握**关**（对照）
##   grip_4_left34_on.png    左前 3/4 全身（第三机位），抓握开
##
## ⚠ 截图**专用**：ak47.glb 网格长轴是 +X 且远离自身原点 ~4.7m，与场景「前=+Z」约定不合，
##   本工具**不做任何补偿**，如实反映游戏内武器摆放（补偿已随 commit 4bf8db2 的根因修复一并移除）。

const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const RIFLE := "res://scenes/weapons/rifle.tscn"
const OUT_DIR := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"

var _model: MikuModel
var _frames := 0
var _grip_on := false


func _ready() -> void:
	process_priority = 100
	var cam := Camera3D.new()
	cam.name = "Cam"
	cam.current = true
	cam.fov = 40.0
	add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, 35, 0)
	light.light_energy = 2.2
	add_child(light)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.72, 0.74, 0.80) # 浅底：黑色步枪 / 手才看得清
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.76, 0.82)
	e.ambient_light_energy = 1.1
	we.environment = e
	add_child(we)

	_model = MikuModel.new()
	_model.name = "MikuModel"
	_model.model_path = CAT_MODEL
	_model.procedural_legs_enabled = true
	_model.hold_ik_enabled = true
	_model.hand_grip_enabled = false
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	_model.add_child(mount)
	var rifle := (load(RIFLE) as PackedScene).instantiate() as Node3D
	mount.add_child(rifle)
	add_child(_model)
	_model.position.y = 0.9
	_model.set_holding_weapon(true)
	print("hold_ik_available=%s  grip_valid=%s" % [
		_model.is_hold_ik_available(),
		_model._hold_ik._grip_r.is_valid() if _model._hold_ik != null and _model._hold_ik._grip_r != null else false])


func _process(d: float) -> void:
	_frames += 1
	_model.update_animation(1.0 / 60.0, 0.0, 0.0, false, true)
	if _frames == 40:
		await _shoot(0, "front_off")
	elif _frames == 44:
		_set_grip(true)
	elif _frames == 80:
		await _shoot(1, "front_on")
	elif _frames == 110:
		await _shoot(2, "rh_on")
	elif _frames == 140:
		_set_grip(false)
	elif _frames == 175:
		await _shoot(3, "rh_off")
	elif _frames == 180:
		_set_grip(true)
	elif _frames == 215:
		await _shoot(4, "left34_on")
		get_tree().quit(0)


## ⚠ 已移除的截图补偿（2026-10-07）：
## 本工具曾对 ak47 做「转 -90°Y + 重心平移」补偿，因为当时场景占位 transform 是错的
## （`.tscn` 的 12 浮点 transform 与变体表差一个转置）⇒ 枪渲染到角色 ~2~4m 外。
## 该缺陷已在 commit `4bf8db2` 从根上修掉（同步 `weapon_variant.gd` 的 transform + 场景占位）。
## ⇒ 补偿**必须删掉**，否则会二次修正、反而把枪推歪。本工具现在如实反映游戏内效果。


func _set_grip(on: bool) -> void:
	_grip_on = on
	_model.set_hand_grip_enabled(on)
	print("grip → %s（hand_grip_enabled=%s  active_r=%s）" % [on, _model.hand_grip_enabled,
		_model._hold_ik._grip_r.active if _model._hold_ik._grip_r != null else false])


func _shoot(shot: int, label: String) -> void:
	_aim_camera(shot)
	await RenderingServer.frame_post_draw
	_diag(shot, label)
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path := "%s/grip_%d_%s.png" % [OUT_DIR, shot, label]
	img.save_png(path)
	print("saved %s（grip %s）" % [path, "on" if _grip_on else "off"])


## 诊断：武器挂点 / 步枪实例的**世界**位置与可见性（定位「截图里没有枪」问题）。
func _diag(shot: int, label: String) -> void:
	var cam := get_node("Cam") as Camera3D
	print("[diag %d/%s] cam=%s" % [shot, label, cam.global_transform.origin])
	var m: Node3D = _model._weapon_mount
	if m == null:
		print("    mount = null")
		return
	print("    mount global=%s visible=%s children=%d" % [m.global_transform.origin, m.visible, m.get_child_count()])
	for c in m.get_children():
		var n3 := c as Node3D
		if n3 == null:
			continue
		print("    child '%s' visible=%s global=%s scale=%s aabb=%s" % [
			n3.name, n3.visible, n3.global_transform.origin,
			n3.global_transform.basis.get_scale(), _world_aabb(n3)])
	print("    weapon_follow=%s ik_enabled=%s grip_active_r=%s" % [
		_model._weapon_follow,
		_model._hold_ik.is_enabled() if _model._hold_ik != null else false,
		_model._hold_ik._grip_r.active if _model._hold_ik != null and _model._hold_ik._grip_r != null else false])


## 递归求一个节点下所有可见 MeshInstance3D 的世界 AABB。
func _world_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var has := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible and mi.mesh != null:
			var b: AABB = mi.global_transform * mi.get_aabb()
			out = b if not has else out.merge(b)
			has = true
		for c in n.get_children():
			stack.push_back(c)
	return out if has else AABB()


func _aim_camera(shot: int) -> void:
	var cam := get_node("Cam") as Camera3D
	match shot:
		0, 1: # 全身正 3/4（与 capture_hold_ik 同机位）
			var focus := Vector3(0.0, 1.10, 0.2)
			cam.position = focus + Vector3(-0.85, 0.22, 1.52)
			cam.look_at(focus, Vector3.UP)
		2, 3: # 右手（握把）特写：从角色右前下方看（能露出握把）
			_hand_closeup(cam, _model._hold_ik._target_r, Vector3(-0.28, -0.10, 0.30))
		_: # 左前 3/4 全身（第三个机位）：从角色左前方看
			var f := Vector3(0.0, 1.15, 0.12)
			cam.position = f + Vector3(0.98, 0.26, 1.34)
			cam.look_at(f, Vector3.UP)


func _hand_closeup(cam: Camera3D, target: Node3D, offset: Vector3) -> void:
	if target == null or not is_instance_valid(target):
		cam.position = Vector3(0.0, 1.1, 1.6)
		cam.look_at(Vector3(0.0, 1.05, 0.2), Vector3.UP)
		return
	var focus: Vector3 = target.global_position
	cam.position = focus + offset
	cam.look_at(focus, Vector3.UP)
