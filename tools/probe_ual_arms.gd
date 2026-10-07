extends Node3D
# tools/probe_ual_arms.gd
# 目的：**窗口模式**实测（headless 下 seek 不更新骨骼姿态，见评估报告 §8-3），
#      为「空手时手臂归谁」这一决策提供**量化依据**。
# 问题：UAL 的 Idle/Walk 自带手臂摆动；若让 UAL 驱动手臂，
#      与持枪时的 WeaponHoldIK 切换是否跳变？跳变多大？
# 测三件事：
#   ① 四条候选剪辑的「腿 vs 手臂 vs 骨盆」位移幅度（各骨骼链的运动量）
#   ② UAL 手臂在 Idle/Walk 时的**手部位移**（相对身体中线）——判断摆臂是否明显
#   ③ cat rest 是 T-pose（已实测 89.1°）⇒ 若「手臂完全没人管」= T-pose 穿帮
# 用法：
#   godot --path . --rendering-driver vulkan --resolution 640x400 res://tools/probe_ual_arms.tscn

const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"
const CLIPS := ["Idle", "Walk", "Jog_Fwd", "Sprint", "Walk_Formal"]


func _ready() -> void:
	var ual: Node = (load(UAL) as PackedScene).instantiate()
	add_child(ual)
	var sk := _find_skel(ual)
	var ap := _find_ap(ual)
	print("=== UAL 四条 locomotion 剪辑的运动量（窗口模式实测，UAL 骨架单位）===")
	print("  %-12s %8s %8s %8s %8s %8s" % ["clip", "footL.y", "handR.y", "hips.y", "手-中线", "步频/周期"])
	for name in CLIPS:
		if not ap.has_animation(name):
			continue
		var an: Animation = ap.get_animation(name)
		ap.play(name)
		var f_min := 999.0; var f_max := -999.0
		var h_min := 999.0; var h_max := -999.0
		var p_min := 999.0; var p_max := -999.0
		var lat_min := 999.0; var lat_max := -999.0
		var t := 0.0
		while t <= an.length + 0.001:
			ap.seek(t, true, true)
			sk.force_update_all_bone_transforms()
			var fy := sk.get_bone_global_pose(sk.find_bone("DEF-foot.L")).origin.y
			var h := sk.get_bone_global_pose(sk.find_bone("DEF-hand.R")).origin
			var py := sk.get_bone_global_pose(sk.find_bone("DEF-hips")).origin.y
			f_min = minf(f_min, fy); f_max = maxf(f_max, fy)
			h_min = minf(h_min, h.y); h_max = maxf(h_max, h.y)
			p_min = minf(p_min, py); p_max = maxf(p_max, py)
			lat_min = minf(lat_min, absf(h.x)); lat_max = maxf(lat_max, absf(h.x))
			t += 0.02
		print("  %-12s %8.3f %8.3f %8.3f %8.3f %8.2fs" % [
			name, f_max - f_min, h_max - h_min, p_max - p_min, lat_max - lat_min, an.length])

	print("")
	print("=== 结论用数据：Walk 剪辑里 UAL 手臂的运动量 vs 腿 ===")
	ap.play("Walk")
	var an: Animation = ap.get_animation("Walk")
	var samples := 8
	var arm_pts: Array[Vector3] = []
	var leg_pts: Array[Vector3] = []
	for i in samples:
		var t := an.length * float(i) / float(samples)
		ap.seek(t, true, true)
		sk.force_update_all_bone_transforms()
		arm_pts.append(sk.get_bone_global_pose(sk.find_bone("DEF-hand.R")).origin)
		leg_pts.append(sk.get_bone_global_pose(sk.find_bone("DEF-foot.L")).origin)
	var arm_span := _span(arm_pts)
	var leg_span := _span(leg_pts)
	print("  手部轨迹包围盒对角线 = %.4f" % arm_span)
	print("  脚部轨迹包围盒对角线 = %.4f" % leg_span)
	print("  ⇒ UAL 自带摆臂幅度是腿的 %.1f%%（>30%% ⇒ 空手时若排除手臂，缺的不是细节）" % [
		(arm_span / maxf(leg_span, 0.0001)) * 100.0])

	print("")
	print("MEASURE_DONE")
	await get_tree().process_frame
	get_tree().quit(0)


func _span(pts: Array[Vector3]) -> float:
	if pts.size() < 2:
		return 0.0
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = lo.min(p)
		hi = hi.max(p)
	return (hi - lo).length()


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var f := _find_ap(c)
		if f != null:
			return f
	return null