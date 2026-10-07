extends SkeletonModifier3D
## 手指抓握的**骨骼应用层**：把 `HandGrip` 的纯逻辑算出的弯曲角写到 15 根指骨上。
##
## ## 为什么是 `SkeletonModifier3D`（而不是在 `_process` 里 set_bone_pose）
## 1. `SkeletonModifier3D` **在 AnimationMixer 之后**运行，且同一骨架下按**子节点顺序**依次执行
##    （官方设计文档）。本节点在 `WeaponHoldIK` 建完两条 `TwoBoneIK3D` **之后**才 add_child，
##    因此**在 IK 之后**运行 ⇒ 可以读到 IK 改过的**手骨姿态**，再在它之上弯手指。
## 2. 在本节点里 set 的骨骼姿态**不影响** AnimationMixer 的采样（mixer 已跑完），
##    也不会被它覆盖；每帧稳定生效。
##
## ## 与现有层不冲突
##   · 它只写 **15 根指骨**（hand 之下），不写 upper/lower/hand ⇒ 不抢 `TwoBoneIK3D`。
##   · 指骨**不在** `MikuProceduralPose._controlled` 里（该清单含腿/躯干/头，`pose_arms=false`
##     时也不含手臂）⇒ 不抢程序化步态。
##   · `active=false` 时完全不处理（默认关闭，保基线）。
##
## ## 引擎 API 备注（本 spike 实测口径）
##   · `_process_modification()` 在 4.5+ 标记 deprecated，新口径是
##     `_process_modification_with_delta(delta)`。**两者都重写 + 帧级去重**（`_apply` 里按
##     `Engine.get_process_frames()` 去重），无论引擎回调哪一个都只跑一次。

## 用 preload 而非全局 `class_name HandGrip`：全局名依赖导入缓存，headless 首次运行解析不到。
const HandGripScript := preload("res://scripts/entities/hand_grip.gd")

var role: int = HandGripScript.Role.GRIP
var side: String = "r"
var hand_bone := ""

var _resolved := {}
var _hand_idx := -1
var _valid := false
var _last_frame := -1


## 配置并解析骨链。`p_hand_bone` = 手骨名（由 `WeaponHoldIK` 提供）。
func configure(p_side: String, p_role: int, p_hand_bone: String) -> bool:
	side = p_side
	role = p_role
	hand_bone = p_hand_bone
	_resolve()
	return _valid


func _resolve() -> void:
	_valid = false
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	var names := PackedStringArray()
	for i in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(i))
	_resolved = HandGripScript.resolve_finger_bones(names, side)
	_hand_idx = skeleton.find_bone(hand_bone)
	_valid = _hand_idx >= 0 and HandGripScript.resolved_is_complete(_resolved)


func is_valid() -> bool:
	return _valid


func _process_modification() -> void:
	_apply()


func _process_modification_with_delta(_delta: float) -> void:
	_apply()


func _apply() -> void:
	# 帧级去重：无论引擎回调哪个虚函数（或两个都回调），每帧只应用一次。
	var frame := Engine.get_process_frames()
	if frame == _last_frame:
		return
	_last_frame = frame
	if not _valid:
		return
	HandGripScript.apply_chain(get_skeleton(), _hand_idx, _resolved, role, side)
