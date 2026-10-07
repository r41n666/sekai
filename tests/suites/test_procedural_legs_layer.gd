extends TestSuite
## 「腿程序化 + 手臂 IK」分层回归基线（Spike 交付）。
##
## 背景：`cat_hatsune_miku` 自带的 idle 剪辑是 **T-pose 定格**（除手臂外全身不动）。
## `MikuModel._start_procedural_pose` 原本是**全有或全无** —— 有 idle 剪辑就永不启用程序化姿态，
## 于是选定该模型后，除 IK 接管的手臂外全身静止。本能力绕开那条 `return`，
## 让 `MikuProceduralPose` **只接管腿 + 躯干**（`pose_arms=false`），手臂留给 `TwoBoneIK3D`。
##
## 本 suite 锁四组不变量：
##   ① **bob 缩放**：起伏幅度与骨架高度成正比；miku.glb（前景标定模型）的起伏**不变**（守恒锚点）。
##      由来：原 `BOB_UNITS=0.22` 是**绝对骨架单位**，在 miku.glb（骨架高 ≈23.5 单位）上 ≈1.6 cm 正好，
##      但在 cat_hatsune_miku（骨架高仅 1.51 单位）上会放大成 ≈25 cm —— 实测躯干起伏 0.44 单位（0.51 m）。
##   ② **分层语义**：`pose_arms=false` 时手臂骨**不在受控清单**（不与 IK 抢骨骼），腿骨仍在。
##   ③ **真实资产集成**：cat 骨架 `valid`；`pose_arms=false` 时腿动、肘不动；`pose_arms=true` 时肘也动。
##   ④ **接线口径**：三个开关默认不破坏基线；IK 躯干锚点默认关、开启后建 BoneAttachment3D。
##
## 断言口径（控制清单 §4-16 双向）：一律用**行为 / 比例**断言，不锁字面量写法，避免误杀
## 语义等价的改写；守恒对照即 ① 的「miku 起伏不变」锚点。

const PoseScript := preload("res://scripts/entities/miku_procedural_pose.gd")
const HoldIKScript := preload("res://scripts/entities/weapon_hold_ik.gd")
const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
## miku.glb 的骨架高度（`MikuProceduralPose._height` 实测值；bob 原标定基准）
const MIKU_HEIGHT := 23.5392299890518
## cat_hatsune_miku 的骨架高度（实测值）
const CAT_HEIGHT := 1.5117363078316
## cat_hatsune_miku 的骨架 → 世界缩放（实测值）
const CAT_SCALE := 1.15967452526093


# ---------------------------------------------------------------------------
# ① bob 缩放：与骨架高度成正比；miku 起伏不变（守恒锚点）
# ---------------------------------------------------------------------------

## 守恒锚点：折算成比例后，miku.glb 的起伏幅度必须仍是 0.22 骨架单位（≈1.6 cm，与修改前一致）。
## 这是 §4-16 的「守恒对照组」——语义等价的另一种写法（比例 / 高度比 / 换算）都应通过。
func test_bob_amplitude_conserves_miku_calibration() -> void:
	check_near(PoseScript.bob_amplitude(MIKU_HEIGHT), 0.22, 0.001,
		"miku.glb（骨架高 23.54）的起伏幅度必须仍是 0.22 骨架单位——不得回归")


## 起伏幅度与骨架高度成正比（不锁具体常量，任何等比例写法都应通过）。
func test_bob_amplitude_is_proportional_to_height() -> void:
	check_near(PoseScript.bob_amplitude(2.0), PoseScript.bob_amplitude(1.0) * 2.0, 1e-6,
		"高度翻倍 → 起伏翻倍")
	check_near(PoseScript.bob_amplitude(0.0), 0.0, 1e-9, "零高度 → 零起伏")


## 起伏 / 高度 是**尺度无关常量**（换骨架不改比例）。
func test_bob_amplitude_ratio_is_scale_free() -> void:
	var r1 := PoseScript.bob_amplitude(10.0) / 10.0
	var r2 := PoseScript.bob_amplitude(3.0) / 3.0
	check_near(r1, r2, 1e-9, "起伏/高度 必须与骨架尺度无关（换模型姿势比例不变）")


## 关键回归：cat_hatsune_miku 的走路起伏必须回到「厘米级」，不得再是 25 cm 的夸张上下跳。
func test_cat_bob_is_not_exaggerated() -> void:
	var bob_units: float = PoseScript.bob_amplitude(CAT_HEIGHT)
	check_ge(bob_units, 0.0, "起伏幅度不得为负")
	check_le(bob_units * CAT_SCALE, 0.03,
		"cat 走路起伏必须 ≤ 3 cm（修复前实为 ≈25 cm；这是本能力可用的前提）")
	check_ge(bob_units * CAT_SCALE, 0.005,
		"cat 走路起伏也不应为 0（要保留可见的呼吸/起伏感）")


# ---------------------------------------------------------------------------
# ② 分层语义：pose_arms 决定手臂骨是否在受控清单内
# ---------------------------------------------------------------------------

func test_pose_arms_defaults_true() -> void:
	var pose = PoseScript.new()
	check_true(pose.pose_arms,
		"pose_arms 默认必须为 true（无剪辑模型的兜底路径要维持「全程序化」）")


# ---------------------------------------------------------------------------
# ③ 真实资产集成（headless 可跑：set_bone_global_pose_override 的结果可读）
# ---------------------------------------------------------------------------

## 造一个「参考节点 + cat 模型」的迷你场景（setup 需要 reference 提供坐标系）。
func _make_cat_context() -> Array:
	var ref := Node3D.new()
	add_child(ref)
	var ps: PackedScene = load(CAT_MODEL)
	check_true(ps != null, "cat_hatsune_miku.glb 必须存在（本能力的验证资产，不得缺失）")
	var inst: Node = ps.instantiate()
	ref.add_child(inst)
	return [ref, inst, _find_skeleton(inst)]


## 核心集成：pose_arms=false 时——腿真的摆动、手臂骨不在受控清单（不与 IK 抢骨骼）。
func test_real_model_legs_move_and_arms_untouched() -> void:
	var ctx := _make_cat_context()
	var ref: Node3D = ctx[0]
	var sk: Skeleton3D = ctx[2]
	if sk == null:
		check_true(false, "cat 模型必须含 Skeleton3D")
		ref.queue_free()
		return
	var pose = PoseScript.new()
	pose.pose_arms = false
	check_true(pose.setup(sk, ref), "cat 骨架必须能被 MikuProceduralPose 解析（valid=true）")
	var thigh := int(pose.debug_indices["thigh_r"])
	var ankle := int(pose.debug_indices["ankle_r"])
	var arm := int(pose.debug_indices["arm_r"])
	check_true(thigh >= 0, "必须解析出大腿根")
	check_true(ankle >= 0, "必须解析出脚踝")
	check_true(arm >= 0, "必须解析出上臂骨（判据：几何启发式在标准 Rigify 骨名上可用）")
	check_true(thigh in pose._controlled, "pose_arms=false：大腿骨必须在受控清单内")
	check_false(arm in pose._controlled, "pose_arms=false：上臂骨**不得**在受控清单内（留给 IK）")

	# 腿真的在动：推进相位，采样**脚踝**骨 global origin 的摆动幅度。
	# ⚠ 不能采样大腿骨 origin —— 大腿绕自己的关节枢轴旋转时 origin 不动（只有 bob 平移它会动）。
	var seen: Array[Vector3] = []
	for i in 14:
		pose.update(0.05, 2.0, true, false, true)
		seen.append(sk.get_bone_global_pose(ankle).origin)
	var swing := _max_pairwise(seen)
	check_ge(swing, 0.1, "腿程序化接管后脚踝骨必须真的摆动（walk 摆幅下实测应远超 0.1 骨架单位）")
	ref.queue_free()


## 对照组：pose_arms=true 时上臂骨**在**受控清单内，且肘部实际被驱动（与 false 分支行为不同）。
## 用「肘骨离 rest 的位移」比较两条分支——不能只断言清单成员（那样换写法也能蒙混）。
func test_full_pose_drives_elbow_unlike_layered() -> void:
	var delta_layered := _elbow_motion(true)
	var delta_full := _elbow_motion(false)
	check_ge(delta_full, delta_layered * 1.5,
		"pose_arms=true 必须比 pose_arms=false 明显更多地驱动肘部（实测差值应显著）")


## 返回：在给定 pose_arms 下，update 后「肘骨 global origin 相对 rest」的位移（骨架单位）。
func _elbow_motion(layered: bool) -> float:
	var ctx := _make_cat_context()
	var ref: Node3D = ctx[0]
	var sk: Skeleton3D = ctx[2]
	if sk == null:
		return 0.0
	var pose = PoseScript.new()
	pose.pose_arms = not layered
	if not pose.setup(sk, ref):
		ref.queue_free()
		return 0.0
	var elbow := int(pose.debug_indices["elbow_r"])
	check_true(elbow >= 0, "必须解析出肘骨")
	var rest := sk.get_bone_global_pose(elbow).origin
	for i in 14:
		pose.update(0.05, 2.0, true, false, true)
	var now := sk.get_bone_global_pose(elbow).origin
	ref.queue_free()
	return rest.distance_to(now)


func _max_pairwise(v: Array[Vector3]) -> float:
	var m := 0.0
	for i in v.size():
		for j in range(i + 1, v.size()):
			m = maxf(m, v[i].distance_to(v[j]))
	return m


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for c in root.get_children():
		var f := _find_skeleton(c)
		if f != null:
			return f
	return null


# ---------------------------------------------------------------------------
# ④ 接线口径 + 降级（默认不破坏基线）
# ---------------------------------------------------------------------------

## 三个开关默认必须关闭 / 保守：不改变既有默认模型（miku.glb）与旧单臂持械行为。
func test_layered_switches_default_off() -> void:
	var model := MikuModel.new()
	check_false(model.procedural_legs_enabled, "procedural_legs_enabled 默认必须 false（保基线）")
	check_false(model.hold_ik_torso_anchor, "hold_ik_torso_anchor 默认必须 false（实测挂钩残差 > 收益）")
	check_false(model.hold_ik_enabled, "hold_ik_enabled 默认必须 false（不破坏旧单臂行为）")
	model.free()


## `procedural_legs_enabled=false`（默认）时，**不得**启用「分层」模式
## （`pose_arms == false` 的那种）。
##
## ⚠ 本用例在 2026-10-07 改过断言方向，原因是一次**真实缺陷**（不是重构）：
##   原断言是「cat 有 idle 剪辑 ⇒ 默认不启用程序化姿态」，而cat 的 idle 剪辑经实测
##   是 **0.083 s 的 T-pose 定格**（98 条骨骼轨道只有 1 条会动，双腿骨一条轨道都没有）。
##   那条断言等于**把 T-pose 当成正确行为锁住** —— 用户实机看到的就是「cat 模型 T-pose 不动」。
##   修复引入「退化剪辑」判据后，cat 的 idle 被判为退化 ⇒ 没有可用状态剪辑
##   ⇒ **回退到全程序化姿态**（`pose_arms = true`）才是正确行为。
##   ⇒ 断言改为锁「**默认不是分层模式**」这一真正的不变量（分层仍需显式开关），
##      同时锁「退化 idle 确实被判退化」，让这个修复不会被静默回退。
func test_default_does_not_enable_layered_for_cat() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.procedural_legs_enabled = false # 默认
	model.hold_ik_enabled = true
	# ⚠ UAL 现在默认 true（2026-10-07 按用户要求），它与程序化姿态**互斥**、
	#   且优先级更高 ⇒ 想验「程序化姿态这条路径」必须先显式关掉 UAL。
	#   （这本身就是一条不变量：两个驱动者不得同时存在，见下一条断言。）
	model.ual_locomotion_enabled = false
	add_child(model)
	check_false(model.is_ual_locomotion_active(), "前置：本用例要验程序化路径，UAL 必须关闭")
	# 前置：cat 的 idle 剪辑必须被判为「退化」（这是本次修复的核心判据）
	check_true(model._clip_is_degenerate(String(model._state_clips.get("idle", ""))),
		"cat 的 idle（0.083 s / 会动轨道 1.0%）必须被判为退化剪辑")
	# 默认不得进入「分层」模式（pose_arms=false 要显式开 procedural_legs_enabled 才有）
	check_true(model._procedural == null or model._procedural.pose_arms,
		"默认（procedural_legs_enabled=false）下不得启用**分层**模式（pose_arms 必须为 true）")
	# 修复后的正确行为：因无可用状态剪辑 ⇒ 回退全程序化姿态，角色不再 T-pose
	check_true(model._procedural != null and model._procedural.valid,
		"cat 的唯一状态剪辑退化 ⇒ 必须回退 MikuProceduralPose（否则角色僵在 T-pose）")
	model.queue_free()


## UAL 与程序化姿态**互斥**：两者都是「腿的驱动者」，同时存在就会抢同一批骨。
## ⚠ 这条在 UAL 默认改为 true 之后更重要了 —— 以前默认关，几乎撞不上；
##   现在默认开，必须确保「UAL 有效时程序化姿态压根没被建」。
func test_ual_and_procedural_never_coexist_on_cat() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	# UAL 走默认（true）
	add_child(model)
	check_true(model.is_ual_locomotion_active(), "前置：UAL 默认应已接管（用户要求开启）")
	check_true(model._procedural == null,
		"UAL 有效时不得同时建程序化姿态（两者都写腿骨 ⇒ 会互抢）")
	# 反向：关掉 UAL ⇒ 必须由程序化姿态接管（绝不出现「没腿」）
	model.ual_locomotion_enabled = false
	model.load_model(CAT_MODEL)
	check_false(model.is_ual_locomotion_active(), "关闭后 UAL 不得接管")
	check_true(model._procedural != null and model._procedural.valid,
		"UAL 关闭后必须有程序化姿态接管腿（绝不出现「没腿」）")
	model.queue_free()


# ---------------------------------------------------------------------------
# ⑤ WeaponHoldIK 躯干锚点（默认关；开启后建 BoneAttachment3D）
# ---------------------------------------------------------------------------

## 造一个「标准人形」合成骨架（只含手臂链 + hips），供躯干锚点结构用例使用。
func _make_arm_skeleton() -> Skeleton3D:
	var sk := Skeleton3D.new()
	var defs := [
		["hips", Vector3(0, 0.9, 0), -1],
		["upper_arm.L_1", Vector3(0.10, 1.10, 0.0), 0],
		["lower_arm.L_2", Vector3(0.32, 1.10, 0.0), 1],
		["hand.L_3", Vector3(0.54, 1.10, 0.0), 2],
		["upper_arm.R_4", Vector3(-0.10, 1.10, 0.0), 0],
		["lower_arm.R_5", Vector3(-0.32, 1.10, 0.0), 4],
		["hand.R_6", Vector3(-0.54, 1.10, 0.0), 5],
	]
	for d in defs:
		var idx := sk.add_bone(String(d[0]))
		sk.set_bone_rest(idx, Transform3D(Basis(), d[1]))
		if int(d[2]) >= 0:
			sk.set_bone_parent(idx, int(d[2]))
	return sk


## 默认（attach_targets_to_torso=false）：目标 / 极节点是骨架的**直接子节点**（与已验证 spike 一致）。
func test_hold_ik_targets_default_direct_children() -> void:
	check_false(HoldIKScript.new().attach_targets_to_torso,
		"attach_targets_to_torso 默认必须 false（保持旧 spike 行为）")
	var sk := _make_arm_skeleton()
	var model := Node3D.new()
	var ik = HoldIKScript.new()
	check_true(ik.setup(sk, model), "标准骨架应能搭起 IK")
	var direct := 0
	for c in sk.get_children():
		if String(c.name).begins_with("HoldIK_Target_"):
			direct += 1
	check_eq(direct, 2, "默认应把握持点直接挂在骨架下（2 个）")
	sk.free()
	model.free()


## 开启躯干锚点：建一个 HoldIK_Torso 的 BoneAttachment3D，把握持点挂到它下面，并引用 chest 骨。
func test_hold_ik_torso_anchor_builds_attachment() -> void:
	var sk := _make_arm_skeleton()
	var model := Node3D.new()
	var ik = HoldIKScript.new()
	ik.attach_targets_to_torso = true
	check_true(ik.setup(sk, model), "标准骨架应能搭起 IK（含躯干锚点）")
	check_true(ik._torso_attached, "应成功建躯干锚点（左右上臂共同祖先 = hips）")
	var torso: BoneAttachment3D = null
	for c in sk.get_children():
		if String(c.name) == "HoldIK_Torso":
			torso = c
	check_true(torso != null, "必须建 HoldIK_Torso 锚点节点")
	if torso != null:
		check_eq(String(torso.bone_name), "hips", "锚点应引用左右上臂的共同祖先骨（hips）")
		var under := 0
		for c in torso.get_children():
			if String(c.name).begins_with("HoldIK_Target_"):
				under += 1
		check_eq(under, 2, "两个握持点应挂在锚点下")
	# teardown 必须把锚点也拆掉（不留垃圾）
	ik.teardown()
	check_false(ik.valid, "teardown 后 valid 必须为 false")
	sk.free()
	model.free()


## 架构纪律：分层是**纯视觉**，不得走 RPC；且分层只能靠 pose_arms 这一条通道协调，不得另起并行姿态系统。
## 用「计数」而不是「逐行断言」——后者会让断言数随文件行数漂移（本项目 §4-15 要求断言数变化可解释）。
func test_layered_is_pure_visual_no_rpc() -> void:
	for path in ["res://scripts/entities/miku_procedural_pose.gd",
			"res://scripts/entities/weapon_hold_ik.gd"]:
		check_eq(_count_rpc(_read_source(path)), 0,
			"%s 不得含 @rpc：姿态是纯视觉表现" % path.get_file())


func _count_rpc(src: String) -> int:
	var n := 0
	for raw in src.split("\n"):
		if _strip_comment(raw).find("@rpc") >= 0:
			n += 1
	return n


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


func _strip_comment(line: String) -> String:
	var i := line.find("#")
	return line if i < 0 else line.substr(0, i)
