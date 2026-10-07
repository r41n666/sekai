extends SceneTree
## [临时只读探针] 验证本项目 Godot 4.7.2 实际可用的动画/重定向/IK 类。
## 决定性判据：若 IKModifier3D 族与 SkeletonProfileHumanoid 存在，
## 则「专业持枪姿势」在 Godot 侧可做（右手握把 + 左手扶护木多点约束）。
## 用法：godot --headless --path . -s tools/audit_godot_anim_caps.gd

const CLASSES := [
	# 骨骼修改器基类（4.4+）
	"SkeletonModifier3D", "LookAtModifier3D", "RetargetModifier3D",
	# 4.5+ 约束 / 弹簧
	"BoneConstraint3D", "AimModifier3D", "CopyTransformModifier3D",
	"ConvertTransformModifier3D", "SpringBoneSimulator3D",
	# 4.6+ IK 求解器族
	"IKModifier3D", "TwoBoneIK3D", "ChainIK3D", "SplineIK3D", "IterateIK3D",
	"FABRIK3D", "CCDIK3D", "JacobianIK3D",
	# 旧 IK（可能已废弃）
	"SkeletonIK3D",
	# 动画重定向（4.3+）
	"SkeletonProfile", "SkeletonProfileHumanoid",
	# 动画系统
	"AnimationTree", "AnimationNodeStateMachine", "AnimationNodeBlendSpace2D",
	"AnimationNodeBlendTree", "AnimationMixer", "AnimationLibrary",
	# 骨骼相关
	"Skeleton3D", "BoneAttachment3D", "BoneMap",
]


func _init() -> void:
	print("=== Godot 版本 ===")
	print("    %s" % Engine.get_version_info())
	print("")
	print("=== 动画/重定向/IK 类可用性 ===")
	var have: Array = []
	var miss: Array = []
	for c in CLASSES:
		# ClassDB 是判断类是否真实存在的权威来源
		if ClassDB.class_exists(c):
			var ok := true
			var note := ""
			# 能否实例化（有些是抽象基类）
			if ClassDB.can_instantiate(c):
				note = "可实例化"
			else:
				note = "抽象/不可直接实例化"
			print("  %-28s ✅ %s" % [c, note])
			have.append(c)
		else:
			print("  %-28s ❌ 不存在" % c)
			miss.append(c)
	print("")
	print("可用 %d / %d" % [have.size(), CLASSES.size()])
	if miss.size() > 0:
		print("缺失: %s" % ", ".join(miss))
	print("")
	# 关键结论
	var ik_ok := ClassDB.class_exists("IKModifier3D") and ClassDB.class_exists("TwoBoneIK3D")
	var rt_ok := ClassDB.class_exists("SkeletonProfileHumanoid")
	var retarget_ok := ClassDB.class_exists("RetargetModifier3D")
	print("=== 结论 ===")
	print("  完整 IK 求解器（TwoBoneIK3D 等）: %s" % ("✅ 有" if ik_ok else "❌ 无"))
	print("  人形骨骼档案 SkeletonProfileHumanoid: %s" % ("✅ 有" if rt_ok else "❌ 无"))
	print("  动画重定向 RetargetModifier3D: %s" % ("✅ 有" if retarget_ok else "❌ 无"))
	quit(0)