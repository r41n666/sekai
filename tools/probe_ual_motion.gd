extends SceneTree
# tools/probe_ual_motion.gd
# 目的：分离「动画数据本身有运动」与「播放未生效」两种可能。
# 前一探针出现矛盾：姿态偏离 rest 但不随时间变 ⇒ 必须查清是数据问题还是应用问题。
# 用法：godot --headless --path . --script res://tools/probe_ual_motion.gd

const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"

func _init() -> void:
	var ual: Node = (load(UAL) as PackedScene).instantiate()
	var sk: Skeleton3D = _find_skel(ual)
	var ap: AnimationPlayer = _find_ap(ual)
	get_root().add_child(ual)

	print("=== SECTION 1: 原始轨道数据本身有运动吗（绕开引擎，直接读 key）===")
	var an: Animation = ap.get_animation("Walk")
	# 找 DEF-hand.R 的旋转轨道，打印其全部 key 的四元数
	var hand_rot_track := -1
	var hips_pos_track := -1
	var head_rot_track := -1
	for t in range(an.get_track_count()):
		var pth := an.track_get_path(t)
		var sub := String(pth.get_subname(0))
		if sub == "DEF-hand.R" and an.track_get_type(t) == Animation.TYPE_ROTATION_3D:
			hand_rot_track = t
		elif sub == "DEF-hips" and an.track_get_type(t) == Animation.TYPE_POSITION_3D:
			hips_pos_track = t
		elif sub == "DEF-head" and an.track_get_type(t) == Animation.TYPE_ROTATION_3D:
			head_rot_track = t
	print("  DEF-hand.R 旋转轨道 #%d，key数=%d" % [hand_rot_track, an.track_get_key_count(hand_rot_track)])
	var q_first: Quaternion = an.track_get_key_value(hand_rot_track, 0)
	var q_last: Quaternion = an.track_get_key_value(hand_rot_track, an.track_get_key_count(hand_rot_track) - 1)
	print("    key[0]=%s" % str(q_first))
	print("    key[last]=%s" % str(q_last))
	print("    两端夹角= %.2f 度 ⇒ %s" % [
		rad_to_deg(q_first.angle_to(q_last)),
		"数据有运动" if rad_to_deg(q_first.angle_to(q_last)) > 1.0 else "**数据是定格的**"])
	print("")
	print("    DEF-hips 位置轨道 #%d，key数=%d" % [hips_pos_track, an.track_get_key_count(hips_pos_track)])
	var p0: Vector3 = an.track_get_key_value(hips_pos_track, 0)
	var pN: Vector3 = an.track_get_key_value(hips_pos_track, an.track_get_key_count(hips_pos_track) - 1)
	print("      key[0]=%s  key[last]=%s  位移=%.4f" % [str(p0), str(pN), p0.distance_to(pN)])

	print("")
	print("=== SECTION 2: AnimationPlayer 的播放头真的在走吗 ===")
	ap.play("Walk")
	for i in range(4):
		ap.seek(0.3 * i, true, true)
		print("  seek(%.1f) → current_animation_position=%.4f  playing=%s  speed=%f" % [
			0.3 * i, ap.current_animation_position, str(ap.is_playing()), ap.speed_scale])

	print("")
	print("=== SECTION 3: 不调 force_update，直接读 pose（验证上一步的元凶）===")
	for t in [0.0, 0.4, 0.8, 1.2]:
		ap.seek(t, true, true)
		var hp := sk.get_bone_global_pose(sk.find_bone("DEF-hand.R")).origin
		var fp := sk.get_bone_global_pose(sk.find_bone("DEF-foot.L")).origin
		print("  t=%.1f  handR=(%.4f, %.4f, %.4f)  footL.y=%.4f" % [t, hp.x, hp.y, hp.z, fp.y])

	print("")
	print("=== SECTION 4: 结论性对照 —— 采样轨道 key 插值，绕过引擎算手部位置 ===")
	# 直接用 Animation 的 sample() API（Godot 4 提供 AnimationMixer 之外的blend/采样）
	print("  用 Animation.sample() 手动采样（不经 AnimationPlayer）：")
	for t in [0.0, 0.4, 0.8, 1.2]:
		#构造一个假的 tracks 目标：直接对 DEF-hand.R 旋转轨道做线性插值取样
		var idx := 0
		for k in range(an.track_get_key_count(hand_rot_track)):
			if an.track_get_key_time(hand_rot_track, k) <= t:
				idx = k
		var qa: Quaternion = an.track_get_key_value(hand_rot_track, maxi(0, idx - 1))
		print("    t=%.1f  轨道 nearest idx=%d  q=%s" % [t, idx, str(qa)])

	print("")
	print("=== SECTION 5: 动画是否被导入器标记成 remove_immutable_tracks 的产物===")
	print("  Idle: root 有 POS 轨道，DEF-hips 有 POS 轨道，其余只有 ROT")
	print("  检查 Idle 的手部旋转轨道两端是否相同（定格式=remove_immutable 误留/或源数据即定格）")
	var an2: Animation = ap.get_animation("Idle")
	for t2 in range(an2.get_track_count()):
		var pth2 := an2.track_get_path(t2)
		if String(pth2.get_subname(0)) == "DEF-hand.R" and an2.track_get_type(t2) == Animation.TYPE_ROTATION_3D:
			var qa2: Quaternion = an2.track_get_key_value(t2, 0)
			var qb2: Quaternion = an2.track_get_key_value(t2, an2.track_get_key_count(t2) - 1)
			print("    Idle DEF-hand.R key数=%d  两端夹角=%.3f 度" % [
				an2.track_get_key_count(t2), rad_to_deg(qa2.angle_to(qb2))])

	ual.free()
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
