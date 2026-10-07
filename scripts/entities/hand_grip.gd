class_name HandGrip
extends RefCounted
## 手指抓握（纯逻辑，无场景依赖 → 可 headless 逐值断言）
##
## ## 它解决什么
## `WeaponHoldIK` 只把每臂的**上臂 / 前臂 / 手**拉到握持点，**手指没被驱动** ⇒ 手是
## **五指大张「拍」在枪上**，不像握住。本类给出「主握 / 副握」两侧各指的弯曲角，
## 以及把角度写成骨骼姿态所需的纯函数；**骨骼应用**（modifier）在
## `hand_grip_modifier.gd`，两者分离以便 headless 断言。
##
## ## 实测结论（探针 `tools/probe_grip_axis.gd`，cat_hatsune_miku，见工程报告）
## 手骨每节局部 rest = `(0, +length, 0)` ⇒ 手指沿局部 **+Y** 延伸。
##   · **弯曲轴 = 局部 X**：绕局部 X 旋转，指尖在**掌背平面内**弯（朝掌心）；
##     绕局部 Z 是**左右侧摆**（不是握）。— 由「指尖世界位移落在 X-Y 平面 / Z-Y 平面」判定。
##   · **符号 = −1（左右手相同）**：本模型（Rigify 导出）左右手的局部 X 轴**未镜像**，
##     故两手都用同一个符号。判据：拇指位于手指**所弯向的一侧**（T-pose 掌心朝下时拇指在前下方），
##     −X 使指尖朝拇指侧收拢；+X 朝手背翻（hyperextension）。
##   · 角度量级：握把（右手）比护木（左手）弯得多；每指 `[proximal, intermediate, distal]`。
##
## ## 坐标系约定
## 角度是**绕骨骼局部轴的弧度**；符号在 `flex_sign()` 里，作用于主轴 `FLEX_AXIS`。

enum Role { GRIP, FOREGRIP }

const FINGERS: Array[String] = ["thumb", "index", "middle", "ring", "little"]
const JOINTS: Array[String] = ["proximal", "intermediate", "distal"]

## 弯曲轴（局部）。实测：绕局部 X = 朝掌心弯；绕局部 Z = 侧摆（不是握）。
const FLEX_AXIS := Vector3(1, 0, 0)
## 弯曲符号（实测左右手同为 -1）；键 = 侧别（"l" / "r"）。
const FLEX_SIGN := {"l": -1.0, "r": -1.0}
## 拇指单独符号（对掌方向可能与四指不同；实测同样为 -1）。
const THUMB_SIGN := {"l": -1.0, "r": -1.0}

## 主握（右手在握把）各指 [proximal, intermediate, distal]（弧度）。
const GRIP_ANGLES := {
	"thumb": [0.30, 0.50, 0.30],
	"index": [0.95, 1.15, 0.55],
	"middle": [1.00, 1.20, 0.60],
	"ring": [0.95, 1.15, 0.55],
	"little": [0.90, 1.10, 0.55],
}
## 副握（左手在护木，圆柱更粗、弯得略浅）各指 [proximal, intermediate, distal]（弧度）。
const FOREGRIP_ANGLES := {
	"thumb": [0.25, 0.40, 0.25],
	"index": [0.75, 0.95, 0.50],
	"middle": [0.80, 1.00, 0.55],
	"ring": [0.75, 0.95, 0.50],
	"little": [0.70, 0.90, 0.50],
}

const _ROLE_TABLES := {
	Role.GRIP: GRIP_ANGLES,
	Role.FOREGRIP: FOREGRIP_ANGLES,
}


# ---------------------------------------------------------------------------
# 骨名解析（纯函数）
# ---------------------------------------------------------------------------

## 该侧 15 根指骨的**骨名前缀**（实测骨名带数字后缀，如 `index_proximal.L_56`，
## 故这里返回可 `begins_with` 匹配的前缀，全部小写）。
static func finger_bone_names(side: String) -> Array:
	var out: Array = []
	for finger in FINGERS:
		for joint in JOINTS:
			out.append("%s_%s.%s" % [finger, joint, side])
	return out


## 把「(finger, joint)」映射到给定骨名数组里的索引；找不到为 -1。
## 返回键形如 `"index:proximal"`。
static func resolve_finger_bones(names: PackedStringArray, side: String) -> Dictionary:
	var out := {}
	for finger in FINGERS:
		for joint in JOINTS:
			out["%s:%s" % [finger, joint]] = _find_prefix(names, "%s_%s.%s" % [finger, joint, side])
	return out


static func _find_prefix(names: PackedStringArray, prefix: String) -> int:
	for i in names.size():
		if String(names[i]).to_lower().begins_with(prefix):
			return i
	return -1


## 15 根指骨是否全部解析到（modifier 用它决定是否启用）。
static func resolved_is_complete(resolved: Dictionary) -> bool:
	for finger in FINGERS:
		for joint in JOINTS:
			if int(resolved.get("%s:%s" % [finger, joint], -1)) < 0:
				return false
	return true


# ---------------------------------------------------------------------------
# 角度（纯函数）
# ---------------------------------------------------------------------------

## 给定角色（Role.GRIP / Role.FOREGRIP）返回各指 `[proximal, intermediate, distal]`。
static func grip_angles(role: int) -> Dictionary:
	return _ROLE_TABLES.get(role, GRIP_ANGLES)


## 单关节的无符号弯曲角（弧度）。
static func grip_angle(finger: String, joint: String, role: int) -> float:
	var table: Dictionary = grip_angles(role)
	var angles: Array = table.get(finger, [0.0, 0.0, 0.0])
	var j := JOINTS.find(joint)
	if j < 0 or j >= angles.size():
		return 0.0
	return float(angles[j])


## 该「指 × 侧」的弯曲符号（拇指用 THUMB_SIGN，其余用 FLEX_SIGN）。
static func flex_sign(side: String, finger: String = "") -> float:
	if finger == "thumb":
		return float(THUMB_SIGN.get(side, -1.0))
	return float(FLEX_SIGN.get(side, -1.0))


## 带符号的弯曲角：`flex_sign × grip_angle`。modifier 直接把它喂给 `Basis`。
static func signed_angle(finger: String, joint: String, role: int, side: String) -> float:
	return flex_sign(side, finger) * grip_angle(finger, joint, role)


## 单关节的局部旋转基（绕 `FLEX_AXIS` 转 `signed_angle`）。
static func flex_rotation(finger: String, joint: String, role: int, side: String) -> Basis:
	return Basis(FLEX_AXIS, signed_angle(finger, joint, role, side))


# ---------------------------------------------------------------------------
# 链式合成（纯函数 + 一个静态应用器）
# ---------------------------------------------------------------------------

## 子骨相对父骨的局部变换（用于保留原姿态偏移）。
static func local_of(parent_global: Transform3D, child_global: Transform3D) -> Transform3D:
	return parent_global.affine_inverse() * child_global


## 把「局部偏移 `child_local` + 绕自身原点的旋转 `rot`」挂到**已更新**的父变换上。
## （绕骨骼自身原点旋转 = 右乘一个纯旋转 Transform3D。）
static func next_bone_pose(parent_new: Transform3D, child_local: Transform3D, rot: Basis) -> Transform3D:
	return parent_new * child_local * Transform3D(rot, Vector3.ZERO)


## 把抓握姿态**写在真实骨架上**（modifier 与 headless 测试共用）。
## `hand_idx` = 手骨索引；`resolved` = `resolve_finger_bones` 的结果。
## 逐指沿 hand → proximal → intermediate → distal 累积（每节绕自己的局部轴转）。
static func apply_chain(skeleton: Skeleton3D, hand_idx: int,
		resolved: Dictionary, role: int, side: String) -> void:
	if skeleton == null or hand_idx < 0:
		return
	var hand_global := skeleton.get_bone_global_pose(hand_idx)
	for finger in FINGERS:
		var parent_new := hand_global
		var parent_orig := hand_global
		for joint in JOINTS:
			var idx := int(resolved.get("%s:%s" % [finger, joint], -1))
			if idx < 0:
				continue
			var child_global := skeleton.get_bone_global_pose(idx)
			var child_local := local_of(parent_orig, child_global)
			var rot := flex_rotation(finger, joint, role, side)
			var next := next_bone_pose(parent_new, child_local, rot)
			skeleton.set_bone_global_pose(idx, next)
			parent_orig = child_global
			parent_new = next
