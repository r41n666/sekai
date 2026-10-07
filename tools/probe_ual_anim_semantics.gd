extends SceneTree
# tools/probe_ual_anim_semantics.gd
# 目的：实测 UAL 动画的轨道语义（决定重定向能否直接套用）。
# 关键疑点：UAL DEF-hips 的 POSITION 轨道值 (0.005, 0.086, 0.877) 与其
#      get_bone_global_rest (0, 0.917, -0.050) 差距巨大 ⇒ 必须确认动画坐标系与 rest 的关系。
# 用法：godot --headless --path . --script res://tools/probe_ual_anim_semantics.gd

const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"

func _init() -> void:
	var ual: Node = (load(UAL) as PackedScene).instantiate()
	var sk: Skeleton3D = _find_skel(ual)
	var ap: AnimationPlayer = _find_ap(ual)
	# 必须入树，AnimationPlayer 才能驱动骨骼
	get_root().add_child(ual)
	ap.play("Idle")
	ap.advance(0.0)

	print("=== SECTION 1: 骨骼rest 的完整 Transform（不只是 origin）===")
	for bn in ["root", "DEF-hips", "DEF-spine.001", "DEF-upper_arm.L", "DEF-hand.L", "DEF-thigh.L"]:
		var i := sk.find_bone(bn)
		if i < 0:
			print("  %-18s NOT_FOUND" % bn)
			continue
		var r := sk.get_bone_rest(i)
		var g := sk.get_bone_global_rest(i)
		print("  %-18s" % bn)
		print("      rest.origin=%s  rest.basis.x=%s" % [str(r.origin), str(r.basis.x.normalized())])
		print("      globalrest.origin=%s  globalrest.basis.x=%s" % [str(g.origin), str(g.basis.x.normalized())])

	print("")
	print("=== SECTION 2: 播放 Idle 后骨骼实际 global_pose vs rest===")
	for t in [0.0, 0.6, 1.25]:
		ap.advance(t - (0.0 if t == 0.0 else [0.0, 0.6, 1.25][[0.0, 0.6, 1.25].find(t) - 1]))
		print("  --- t=%.2f ---" % t)
		for bn in ["root", "DEF-hips", "DEF-upper_arm.L", "DEF-hand.L", "DEF-thigh.L", "DEF-foot.L"]:
			var i2 := sk.find_bone(bn)
			if i2 < 0:
				continue
			var pose := sk.get_bone_global_pose(i2)
			var rest := sk.get_bone_global_rest(i2)
			print("      %-18s pose.origin=%-28s rest.origin=%-28s |dpos|=%.4f" % [
				bn, str(pose.origin), str(rest.origin), pose.origin.distance_to(rest.origin)])

	print("")
	print("=== SECTION 3: 直接读轨道原始值 vs rest（诊断坐标系）===")
	var an: Animation = ap.get_animation("Idle")
	for tr in range(an.get_track_count()):
		var pth := String(an.track_get_path(tr))
		var ty := an.track_get_type(tr)
		var bn2 := pth.get_file()
		if not (bn2 == "DEF-hips" or bn2 == "root" or bn2 == "DEF-upper_arm.L"):
			continue
		var bi := sk.find_bone(bn2)
		var rest2 := sk.get_bone_rest(bi) if bi >= 0 else Transform3D()
		if ty == Animation.TYPE_POSITION_3D:
			var v: Vector3 = an.track_get_key_value(tr, 0)
			print("  POS %-16s key0=%-30s bone_rest.origin=%-30s rest+key=%s" % [
				bn2, str(v), str(rest2.origin), str(rest2.origin + v)])
		elif ty == Animation.TYPE_ROTATION_3D:
			var q: Quaternion = an.track_get_key_value(tr, 0)
			var br := rest2.basis.get_rotation_quaternion()
			print("  ROT %-16s key0=%-46s" % [bn2, str(q)])
			print("      bone_rest.quat=%-40s key*inv(rest)=%s" % [str(br), str(q * br.inverse())])

	print("")
	print("=== SECTION 4: UAL Skeleton3D 节点自身 transform（是否被导入期旋转过）===")
	print("  Skeleton3D.transform      = %s" % str(sk.transform))
	print("  Skeleton3D.global_transform = %s" % str(sk.global_transform))
	var rig := sk.get_parent()
	print("  父节点 %s (%s).transform = %s" % [rig.name, rig.get_class(), str(rig.transform)])

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
