extends SceneTree
## 一次性探针：把「cat 自带剪辑到底是不是退化的」「_build_state_clips 会选中哪些剪辑」
## 「AnimationPlayer 里的 loop 设置」这三件事**量化**出来。
##
## ⚠ 为什么能在 headless 做：`Animation.length` / `loop_mode` / 轨道 key 都是纯数据，
##   直接读即可（不需要 seek —— seek 在 headless 不更新骨骼，那是另一回事，见 ual_locomotion.gd 文件头）。
##
## 运行：godot --headless --path . -s res://tools/probe_tpose.gd

const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"

## 与 MikuModel 的导出默认值逐字一致（不可改测试，只能照抄）
const IDLE_KEYS := ["idle", "stand", "wait"]
const WALK_KEYS := ["walk", "move"]
const RUN_KEYS := ["run", "sprint"]
const JUMP_KEYS := ["jump", "fall", "air"]


func _initialize() -> void:
	var packed := load(CAT_MODEL) as PackedScene
	if packed == null:
		print("FATAL: 模型加载失败")
		quit(1)
		return
	var inst := packed.instantiate()
	root.add_child(inst)
	var ap := _find_ap(inst)
	var sk := _find_skel(inst)
	print("== cat 资产 ==")
	print("AnimationPlayer: %s" % ("有" if ap != null else "无"))
	print("Skeleton3D: %s（骨数 %d）" % ["有" if sk != null else "无",
		sk.get_bone_count() if sk != null else -1])
	if ap == null:
		quit(1)
		return

	print("\n== 全部剪辑（name / length / loop_mode / 轨道数） ==")
	var names: Array[String] = []
	for n in ap.get_animation_list():
		names.append(String(n))
	names.sort()
	for n in names:
		var a := ap.get_animation(n)
		print("  %-28s len=%6.3f  loop=%d  tracks=%d" % [n, a.length, int(a.loop_mode), a.get_track_count()])

	print("\n== _build_state_clips 会选中谁（照抄 MikuModel 的 _match_clip 语义） ==")
	print("  idle  <- '%s'" % _match(names, IDLE_KEYS))
	print("  walk  <- '%s'" % _match(names, WALK_KEYS))
	print("  run   <- '%s'" % _match(names, RUN_KEYS))
	print("  jump  <- '%s'" % _match(names, JUMP_KEYS))

	print("\n== 退化判据实测：每个剪辑的「自身变化量」 ==")
	print("   （位置轨道 key 之间的最大 L2 差/ 旋转轨道 key 之间的最大夹角）")
	for n in names:
		_report_clip_motion(ap.get_animation(n))

	print("\n== MikuIdleMotion 是否索引骨骼（源码级事实） ==")
	var src := FileAccess.get_file_as_string("res://scripts/entities/miku_idle_motion.gd")
	var code := ""
	for raw in src.split("\n"):
		var i := raw.find("#")
		code += (raw if i < 0 else raw.substr(0, i)) + "\n"
	print("  find_bone   出现次数 = %d" % code.count("find_bone"))
	print("  get_bone    出现次数 = %d" % code.count("get_bone"))
	print("  set_bone    出现次数 = %d" % code.count("set_bone"))
	print("  Skeleton3D  出现次数 = %d" % code.count("Skeleton3D"))
	quit(0)


## 一个剪辑的「自身变化量」：同一条轨道上，任意两个 key 的最大差（位置 L2 / 角度 deg）
## 这就是「播完等于没播」的量化。
func _report_clip_motion(a: Animation) -> void:
	if a == null:
		return
	var max_pos := 0.0
	var max_rot_deg := 0.0
	var moving_tracks := 0
	var pos_tracks := 0
	var rot_tracks := 0
	var bones: Array[String] = []
	for track in a.get_track_count():
		var ttype := a.track_get_type(track)
		if ttype == Animation.TYPE_POSITION_3D:
			pos_tracks += 1
		elif ttype == Animation.TYPE_ROTATION_3D:
			rot_tracks += 1
		else:
			continue
		var path := a.track_get_path(track)
		if String(path).contains("Skeleton3D"):
			bones.append(String(path.get_subname(path.get_subname_count() - 1)))
		var keys := a.track_get_key_count(track)
		if keys < 2:
			continue
		var has_motion := false
		for k in keys:
			for j in range(k + 1, keys):
				var ka: Variant = a.track_get_key_value(track, k)
				var kb: Variant = a.track_get_key_value(track, j)
				if ttype == Animation.TYPE_POSITION_3D:
					var d := (Vector3(ka) - Vector3(kb)).length()
					max_pos = maxf(max_pos, d)
					if d > 1e-6:
						has_motion = true
				else:
					var ang := rad_to_deg(Quaternion(ka).angle_to(Quaternion(kb)))
					max_rot_deg = maxf(max_rot_deg, ang)
					if ang > 0.05:
						has_motion = true
		if has_motion:
			moving_tracks += 1
	print("  %-28s len=%6.3f loop=%d 位置轨道=%3d 旋转轨道=%3d **会动的轨道=%3d** 最大位移=%.6f 最大夹角=%.3f° %s" % [
		a.resource_name, a.length, int(a.loop_mode), pos_tracks, rot_tracks, moving_tracks,
		max_pos, max_rot_deg, "<=【退化】" if moving_tracks == 0 else ""])


func _match(names: Array[String], keys: Array) -> String:
	for key in keys:
		var lk := String(key).to_lower()
		for n in names:
			if n.to_lower().contains(lk):
				return n
	return ""


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