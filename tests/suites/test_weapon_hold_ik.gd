extends TestSuite
## 双手持枪 IK（WeaponHoldIK）回归基线
##
## 背景：用户抱怨「人物姿势都不是正常拿枪的」。根因是**单臂**持械 —— 武器位置跟右手骨，
## 但朝向被强制固定为角色正前方；左手完全不参与。本能力用 Godot 4.4+ 的 `TwoBoneIK3D`
## 把**双臂**拉到「右手握把 + 左手护木」两个握持点，武器坐标系由两点推导。
##
## 本 suite 锁五组不变量：
##   ① **骨骼名解析**：标准人形骨架（Blender/Rigify 命名）能解析出左右手臂链；
##      辅助骨（Twist/手指/IK/肩锁骨）不得被误当手臂；乱码骨名（miku.glb）必须解析失败。
##   ② **两骨链结构**：符合 `TwoBoneIK3D` 的硬要求（end 是 middle 的子、middle 是 root 的子）。
##   ③ **武器坐标系推导**（核心）：枪身轴 = 右手→左手连线、右手性正交基、原点回退；
##      **改变握持点必须改变枪口朝向**（这正是「朝向不再被固定为正前方」的语义）；
##      退化输入（两点重合 / 与上方向共线）不得产生 NaN 或非正交基。
##   ④ **握持点几何**：随臂展按比例缩放（换模型不改姿势比例）。
##   ⑤ **接线口径 + 降级**：默认关闭（不破坏既有单臂行为）、旧路径保留、不走 RPC、
##      modifier 用 settings 索引 API；合成骨架能搭起链、乱码骨架安全失败。
##
## 断言口径（§4-16 双向）：几何类断言按**语义**写（正交性 / 方向关系 / 退化安全性），
## 不写死「必须用某个公式」；`tools/mutation_weapon_hold.py` 另配**守恒对照组**验证不误杀。

const HOLD_IK_SRC := "res://scripts/entities/weapon_hold_ik.gd"
const MIKU_MODEL_SRC := "res://scripts/entities/miku_model.gd"
const PLAYER_SRC := "res://scripts/player.gd"
const WeaponHoldIKScript := preload("res://scripts/entities/weapon_hold_ik.gd")


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


func _strip_comment(line: String) -> String:
	var i := line.find("#")
	return line if i < 0 else line.substr(0, i)


static func _n(v: Vector3) -> Vector3:
	return v.normalized()


## 造一个「标准人形」合成骨架（只含必需的手臂骨 + 父链），供结构类用例使用。
func _make_standard_skeleton() -> Skeleton3D:
	var sk := Skeleton3D.new()
	# 骨架空间：右臂在 -X、左臂在 +X、正面 +Z（项目约定）
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


# ---------------------------------------------------------------------------
# ① 骨骼名解析
# ---------------------------------------------------------------------------

## 标准 Rigify/Blender 命名（正是 cat_hatsune_miku 的实际骨名）必须解析出完整左右手臂链。
func test_resolve_arm_chain_on_standard_names() -> void:
	var names := PackedStringArray([
		"hips_106", "spine_95", "chest_94",
		"shoulder.L_69", "upper_arm.L_68", "lower_arm.L_67", "hand.L_66",
		"shoulder.R_88", "upper_arm.R_87", "lower_arm.R_86", "hand.R_85",
		"index.L_60", "thumb.L_61", "lower_arm_twist.L_70",
	])
	var chain := WeaponHoldIKScript.resolve_arm_chain(names)
	check_eq(int(chain["upper_l"]), 4, "左 上臂应命中 upper_arm.L_68")
	check_eq(int(chain["lower_l"]), 5, "左 前臂应命中 lower_arm.L_67")
	check_eq(int(chain["hand_l"]), 6, "左 手应命中 hand.L_66")
	check_eq(int(chain["upper_r"]), 8, "右 上臂应命中 upper_arm.R_87")
	check_eq(int(chain["lower_r"]), 9, "右 前臂应命中 lower_arm.R_86")
	check_eq(int(chain["hand_r"]), 10, "右 手应命中 hand.R_85")


## 左右不得混淆：左手 x>0、右手 x<0 由骨名判定，与骨序无关。
func test_resolve_arm_chain_does_not_swap_sides() -> void:
	var names := PackedStringArray([
		"upper_arm.R_1", "lower_arm.R_2", "hand.R_3",
		"upper_arm.L_4", "lower_arm.L_5", "hand.L_6",
	])
	var chain := WeaponHoldIKScript.resolve_arm_chain(names)
	check_eq(int(chain["upper_r"]), 0, "右 上臂应是第 0 根")
	check_eq(int(chain["upper_l"]), 3, "左 上臂应是第 3 根")


## 辅助骨不得被当成手臂：Twist / 手指 / IK / 肩锁骨 都要排除。
func test_resolve_arm_chain_excludes_helper_bones() -> void:
	var names := PackedStringArray([
		"shoulder.L_1", "upper_arm_twist.L_2",
		"index.L_3", "thumb.L_4", "hand_ik.L_5",
		"upper_arm.L_6", "lower_arm.L_7", "hand.L_8",
	])
	var chain := WeaponHoldIKScript.resolve_arm_chain(names)
	check_eq(int(chain["upper_l"]), 5, "上臂不得命中 shoulder / twist / ik")
	check_eq(int(chain["lower_l"]), 6, "前臂不得命中辅助骨")
	check_eq(int(chain["hand_l"]), 7, "手不得命中手指骨 / ik 目标")


## 乱码骨名（默认模型 miku.glb 的真实情况）必须解析失败 —— 返回全 -1，而不是瞎猜。
func test_resolve_arm_chain_fails_on_garbled_names() -> void:
	var names := PackedStringArray(["���.R_0269", "���.L_0270", "������.R_0249", "center_013"])
	var chain := WeaponHoldIKScript.resolve_arm_chain(names)
	for key in ["upper_l", "lower_l", "hand_l", "upper_r", "lower_r", "hand_r"]:
		check_eq(int(chain[key]), -1, "乱码骨名不得解析出 %s" % key)


# ---------------------------------------------------------------------------
# ② 两骨链结构（TwoBoneIK3D 的硬要求）
# ---------------------------------------------------------------------------

func test_two_bone_chain_accepts_correct_parenting() -> void:
	# 0=upper 1=lower 2=hand，parent[1]=0, parent[2]=1
	check_true(WeaponHoldIKScript.is_two_bone_chain(0, 1, 2, PackedInt32Array([-1, 0, 1])),
		"end 是 middle 的子、middle 是 root 的子 → 合法链")


func test_two_bone_chain_rejects_broken_parenting() -> void:
	# hand 的父不是 lower（都挂在 root 下）→ 不合法
	check_false(WeaponHoldIKScript.is_two_bone_chain(0, 1, 2, PackedInt32Array([-1, 0, 0])),
		"hand 与 lower 平级 → 非法链（IK 会算错）")
	check_false(WeaponHoldIKScript.is_two_bone_chain(0, 1, 2, PackedInt32Array([-1, 2, 1])),
		"lower 的父不是 upper → 非法链")


func test_two_bone_chain_rejects_missing_bones() -> void:
	check_false(WeaponHoldIKScript.is_two_bone_chain(-1, 1, 2, PackedInt32Array([-1, 0, 1])),
		"缺骨（-1）必须判非法")


# ---------------------------------------------------------------------------
# ③ 武器坐标系推导（核心：朝向由握持决定）
# ---------------------------------------------------------------------------

func test_weapon_barrel_axis_follows_grip_line() -> void:
	var r := Vector3(-0.1, 1.0, 0.1)
	var l := Vector3(0.0, 1.05, 0.5)
	var t := WeaponHoldIKScript.derive_weapon_transform(r, l, Vector3.UP, 0.0)
	var expected := (l - r).normalized()
	check_near(t.basis.z.normalized().distance_to(expected), 0.0, 0.0001,
		"武器 +Z（枪口）必须等于「右手→左手」连线方向")


## 最核心的语义：**握持点变了，枪口朝向必须跟着变** —— 这正是「不再无条件朝正前方」。
func test_weapon_orientation_changes_with_grip() -> void:
	var r := Vector3(0.0, 1.0, 0.0)
	var straight := WeaponHoldIKScript.derive_weapon_transform(
		r, Vector3(0.0, 1.0, 0.5), Vector3.UP, 0.0).basis.z.normalized()
	var turned := WeaponHoldIKScript.derive_weapon_transform(
		r, Vector3(0.45, 1.0, 0.30), Vector3.UP, 0.0).basis.z.normalized()
	check_true(straight.distance_to(turned) > 0.2,
		"改变握持点必须显著改变枪口朝向（否则又退回「固定朝正前方」的旧缺陷）")
	check_near(straight.distance_to(Vector3(0, 0, 1)), 0.0, 0.0001,
		"握持点在正前方时枪口应朝 +Z")


## 结果必须是**右手性正交基**（行列式 ≈ +1）。左手性基会让枪模型镜像 / 翻转。
func test_weapon_basis_is_orthonormal_right_handed() -> void:
	var t := WeaponHoldIKScript.derive_weapon_transform(
		Vector3(-0.1, 1.0, 0.1), Vector3(0.1, 1.1, 0.4), Vector3.UP, 0.0)
	var b := t.basis
	check_near(b.x.length(), 1.0, 0.0001, "X 轴应为单位向量")
	check_near(b.y.length(), 1.0, 0.0001, "Y 轴应为单位向量")
	check_near(b.z.length(), 1.0, 0.0001, "Z 轴应为单位向量")
	check_near(b.x.dot(b.y), 0.0, 0.0001, "X ⟂ Y")
	check_near(b.x.dot(b.z), 0.0, 0.0001, "X ⟂ Z")
	check_near(b.y.dot(b.z), 0.0, 0.0001, "Y ⟂ Z")
	check_near(b.determinant(), 1.0, 0.0001, "必须是右手性正交基（det=+1）")


## 上方向提示只用于定滚转：枪身轴不受其长度缩放影响；且 Y 轴（枪的「上」）应接近 up_hint。
func test_weapon_up_axis_tracks_up_hint() -> void:
	var r := Vector3(0.0, 1.0, 0.0)
	var l := Vector3(0.0, 1.0, 0.5)
	var t := WeaponHoldIKScript.derive_weapon_transform(r, l, Vector3(0, 1, 0).normalized() * 7.0, 0.0)
	check_near(t.basis.y.normalized().distance_to(Vector3.UP), 0.0, 0.0001,
		"枪的「上」应落在 up_hint 方向（握持方向 → 滚转由角色上方向定）")
	check_near(t.basis.z.normalized().distance_to(Vector3(0, 0, 1)), 0.0, 0.0001,
		"up_hint 的长度不得影响枪身轴方向")


func test_weapon_origin_retreats_along_barrel_from_right_grip() -> void:
	var r := Vector3(-0.1, 1.0, 0.1)
	var l := Vector3(0.0, 1.05, 0.5)
	var back := 0.12
	var t := WeaponHoldIKScript.derive_weapon_transform(r, l, Vector3.UP, back)
	var expected := r - (l - r).normalized() * back
	check_near(t.origin.distance_to(expected), 0.0, 0.0001,
		"武器原点应落在「右手握把点沿枪身向后 back」处")


## 退化输入不得产生 NaN / 非正交基（否则骨骼与武器变换会被污染）。
func test_weapon_derivation_survives_degenerate_input() -> void:
	var coincident := WeaponHoldIKScript.derive_weapon_transform(
		Vector3(0.2, 1.0, 0.0), Vector3(0.2, 1.0, 0.0), Vector3.UP, 0.1)
	check_true(is_finite(coincident.origin.x + coincident.origin.y + coincident.origin.z),
		"两点重合不得产生 NaN 原点")
	check_near(coincident.basis.determinant(), 1.0, 0.0001,
		"两点重合时仍应是右手性正交基（有兜底方向）")
	var colinear := WeaponHoldIKScript.derive_weapon_transform(
		Vector3(0.0, 1.0, 0.0), Vector3(0.0, 1.5, 0.0), Vector3(0, 1, 0), 0.0)
	check_true(is_finite(colinear.basis.x.x + colinear.basis.y.y + colinear.basis.z.z),
		"枪身轴与 up_hint 共线不得产生 NaN")
	check_near(colinear.basis.determinant(), 1.0, 0.0001,
		"共线时仍应是右手性正交基")


## 调试开关接线：player.gd 用**裸键** T 切换双手 IK（纯本地演示开关）。
## ⚠ 必须是裸键而不是 [input] 动作：项目铁律禁止改 project.godot 的输入映射表（§4-17）。
func test_player_wires_hold_ik_toggle_to_raw_key() -> void:
	var src := _read_source(PLAYER_SRC)
	check_true(src.find("toggle_hold_ik()") >= 0, "player.gd 必须接线 toggle_hold_ik()（T 键演示开关）")
	check_true(src.find("physical_keycode == KEY_T") >= 0,
		"应用裸键判定（physical_keycode == KEY_T），而不是新增 [input] 动作")
	check_false(src.find("Input.is_action_pressed(\"hold_ik\"") >= 0,
		"不得为持枪 IK 新增输入动作（会牵动 project.godot）")


# ---------------------------------------------------------------------------
# ④ 握持点几何（随臂展按比例缩放）
# ---------------------------------------------------------------------------

func test_grip_point_scales_with_reach() -> void:
	var shoulder := Vector3(0.1, 1.1, 0.0)
	var coeff := {"front": 0.5, "up": -0.2, "right": 0.1}
	var a := WeaponHoldIKScript.grip_point(shoulder, 1.0, Vector3.BACK, Vector3.UP, Vector3.LEFT, coeff)
	var b := WeaponHoldIKScript.grip_point(shoulder, 2.0, Vector3.BACK, Vector3.UP, Vector3.LEFT, coeff)
	check_near(a.distance_to(shoulder) * 2.0, b.distance_to(shoulder), 0.0001,
		"握持点偏移必须与臂展成正比（换模型时姿势比例不变）")


func test_grip_point_direction_coefficients_are_interpreted() -> void:
	var shoulder := Vector3.ZERO
	var front_only := WeaponHoldIKScript.grip_point(
		shoulder, 1.0, Vector3.BACK, Vector3.UP, Vector3.LEFT, {"front": 1.0, "up": 0.0, "right": 0.0})
	check_near(front_only.distance_to(Vector3.BACK), 0.0, 0.0001, "front 系数作用在「前」方向")
	var up_only := WeaponHoldIKScript.grip_point(
		shoulder, 1.0, Vector3.BACK, Vector3.UP, Vector3.LEFT, {"front": 0.0, "up": 1.0, "right": 0.0})
	check_near(up_only.distance_to(Vector3.UP), 0.0, 0.0001, "up 系数作用在「上」方向")


# ---------------------------------------------------------------------------
# ⑤ 接线口径 + 降级
# ---------------------------------------------------------------------------

## 默认必须**关闭**：不改变既有单臂持械行为（不破坏 293 用例基线）。用真实实例断言，不锁字面量。
func test_hold_ik_is_disabled_by_default() -> void:
	var model := MikuModel.new()
	check_false(model.hold_ik_enabled, "hold_ik_enabled 默认必须是 false（不破坏基线）")
	check_false(model.is_hold_ik_available(), "未载入模型时 IK 应不可用")
	model.set_hold_ik_enabled(true)
	check_true(model.hold_ik_enabled, "set_hold_ik_enabled(true) 应写开关")
	check_false(model.is_hold_ik_available(), "无骨架时即便打开开关也不得「可用」")
	model.free()


## 旧路径必须保留：关闭 IK 时第三人称仍走 `_follow_hand_bone`。
func test_legacy_hand_follow_path_is_preserved() -> void:
	var src := _read_source(MIKU_MODEL_SRC)
	check_true(src.find("func _follow_hand_bone") >= 0, "旧的单臂跟随函数不得删除（降级路径）")
	var proc := src.find("func _process(")
	var body := src.substr(proc, src.find("\nfunc ", proc + 1) - proc)
	check_true(body.find("_follow_hand_bone()") >= 0, "_process 必须仍保留 _follow_hand_bone 分支")


## 打开 IK 时 `_process` 应优先用推导出来的武器变换（而不是手骨位置）。
func test_process_prefers_ik_weapon_transform_when_enabled() -> void:
	var src := _read_source(MIKU_MODEL_SRC)
	var proc := src.find("func _process(")
	var body := src.substr(proc, src.find("\nfunc ", proc + 1) - proc)
	var i_ik := body.find("get_weapon_transform()")
	var i_legacy := body.find("_follow_hand_bone()")
	check_true(i_ik >= 0, "_process 启用分支必须调用 get_weapon_transform()")
	if i_ik >= 0 and i_legacy >= 0:
		check_true(i_ik < i_legacy, "IK 分支必须排在旧手骨分支之前（先 IK，否则被旧路径盖掉）")


## 架构纪律：新能力是纯视觉，**不得**走 RPC（各端本地自行摆姿势）。
## ⚠ 只查本能力的两个文件 —— player.gd 本来就有网络 RPC（不是本能力的），不能一并扫。
func test_hold_ik_is_not_rpc_driven() -> void:
	for path in [HOLD_IK_SRC, MIKU_MODEL_SRC]:
		var src := _read_source(path)
		for raw in src.split("\n"):
			check_false(_strip_comment(raw).find("@rpc") >= 0,
				"%s 不得含 @rpc：持枪 IK 是纯视觉表现" % path.get_file())


## 引擎 API 口径：必须用 Godot 4.4+ 的 **settings 索引 API**。
## ⚠ 有人若退回「同名属性」写法（`root_bone_name = ...`），运行期静默无效（IK 不动）——
##   这条锁住「必须调用带 index 的 setter」。
func test_hold_ik_uses_indexed_settings_api() -> void:
	var src := _read_source(HOLD_IK_SRC)
	for call in ["set_setting_count(", "set_root_bone_name(0,", "set_middle_bone_name(0,",
			"set_end_bone_name(0,", "set_target_node(0,", "set_pole_node(0,"]:
		check_true(src.find(call) >= 0, "WeaponHoldIK 必须调用 %s" % call)


## 合成标准骨架应能搭起双臂 IK 链（真 integration：建 modifier + 目标/极节点）。
func test_setup_builds_ik_on_standard_skeleton() -> void:
	var sk := _make_standard_skeleton()
	var model := Node3D.new()
	var ik = WeaponHoldIKScript.new()
	var ok: bool = ik.setup(sk, model)
	check_true(ok, "标准骨架应能搭起 IK 链")
	check_true(ik.valid, "搭起后 valid 应为 true")
	check_eq(String(ik.debug_names.get("upper_r", "")), "upper_arm.R_4", "右臂链上臂应解析到 upper_arm.R_4")
	# 两条 IK + 两个目标 + 两个极节点 = 6 个子节点挂在骨架下
	var ik_nodes := 0
	var target_nodes := 0
	for c in sk.get_children():
		if c is TwoBoneIK3D:
			ik_nodes += 1
		if String(c.name).begins_with("HoldIK_Target_"):
			target_nodes += 1
	check_eq(ik_nodes, 2, "应建 2 条 TwoBoneIK3D（左右臂）")
	check_eq(target_nodes, 2, "应建 2 个握持点目标节点")
	# 默认不启用（active=false），避免无谓开销
	ik.set_enabled(false)
	check_false(ik.is_enabled(), "未启用时 is_enabled() 应为 false")
	sk.free()
	model.free()


## 乱码骨架（缺标准手臂骨）必须**安全失败**：不建任何节点、不崩。
func test_setup_fails_safely_on_garbled_skeleton() -> void:
	var sk := Skeleton3D.new()
	var i0 := sk.add_bone("a_1")
	sk.set_bone_rest(i0, Transform3D(Basis(), Vector3(0, 1, 0)))
	var i1 := sk.add_bone("b_2")
	sk.set_bone_rest(i1, Transform3D(Basis(), Vector3(0, 2, 0)))
	sk.set_bone_parent(i1, i0)
	var model := Node3D.new()
	var ik = WeaponHoldIKScript.new()
	check_false(ik.setup(sk, model), "乱码骨名必须 setup 失败")
	check_false(ik.valid, "失败后 valid 必须为 false")
	check_eq(sk.get_child_count(), 0, "失败时不得在骨架下建任何节点（不留垃圾）")
	sk.free()
	model.free()


## 目标节点必须挂在 Skeleton3D 下（骨架空间坐标随角色变换自动跟随）——否则姿势不贴身体。
func test_grip_targets_are_children_of_skeleton() -> void:
	var sk := _make_standard_skeleton()
	var model := Node3D.new()
	var ik = WeaponHoldIKScript.new()
	ik.setup(sk, model)
	for c in sk.get_children():
		if String(c.name).begins_with("HoldIK_Target_"):
			check_eq(c.get_parent(), sk, "握持点目标节点必须是骨架的子节点")
	sk.free()
	model.free()
