extends SceneTree
# tools/probe_cat_scene.gd
# 目的：查 cat 场景节点结构（重定向要写对轨道路径），并实测 Godot 4 骨骼位置轨道的语义。
const CAT := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"

func _init() -> void:
	print("=== SECTION 1: cat 场景节点树（带完整路径）===")
	var cat: Node = (load(CAT) as PackedScene).instantiate()
	_dump(cat, NodePath(""), 0)

	print("")
	print("=== SECTION 2: cat 自带 idle 剪辑的轨道路径与取值（判断位置轨道语义）===")
	var aps: Array = []
	_collect_aps(cat, aps)
	for ap in aps:
		var p: AnimationPlayer = ap
		for an_name in p.get_animation_list():
			var an: Animation = p.get_animation(String(an_name))
			print("  --- %s (len=%.2f, tracks=%d) ---" % [String(an_name), an.length, an.get_track_count()])
			var shown := 0
			for t in range(an.get_track_count()):
				var pth := String(an.track_get_path(t))
				var typ := an.track_get_type(t)
				if typ == Animation.TYPE_POSITION_3D and (pth.contains("hips") or pth.contains("root")):
					var v0: Vector3 = an.track_get_key_value(t, 0)
					var v1: Vector3 = an.track_get_key_value(t, mini(1, an.track_get_key_count(t) - 1))
					print("    POS %s  key0=%s  keyLast=%s" % [pth, str(v0), str(v1)])
					shown += 1
				elif typ == Animation.TYPE_ROTATION_3D and pth.contains("hips"):
					var q0: Quaternion = an.track_get_key_value(t, 0)
					print("    ROT %s  key0=%s" % [pth, str(q0)])
					shown += 1
				if shown >= 6:
					break
	cat.free()

	print("")
	print("=== SECTION 3: UAL 动画轨道路径样式 + 位置轨道取值 ===")
	var ual: Node = (load(UAL) as PackedScene).instantiate()
	var uaps: Array = []
	_collect_aps(ual, uaps)
	for ap2 in uaps:
		var p2: AnimationPlayer = ap2
		print("  UAL AnimationPlayer 路径(未入树时用相对) root_node=%s" % str(p2.root_node))
		for an_name in ["Idle", "Walk", "Pistol_Shoot"]:
			if not p2.has_animation(an_name):
				continue
			var an2: Animation = p2.get_animation(an_name)
			print("  --- %s (len=%.2f tracks=%d) ---" % [an_name, an2.length, an2.get_track_count()])
			var shown2 := 0
			for t in range(an2.get_track_count()):
				var pth := String(an2.track_get_path(t))
				var typ := an2.track_get_type(t)
				if typ == Animation.TYPE_POSITION_3D and (pth.contains("DEF-hips") or pth.contains(":root")):
					var v0: Vector3 = an2.track_get_key_value(t, 0)
					var v1: Vector3 = an2.track_get_key_value(t, mini(1, an2.track_get_key_count(t) - 1))
					print("    POS %s  key0=%s  key1=%s" % [pth, str(v0), str(v1)])
					shown2 += 1
				elif typ == Animation.TYPE_ROTATION_3D and pth.contains("DEF-hips"):
					var q0: Quaternion = an2.track_get_key_value(t, 0)
					print("    ROT %s key0=%s" % [pth, str(q0)])
					shown2 += 1
				if shown2 >= 6:
					break
			# 打印前 6 条轨道路径原文，看清完整格式
			print("    [前6条轨道路径]")
			for t in range(mini(6, an2.get_track_count())):
				print("      t%d type=%d path=%s" % [t, an2.track_get_type(t), an2.track_get_path(t)])
	ual.free()
	quit(0)

func _dump(n: Node, path: NodePath, depth: int) -> void:
	var np := NodePath(String(path).path_join(String(n.name)))
	var extra := ""
	if n is Skeleton3D:
		extra = "  [Skeleton3D bones=%d]" % (n as Skeleton3D).get_bone_count()
	elif n is AnimationPlayer:
		extra = "  [AnimationPlayer anims=%d]" % (n as AnimationPlayer).get_animation_list().size()
	elif n is MeshInstance3D:
		extra = "  [MeshInstance3D]"
	print("%s%s (%s)%s" % ["  ".repeat(depth), np, n.get_class(), extra])
	for c in n.get_children():
		_dump(c, np, depth + 1)

func _collect_aps(n: Node, out: Array) -> void:
	if n is AnimationPlayer:
		out.append(n)
	for c in n.get_children():
		_collect_aps(c, out)
