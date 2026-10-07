extends SceneTree
# tools/probe_ual_topology.gd
# 目的：验证「驱动配对必须按拓扑序（父先于子）」这条实现约束。
# 风险：pose-delta 重定向里每根骨的局部姿态要用**父骨当前已写入的姿态**换算
#       （`q_local = q_parent⁻¹ · q_target`）。若配对顺序里子骨排在父骨之前，
#       父骨此刻还是上一帧 / rest 的姿态 ⇒ 该骨的旋转增量会算错（表现为腿歪 / 滑步）。
# 本探针打印 DRIVE 列表的每根骨在 **cat 骨架**里的父骨，验证「父骨也在列表里且更早」。
# 用法：godot --headless --path . --script res://tools/probe_ual_topology.gd

const CAT := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const UalBoneMapScript := preload("res://scripts/entities/ual_bone_map.gd")

## 与 ual_locomotion.gd 的 DRIVE_UAL_BONES + ARM_CHAIN_UAL 保持一致（故意手抄，
## 这样探针能独立验证组件里的顺序假设，而不是复用组件常量自证）。
const ORDER := [
	"DEF-hips", "DEF-spine.001", "DEF-spine.002", "DEF-neck",
	"DEF-shoulder.L", "DEF-upper_arm.L", "DEF-forearm.L", "DEF-hand.L",
	"DEF-shoulder.R", "DEF-upper_arm.R", "DEF-forearm.R", "DEF-hand.R",
	"DEF-thigh.L", "DEF-shin.L", "DEF-foot.L", "DEF-toe.L",
	"DEF-thigh.R", "DEF-shin.R", "DEF-foot.R", "DEF-toe.R",
]


func _init() -> void:
	var cat: Node = (load(CAT) as PackedScene).instantiate()
	get_root().add_child(cat)
	var sk := _find_skel(cat)

	print("=== cat 骨架里，这 20 根骨的父子关系（验证拓扑序）===")
	var seen := {}
	var violations := 0
	print("  %-3s %-20s → %-22s %-22s %s" % ["#", "UAL 骨", "cat 骨", "cat 父骨", "父是否更早出现"])
	for n in ORDER.size():
		var ual_bone := String(ORDER[n])
		var cat_bone := String(UalBoneMapScript.UAL_TO_CAT.get(ual_bone, ""))
		var ci := sk.find_bone(cat_bone)
		if ci < 0:
			print("  %-3d %-20s → %-22s (未找到!)" % [n, ual_bone, cat_bone])
			violations += 1
			continue
		seen[cat_bone] = n
		var cp := sk.get_bone_parent(ci)
		var parent_name := "<root>" if cp < 0 else sk.get_bone_name(cp)
		var ok := "-"
		if cp >= 0:
			# 父骨必须也在本列表里（这样它会被本类一起写），且序号更小（父先于子）
			if not seen.has(sk.get_bone_name(cp)):
				ok = "父不在列表(不写,安全)"
			elif int(seen[sk.get_bone_name(cp)]) < n:
				ok = "OK 父更早"
			else:
				ok = "✗✗ 父更晚(顺序错!)"
				violations += 1
		print("  %-3d %-20s → %-22s %-22s %s" % [n, ual_bone, cat_bone, parent_name, ok])

	print("")
	print("=== 汇总：拓扑序违规数 = %d%s" % [
		violations, "（0 = 组件里的配对顺序正确）" if violations == 0 else " ⇒ 组件顺序需修"])

	print("")
	print("=== 附加：确认「手指骨」不在列表里（归HandGripModifier）===")
	var finger_leak := 0
	for n in ORDER.size():
		var cat_bone := String(UalBoneMapScript.UAL_TO_CAT.get(String(ORDER[n]), ""))
		var low := cat_bone.to_lower()
		for kw in ["thumb", "index", "middle", "ring", "little", "finger"]:
			if low.contains(kw):
				print("  ✗ 手指骨泄漏进驱动列表：%s" % cat_bone)
				finger_leak += 1
	print("  手指骨泄漏数 = %d（必须 0）" % finger_leak)

	cat.free()
	quit(0)


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null