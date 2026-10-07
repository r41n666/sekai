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
##
## 战斗动作（开火 / 受击 / 死亡 / 换弹）在步态**之上**叠加：
##   - 状态机、alpha 包络、叠加量换算全部在 `MikuCombatAnim`（纯逻辑，可 headless 逐值断言）；
##   - 本类只负责「把叠加量变成骨骼旋转」，并处理死亡对整个身体的接管。
## valid=false 时所有战斗动作**静默跳过**（不报错、不崩）。

const WALK_LEG_DEG := 28.0      # 大腿摆幅（走）
const RUN_LEG_DEG := 40.0       # 大腿摆幅（跑）
const WALK_KNEE_DEG := 46.0     # 摆动期屈膝（走）
const RUN_KNEE_DEG := 58.0      # 摆动期屈膝（跑）
const WALK_ARM_DEG := 16.0
const RUN_ARM_DEG := 28.0
const ELBOW_BEND_DEG := 18.0    # 肘部常态弯曲
const ANKLE_FACTOR := 0.45      # 脚掌补偿系数（抵消大腿+膝盖旋转，保持脚大致水平）
## 身体起伏幅度 = 骨架高度 × 该比例（**不是**绝对骨架单位 —— 绝对单位在不同单位的骨架上会差 ~15 倍）。
## 原常量 `BOB_UNITS = 0.22 骨架单位` 是在 miku.glb（骨架高 ≈23.539 单位）上标定的，
## 折算成比例 = 0.22 / 23.5392299890518 ≈ 0.00934601 → **miku.glb 的起伏完全不变（0.22 单位 ≈1.6 cm）**。
## 而骨架单位小的模型（cat_hatsune_miku 骨架高仅 1.51 单位）不再出现 25 cm 的夸张起伏（→ ≈1.6 cm）。
## 守恒锚点：`bob_amplitude(23.5392299890518) == 0.22`（见 tests/suites/test_procedural_legs_layer.gd）。
const BOB_RATIO := 0.00934601
const LEAN_DEG := 4.0           # 移动时前倾（跑动再乘 1.6）
const JUMP_LEG_DEG := 14.0
const JUMP_KNEE_DEG := 30.0
const JUMP_ARM_DOWN_DEG := 42.0
const ARM_DOWN_DEG := 66.0      # 站立时从 T-pose 放下来
## 端着武器时右手的姿态（空手时手臂自然垂下，持械时右手抬到身前，武器才不垂在腿边）
const HOLD_ARM_DOWN_DEG := 34.0     # 右侧上臂下垂角度（比空手小 = 抬起来）
const HOLD_ARM_FORWARD_DEG := 58.0  # 右侧上臂向前抬
const HOLD_ELBOW_DEG := 62.0        # 持械侧肘部弯曲
const HOLD_SWING_SCALE := 0.25      # 持械侧摆臂幅度（端着东西时几乎不甩）
const SMOOTH_SPEED := 10.0
const HIP_RATIO := 0.42
const ARM_MIN_RATIO := 0.60
const ARM_INNER_RATIO := 0.04
const MAX_CHAIN_STEPS := 8

const HELPER_KEYWORDS := [
	"collider", "dummy", "shadow", "rigid", "joint", "hair", "skirt", "ribbon", "offset", "end",
	"リボン", "スカート", "髪", "影"
]
## 按名字找骨骼时的排除词（IK / 親 / 先 等辅助骨骼）
const NAME_EXCLUDE_LIMB := ["ik", "ｉｋ", "親", "先", "end"]
const NAME_EXCLUDE_THIGH := ["ik", "ｉｋ", "親", "先", "首", "ひざ", "膝", "end"]
const NAME_EXCLUDE_ARM := ["ik", "ｉｋ", "親", "先", "ひじ", "肘", "手首", "end"]

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
## 头骨（受击时「头微微后」用）。找不到时为 -1，该子动作静默跳过。
var _head := -1
## 上臂「放下」的旋转方向：取决于这条胳膊在骨架的哪一侧
## （正常模型右臂在 -X 侧；PMX 转出来的模型左右镜像，右臂在 +X 侧，符号要反过来）
var _down_sign_r := 1.0
var _down_sign_l := -1.0

var _phase := 0.0
var _leg_amplitude := 0.0    # 当前大腿摆幅（弧度，平滑）
var _knee_amplitude := 0.0
var _arm_swing := 0.0
var _arm_down := ARM_DOWN_DEG
## 是否端着武器（由 MikuModel.set_holding_weapon 设置）
var holding_weapon := false
## 是否由本类接管**手臂**。默认 true（全有：腿 + 手臂 + 躯干都由程序化姿态驱动，miku.glb 路径）。
## 设为 false 时只驱动**腿 + 躯干（_center）+ 头**，两条手臂链**完全不动**——留给 `TwoBoneIK3D`
## （双手持枪）或 AnimationPlayer 剪辑。这是「腿程序化 + 手臂 IK」分层的开关（见
## `MikuModel.procedural_legs_enabled`）。
## ⚠ 语义：`pose_arms=false` 时本类**既不写也不清**手臂骨（`_apply_pose` 跳过 `_pose_arm`），
## 避免与 IK modifier 抢同一批骨骼。
var pose_arms := true
var _hold_forward := 0.0     # 持械时上臂前抬角（平滑，弧度）
var _hold_elbow := ELBOW_BEND_DEG
var _lean := 0.0
var _bob := 0.0
var _bob_offset := Vector3.ZERO
var frequency := 1.2         # 当前步频（Hz，测试/调试可读）

## 战斗动作状态机（开火 / 受击 / 死亡 / 换弹）。逻辑与包络全在 MikuCombatAnim 里，
## 本类只在 _apply_pose 里把它的叠加量变成骨骼旋转。
var combat := MikuCombatAnim.new()

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

	# 1) 先按标准 MMD / 人形骨骼名找（PMX 转换过来的模型骨骼名是正常日文名，比启发式准）
	_thigh_r = _find_by_names(["右足"], NAME_EXCLUDE_THIGH)
	_thigh_l = _find_by_names(["左足"], NAME_EXCLUDE_THIGH)
	_knee_r = _find_by_names(["右ひざ", "右膝"], NAME_EXCLUDE_LIMB)
	_knee_l = _find_by_names(["左ひざ", "左膝"], NAME_EXCLUDE_LIMB)
	_ankle_r = _find_by_names(["右足首"], NAME_EXCLUDE_LIMB)
	_ankle_l = _find_by_names(["左足首"], NAME_EXCLUDE_LIMB)
	_arm_r = _find_by_names(["右腕"], NAME_EXCLUDE_ARM)
	_arm_l = _find_by_names(["左腕"], NAME_EXCLUDE_ARM)
	_elbow_r = _find_by_names(["右ひじ", "右肘"], NAME_EXCLUDE_LIMB)
	_elbow_l = _find_by_names(["左ひじ", "左肘"], NAME_EXCLUDE_LIMB)
	_center = _find_by_names(["腰", "センター", "下半身"], [])
	_head = _find_by_names(["頭", "首", "head"], NAME_EXCLUDE_LIMB)

	# 2) 名字对不上（例如 miku.glb 的骨骼名是乱码）再回退到启发式
	if _thigh_r < 0:
		_thigh_r = _find_thigh(positions, -1)
	if _thigh_l < 0:
		_thigh_l = _find_thigh(positions, 1)
	if _arm_r < 0:
		_arm_r = _find_arm(positions, -1)
	if _arm_l < 0:
		_arm_l = _find_arm(positions, 1)

	if _knee_r < 0:
		_knee_r = _child_chain(_thigh_r, 0)
	if _ankle_r < 0:
		_ankle_r = _child_chain(_thigh_r, 1)
	if _knee_l < 0:
		_knee_l = _child_chain(_thigh_l, 0)
	if _ankle_l < 0:
		_ankle_l = _child_chain(_thigh_l, 1)
	if _elbow_r < 0:
		_elbow_r = _find_elbow(_arm_r)
	if _elbow_l < 0:
		_elbow_l = _find_elbow(_arm_l)
	# 起伏 / 前倾的参考骨骼：优先「大腿根与上臂的共同祖先」，找不到就退到两侧大腿的共同祖先
	if _center < 0:
		_center = _find_common_ancestor(_thigh_r, _arm_r)
	if _center < 0:
		_center = _find_common_ancestor(_thigh_r, _thigh_l)
	if _center < 0:
		_center = _thigh_r
	# 头骨：名字对不上就从「身体中心」沿父链往上走，取第一个明显高于中心的骨骼。
	# 找不到时 _head 保持 -1 → 受击的「头微微后」静默跳过（不报错）。
	if _head < 0:
		_head = _find_head(positions)
	if _thigh_r >= 0:
		var toe := _child_chain(_thigh_r, 2)
		if toe >= 0:
			_leg_length = positions[_thigh_r].distance_to(positions[toe])
		else:
			_leg_length = (positions[_thigh_r].dot(_up) - min_h)
	else:
		_leg_length = _height * 0.5

	valid = (_thigh_r >= 0 or _thigh_l >= 0) and _leg_length > 0.001
	_down_sign_r = _down_sign(_arm_r)
	_down_sign_l = _down_sign(_arm_l) if _arm_l >= 0 else -_down_sign_r
	# 受控骨骼清单：`pose_arms=false` 时**不含**手臂骨 —— 这样 `_apply_pose` 的「先清空覆写」
	# 循环也不会碰手臂，手臂链完全留给 IK modifier / 剪辑（不与 IK 抢骨骼）。
	_controlled = [_thigh_r, _thigh_l, _knee_r, _knee_l, _ankle_r, _ankle_l, _center, _head]
	if pose_arms:
		_controlled.append_array([_arm_r, _arm_l, _elbow_r, _elbow_l])
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
	# 战斗动作计时无条件推进（死亡后也要继续走完倒地过渡）。
	# ⚠ valid=false 时**不碰骨骼**：找不到关键骨骼的模型保持原姿态，动作静默跳过。
	combat.advance(delta)
	if not valid:
		return
	# 死亡接管：步态目标全部归零（`_apply_pose` 里再叠加倒地旋转），不恢复直到 reset_pose()。
	var dead := combat.is_dead()
	var leg_target := 0.0
	var knee_target := 0.0
	var arm_target := 0.0
	var down_target := ARM_DOWN_DEG
	var lean_target := 0.0
	var frequency_target := 0.0 if dead else 1.2
	if dead:
		pass # 保持上面的全零目标：倒地时腿不再交替迈步
	elif not on_floor:
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
	# 端着武器：右手抬到身前（手臂垂下的话武器会挂在腿边，看起来像掉在地上）
	var hold_forward_target := 0.0
	var hold_elbow_target := ELBOW_BEND_DEG
	if holding_weapon:
		down_target = minf(down_target, HOLD_ARM_DOWN_DEG)
		hold_forward_target = HOLD_ARM_FORWARD_DEG
		hold_elbow_target = HOLD_ELBOW_DEG
	var k := 1.0 - exp(-SMOOTH_SPEED * delta)
	_leg_amplitude = lerpf(_leg_amplitude, leg_target, k)
	_knee_amplitude = lerpf(_knee_amplitude, knee_target, k)
	_arm_swing = lerpf(_arm_swing, arm_target, k)
	_arm_down = lerpf(_arm_down, down_target, k)
	_hold_forward = lerpf(_hold_forward, deg_to_rad(hold_forward_target), k)
	_hold_elbow = lerpf(_hold_elbow, hold_elbow_target, k)
	_lean = lerpf(_lean, lean_target, k)
	frequency = lerpf(frequency, frequency_target, k)
	# 死亡后步频归零 → _phase 不再前进，倒地姿态不会还在原地迈步
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
	_bob = -bob_amplitude(_height) * cos(_phase * 2.0) * (_leg_amplitude / maxf(deg_to_rad(WALK_LEG_DEG), 0.001))
	_bob_offset = _up * _bob
	var down := deg_to_rad(_arm_down)
	var swing_scale := HOLD_SWING_SCALE if holding_weapon else 1.0
	var elbow := deg_to_rad(ELBOW_BEND_DEG)

	# 注意：覆写是「绝对」的，父子链必须手工累积（每级绕自己的关节枢轴旋转），
	# 否则大腿转动不会带动膝盖 / 脚，身体会被钉在 rest 位置。
	# 战斗动作叠加量（弧度 / 骨架空间单位）：在步态之上**相加**，
	# 所以 alpha 从 1 衰减到 0 的过程是「动作渐渐融回步态」，不会硬切抽搐。
	var off := _combat_offsets()
	# 俯仰：步态前倾是 -_lean（绕right 轴），战斗通道 pitch 正 = 后仰，两者相加。
	var lean_total := -_lean + float(off[MikuCombatAnim.CH_PITCH])
	var roll := float(off[MikuCombatAnim.CH_ROLL])
	var drop := float(off[MikuCombatAnim.CH_DROP])
	var base := _pivot(_center, Basis(_right, lean_total) * Basis(_front, roll))
	base = Transform3D(base.basis, base.origin + _bob_offset + _up * drop)
	_override(_center, base * _skeleton.get_bone_global_rest(_center))

	_pose_leg(_thigh_r, _knee_r, _ankle_r, base,
		thigh_r + float(off[MikuCombatAnim.CH_LEG]),
		knee_r + float(off[MikuCombatAnim.CH_KNEE]),
		ankle_r)
	_pose_leg(_thigh_l, _knee_l, _ankle_l, base,
		thigh_l + float(off[MikuCombatAnim.CH_LEG]),
		knee_l + float(off[MikuCombatAnim.CH_KNEE]),
		ankle_l)
	# 摆臂：正 = 前摆（与 HOLD_ARM_FORWARD_DEG 同向）；down：正 = 更垂（与 ARM_DOWN_DEG 同向）
	# ⚠ pose_arms=false 时**完全不碰手臂**（连摆臂/持械臂动作也不做），手臂交给 IK / 剪辑。
	if pose_arms:
		var arm_swing_r := -_arm_swing * swing_scale * cos(theta_r) + _hold_forward \
			+ float(off[MikuCombatAnim.CH_ARM_R_SWING])
		var arm_swing_l := -_arm_swing * cos(theta_l) + float(off[MikuCombatAnim.CH_ARM_L_SWING])
		var arm_down_r := (down + float(off[MikuCombatAnim.CH_ARM_R_DOWN])) * _down_sign_r
		var arm_down_l := (down + float(off[MikuCombatAnim.CH_ARM_L_DOWN])) * _down_sign_l
		_pose_arm(_arm_r, _elbow_r, base, arm_swing_r, arm_down_r,
			_hold_elbow + float(off[MikuCombatAnim.CH_ARM_R_ELBOW]))
		_pose_arm(_arm_l, _elbow_l, base, arm_swing_l, arm_down_l,
			elbow + float(off[MikuCombatAnim.CH_ARM_L_ELBOW]))
	# 头：叠在身体链之上（base 已含俯仰 / 侧倾 / 下沉）。找不到头骨时静默跳过。
	if _head >= 0:
		var head_rest := _skeleton.get_bone_global_rest(_head)
		_override(_head, base * _pivot_at(head_rest.origin,
			Basis(_right, float(off[MikuCombatAnim.CH_HEAD]))) * head_rest)


## 当前所有战斗动作的叠加量之和（死亡 / 开火 / 受击 / 换弹逐个求和）。
## 同一时刻通常只有一个动作（状态机里后触发者接管），但求和的写法让「叠加」语义显式化，
## 且包络重叠时不会出现硬切。
func _combat_offsets() -> Dictionary:
	var list: Array = []
	for action in [MikuCombatAnim.Action.FIRE, MikuCombatAnim.Action.HIT,
			MikuCombatAnim.Action.DEATH, MikuCombatAnim.Action.RELOAD]:
		var w := combat.overlay_alpha(action)
		if w > 0.0:
			list.append(MikuCombatAnim.combat_offsets(action, w))
	return MikuCombatAnim.sum_offsets(list)


## 触发开火（持械臂后坐上抬 + 肘部收回 + 躯干轻微后仰；短促约 0.12 s）。
## 返回是否被接受（已死亡时返回 false —— 死亡不可逆）。
## valid=false（没识别出关键骨骼）时静默跳过，返回 false，不报错。
func trigger_fire() -> bool:
	if not valid:
		return false
	return combat.trigger(MikuCombatAnim.Action.FIRE)


## 触发受击（上身小幅后仰 / 侧倾 + 头微微后；短促约 0.18 s，可叠加在行走之上）。
func trigger_hit() -> bool:
	if not valid:
		return false
	return combat.trigger(MikuCombatAnim.Action.HIT)


## 触发死亡（**不可逆**：接管整个身体，倒地后不恢复，直到 reset_pose()）。
func trigger_death() -> bool:
	if not valid:
		return false
	return combat.trigger(MikuCombatAnim.Action.DEATH)


## 触发换弹（左手离开护木去摸弹匣 + 右臂下压；中等时长约 1.2 s，期间移动速度受影响）。
func trigger_reload() -> bool:
	if not valid:
		return false
	return combat.trigger(MikuCombatAnim.Action.RELOAD)


## 复位姿态（重生时调用）：清掉战斗动作状态与死亡不可逆标记。
func reset_pose() -> void:
	combat.reset()
	if valid and _skeleton != null:
		for idx in _controlled:
			if idx >= 0:
				_skeleton.set_bone_global_pose_override(idx, Transform3D(), 0.0, false)


## 当前动作对移动速度的影响系数（1 = 不影响；换弹 <1；死亡 = 0）。
func movement_scale() -> float:
	return combat.movement_scale()


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


## 绕骨骼自己的 rest 原点旋转（idx < 0 时退化为绕骨架原点，见 _pivot_at）
func _pivot(idx: int, basis: Basis) -> Transform3D:
	if idx < 0:
		return Transform3D(basis, Vector3.ZERO)
	return _pivot_at(_skeleton.get_bone_global_rest(idx).origin, basis)


func _override(idx: int, transform: Transform3D) -> void:
	if idx < 0:
		return
	_skeleton.set_bone_global_pose_override(idx, transform, 1.0, true)


## 按骨骼名找骨骼：先完全匹配，再「包含」匹配（排除 IK / 親 / 先 之类的辅助骨骼）
func _find_by_names(names: Array, exclude: Array) -> int:
	for target in names:
		var wanted := String(target).to_lower().strip_edges()
		for i in _skeleton.get_bone_count():
			if _skeleton.get_bone_name(i).to_lower().strip_edges() == wanted:
				return i
	for target in names:
		var wanted := String(target).to_lower().strip_edges()
		for i in _skeleton.get_bone_count():
			var bone_name := _skeleton.get_bone_name(i).to_lower()
			if not bone_name.contains(wanted):
				continue
			var blocked := false
			for bad in exclude:
				if bone_name.contains(String(bad).to_lower()):
					blocked = true
					break
			if not blocked:
				return i
	return -1


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


## 头骨（启发式）：从身体中心沿**父链**往上走，取第一个「明显高于中心」的骨骼。
## 用父链而不是全骨架最高点，是为了让头的旋转叠在身体链上（不会把头从身体里拧出来）。
## 沿途都是辅助骨 / 走完 MAX_CHAIN_STEPS 都没找到 → 返回 -1（该子动作静默跳过）。
const HEAD_MIN_RATIO := 0.72   # 头的高度比例门槛（相对 min→max 的全高）
const HEAD_CENTER_MARGIN := 0.04 # 必须比中心骨高出这个比例才算「头」


func _find_head(positions: Array[Vector3]) -> int:
	if _center < 0:
		return -1
	var center_h := _height_ratio(positions[_center])
	var current := _skeleton.get_bone_parent(_center)
	for step in MAX_CHAIN_STEPS:
		if current < 0:
			return -1
		if _is_helper(current):
			current = _skeleton.get_bone_parent(current)
			continue
		var ratio := _height_ratio(positions[current])
		if ratio >= HEAD_MIN_RATIO and ratio > center_h + HEAD_CENTER_MARGIN:
			return current
		current = _skeleton.get_bone_parent(current)
	return -1


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


## 上臂「放下」旋转的符号：骨在骨架的右半侧（-X 侧）为 +1，镜像模型（+X 侧）为 -1
func _down_sign(arm_idx: int) -> float:
	if arm_idx < 0:
		return 1.0
	return 1.0 if _skeleton.get_bone_global_rest(arm_idx).origin.dot(_right) > 0.0 else -1.0


## 身体起伏幅度（骨架空间单位）：与骨架高度成正比。
## 纯静态函数，便于逐值断言「换骨架时起伏按比例缩放」（见守恒对照测试）。
static func bob_amplitude(height: float) -> float:
	return BOB_RATIO * height