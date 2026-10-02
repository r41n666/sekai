class_name MikuProceduralPose
extends RefCounted
## 程序化姿态 / 行走动画（阶段 4）：模型没有动画剪辑时，直接用骨骼摆出站立 / 走 / 跑 / 跳。
##
## 行走采用完整步态循环（不再是直腿前后摆）：
##   - 大腿前后摆 + **摆动期屈膝抬脚** + 脚掌角度补偿（落地更自然）；
##   - 身体随步伐上下起伏（两次/周期）与轻微前倾（跑步更明显）；
##   - 手臂与同侧腿反相摆动，肘部保持自然弯曲；
##   - **步频按实际移动速度自适应**（步幅由腿长与摆幅推算），减少"滑步"。
##
## 骨骼识别是启发式的（MMD / FBX 类人形骨骼，骨骼名乱码也能用）：
##   - 坐标系：以 MikuModel 节点为参考（模型正面朝 +Z 是项目约定），换算到骨架空间得到 up / front / left；
##   - 大腿根：从每侧最低的骨骼（脚）沿父链往上走，取第一个「高度到胯部」的骨骼；
##     膝 / 脚踝 = 沿这条链往下（儿童链）；
##   - 上臂：从该侧最远端的骨骼（手）沿父链往上走，取仍在手臂范围内的靠内骨骼；肘 = 手臂链的中点骨骼；
##   - 起伏/前倾：取「大腿根」与「上臂」的共同祖先（骨盆/腰），这样动作不会把身体撕开；
##   - 名字里带 collider / dummy / hair / skirt / end 等辅助骨骼会被跳过。
## 找不到关键骨骼时 valid=false，模型保持原姿态。

const WALK_LEG_DEG := 28.0      # 大腿摆幅（走）
const RUN_LEG_DEG := 40.0       # 大腿摆幅（跑）
const WALK_KNEE_DEG := 46.0     # 摆动期屈膝（走）
const RUN_KNEE_DEG := 58.0      # 摆动期屈膝（跑）
const WALK_ARM_DEG := 16.0
const RUN_ARM_DEG := 28.0
const ELBOW_BEND_DEG := 18.0    # 肘部常态弯曲
const ANKLE_FACTOR := 0.45      # 脚掌补偿系数（抵消大腿+膝盖旋转，保持脚大致水平）
const BOB_UNITS := 0.22         # 身体起伏（骨架空间单位，≈1.7 cm）
const LEAN_DEG := 4.0           # 移动时前倾（跑动再乘 1.6）
const JUMP_LEG_DEG := 14.0
const JUMP_KNEE_DEG := 30.0
const JUMP_ARM_DOWN_DEG := 42.0
const ARM_DOWN_DEG := 66.0      # 站立时从 T-pose 放下来
const SMOOTH_SPEED := 10.0
const HIP_RATIO := 0.42
const ARM_MIN_RATIO := 0.60
const ARM_INNER_RATIO := 0.04
const MAX_CHAIN_STEPS := 8

const HELPER_KEYWORDS := [
	"collider", "dummy", "shadow", "rigid", "joint", "hair", "skirt", "ribbon", "offset", "end"
]

var valid := false
var debug_names := {}
var debug_indices := {}

var _skeleton: Skeleton3D
var _up := Vector3.UP
var _front := Vector3.BACK   # +Z
var _left := Vector3.RIGHT   # +X
var _right := Vector3.LEFT
var _axis_plane := 0.0
var _height := 1.0
var _min_height := 0.0
var _leg_length := 0.0       # 骨架空间里的腿长（大腿根 → 脚尖）
var _model_scale := 1.0      # 骨架 → 世界的缩放（估算步幅）

var _thigh_r := -1
var _thigh_l := -1
var _knee_r := -1
var _knee_l := -1
var _ankle_r := -1
var _ankle_l := -1
var _arm_r := -1
var _arm_l := -1
var _elbow_r := -1
var _elbow_l := -1
var _center := -1

var _phase := 0.0
var _leg_amplitude := 0.0    # 当前大腿摆幅（弧度，平滑）
var _knee_amplitude := 0.0
var _arm_swing := 0.0
var _arm_down := ARM_DOWN_DEG
var _lean := 0.0
var _bob := 0.0
var _bob_offset := Vector3.ZERO
var frequency := 1.2         # 当前步频（Hz，测试/调试可读）

var _controlled: Array[int] = []


func setup(skeleton: Skeleton3D, reference: Node3D) -> bool:
	_skeleton = skeleton
	var count := skeleton.get_bone_count()
	if count == 0:
		return false

	# 参考系：把 MikuModel 空间的「上 / 前 / 左」换算到骨架空间
	var skeleton_inv := skeleton.global_transform.basis.inverse()
	var ref_basis := reference.global_transform.basis
	_up = (skeleton_inv * (ref_basis * Vector3.UP)).normalized()
	_front = (skeleton_inv * (ref_basis * Vector3.BACK)).normalized()
	_left = (skeleton_inv * (ref_basis * Vector3.RIGHT)).normalized()
	_right = -_left
	_model_scale = skeleton.global_transform.basis.get_scale().x
	if _model_scale <= 0.0001:
		_model_scale = 1.0

	var positions: Array[Vector3] = []
	var min_h := INF
	var max_h := -INF
	for i in count:
		var p: Vector3 = skeleton.get_bone_global_pose(i).origin
		positions.append(p)
		var h := p.dot(_up)
		min_h = minf(min_h, h)
		max_h = maxf(max_h, h)
	_min_height = min_h
	_height = maxf(max_h - min_h, 0.001)
	_axis_plane = positions[0].dot(_up)

	_thigh_r = _find_thigh(positions, -1)
	_thigh_l = _find_thigh(positions, 1)
	_arm_r = _find_arm(positions, -1)
	_arm_l = _find_arm(positions, 1)

	_knee_r = _child_chain(_thigh_r, 0)
	_ankle_r = _child_chain(_thigh_r, 1)
	_knee_l = _child_chain(_thigh_l, 0)
	_ankle_l = _child_chain(_thigh_l, 1)
	_elbow_r = _find_elbow(_arm_r)
	_elbow_l = _find_elbow(_arm_l)
	_center = _find_common_ancestor(_thigh_r, _arm_r)
	if _thigh_r >= 0:
		var toe := _child_chain(_thigh_r, 2)
		if toe >= 0:
			_leg_length = positions[_thigh_r].distance_to(positions[toe])
		else:
			_leg_length = (positions[_thigh_r].dot(_up) - min_h)
	else:
		_leg_length = _height * 0.5

	valid = (_thigh_r >= 0 or _thigh_l >= 0) and _leg_length > 0.001
	_controlled = [_thigh_r, _thigh_l, _knee_r, _knee_l, _ankle_r, _ankle_l,
		_arm_r, _arm_l, _elbow_r, _elbow_l, _center]
	debug_names = {
		"thigh_r": _name_of(_thigh_r), "thigh_l": _name_of(_thigh_l),
		"knee_r": _name_of(_knee_r), "ankle_r": _name_of(_ankle_r),
		"arm_r": _name_of(_arm_r), "elbow_r": _name_of(_elbow_r),
		"center": _name_of(_center),
	}
	debug_indices = {
		"thigh_r": _thigh_r, "thigh_l": _thigh_l,
		"knee_r": _knee_r, "ankle_r": _ankle_r,
		"arm_r": _arm_r, "elbow_r": _elbow_r, "center": _center,
	}
	return valid


## 每帧由 MikuModel.update_animation 调用；speed_mps 用于把步频配到实际速度（防滑步）
func update(delta: float, speed_mps: float, moving: bool, running: bool, on_floor: bool) -> void:
	if not valid:
		return
	var leg_target := 0.0
	var knee_target := 0.0
	var arm_target := 0.0
	var down_target := ARM_DOWN_DEG
	var lean_target := 0.0
	var frequency_target := 1.2
	if not on_floor:
		down_target = JUMP_ARM_DOWN_DEG
		leg_target = deg_to_rad(JUMP_LEG_DEG)
		knee_target = deg_to_rad(JUMP_KNEE_DEG)
	elif moving:
		leg_target = deg_to_rad(RUN_LEG_DEG if running else WALK_LEG_DEG)
		knee_target = deg_to_rad(RUN_KNEE_DEG if running else WALK_KNEE_DEG)
		arm_target = deg_to_rad(RUN_ARM_DEG if running else WALK_ARM_DEG)
		lean_target = deg_to_rad(LEAN_DEG * (1.6 if running else 1.0))
		# 步幅 ≈ 2 步 ×（2 × 腿长 × sin(摆幅)），步频 = 速度 / 步幅
		var leg_world := _leg_length * _model_scale
		var stride := 4.0 * leg_world * sin(leg_target)
		frequency_target = clampf(speed_mps / maxf(stride, 0.25), 0.8, 3.0)
	var k := 1.0 - exp(-SMOOTH_SPEED * delta)
	_leg_amplitude = lerpf(_leg_amplitude, leg_target, k)
	_knee_amplitude = lerpf(_knee_amplitude, knee_target, k)
	_arm_swing = lerpf(_arm_swing, arm_target, k)
	_arm_down = lerpf(_arm_down, down_target, k)
	_lean = lerpf(_lean, lean_target, k)
	frequency = lerpf(frequency, frequency_target, k)
	_phase = fmod(_phase + delta * TAU * frequency, TAU)
	_apply_pose()


func _apply_pose() -> void:
	for idx in _controlled:
		if idx >= 0:
			_skeleton.set_bone_global_pose_override(idx, Transform3D(), 0.0, false)

	# 右腿相位 = _phase，左腿 +π
	var theta_r := _phase
	var theta_l := _phase + PI
	var thigh_r := _leg_amplitude * cos(theta_r)
	var thigh_l := _leg_amplitude * cos(theta_l)
	# 摆动期（腿从后往前）屈膝，落地前伸直
	var knee_r := -_knee_amplitude * maxf(0.0, -sin(theta_r))
	var knee_l := -_knee_amplitude * maxf(0.0, -sin(theta_l))
	var ankle_r := -(thigh_r + knee_r) * ANKLE_FACTOR
	var ankle_l := -(thigh_l + knee_l) * ANKLE_FACTOR
	# 身体起伏：每周期两次（双支撑最低、过渡最高）
	_bob = -BOB_UNITS * cos(_phase * 2.0) * (_leg_amplitude / maxf(deg_to_rad(WALK_LEG_DEG), 0.001))
	_bob_offset = _up * _bob
	var down := deg_to_rad(_arm_down)
	var arm_swing_r := -_arm_swing * cos(theta_r)
	var arm_swing_l := -_arm_swing * cos(theta_l)
	var elbow := deg_to_rad(ELBOW_BEND_DEG)

	# 注意：覆写是「绝对」的，父子链必须手工累积（每级绕自己的关节枢轴旋转），
	# 否则大腿转动不会带动膝盖 / 脚，身体会被钉在 rest 位置。
	var base := _pivot(_center, Basis(_right, -_lean))
	base = Transform3D(base.basis, base.origin + _bob_offset)
	_override(_center, base * _skeleton.get_bone_global_rest(_center))

	_pose_leg(_thigh_r, _knee_r, _ankle_r, base, thigh_r, knee_r, ankle_r)
	_pose_leg(_thigh_l, _knee_l, _ankle_l, base, thigh_l, knee_l, ankle_l)
	_pose_arm(_arm_r, _elbow_r, base, arm_swing_r, down, elbow)
	_pose_arm(_arm_l, _elbow_l, base, arm_swing_l, -down, elbow)


## 腿链：大腿 → 膝盖 → 脚踝逐级累积（脚踝以下由引擎自然跟随）
func _pose_leg(thigh_idx: int, knee_idx: int, ankle_idx: int, base: Transform3D, thigh_angle: float, knee_angle: float, ankle_angle: float) -> void:
	if thigh_idx < 0:
		return
	var thigh_rest := _skeleton.get_bone_global_rest(thigh_idx)
	var leg := base * _pivot_at(thigh_rest.origin, Basis(_right, thigh_angle))
	_override(thigh_idx, leg * thigh_rest)
	if knee_idx < 0:
		return
	var knee_rest := _skeleton.get_bone_global_rest(knee_idx)
	var lower := leg * _pivot_at(knee_rest.origin, Basis(_right, knee_angle))
	_override(knee_idx, lower * knee_rest)
	if ankle_idx < 0:
		return
	var ankle_rest := _skeleton.get_bone_global_rest(ankle_idx)
	_override(ankle_idx, lower * _pivot_at(ankle_rest.origin, Basis(_right, ankle_angle)) * ankle_rest)


## 手臂链：上臂（含放下 + 摆动）→ 肘部弯曲
func _pose_arm(arm_idx: int, elbow_idx: int, base: Transform3D, swing: float, down: float, elbow: float) -> void:
	if arm_idx < 0:
		return
	var arm_rest := _skeleton.get_bone_global_rest(arm_idx)
	var arm := base * _pivot_at(arm_rest.origin, Basis(_right, swing) * Basis(_front, down))
	_override(arm_idx, arm * arm_rest)
	if elbow_idx < 0:
		return
	var elbow_rest := _skeleton.get_bone_global_rest(elbow_idx)
	_override(elbow_idx, arm * _pivot_at(elbow_rest.origin, Basis(_right, elbow)) * elbow_rest)


## 绕某个枢轴点旋转（用于把旋转正确地叠到运动链上）
func _pivot_at(pivot: Vector3, basis: Basis) -> Transform3D:
	return Transform3D(basis, pivot - basis * pivot)


## 绕骨骼自己的 rest 原点旋转
func _pivot(idx: int, basis: Basis) -> Transform3D:
	return _pivot_at(_skeleton.get_bone_global_rest(idx).origin, basis)


func _override(idx: int, transform: Transform3D) -> void:
	_skeleton.set_bone_global_pose_override(idx, transform, 1.0, true)


## 沿子链取第 n 个子骨骼（0=第一个子级）
func _child_chain(start: int, depth: int) -> int:
	var current := start
	for step in depth + 1:
		if current < 0:
			return -1
		var children := _skeleton.get_bone_children(current)
		if children.is_empty():
			return -1
		current = children[0]
	return current


## 肘：手臂链上离「肩→手」中点最近的骨骼
func _find_elbow(arm_root: int) -> int:
	if arm_root < 0:
		return -1
	var root_distance := _axis_distance(_skeleton.get_bone_global_pose(arm_root).origin)
	var chain: Array[int] = []
	var current := arm_root
	for step in 8:
		var children := _skeleton.get_bone_children(current)
		if children.is_empty():
			break
		current = children[0]
		chain.append(current)
	if chain.is_empty():
		return -1
	var hand_distance := _axis_distance(_skeleton.get_bone_global_pose(chain[-1]).origin)
	var mid := (root_distance + hand_distance) * 0.5
	var best := -1
	var best_gap := INF
	for idx in chain:
		var gap := absf(_axis_distance(_skeleton.get_bone_global_pose(idx).origin) - mid)
		if gap < best_gap:
			best_gap = gap
			best = idx
	return best


## 两个骨骼的共同祖先（用于找骨盆/腰部——身体起伏与前倾作用在这里才不会撕开身体）
func _find_common_ancestor(a: int, b: int) -> int:
	if a < 0 or b < 0:
		return -1
	var ancestors := {}
	var current := a
	while current >= 0:
		ancestors[current] = true
		current = _skeleton.get_bone_parent(current)
	current = b
	while current >= 0:
		if ancestors.has(current):
			return current
		current = _skeleton.get_bone_parent(current)
	return -1


## 从脚沿父链往上，取第一个「到胯部高度」的骨骼 = 大腿根
func _find_thigh(positions: Array[Vector3], side: int) -> int:
	var candidates: Array[int] = []
	for i in positions.size():
		if _is_helper(i) or _side_of(positions[i]) * side <= 0.0:
			continue
		candidates.append(i)
	candidates.sort_custom(func(a, b): return positions[a].dot(_up) < positions[b].dot(_up))
	for t in mini(3, candidates.size()):
		var current: int = candidates[t]
		for step in MAX_CHAIN_STEPS:
			if _height_ratio(positions[current]) >= HIP_RATIO:
				return current
			var parent := _skeleton.get_bone_parent(current)
			if parent < 0:
				break
			current = parent
	return -1


## 从手沿父链往回走，取仍在手臂范围内（离身体较远）的最后一根 = 上臂
func _find_arm(positions: Array[Vector3], side: int) -> int:
	var hand := -1
	var farthest := -1.0
	for i in positions.size():
		if _is_helper(i) or _side_of(positions[i]) * side <= 0.0:
			continue
		if _height_ratio(positions[i]) < ARM_MIN_RATIO:
			continue
		var distance := _axis_distance(positions[i])
		if distance > farthest:
			farthest = distance
			hand = i
	if hand < 0:
		return -1
	var inner_threshold := ARM_INNER_RATIO * _height
	var current := hand
	var arm := hand
	for step in MAX_CHAIN_STEPS:
		var parent := _skeleton.get_bone_parent(current)
		if parent < 0:
			break
		if _axis_distance(positions[parent]) <= inner_threshold:
			break
		arm = parent
		current = parent
	return arm


func _is_helper(idx: int) -> bool:
	var bone_name := _skeleton.get_bone_name(idx).to_lower()
	for keyword in HELPER_KEYWORDS:
		if bone_name.contains(keyword):
			return true
	return false


func _side_of(p: Vector3) -> float:
	return p.dot(_left)


func _height_ratio(p: Vector3) -> float:
	return (p.dot(_up) - _min_height) / _height


## 骨骼到「过原点的竖直轴」的水平距离
func _axis_distance(p: Vector3) -> float:
	var along := p.dot(_up) - _axis_plane
	var rel := p - (_up * along + _up * _axis_plane)
	return rel.length()


func _name_of(idx: int) -> String:
	return _skeleton.get_bone_name(idx) if idx >= 0 else "-"