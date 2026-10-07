extends SceneTree
## 探针 2：把cat 的 `idle`（0.083 s）剪辑**逐轨道**摊开，回答三个问题：
##   Q1 唯一那条「会动」的轨道是**哪根骨**？它每0.083 s 摆动多少度？
##   Q2 `idle` 的姿态 key 与 Skeleton3D 的 **rest 全局姿态**差多少？（=「播完等于没播」的量化）
##   Q3 `_build_state_clips` 把 idle 设成 LOOP_LINEAR 后，AnimationPlayer 每秒重写多少次骨骼？
##      以及 blend(fade_time=0.18) > clip长度(0.083) 会不会导致反复重blend？
##
## 运行：godot --headless --path . -s res://tools/probe_idle_clip.gd

const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const FADE_TIME := 0.18


func _initialize() -> void:
	var inst := (load(CAT_MODEL) as PackedScene).instantiate()
	root.add_child(inst)
	var ap := _find_ap(inst)
	var sk := _find_skel(inst)

	print("=== Q1: idle 剪辑逐轨道（只看会动的） ===")
	var a := ap.get_animation("idle")
	for track in a.get_track_count():
		var ttype := a.track_get_type(track)
		if ttype != Animation.TYPE_POSITION_3D and ttype != Animation.TYPE_ROTATION_3D:
			continue
		var keys := a.track_get_key_count(track)
		var path := a.track_get_path(track)
		var bone := ""
		if path.get_subname_count() > 0:
			bone = String(path.get_subname(path.get_subname_count() - 1))
		var maxd := 0.0
		var maxdeg := 0.0
		for k in keys:
			for j in range(k + 1, keys):
				var ka: Variant = a.track_get_key_value(track, k)
				var kb: Variant = a.track_get_key_value(track, j)
				if ttype == Animation.TYPE_POSITION_3D:
					maxd = maxf(maxd, (Vector3(ka) - Vector3(kb)).length())
				else:
					maxdeg = maxf(maxdeg, rad_to_deg(Quaternion(ka).angle_to(Quaternion(kb))))
		if maxd > 1e-6 or maxdeg > 0.05:
			print("  ★ 会动的轨道: path=%s bone='%s' type=%s keys=%d 最大位移=%.6f 最大夹角=%.4f°" % [
				str(path), bone, "ROT" if ttype == Animation.TYPE_ROTATION_3D else "POS",
				keys, maxd, maxdeg])
			for k in keys:
				var t := a.track_get_key_time(track, k)
				var v: Variant = a.track_get_key_value(track, k)
				if ttype == Animation.TYPE_ROTATION_3D:
					var q := Quaternion(v)
					print("      t=%.4f  euler_deg=(%.3f, %.3f, %.3f)" % [
						t, rad_to_deg(q.get_euler().x), rad_to_deg(q.get_euler().y), rad_to_deg(q.get_euler().z)])
				else:
					print("      t=%.4f  pos=%s" % [t, str(Vector3(v))])

	print("\n=== Q1b: ArmatureAction（2.5s 那条）里 idle 缺了什么：腿骨有没有动===")
	var big := ap.get_animation("ArmatureAction")
	for bone in ["upper_leg.L_100", "upper_leg.R_94", "lower_leg", "foot.L_97", "foot.R_102"]:
		var track := big.find_track(NodePath("Skeleton3D:" + bone), Animation.TYPE_ROTATION_3D)
		if track < 0:
			print("  %-20s 无旋转轨道" % bone)
			continue
		var maxdeg := 0.0
		var keys := big.track_get_key_count(track)
		for k in keys:
			for j in range(k + 1, keys):
				var qa := Quaternion(big.track_get_key_value(track, k))
				var qb := Quaternion(big.track_get_key_value(track, j))
				maxdeg = maxf(maxdeg, rad_to_deg(qa.angle_to(qb)))
		print("  %-20s keys=%3d 最大夹角=%.3f°" % [bone, keys, maxdeg])

	print("\n=== Q2: idle 的 key 姿态 vs Skeleton3D rest 全局姿态 ===")
	# idle 的旋转轨道写的是**局部**姿态；rest 全局姿态 rest_global。
	# 用「局部姿态反推全局」比较：先按 rest 的父子关系累乘。
	sk.force_update_all_bone_transforms()
	var worst := 0.0
	var worst_bone := ""
	var checked := 0
	for track in a.get_track_count():
		if a.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var path := a.track_get_path(track)
		if path.get_subname_count() == 0:
			continue
		var bone := String(path.get_subname(path.get_subname_count() - 1))
		var bi := sk.find_bone(bone)
		if bi < 0:
			continue
		checked += 1
		# clip 的局部旋转（取首 key）
		var local := Quaternion(a.track_get_key_value(track, 0))
		# rest 的局部旋转
		var rest_local := Quaternion(sk.get_bone_rest(bi).basis.orthonormalized())
		var d := rad_to_deg(local.angle_to(rest_local))
		if d > worst:
			worst = d
			worst_bone = bone
	print("  比对的旋转轨道数 = %d" % checked)
	print("  「idle 首帧局部姿态 vs rest 局部姿态」最大夹角 = %.4f° （骨 %s）" % [worst, worst_bone])

	print("\n=== Q3: 循环 + blend 的数字 ===")
	print("  idle.length = %.4f s  → 每秒播放 %.2f 轮" % [a.length, 1.0 / a.length])
	print("  _build_state_clips 会把 idle/walk/run 设成 loop_mode = LOOP_LINEAR(1)")
	print("  fade_time = %.2f s  >  idle.length = %.4f s  ⇒ blend 时长是剪辑长度的 %.1f 倍" % [
		FADE_TIME, a.length, FADE_TIME / a.length])
	print("  ⚠ 若 blend 未完成就再次 play()，AnimationMixer 会从当前权重重新交叉淡入 ⇒ 视觉抖动")

	print("\n=== Q3b: 头/胸/腿在 rest 姿态下的「手高度」参照（T-pose 判别）===")
	for bone in ["hand.L_66", "hand.R_85", "head_49", "foot.L_97", "foot.R_102"]:
		var bi := sk.find_bone(bone)
		if bi < 0:
			print("  %-14s 找不到" % bone)
			continue
		print("  %-14s rest全局位置 y=%.4f" % [bone, sk.get_bone_global_pose(bi).origin.y])
	quit(0)


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var f := _find_ap(c)
		if f != null:
			return f
	return null


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null