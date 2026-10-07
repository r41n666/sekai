extends SceneTree
# tools/probe_ual_clips.gd
# 目的：为「只注册 4 条 locomotion 剪辑」选定**有实测依据**的清单，并拿到
#       状态机阈值所需的长度 / 步频数据。
# 事实问题：
#   ① Idle / Walk / Jog_Fwd / Sprint 四条各多长？loop_mode 是什么？
#   ② 首尾帧是否首尾相接（loop 是否会「跳一下」）？—— 用首尾姿态夹角判定
#   ③ cat_hatsune_miku 的 **rest 姿态**手臂是什么姿势（T-pose 还是 A-pose）？
#      这决定「排除手臂链」后空手时的手臂观感。
#   ④ UAL 四条剪辑里的手臂骨运动幅度（量化「UAL 自带摆臂」，供手臂所有权决策）
#   ⑤ 本项目实际速度档：walk 3.6 / sprint 6.5 m�� ⇒ speed_ratio 分档
# 用法：godot --headless --path . --script res://tools/probe_ual_clips.gd

const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"
const CAT := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const CANDIDATES := ["Idle", "Walk", "Jog_Fwd", "Sprint", "Walk_Formal", "Crouch_Idle"]


func _init() -> void:
	var ual: Node = (load(UAL) as PackedScene).instantiate()
	var usk := _find_skel(ual)
	var uap := _find_ap(ual)
	get_root().add_child(ual)

	print("=== SECTION 1: 候选 locomotion 剪辑的长度 / 循环 / 首尾连续性 ===")
	print("  %-12s %6s %-14s %8s %8s %8s" % ["clip", "len", "loop", "首尾夹角", "脚Y幅度", "手Y幅度"])
	for name in CANDIDATES:
		if not uap.has_animation(name):
			print("  %-12s （不存在）" % name)
			continue
		var an: Animation = uap.get_animation(name)
		# 首尾姿态夹角：同一根骨在 t=0 与 t=len 的全局旋转差（越小越平滑）
		uap.play(name)
		uap.seek(0.0, true, true)
		usk.force_update_all_bone_transforms()
		var q0 := usk.get_bone_global_pose(usk.find_bone("DEF-spine.002")).basis.orthonormalized().get_rotation_quaternion()
		var f0 := usk.get_bone_global_pose(usk.find_bone("DEF-foot.L")).origin
		var h0 := usk.get_bone_global_pose(usk.find_bone("DEF-hand.R")).origin
		var dur := an.length
		uap.seek(dur, true, true)
		usk.force_update_all_bone_transforms()
		var q1 := usk.get_bone_global_pose(usk.find_bone("DEF-spine.002")).basis.orthonormalized().get_rotation_quaternion()
		var f1 := usk.get_bone_global_pose(usk.find_bone("DEF-foot.L")).origin
		var h1 := usk.get_bone_global_pose(usk.find_bone("DEF-hand.R")).origin
		print("  %-12s %6.2f %-14s %7.1f° %7.3f %7.3f" % [
			name, dur, str(an.loop_mode), rad_to_deg(q0.angle_to(q1)),
			absf(f1.y - f0.y), absf(h1.y - h0.y)])

	print("")
	print("=== SECTION 2: 全 46 条剪辑里，哪些是「纯 locomotion」（名字过滤，仅供参考）===")
	var all: Array = []
	for a in uap.get_animation_list():
		all.append(String(a))
	all.sort()
	print("  ", str(all))

	print("")
	print("=== SECTION 3: cat_hatsune_miku 的 rest 姿态 —— 手臂是 T-pose 还是 A-pose？ ===")
	var cat: Node = (load(CAT) as PackedScene).instantiate()
	get_root().add_child(cat)
	var csk := _find_skel(cat)
	var up := Vector3.UP
	var shoulder_r := csk.get_bone_global_rest(csk.find_bone("upper_arm.R_87")).origin
	var hand_r := csk.get_bone_global_rest(csk.find_bone("hand.R_85")).origin
	var v := hand_r - shoulder_r
	print("  rest: shoulder.R=(%.3f,%.3f,%.3f) hand.R=(%.3f,%.3f,%.3f)" % [
		shoulder_r.x, shoulder_r.y, shoulder_r.z, hand_r.x, hand_r.y, hand_r.z])
	print("  手臂方向向量 = (%.3f,%.3f,%.3f) ｜ 与「水平外展」夹角 = %.1f° ｜ 与「竖直向下」夹角 = %.1f°" % [
		v.x, v.y, v.z,
		rad_to_deg(Vector3(v.x, 0, v.z).normalized().angle_to(Vector3.RIGHT)),
		rad_to_deg(v.normalized().angle_to(Vector3.DOWN))])
	print("  ⇒ 夹角接近 90°=水平外展(T-pose 特征)；接近 0°=竖直(A-pose 特征)")

	print("")
	print("=== SECTION 4: cat 自带 idle 剪辑（0.08s T-pose 定格）播完后手臂在哪 ===")
	var cap := _find_ap(cat)
	if cap != null:
		print("  cat 剪辑列表 = ", str(cap.get_animation_list()))
		cap.play("idle")
		cap.seek(0.079, true, true)
		csk.force_update_all_bone_transforms()
		var hr := csk.get_bone_global_pose(csk.find_bone("hand.R_85")).origin
		var sr := csk.get_bone_global_pose(csk.find_bone("upper_arm.R_87")).origin
		var v2 := hr - sr
		print("  播完 idle 后手臂向量=(%.3f,%.3f,%.3f) 与竖直向下夹角=%.1f°" % [
			v2.x, v2.y, v2.z, rad_to_deg(v2.normalized().angle_to(Vector3.DOWN))])
		cap.stop()
	else:
		print("  cat 无 AnimationPlayer")

	print("")
	print("=== SECTION 5: 四条候选剪辑的「腿/躯干 vs 手臂」分家幅度（手臂所有权决策依据）===")
	for name in ["Idle", "Walk", "Jog_Fwd", "Sprint"]:
		if not uap.has_animation(name):
			continue
		var an2: Animation = uap.get_animation(name)
		uap.play(name)
		var foot_min := 999.0
		var foot_max := -999.0
		var hand_min := 999.0
		var hand_max := -999.0
		var hips_min := 999.0
		var hips_max := -999.0
		var t := 0.0
		while t <= an2.length + 0.001:
			uap.seek(t, true, true)
			usk.force_update_all_bone_transforms()
			var fy := usk.get_bone_global_pose(usk.find_bone("DEF-foot.L")).origin.y
			var hy := usk.get_bone_global_pose(usk.find_bone("DEF-hand.R")).origin.y
			var py := usk.get_bone_global_pose(usk.find_bone("DEF-hips")).origin.y
			foot_min = minf(foot_min, fy); foot_max = maxf(foot_max, fy)
			hand_min = minf(hand_min, hy); hand_max = maxf(hand_max, hy)
			hips_min = minf(hips_min, py); hips_max = maxf(hips_max, py)
			t += 0.04
		print("  %-10s 脚L.y幅度=%.3f  手R.y幅度=%.3f  骨盆.y幅度=%.3f  (UAL骨架单位)" % [
			name, foot_max - foot_min, hand_max - hand_min, hips_max - hips_min])

	print("")
	print("=== SECTION 6: 本项目速度档 ⇒ speed_ratio（player: walk 3.6 / sprint 6.5）===")
	for sp in [0.0, 2.8, 3.6, 5.2, 6.5]:
		print("  speed=%.1f m/s ⇒ ratio=%.3f  (run_threshold=0.62 ⇒ %s)" % [
			sp, sp / 6.5, "run" if sp / 6.5 >= 0.62 else "walk"])

	ual.free()
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


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var f := _find_ap(c)
		if f != null:
			return f
	return null