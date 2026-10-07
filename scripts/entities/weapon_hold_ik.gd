class_name WeaponHoldIK
extends RefCounted
## 双手持枪 IK（Spike / 可切换能力）
##
## ## 它解决什么
## 旧实现（`MikuModel._follow_hand_bone`）是**单臂**持械：武器位置跟右手骨骼，但**朝向被强制
## 固定为角色正前方**，且只有右臂被抬起（`MikuProceduralPose` 的 HOLD_* 常量）——真枪是
## **双手**握持，姿势因此「不像拿枪」。
##
## 本类用 Godot 4.4+ 的 `TwoBoneIK3D`（`SkeletonModifier3D` 家族）把**双臂**拉到两个握持点：
##   · 右手 = 握把（靠身体一侧、偏后）
##   · 左手 = 护木（前伸、靠近中线）
## 武器坐标系由这两个握持点**推导**（右手为原点、两点连线为枪身轴、角色上方向定滚转），
## 不再是无条件「朝角色正前方」。
##
## ## 分层与不冲突
## `SkeletonModifier3D` 是**叠加管线**：它在 `AnimationMixer` 播放**之后**运行，只改手臂链的
## 3 根骨（上臂 / 前臂 / 手）。腿仍由剪辑或程序化姿态负责，两者不打架。
##
## ## ⚠ 重要引擎事实（本 spike 实测，见报告）
## 1. `TwoBoneIK3D` 用的是 Godot 4.4+ 的 **settings 索引 API**
##    （`set_setting_count(n)` + `set_root_bone_name(index, name)` …），**不是**同名属性。
## 2. IK 结果**不会**反映在 `Skeleton3D.get_bone_pose()`/`get_bone_global_pose()` 的常规读取里
##    —— 官方设计文档：modification 「应用到皮肤后立即丢弃」。要在 `skeleton_updated` 信号
##    触发的那一刻才能读到修改后的姿态。
## 3. **headless（dummy 渲染）下 `skeleton_updated` 不触发、modifier 不产出可见结果**，
##    因此 IK 的**形变**只能在真实渲染窗口里目视验证（`tools/capture_hold_ik.gd`）。
##    纯数学部分（骨骼解析 / 武器坐标系推导）→ 走 `tests/suites/test_weapon_hold_ik.gd`。
##
## ## 坐标系约定
## 项目约定：模型正面 = +Z，上 = +Y，因此角色「右」= front × up = **-X**。
## 目标节点是 **Skeleton3D 的子节点**，其 `position` 为**骨架空间**坐标（随角色变换自动跟随）。

## ── 骨骼名解析 ────────────────────────────────────────────────────────────
## 部位关键字（小写「包含」匹配）。优先标准 Blender / Rigify 命名。
const PART_KEYS := {
	"upper": ["upper_arm", "upperarm", "upper arm"],
	"lower": ["lower_arm", "lowerarm", "forearm", "lower arm"],
	"hand": ["hand", "wrist"],
}
## 左右关键字（骨头名里出现的「任一个」即判定该侧）
const SIDE_KEYS := {
	"l": ["left", ".l", "_l", "左"],
	"r": ["right", ".r", "_r", "右"],
}
## 这些辅助骨不能当手臂链（Twist / 手指 / IK 目标 / 肩锁骨 等）
const ARM_EXCLUDE := [
	"twist", "finger", "thumb", "index", "pinky", "ring", "middle",
	"ik", "shoulder", "clavicle", "collar", "end", "tip", "nub",
]

## ── 握持姿态（以「臂展 reach」为单位的方向系数，模型无关）──────────────────
## 右手握把：靠身体一侧、略下、略前
const GRIP_R := {"front": 0.32, "up": -0.33, "right": 0.02}
## 左手护木：明显前伸、略下、向中线收（握在枪管下方）
const GRIP_L := {"front": 0.72, "up": -0.24, "right": 0.30}
## 极向量（肘部朝向）：握持点下方偏后 → 肘自然下垂
const POLE_DOWN := 1.10
const POLE_BACK := 0.55
## 武器原点在「右手握把点」沿枪身**向后**的偏移（以臂展为单位）
const GRIP_BACK := 0.20

var valid := false
var debug_names := {}

var _skeleton: Skeleton3D
var _model: Node3D
var _reach := 0.0
var _up := Vector3.UP
var _front := Vector3.BACK
var _right := Vector3.LEFT

var _ik_l: TwoBoneIK3D
var _ik_r: TwoBoneIK3D
var _target_l: Node3D
var _target_r: Node3D
var _pole_l: Node3D
var _pole_r: Node3D

var _enabled := false
## 左右手触达误差（世界空间，米）。由 capture 脚本在 skeleton_updated 里回填，仅供调试。
var reach_error := {}

## 是否把握持点目标 / 极节点挂在**躯干**（左右上臂的共同祖先 = chest）的 `BoneAttachment3D` 下。
##
## 为什么需要（本 spike 实测）：程序化步态会移动 / 倾斜骨盆（`_center` 通道的 lean / bob）。
## 若目标点固定在**骨架根**，躯干动了而目标点不动 → 手臂被拉扯、枪不随身体走（基准冲突）。
## 挂在 chest 上则目标随躯干一起走，姿势保持「枪端着」。
##
## ⚠ 默认 **false**（保持既有静态目标行为，不影响已有测试与旧 spike 行为）。
## `MikuModel` 在「腿程序化 + 手臂 IK」分层模式下才置 true。
var attach_targets_to_torso := false
var _torso: BoneAttachment3D
var _chest_rest_inv := Transform3D.IDENTITY
var _torso_attached := false


# ---------------------------------------------------------------------------
# 静态纯函数（headless 可逐值断言；不含任何场景依赖）
# ---------------------------------------------------------------------------

## 在一串骨骼名里解析出「左 / 右 × 上臂 / 前臂 / 手」6 个索引。找不到的为 -1。
## 返回：{"upper_l": int, "lower_l": int, "hand_l": int, "upper_r": int, ...}
static func resolve_arm_chain(names: PackedStringArray) -> Dictionary:
	var out := {
		"upper_l": -1, "lower_l": -1, "hand_l": -1,
		"upper_r": -1, "lower_r": -1, "hand_r": -1,
	}
	for side in ["l", "r"]:
		for part in ["upper", "lower", "hand"]:
			var idx := _find_part(names, part, side)
			out["%s_%s" % [part, side]] = idx
	return out


## 找「部位 + 左右」都命中的第一根骨骼；排除辅助骨。
static func _find_part(names: PackedStringArray, part: String, side: String) -> int:
	var part_keys: Array = PART_KEYS[part]
	var side_keys: Array = SIDE_KEYS[side]
	for i in names.size():
		var low := String(names[i]).to_lower()
		if _has_any(low, ARM_EXCLUDE):
			continue
		if not _has_any(low, part_keys):
			continue
		if not _has_any(low, side_keys):
			continue
		return i
	return -1


static func _has_any(low_name: String, keys: Array) -> bool:
	for k in keys:
		if low_name.contains(String(k)):
			return true
	return false


## 取节点世界基变换；不在场景树里时返回单位基（避免 global_transform 的报错与噪声）。
static func _basis_of(node: Node3D) -> Basis:
	if node != null and is_instance_valid(node) and node.is_inside_tree():
		return node.global_transform.basis
	return Basis.IDENTITY


## TwoBoneIK3D 的硬性结构要求：end 是 middle 的子、middle 是 root 的子。
static func is_two_bone_chain(upper: int, lower: int, hand: int, parents: PackedInt32Array) -> bool:
	if upper < 0 or lower < 0 or hand < 0:
		return false
	if lower >= parents.size() or hand >= parents.size():
		return false
	return parents[lower] == upper and parents[hand] == lower


## 由「右手握把点 + 左手护木点」推导武器世界变换。
##   · 枪身轴（武器 +Z）= 右手 → 左手
##   · 滚转由 `up_hint`（角色上方向）定：先对 `up_hint` 正交化
##   · 原点 = 右手点沿枪身**向后**退 `back_offset`
## 退化输入（两点重合 / 与 up_hint 共线）都有兜底，不会产生 NaN 或非正交基。
static func derive_weapon_transform(
		right_grip: Vector3, left_grip: Vector3, up_hint: Vector3, back_offset: float) -> Transform3D:
	var barrel := left_grip - right_grip
	if barrel.length_squared() < 1e-10:
		barrel = Vector3.BACK # 两点重合：退回角色正前方，避免 NaN
	barrel = barrel.normalized()
	var up := up_hint
	if up.length_squared() < 1e-10:
		up = Vector3.UP
	up = up.normalized()
	# 右手性构造：X = up × forward，Y = forward × X（X×Y = forward）
	var x_axis := up.cross(barrel)
	if x_axis.length_squared() < 1e-10:
		# up 与枪身共线：换一个参考轴
		x_axis = Vector3.RIGHT.cross(barrel)
		if x_axis.length_squared() < 1e-10:
			x_axis = Vector3.FORWARD.cross(barrel)
	x_axis = x_axis.normalized()
	var y_axis := barrel.cross(x_axis).normalized()
	var basis := Basis(x_axis, y_axis, barrel)
	return Transform3D(basis, right_grip - barrel * back_offset)


## 握持点（骨架空间）——方向系数 × 臂展。纯函数，便于断言「换模型时姿势按比例缩放」。
static func grip_point(shoulder: Vector3, reach: float,
		front: Vector3, up: Vector3, right: Vector3, coeff: Dictionary) -> Vector3:
	return shoulder + (
		front * float(coeff["front"]) + up * float(coeff["up"]) + right * float(coeff["right"])
	) * reach


# ---------------------------------------------------------------------------
# 实例：搭建 / 驱动
# ---------------------------------------------------------------------------

## 在骨架上搭建双臂 IK 链。成功返回 true；骨架缺标准手臂骨（如乱码 MMD 名）返回 false。
func setup(skeleton: Skeleton3D, model: Node3D) -> bool:
	valid = false
	_skeleton = skeleton
	_model = model
	if skeleton == null or model == null:
		return false

	var names := PackedStringArray()
	var parents := PackedInt32Array()
	for i in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(i))
		parents.append(skeleton.get_bone_parent(i))

	var chain := resolve_arm_chain(names)
	if not is_two_bone_chain(int(chain["upper_l"]), int(chain["lower_l"]), int(chain["hand_l"]), parents):
		return false
	if not is_two_bone_chain(int(chain["upper_r"]), int(chain["lower_r"]), int(chain["hand_r"]), parents):
		return false

	# 骨架空间的「上 / 前 / 右」——由模型基变换换算（模型正面 +Z 是项目约定）
	# ⚠ 节点不在场景树里时 global_transform 会报错并返回单位变换，这里显式兜底（便于 headless 单测）
	var sk_inv := _basis_of(skeleton).inverse()
	var ref := _basis_of(model)
	_up = (sk_inv * (ref * Vector3.UP)).normalized()
	_front = (sk_inv * (ref * Vector3.BACK)).normalized()
	_right = _front.cross(_up).normalized()

	_reach = _side_reach(int(chain["upper_l"]), int(chain["lower_l"]), int(chain["hand_l"]), names)
	if _reach <= 0.0001:
		return false

	# 先在躯干（左右上臂共同祖先）上建锚点（可选），再建目标 / 极节点 —— 目标才会挂到锚点下。
	_prepare_torso(int(chain["upper_r"]), int(chain["upper_l"]))
	_target_r = _make_anchor_node("HoldIK_Target_R", _grip_sk(int(chain["upper_r"]), GRIP_R))
	_target_l = _make_anchor_node("HoldIK_Target_L", _grip_sk(int(chain["upper_l"]), GRIP_L))
	_pole_r = _make_anchor_node("HoldIK_Pole_R", _pole_point(_grip_sk(int(chain["upper_r"]), GRIP_R)))
	_pole_l = _make_anchor_node("HoldIK_Pole_L", _pole_point(_grip_sk(int(chain["upper_l"]), GRIP_L)))

	var upper_r := String(names[int(chain["upper_r"])])
	var lower_r := String(names[int(chain["lower_r"])])
	var hand_r := String(names[int(chain["hand_r"])])
	var upper_l := String(names[int(chain["upper_l"])])
	var lower_l := String(names[int(chain["lower_l"])])
	var hand_l := String(names[int(chain["hand_l"])])

	_ik_r = _make_ik("HoldIK_R", upper_r, lower_r, hand_r, _target_r, _pole_r)
	_ik_l = _make_ik("HoldIK_L", upper_l, lower_l, hand_l, _target_l, _pole_l)
	if _ik_r == null or _ik_l == null:
		return false

	debug_names = {
		"upper_r": upper_r, "lower_r": lower_r, "hand_r": hand_r,
		"upper_l": upper_l, "lower_l": lower_l, "hand_l": hand_l,
		"reach": _reach,
	}
	valid = true
	set_enabled(_enabled)
	return true


func _side_reach(upper: int, lower: int, hand: int, _names: PackedStringArray) -> float:
	var shoulder := _skeleton.get_bone_global_rest(upper).origin
	var elbow := _skeleton.get_bone_global_rest(lower).origin
	var wrist := _skeleton.get_bone_global_rest(hand).origin
	return shoulder.distance_to(elbow) + elbow.distance_to(wrist)


## 握持点（骨架空间）：肩点 + 方向系数 × 臂展。
func _grip_sk(upper_idx: int, coeff: Dictionary) -> Vector3:
	var shoulder := _skeleton.get_bone_global_rest(upper_idx).origin
	return grip_point(shoulder, _reach, _front, _up, _right, coeff)


## 极向量点（骨架空间）：握持点下方偏后（肘部朝向）。
func _pole_point(grip: Vector3) -> Vector3:
	return grip + (_up * -POLE_DOWN + _front * -POLE_BACK) * _reach


## 在躯干上建 `BoneAttachment3D` 锚点（`attach_targets_to_torso=true` 时）。找不到共同祖先则跳过。
func _prepare_torso(upper_r: int, upper_l: int) -> void:
	_torso_attached = false
	if not attach_targets_to_torso:
		return
	var chest := _common_ancestor(upper_r, upper_l)
	if chest < 0:
		return
	_torso = BoneAttachment3D.new()
	_torso.name = "HoldIK_Torso"
	_skeleton.add_child(_torso)
	_torso.bone_name = _skeleton.get_bone_name(chest)
	# 把「骨架空间的目标点」换算到「chest 骨空间」：BoneAttachment3D 的变换 = 该骨的当前全局姿态，
	# 因此子节点 position 用 chest rest 的逆换算，静态时落在目标点、躯干动时随躯干走。
	_chest_rest_inv = _skeleton.get_bone_global_rest(chest).affine_inverse()
	_torso_attached = true


## 建一个锚定节点：`point_in_skeleton` 是**骨架空间**坐标。
## 有躯干锚点时挂到锚点下（换算成骨空间）；否则直接挂到骨架下（旧的静态行为）。
func _make_anchor_node(node_name: String, point_in_skeleton: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	if _torso_attached:
		_torso.add_child(node)
		node.position = _chest_rest_inv * point_in_skeleton
	else:
		_skeleton.add_child(node)
		node.position = point_in_skeleton
	return node


## 两个骨骼的共同祖先（用于找「躯干」锚点骨）
func _common_ancestor(a: int, b: int) -> int:
	if a < 0 or b < 0:
		return -1
	var seen := {}
	var cur := a
	while cur >= 0:
		seen[cur] = true
		cur = _skeleton.get_bone_parent(cur)
	cur = b
	while cur >= 0:
		if seen.has(cur):
			return cur
		cur = _skeleton.get_bone_parent(cur)
	return -1


func _make_ik(node_name: String, upper: String, lower: String, hand: String,
		target: Node3D, pole: Node3D) -> TwoBoneIK3D:
	var ik := TwoBoneIK3D.new()
	ik.name = node_name
	_skeleton.add_child(ik)
	# ⚠ Godot 4.4+ 的 settings 索引 API
	ik.set_setting_count(1)
	ik.set_root_bone_name(0, upper)
	ik.set_middle_bone_name(0, lower)
	ik.set_end_bone_name(0, hand)
	ik.set_target_node(0, ik.get_path_to(target))
	ik.set_pole_node(0, ik.get_path_to(pole))
	return ik


## 拆掉本类建的所有节点（模型重载 / 关闭能力时调用）。
func teardown() -> void:
	if _torso != null and is_instance_valid(_torso):
		_torso.queue_free() # 挂到躯干下的目标 / 极节点是它的子节点，随它一起释放
	for n in [_ik_l, _ik_r, _target_l, _target_r, _pole_l, _pole_r]:
		if n != null and is_instance_valid(n) and n.get_parent() != _torso:
			n.queue_free()
	_ik_l = null
	_ik_r = null
	_target_l = null
	_target_r = null
	_pole_l = null
	_pole_r = null
	_torso = null
	_torso_attached = false
	valid = false


func set_enabled(on: bool) -> void:
	_enabled = on and valid
	for ik in [_ik_l, _ik_r]:
		if ik != null and is_instance_valid(ik):
			ik.active = _enabled
			ik.influence = 1.0


func is_enabled() -> bool:
	return _enabled


## 由「两个握持点」推导的武器世界变换（第三人称下 MikuModel 用它摆放 WeaponMount）。
func get_weapon_transform() -> Transform3D:
	if not valid or _target_r == null or _target_l == null:
		return Transform3D.IDENTITY
	var up_hint := Vector3.UP
	if _model != null and is_instance_valid(_model) and _model.is_inside_tree():
		up_hint = _model.global_transform.basis.y
	var scale := 1.0
	if _skeleton != null and is_instance_valid(_skeleton) and _skeleton.is_inside_tree():
		scale = _skeleton.global_transform.basis.get_scale().x
	return derive_weapon_transform(
		_target_r.global_position, _target_l.global_position, up_hint, GRIP_BACK * _reach * maxf(scale, 0.0001)
	)
