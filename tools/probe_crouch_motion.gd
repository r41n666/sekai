extends SceneTree
## 探针：UAL 蹲姿剪辑的**首尾闭合度**与**腿幅度**，用来决定「蹲下移动」怎么配。
const UAL := "res://assets/animations/ual/AnimationLibrary_Godot_Standard.glb"
const LegBONES := ["DEF-thigh.L","DEF-shin.L","DEF-foot.L","DEF-thigh.R","DEF-shin.R","DEF-foot.R",
	"DEF-hips","DEF-spine.001","DEF-spine.002","DEF-neck"]
func _initialize() -> void:
	var inst := (load(UAL) as PackedScene).instantiate()
	root.add_child(inst)
	var ap := _find_ap(inst)
	for clip in ["Idle","Crouch_Idle","Crouch_Fwd","Walk","Jog_Fwd","Sprint"]:
		var a := ap.get_animation(clip)
		var tracks := 0; var moving := 0; var maxpos := 0.0; var maxdeg := 0.0
		var leg_moving := 0; var leg_total := 0; var leg_deg := 0.0
		for t in a.get_track_count():
			var tt := a.track_get_type(t)
			if tt != Animation.TYPE_POSITION_3D and tt != Animation.TYPE_ROTATION_3D: continue
			tracks += 1
			var path := a.track_get_path(t)
			var bn := ""
			if path.get_subname_count() > 0:
				bn = String(path.get_subname(path.get_subname_count()-1))
			var is_leg := bn in LegBONES
			if is_leg: leg_total += 1
			var keys := a.track_get_key_count(t)
			if keys < 2: continue
			var hm := false; var hleg := false; var tdeg := 0.0
			for k in keys:
				for j in range(k+1, keys):
					var ka: Variant = a.track_get_key_value(t,k)
					var kb: Variant = a.track_get_key_value(t,j)
					var d := 0.0
					if tt == Animation.TYPE_ROTATION_3D:
						d = rad_to_deg(Quaternion(ka).angle_to(Quaternion(kb)))
						maxdeg = maxf(maxdeg, d); tdeg = maxf(tdeg, d)
						if d > 0.05: hm = true
					else:
						d = (Vector3(ka)-Vector3(kb)).length()
						maxpos = maxf(maxpos, d)
						if d > 1e-6: hm = true
			if hm: moving += 1
			if is_leg and hm: leg_moving += 1
			if is_leg: leg_deg = maxf(leg_deg, tdeg)
		print("%-12s len=%5.3f loop=%d | 全轨迹 %d 动 %d (%.0f%%) 位置max=%.4f 角度max=%.1f° | 腿 动%d/%d 腿角max=%.1f°" % [
			clip, a.length, int(a.loop_mode), tracks, moving, 100.0*float(moving)/maxf(tracks,1), maxpos, maxdeg,
			leg_moving, leg_total, leg_deg])
	quit(0)
func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer: return n
	for c in n.get_children():
		var f := _find_ap(c)
		if f != null: return f
	return null
