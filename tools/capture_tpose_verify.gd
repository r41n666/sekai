extends Node3D
## 窗口模式**实机路径等价**验证 + 连拍：T-pose / 抽搐。
##
## ## 为什么必须窗口模式（两个实测事实）
##   ① headless（dummy 渲染）下 `AnimationPlayer` 不推进、`seek()` 不更新骨骼
##     （见 ual_locomotion.gd 文件头§8-3）⇒ 骨骼运动**只能**在窗口模式验证。
##   ② 本工具**不用 seek**，而是让AnimationPlayer 自行推进 + 连续调用
##     MikuModel.update_animation —— 这就是玩家实机走的同一条路径。
##
## ## 相机按包围盒自动取景（不要硬编码机位）
## 上轮踩过：硬编码机位导致拍空/切腿。这里每组都按该组模型的 AABB
## 现算中心、半径与机位 ⇒ 换模型 / 换姿态都不会拍飞。
##
## ## 输出
##   · 每帧数值：双脚高度差、大腿骨世界朝向夹角、手高度（T-pose 判别）、胸骨 yaw
##   · 连拍 PNG（证明「在动」/「在抖」）
##
## 用法：
##   godot --path . --rendering-driver vulkan --resolution 900x900 res://tools/capture_tpose_verify.tscn -- frozen
##   组：frozen（UAL 关 = 出货默认，本轮要修的） / proc（程序化腿） / ual（UAL locomotion）

const MikuModelScript := preload("res://scripts/entities/miku_model.gd")
const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const OUT := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"
const FPS := 30.0
const DT := 1.0 / FPS
## 每个组连续拍多少帧（连拍，用来看「在动」还是「在抖」）
const FRAMES := 24

var _cam: Camera3D
var _model: Node3D
var _group := "frozen"
var _skel: Skeleton3D
var _frame := 0
var _busy := false
var _measured := 0
## 逐帧记录，用于收尾统计
var _foot_diff: Array[float] = []
var _thigh_angle: Array[float] = []
var _hand_y: Array[float] = []
var _chest_yaw: Array[float] = []
## 走动状态：让update_animation 拿到 moving=true / ratio=0.554（player walk档）
var _moving := true
var _ratio := 0.554


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var a := String(args[i])
		if a in ["frozen", "proc", "ual"]:
			_group = a
		elif a == "--view" and i + 1 < args.size():
			_view = int(String(args[i + 1]))
	_setup_env()
	_model = MikuModelScript.new()
	_model.name = "MikuModel"
	_model.model_path = CAT_MODEL
	# ⚠ 开关必须在 add_child **之前**设好：MikuModel._ready() 里就会 load_model，
	#   之后再改开关就得二次 load_model，而 _clear_loaded_model 用的是 queue_free（延迟释放）
	#   ⇒ 旧的骨架这一帧还在树里，_find_skel 会抓到一个**已排队释放**的骨架引用（实测踩过：
	#   统计变成「连续 0 帧」）。
	_model.ual_locomotion_enabled = (_group == "ual")
	_model.procedural_legs_enabled = (_group == "proc")
	add_child(_model)
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	_model.add_child(mount)
	_skel = _find_skel(_model)
	print("[组=%s] UAL生效=%s  程序化姿态=%s  骨数=%d" % [
		_group, str(_model.is_ual_locomotion_active()),
		str(_model._procedural != null and _model._procedural.valid),
		_skel.get_bone_count() if _skel != null else -1])
	print("[组=%s] AnimationPlayer.current=%s  loop=%d" % [
		_group,
		str(_model._anim.current_animation) if _model._anim != null else "无 _anim",
		int((_model._anim.get_animation(String(_model._anim.current_animation)).loop_mode)
			if _model._anim != null and _model._anim.current_animation != "" else -1)])
	_frame = 0
	_measured = 0


func _process(_delta: float) -> void:
	if _busy:
		return
	if _frame >= FRAMES:
		_report()
		print("ALL_SHOTS_DONE")
		get_tree().quit(0)
		return
	# —— 走**出货路径**：与 player.gd::_physics_process 里那句完全同形——
	_model.update_animation(DT, _ratio * 6.5, _ratio, _moving, true)
	if _skel != null and is_instance_valid(_skel):
		_skel.force_update_all_bone_transforms()
	_frame += 1
	if _frame >= 3: # 前2 帧是启动预热，不计入统计（UAL 的播放器需要时间开始播）
		_measure()
	# 每一帧都拍 ⇒ 连拍
	_shoot_async()


func _measure() -> void:
	if _skel == null or not is_instance_valid(_skel):
		_skel = _find_skel(_model)
		if _skel == null:
			return
	_measured += 1
	var fl := _bone_y("foot.L_97")
	var fr := _bone_y("foot.R_102")
	_foot_diff.append(absf(fl - fr))
	_thigh_angle.append(absf(_bone_angle("upper_leg.L_100", "lower_leg.L_98")))
	_hand_y.append(_bone_y("hand.L_66"))
	_chest_yaw.append(_bone_yaw("chest_94"))
	# 逐帧打印胸骨 yaw：抽搐是**高频**来回，抽样统计看不出「锯齿」，必须逐帧看
	# ⚠ `current_animation_position` 在「播放器无当前动画」时会报错
	#   （修复后退化剪辑不再被播，正是这种状态）⇒ 必须先判 `current_animation != ""`。
	var ap_desc := "无AP"
	if _model._anim != null and _model._anim.current_animation != "":
		ap_desc = "%s@%.3f" % [_model._anim.current_animation,
			_model._anim.current_animation_position]
	print("   f%02d  脚高度差=%.4f  膝夹角=%6.2f°  手y=%.4f  胸yaw=%7.3f°  AP=%s" % [
		_frame, absf(fl - fr), _thigh_angle[_thigh_angle.size() - 1],
		_hand_y[_hand_y.size() - 1], _chest_yaw[_chest_yaw.size() - 1], ap_desc])


func _report() -> void:
	print("\n===== [%s] 连续 %d 帧统计（每帧都调了 update_animation） =====" % [_group, _measured])
	print("  双脚高度差: min=%.4f max=%.4f跨度=%.4f  （>0.01 ⇒ 腿真的在交替迈步）" % [
		_min(_foot_diff), _max(_foot_diff), _max(_foot_diff) - _min(_foot_diff)])
	print("  大腿-小腿夹角: min=%.3f° max=%.3f° 跨度=%.3f° （>3° ⇒ 膝真的在屈伸）" % [
		_min(_thigh_angle), _max(_thigh_angle), _max(_thigh_angle) - _min(_thigh_angle)])
	print("  手高度 y   : min=%.4f max=%.4f  （≈1.16=肩高 ⇒ **T-pose**；<0.8 ⇒ 垂臂/持枪）" % [
		_min(_hand_y), _max(_hand_y)])
	print("  胸骨 yaw   : min=%.3f° max=%.3f° 跨度=%.3f° （反复大幅摆 ⇒ 抽搐）" % [
		_min(_chest_yaw), _max(_chest_yaw), _max(_chest_yaw) - _min(_chest_yaw)])
	# 抽搐的量化：逐帧变化量的**符号翻转次数**（左右来回抽）
	var flips := 0
	for i in range(2, _chest_yaw.size()):
		var d1 := _chest_yaw[i - 1] - _chest_yaw[i - 2]
		var d2 := _chest_yaw[i] - _chest_yaw[i - 1]
		if absf(d1) > 0.5 and absf(d2) > 0.5 and signf(d1) != signf(d2):
			flips += 1
	print("  胸骨逐帧变化>0.5° 且方向翻转的次数 = %d / %d 帧  （高 ⇒ 高频抖动）" % [flips, _foot_diff.size()])


func _shoot_async() -> void:
	_busy = true
	_frame_camera()
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/tpose_%s_f%02d.png" % [OUT, _group, _frame]
	img.save_png(path)
	_busy = false
	print("saved %s" % path)


## —— 相机按包围盒自动取景 ——
## ⚠ **机位必须固定**：判断「抽搐」靠的是**连续两帧的差异**，机位一动就把
##   「角色动了」和「相机动了」混在一起（本轮踩过：机位逐帧绕行⇒ 连拍不可比）。
##   取景只按 AABB 算一次（换模型 / 换姿态不会拍飞），之后锁死。
var _cam_locked := false
var _view := 0


func _frame_camera() -> void:
	if _cam_locked:
		return
	_cam_locked = true
	var box := _model_box()
	if box.size.length() < 0.01:
		_cam.position = Vector3(-1.45, 0.40, 2.95)
		_cam.look_at(Vector3.ZERO, Vector3.UP)
		return
	var center := box.get_center()
	var radius := maxf(box.size.length() * 0.5, 0.2)
	var dist := radius / tan(deg_to_rad(_cam.fov) * 0.5) * 1.25
	# 三个**固定**机位（正面 / 侧面 / 斜前），逐组轮换 —— 不逐帧动
	var dirs := [Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.35), Vector3(0.55, 0.0, 1.0)]
	var dir: Vector3 = (dirs[_view % dirs.size()] as Vector3).normalized()
	# 抬高机位俯视约 15°，能看清腿（腿是本次的主要证据）
	var eye := center + dir * dist + Vector3(0.0, radius * 0.30, 0.0)
	_cam.position = eye
	_cam.look_at(center, Vector3.UP)
	print("[相机] 包围盒中心=%s 半径=%.3f 机位=%s（固定不动，连拍才可比）" % [
		str(center), radius, str(_cam.position)])


func _model_box() -> AABB:
	var box := AABB()
	var first := true
	for m in _collect_meshes(_model):
		var mb := (m as MeshInstance3D).get_aabb()
		var xf := (m as Node3D).global_transform
		for c in 8:
			var corner := mb.position + Vector3(
				mb.size.x * float(c & 1), mb.size.y * float((c >> 1) & 1),
				mb.size.z * float((c >> 2) & 1))
			var p := xf * corner
			if first:
				box = AABB(p, Vector3.ZERO)
				first = false
			else:
				box = box.expand(p)
	return box


func _bone_y(bone: String) -> float:
	if _skel == null:
		return 0.0
	var i := _skel.find_bone(bone)
	return 0.0 if i < 0 else _skel.get_bone_global_pose(i).origin.y


## 两根骨的世界朝向夹角（度）：骨自身没有长度信息时也能判「有没有转」。
func _bone_angle(a: String, b: String) -> float:
	if _skel == null:
		return 0.0
	var ia := _skel.find_bone(a)
	var ib := _skel.find_bone(b)
	if ia < 0 or ib < 0:
		return 0.0
	var qa := _skel.get_bone_global_pose(ia).basis.orthonormalized().get_rotation_quaternion()
	var qb := _skel.get_bone_global_pose(ib).basis.orthonormalized().get_rotation_quaternion()
	return rad_to_deg(qa.angle_to(qb))


## 胸骨（spine）在世界空间的偏航角（度）—— 抽搐的直接指标。
func _bone_yaw(bone: String) -> float:
	if _skel == null:
		return 0.0
	var i := _skel.find_bone(bone)
	if i < 0:
		return 0.0
	var e := _skel.get_bone_global_pose(i).basis.orthonormalized().get_euler()
	return rad_to_deg(e.y)


func _min(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var m := a[0]
	for v in a:
		m = minf(m, v)
	return m


func _max(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var m := a[0]
	for v in a:
		m = maxf(m, v)
	return m


func _setup_env() -> void:
	_cam = Camera3D.new()
	_cam.name = "Cam"
	_cam.current = true
	_cam.fov = 40.0
	add_child(_cam)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 40, 0)
	key.light_energy = 1.5
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, -140, 0)
	fill.light_energy = 0.55
	add_child(fill)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.18, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.7)
	e.ambient_light_energy = 0.8
	we.environment = e
	add_child(we)


func _collect_meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_collect_meshes(c))
	return out


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null