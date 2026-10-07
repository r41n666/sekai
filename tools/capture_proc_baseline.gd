extends Node3D
## 「当前程序化姿态」的**同机位对照图**（窗口工具，Vulkan）。
##
## ⚠ 机位参数必须与 `capture_ual_retarget.gd` **逐字一致**（FOCUS / DIST / VIEWS），
##    否则 UAL 与程序化的对比图不成立（不同机位无法判断动作质量差异）。
##    这也是本工具存在的唯一理由 —— 不复用 capture_layered_walk.gd（它的机位是另一个值）。
##
## 走**真实**生产代码路径：MikuModel(procedural_legs_enabled + hold_ik_enabled)
##    + 真实步枪模型，与游戏内一致。
##
## 用法：godot --path . --rendering-driver vulkan --resolution 900x900 res://tools/capture_proc_baseline.tscn
##      可选 `-- walk` 拍行走相位（默认拍站立持枪）
## 产物：tmp_spike/ual_proc_<机位>.png / tmp_spike/ual_proc_walk_<机位>.png

const RIFLE := "res://scenes/weapons/rifle.tscn"
const OUT := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"

## —— 与 capture_ual_retarget.gd 逐字一致（改一处必须同步改另一处）——
const FOCUS := Vector3(0.0, 0.75, 0.0)
const DIST := 2.6

var _model: MikuModel
var _cam: Camera3D
var _plan: Array = []
var _sub := 0
var _busy := false
var _walk := false
var _frames := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	_walk = "walk" in OS.get_cmdline_user_args()
	_setup_env()

	_model = MikuModel.new()
	_model.name = "MikuModel"
	_model.model_path = "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
	_model.procedural_legs_enabled = true
	_model.hold_ik_enabled = true
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	_model.add_child(mount)
	mount.add_child((load(RIFLE) as PackedScene).instantiate())
	add_child(_model)
	_model.position.y = 0.9
	_model.set_holding_weapon(true)

	for v in [0, 1, 2, 3]:
		_plan.append(int(v))
	print("程序化对照：procedural=%s hold_ik=%s walk=%s ｜ 待拍 %d 张（同机位）" % [
		_model.procedural_legs_enabled, _model.hold_ik_enabled, str(_walk), _plan.size()])


func _process(_d: float) -> void:
	_frames += 1
	# 固定步长推进：窗口模式不锁帧，用真实 delta 会让「第 N 帧」落在不同相位，截图不可复现。
	_model.update_animation(1.0 / 60.0, 2.0 if _walk else 0.0, 0.5, _walk, true)

	if _busy or _plan.is_empty():
		if _plan.is_empty() and not _busy:
			print("ALL_SHOTS_DONE")
			get_tree().quit(0)
		return

	if _sub == 0:
		_aim_camera(int(_plan[0]))
		_sub = 1
		return

	_sub = 0
	var view := int(_plan.pop_front())
	_busy = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/ual_proc%s_%d.png" % [OUT, "_walk" if _walk else "", view]
	img.save_png(path)
	_busy = false
	print("saved %s" % path)


func _aim_camera(view: int) -> void:
	match view:
		0: _cam.position = FOCUS + Vector3(-0.95, 0.28, 1.95)
		1: _cam.position = FOCUS + Vector3(2.20, 0.18, 0.18)
		2: _cam.position = FOCUS + Vector3(0.55, 0.55, -2.05)
		_: _cam.position = FOCUS + Vector3(0.06, 0.15, 2.25)
	_cam.look_at(FOCUS, Vector3.UP)


func _setup_env() -> void:
	_cam = Camera3D.new()
	_cam.name = "Cam"
	_cam.current = true
	_cam.fov = 40.0
	add_child(_cam)
	_aim_camera(0)
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
