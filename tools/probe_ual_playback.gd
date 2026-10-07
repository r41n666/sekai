extends SceneTree
# tools/probe_ual_playback.gd
# 目的：决定性实测 —— UAL 动画在它**自己的**骨架上能否正常播放。
# 疑点来源：probe_ual_anim_semantics.gd 用 ap.advance() 推进时，t=0/0.6/1.25 三个时刻
#      骨骼 global_pose 完全相同 ⇒ 要么是 advance 没生效，要么是动画本身有问题。
#      **这一步必须先答对**，否则后面所有重定向结论都不可信。
# 用法：godot --headless --path . --script res://tools/probe_ual_playback.gd

const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"

func _init() -> void:
	var ual: Node = (load(UAL) as PackedScene).instantiate()
	var sk: Skeleton3D = _find_skel(ual)
	var ap: AnimationPlayer = _find_ap(ual)
	get_root().add_child(ual)

	print("=== SECTION 1: 全部53 条轨道的类型与路径（搞清哪些骨有 POS 轨道）===")
	var an: Animation = ap.get_animation("Idle")
	var pos_bones: Array = []
	var rot_bones: Array = []
	for t in range(an.get_track_count()):
		var pth := an.track_get_path(t)
		var ty := an.track_get_type(t)
		var sub := String(pth.get_subname(0))
		if ty == Animation.TYPE_POSITION_3D:
			pos_bones.append(sub)
		elif ty == Animation.TYPE_ROTATION_3D:
			rot_bones.append(sub)
	print("  POSITION_3D 轨道 %d 条: %s" % [pos_bones.size(), str(pos_bones)])
	print("  ROTATION_3D  轨道 %d 条" % rot_bones.size())
	print("  ⇒ 有 POS 轨道的骨= %d / 53（有 POS 轨道的骨才带位移，其余只被父级带动）"
		% pos_bones.size())

	print("")
	print("=== SECTION 2: 用 seek 采样（比 advance 可靠），看姿态是否真的随时间变===")
	ap.play("Idle")
	for t in [0.0, 0.3, 0.6, 0.9, 1.2, 1.6, 2.0, 2.4]:
		ap.seek(t, true, true)
		sk.force_update_all_bone_transforms()
		var hand := sk.get_bone_global_pose(sk.find_bone("DEF-hand.L"))
		var hand_r := sk.get_bone_global_pose(sk.find_bone("DEF-hand.R"))
		var foot := sk.get_bone_global_pose(sk.find_bone("DEF-foot.L"))
		var head := sk.get_bone_global_pose(sk.find_bone("DEF-head"))
		print("  t=%.2f  handL=(%.3f, %.3f, %.3f)  handR=(%.3f, %.3f, %.3f)  footL.y=%.3f  head.y=%.3f"
			% [t, hand.origin.x, hand.origin.y, hand.origin.z,
			hand_r.origin.x, hand_r.origin.y, hand_r.origin.z, foot.origin.y, head.origin.y])

	print("")
	print("=== SECTION 3: 极值扫描（整个 Idle 周期内手部/脚部的位移幅度）===")
	var min_h := Vector3(999, 999, 999)
	var max_h := Vector3(-999, -999, -999)
	var min_fy := 999.0
	var max_fy := -999.0
	var t2 := 0.0
	while t2 <= 2.5:
		ap.seek(t2, true, true)
		sk.force_update_all_bone_transforms()
		var h := sk.get_bone_global_pose(sk.find_bone("DEF-hand.L")).origin
		var fy := sk.get_bone_global_pose(sk.find_bone("DEF-foot.L")).origin.y
		min_h = min_h.min(h)
		max_h = max_h.max(h)
		min_fy = minf(min_fy, fy)
		max_fy = maxf(max_fy, fy)
		t2 += 0.05
	print("  handL  X[%.3f, %.3f] Y[%.3f, %.3f] Z[%.3f, %.3f]" % [
		min_h.x, max_h.x, min_h.y, max_h.y, min_h.z, max_h.z])
	print("  ⇒手部位移幅度 = %.4f（若≈0 说明动画没生效）" % (max_h - min_h).length())
	print("  footL.y 范围 [%.3f, %.3f]幅度= %.4f" % [min_fy, max_fy, max_fy - min_fy])

	print("")
	print("=== SECTION 4: 用Walk / Pistol_Shoot 复核（不同剪辑是否也不动）===")
	for anim_name in ["Walk", "Pistol_Shoot", "Death01"]:
		if not ap.has_animation(anim_name):
			continue
		ap.play(anim_name)
		var amin := 999.0
		var amax := -999.0
		var ymin := 999.0
		var ymax := -999.0
		var tt := 0.0
		var dur: float = ap.get_animation(anim_name).length
		while tt <= dur:
			ap.seek(tt, true, true)
			sk.force_update_all_bone_transforms()
			var hy := sk.get_bone_global_pose(sk.find_bone("DEF-hand.R")).origin.y
			var fy2 := sk.get_bone_global_pose(sk.find_bone("DEF-foot.L")).origin.y
			amin = minf(amin, hy)
			amax = maxf(amax, hy)
			ymin = minf(ymin, fy2)
			ymax = maxf(ymax, fy2)
			tt += 0.05
		print("  %-14s len=%.2f  handR.y 幅度=%.4f  footL.y 幅度=%.4f" % [
			anim_name, dur, amax - amin, ymax - ymin])

	ual.free()
	quit(0)

func ty_of(t: int) -> int:
	return t

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
