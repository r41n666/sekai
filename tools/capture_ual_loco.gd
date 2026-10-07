extends Node3D
## UAL locomotion 集成的**窗口渲染**对照截图（Vulkan）。
##
## ⚠ 为什么必须窗口模式：headless（dummy 渲染）下 `AnimationPlayer` 不推进、
##   `seek()` 不更新骨骼姿态（实测，见评估报告 §8-3）⇒ 动画正确性**无法**在 headless 验证。
##
## ## 拍什么（同机位对照，机位常量与 capture_ual_retarget.gd / capture_proc_baseline.gd 逐字一致）
##   1. `ual`   组：MikuModel + ual_locomotion_enabled=true → UAL 驱动腿 + 躯干
##   2. `proc`  组：MikuModel + ual_locomotion_enabled=false（默认）→ 程序化姿态（现状基线）
##   3. `armed` 组：UAL 接管腿 + 躯干**且**开启持枪 IK / 手指抓握 → 验证两层共存
##   每组拍 Idle / Walk / Jog_Fwd / Sprint 各 2~3 帧 × 4 机位。
##
## ## 额外输出（数值证据，比肉眼更可靠）
##   · 每帧打印脚 / 手 / 头 / 骨盆的骨架空间坐标与「双马尾骨」的世界坐标；
##   · 打印 `drive_pairs`（确认手臂确实**不在**写入列表里）与 UAL 是否 active。
##
## 用法：
##   godot --path . --rendering-driver vulkan --resolution 900x900 res://tools/capture_ual_loco.tscn
##   可选 `-- armed` 只拍持枪组；`-- proc` 只拍程序化对照组

const MikuModelScript := preload("res://scripts/entities/miku_model.gd")
const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const RIFLE := "res://scenes/weapons/rifle.tscn"
const OUT := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"
const UalScript := preload("res://scripts/entities/ual_locomotion.gd")

## 机位常量。⚠ 与 capture_ual_retarget.gd 的 FOCUS/DIST **刻意不同**：
##   那套常量是给**裸 glb**（骨架高 2.435、脚底 y=0）标定的；本工具走 **MikuModel**，
##   它的 `_fit_to_capsule()` 会把模型底面对齐到 `PLACEHOLDER_BOTTOM_Y = -0.9`
##   （因为 MikuModel 在场景里位于玩家脚下 y=+0.9 处）⇒ **MikuModel 局部空间里
##   脚底 y=-0.9、头顶 y≈+0.85**，身体中心在 y≈0。沿用旧常量会把角色拍偏、切掉腿（本轮踩过）。
##   四组之间用**同一组**常量 ⇒ 组间可比（这才是本工具要的对照）。
const FOCUS := Vector3(0.0, 0.0, 0.0)
const DIST := 3.8

## 拍摄计划：[组, 状态键, 采样时刻, 标签]
## 时刻按各剪辑长度选取（Idle 2.50 / Walk 1.33 / Jog_Fwd 0.93 / Sprint 0.67，实测）
##
## 四个对照组（同机位、同状态、唯一变量 = 「谁驱动腿 + 躯干」）：
##   ual    = UAL locomotion（本任务交付）
##   frozen = UAL 关 + procedural_legs 关 ⇒ **出货默认**：cat 有 idle 剪辑 ⇒ 程序化姿态不启用
##            ⇒ 腿**完全不动**（这正是本任务要修的问题本身）
##   proc   = UAL 关 + procedural_legs 开⇒ 既有程序化腿（最好的现有替代方案）
##   armed  = UAL 开 + 持枪 IK + 手指抓握 ⇒ 验证 UAL 腿 与 IK 手臂**共存**
const SHOTS := [
	["ual", "walk", 0.33, "walk"],
	["ual", "jog", 0.30, "jog"],
	["ual", "sprint", 0.20, "sprint"],
	["frozen", "walk", 0.33, "walk"],
	["proc", "walk", 0.33, "walk"],
	["proc", "jog", 0.30, "jog"],
	["armed", "walk", 0.33, "walk"],
	["armed", "sprint", 0.20, "sprint"],
]
const VIEWS := [0, 1, 2, 3]

var _cam: Camera3D
var _model: Node3D
var _plan: Array = []
var _sub := 0
var _busy := false
var _phase := 0
var _states := {}
var _sim_time := 0.0
## 当前生效的组（用于检测换组）与换组后的预热帧数。
var _active_group := ""
var _warmup := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var args := OS.get_cmdline_user_args()
	var only_armed := "armed" in args
	var only_proc := "proc" in args
	_setup_env()
	# 建 MikuModel（走真实接线：UAL 或程序化由开关决定）
	_model = MikuModelScript.new()
	_model.name = "MikuModel"
	_model.model_path = CAT_MODEL
	_model.ual_locomotion_enabled = false # 首组必然触发 _enter_group，避免沿用 _ready 里的配置
	# 持枪：需要 IK + 手指抓握同时开（否则手臂是 T-pose，比不出共存效果）
	_model.hold_ik_enabled = true
	_model.hand_grip_enabled = true
	add_child(_model)
	# ⚠ MikuModel.new() **不带场景子节点** —— `WeaponMount` 是 player.tscn / bot.tscn 里的子节点，
	#   直接 new 出来的话 `_weapon_mount == null` ⇒ 武器不出现（截图里会「持枪但没枪」），
	#   且 `_attach_weapon_to_hand`  early-return。这里手工补一个，保证「持枪」组真的带枪。
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	_model.add_child(mount)
	var rifle: Node = (load(RIFLE) as PackedScene).instantiate()
	rifle.name = "Rifle"
	mount.add_child(rifle)
	rifle.visible = true
	_model.set_holding_weapon(true)
	# 各状态键 → [moving, speed_ratio]（ratio 取 player 实际速度档，见 probe_ual_clips SECTION 6）
	_states = {
		"idle": [false, 0.0],
		"walk": [true, 0.554],   # walk_speed 3.6 / sprint_speed 6.5
		"jog": [true, 0.80],     # bot run 5.2 / 6.5
		"sprint": [true, 1.0],   # 满速
	}
	for s in SHOTS:
		var group := String(s[0])
		if only_armed and group != "armed":
			continue
		if only_proc and group != "proc":
			continue
		if group == "proc" and _model.ual_locomotion_enabled and not only_proc:
			pass # 对照组：同一 MikuModel 关掉开关即可
		for v in VIEWS:
			_plan.append({"group": group, "state": String(s[1]), "at": float(s[2]),
				"tag": String(s[3]), "view": int(v)})
	print("待拍 %d 张（组：%s）" % [_plan.size(), str(_group_set(_plan))])


func _group_set(plan: Array) -> Array:
	var out: Array = []
	for j in plan:
		if not out.has(String(j["group"])):
			out.append(String(j["group"]))
	return out


## 打印「手臂确实不在写入列表里」的数值证据。
## ⚠ 不能用 TestSuite 的 check_*（那是测试基类的方法，工具脚本里不存在）——这里只打印 + 计数。
func _report_arm_exclusion() -> void:
	var sk := _find_skel(_model)
	if sk == null or _model._ual_loco == null:
		print("[手臂排除证据] 无 UAL 驱动（对照组），跳过")
		return
	var written: Array[String] = []
	for entry in _model._ual_loco.debug_pairs:
		written.append(String(sk.get_bone_name(int(entry[1]))))
	print("[手臂排除证据] 实际写入的 cat 骨（%d 根）= %s" % [written.size(), str(written)])
	var leaked: Array[String] = []
	for arm in ["upper_arm.L_68", "upper_arm.R_87", "lower_arm.L_67", "hand.L_66", "hand.R_85"]:
		if written.has(arm):
			leaked.append(arm)
	print("[手臂排除证据] 手臂骨泄漏 = %d %s（必须 0）" % [leaked.size(), str(leaked)])


func _process(delta: float) -> void:
	if _busy or _plan.is_empty():
		if _plan.is_empty() and not _busy:
			print("ALL_SHOTS_DONE")
			get_tree().quit(0)
		return
	var job: Dictionary = _plan[0]
	if _sub == 0:
		# —— 摆姿势 ——
		var group := String(job["group"])
		var state := String(job["state"])
		# ⚠ 换组必须**重载模型**（`_try_start_ual_locomotion` 只在 load_model 里跑）。
		#   并且重载后必须**等一帧**让 UAL 的 AnimationPlayer 真正开始播放 ——
		#   否则第一次 seek 落在「还没初始化」的播放器上，量到的是 rest 姿态（本轮踩过）。
		if _active_group != group:
			_enter_group(group)
			# ⚠ 切组这一帧**只重建**、**不摆姿势也不截图**（`_sub` 保持 0）。
			#   踩过的坑：曾在这里置 `_sub = 1` ⇒ 紧接着的截图分支直接消费掉了 view 0，
			#   于是每组第一张图拍的是「刚重载、还没摆姿势」的 rest 姿态（T-pose 手臂），
			#   而它看起来像「UAL 空手手臂穿帮」，差点导致误判。
			_warmup = 3
			return
		if _warmup > 0:
			_warmup -= 1
			_step(group, state)
			return
		_step(group, state)
		_advance_to(float(job["at"]), state)   # 确定性时刻（UAL 源手动 seek）
		_aim_camera(int(job["view"]))
		_measure(group, state, int(job["view"]))
		_sub = 1
		return
	_sub = 0
	_plan.pop_front()
	_busy = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/loco_%s_%s_%d.png" % [OUT, String(job["group"]), String(job["tag"]), int(job["view"])]
	img.save_png(path)
	_busy = false
	print("saved %s" % path)


## 按组名配置「谁驱动腿 + 躯干」并重载模型。
## 四组的唯一变量就是这两个开关（见 SHOTS 注释）。
func _enter_group(group: String) -> void:
	_model.ual_locomotion_enabled = group == "ual" or group == "armed"
	_model.procedural_legs_enabled = group == "proc"
	_model.load_model(CAT_MODEL)
	_model.set_hold_ik_enabled(true)
	_model.set_hand_grip_enabled(true)
	_model.set_holding_weapon(group == "armed")
	_active_group = group
	if _model._ual_loco != null:
		_report_arm_exclusion()
	print("  -- 切组 → %s（ual=%s proc_legs=%s armed=%s ⇒ UAL生效=%s  程序化姿态=%s）" % [
		group, str(_model.ual_locomotion_enabled), str(_model.procedural_legs_enabled),
		str(group == "armed"), str(_model.is_ual_locomotion_active()),
		str(_model._procedural != null and _model._procedural.valid)])


## 推进一帧的动画（走 MikuModel 的**真实**调用路径）。
func _step(_group: String, state: String) -> void:
	var moving := bool(_states[state][0])
	var ratio := float(_states[state][1])
	# 用 MikuModel 公开入口，确保拍到的是**出货路径**（UAL 或程序化，二者互斥）
	_model.update_animation(1.0 / 60.0, ratio * 6.5, ratio, moving, true)
	_force(_find_skel(_model))


## 把 UAL 的 AnimationPlayer 推进到指定时刻（确定性）。
## ⚠ 必须**手动 seek**：截图需要可复现的确定时刻，而 UAL 的播放器会自行推进。
func _advance_to(target: float, state: String) -> void:
	var loco = _model._ual_loco
	if loco != null and loco.valid and loco._ual_ap != null:
		loco._ual_ap.seek(target, true, true)
		loco._ual_skel.force_update_all_bone_transforms()
		loco._sample_and_apply()


func _force(sk: Skeleton3D) -> void:
	if sk != null:
		sk.force_update_all_bone_transforms()


## 打印关键骨的骨架空间坐标（数值证据）。
## 双马尾骨用 `ponytail` 前缀找（它们不在驱动集合里，理论上应保持 rest ⇒ 僵直）。
func _measure(group: String, state: String, view: int) -> void:
	var sk := _find_skel(_model)
	if sk == null:
		return
	var foot_l := _pose(sk, "foot.L_97")
	var foot_r := _pose(sk, "foot.R_102")
	var hand_l := _pose(sk, "hand.L_66")
	var hand_r := _pose(sk, "hand.R_85")
	var head := _pose(sk, "head_49")
	var pony := _ponytail_positions(sk)
	var pony_span := Vector3.ZERO
	if pony.size() > 1:
		var lo: Vector3 = pony[0]
		var hi: Vector3 = pony[0]
		for p in pony:
			lo = lo.min(p)
			hi = hi.max(p)
		pony_span = hi - lo
	# ⚠ 双手距**无法**区分「T-pose」与「垂臂」（两者左右对称、间距都≈肩宽），
	#   必须看**手的高度**：T-pose ≈ 肩高(1.1)，垂臂 ≈ 0.6。这是指南针。
	print("[%-6s %-6s v%d] footL.y=%.3f footR.y=%.3f 脚高度差=%.3f | head.y=%.3f | 手.y=%.3f/%.3f | 双马尾包围盒=%.3f" % [
		group, state, int(view), foot_l.y, foot_r.y, absf(foot_l.y - foot_r.y), head.y,
		hand_l.y, hand_r.y, pony_span.length()])


func _pose(sk: Skeleton3D, bone: String) -> Vector3:
	var i := sk.find_bone(bone)
	return Vector3.ZERO if i < 0 else sk.get_bone_global_pose(i).origin


func _ponytail_positions(sk: Skeleton3D) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in sk.get_bone_count():
		if sk.get_bone_name(i).to_lower().contains("ponytail"):
			out.append(sk.get_bone_global_pose(i).origin)
	return out


func _aim_camera(view: int) -> void:
	match view:
		0: _cam.position = FOCUS + Vector3(-1.45, 0.40, 2.95)
		1: _cam.position = FOCUS + Vector3(3.30, 0.25, 0.28)
		2: _cam.position = FOCUS + Vector3(0.85, 0.80, -3.10)
		_: _cam.position = FOCUS + Vector3(0.10, 0.22, 3.40)
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


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null