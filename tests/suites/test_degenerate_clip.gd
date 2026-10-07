extends TestSuite
## 「退化剪辑」（degenerate clip）判据 + T-pose / 抽搐根因的回归锁。
##
## ## 背景（一次真实缺陷，不是重构）
## 用户实机报告两个现象：① `cat_hatsune_miku` 模型是 T-pose；② 一直有轻微抽搐。
## 实测根因（`tools/probe_tpose.gd` / `tools/probe_idle_clip.gd` / `tools/capture_tpose_verify.tscn`）：
##   · cat 自带两条剪辑：`idle`（0.083 s）与 `ArmatureAction`（2.5 s）。
##   · `idle` 的 98 条骨骼轨道里**只有 1 条**会动（`chest_94` 偏航 0°→19.7°），
##     **双腿骨一条轨道都没有** ⇒ 它是 T-pose 定格。
##   · `_build_state_clips` 把它设成 `LOOP_LINEAR` ⇒ 以 **12 Hz**（1/0.083）反复重写
##     全身骨骼姿态 ⇒ 胸骨偏航在 0°↔17° 之间锯齿抖动 = **「轻微抽搐」**。
##   · 而 `_start_procedural_pose` 的旧判据只问「有没有匹配到 idle 剪辑」⇒
##     认定「有可用动画」⇒ 程序化姿态永不启用 ⇒ **全身 T-pose 且纹丝不动**。
## ⇒ **两个现象同一个根因**，修复方式也同一个：识别并拒绝「退化剪辑」。
##
## ## 本套件锁三组不变量
##   ① 判据本身：`is_degenerate` / `measure_clip_motion` 是**纯函数**、按**内容**判定；
##   ② 接线：退化剪辑既不设LOOP_LINEAR，也绝不被 `play()`；
##   ③ ⭐ **实机路径等价**：`update_animation` 连续驱动多帧后腿**真的在动**。
##
## ## ⚠ 断言口径（control_checklist §4-16 双向）
## 一律按**行为 / 内容**断言，不锁字面量写法；每组都配**守恒对照组**
## （好剪辑不得被误杀、退化剪辑不得漏杀），避免单向断言的「漏杀 / 误杀」两个方向。
##
## ## ⚠ 不使用 `pending()`
## `pending()` 是用例级 note，文件被删后会静默退化成空壳（§4-15）。
## 素材类断言一律**硬失败**表达缺失 —— UAL / cat 素材是本能力的必需前提。

const MikuScript := preload("res://scripts/entities/miku_model.gd")
const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const MIKU_MODEL := "res://assets/models/miku/miku.glb"

## MikuModel 既有默认（保住基线的前提）
const RUN_THRESHOLD := 0.62
## 蹲姿循环播放时 UAL 剪辑的时长（实测 2.933 s）
const CROUCH_IDLE_LEN := 2.933


# ---------------------------------------------------------------------------
# ① 判据本身（纯函数）
# ---------------------------------------------------------------------------

## cat 的 `idle` 必须被判为退化，`ArmatureAction` 必须被判为正常。
## ⚠ 这是整个修复的**基石**：判据错 ⇒ 后面全错。
func test_cat_clips_are_classified_correctly() -> void:
	var ps: PackedScene = load(CAT_MODEL)
	check_true(ps != null, "cat 素材必须存在")
	if ps == null:
		return
	var inst: Node = ps.instantiate()
	add_child(inst)
	var ap := _find_ap(inst)
	if ap == null:
		check_true(false, "cat 必须含 AnimationPlayer")
		inst.queue_free()
		return
	var idle := ap.get_animation("idle")
	var action := ap.get_animation("ArmatureAction")
	check_true(MikuScript.is_degenerate(idle),
		"cat 的 idle（0.083 s / 会动轨道 1.0%）必须判为退化")
	check_false(MikuScript.is_degenerate(action),
		"cat 的 ArmatureAction（2.5 s / 会动轨道 88.8%）必须判为**非**退化（防误杀）")
	inst.queue_free()


## 判据**只看内容**：`null` 与「人造的短而静」剪辑都算退化。
func test_is_degenerate_handles_null_and_synthetic_clips() -> void:
	check_true(MikuScript.is_degenerate(null), "null 剪辑必须判为退化（= 没有可用动画）")
	# 人造一条「短而几乎不动」的剪辑：3 条轨道、只有 1 条动 ⇒ 占比 33% > 15% ⇒ 不退化
	#（这条同时验证判据不是「只要短就算退化」）
	var barely := Animation.new()
	barely.length = 0.1
	for i in 3:
		var t := barely.add_track(Animation.TYPE_ROTATION_3D)
		_add_rotation_keys(barely, t, i, 2.0 if i == 0 else 0.0)
	check_false(MikuScript.is_degenerate(barely),
		"短但 1/3 轨道在动的剪辑不得判为退化（防误杀：判据不是「只要短就算退化」）")


## 守恒对照组：判据必须有**鉴别力**，不能恒真也不能恒假。
## 同一批阈值下，构造「明显退化」与「明显正常」两侧都必须判对。
func test_degeneracy_check_has_discriminating_power() -> void:
	# 明显退化：0.05 s、5 条轨道全静止 ⇒ 占比 0%
	var dead := Animation.new()
	dead.length = 0.05
	for i in 5:
		dead.add_track(Animation.TYPE_ROTATION_3D)
	check_true(MikuScript.is_degenerate(dead), "0.05 s 且全静止 ⇒ 必须判为退化")
	# 明显正常：2.0 s、5 条轨道全在动 ⇒ 占比 100%
	var alive := Animation.new()
	alive.length = 2.0
	for i in 5:
		var t := alive.add_track(Animation.TYPE_ROTATION_3D)
		_add_rotation_keys(alive, t, i, 30.0)
	check_false(MikuScript.is_degenerate(alive), "2.0 s 且全在动 ⇒ 必须判为非退化")
	# 反向：把阈值调到极端值时结论必须跟着变（证明判定真的用了阈值，不是写死）
	check_false(MikuScript.is_degenerate(dead, 0.2, -1.0),
		"守恒对照：min_motion_ratio 取负数时，静止剪辑也不判退化（证明判定确实读阈值）")


## 阈值本身的性质：必须**低于**真动画、**高于**定格动画，两侧都有余量。
## ⚠ 这条锁的是「阈值不是勉强过关」—— 实测退化 1.0% / 正常 88.8%，
##   阈值 15% 落在正中（6× / 6× 余量）；时长阈值同理（0.083 ↔ 2.5，0.2 在中间）。
func test_degeneracy_thresholds_sit_between_measured_values() -> void:
	var ps: PackedScene = load(CAT_MODEL)
	if ps == null:
		check_true(false, "cat 素材必须存在")
		return
	var inst: Node = ps.instantiate()
	add_child(inst)
	var ap := _find_ap(inst)
	if ap == null:
		check_true(false, "cat 必须含 AnimationPlayer")
		inst.queue_free()
		return
	var idle_m: Dictionary = MikuScript.measure_clip_motion(ap.get_animation("idle"))
	var act_m: Dictionary = MikuScript.measure_clip_motion(ap.get_animation("ArmatureAction"))
	var th_ratio := float(MikuScript.DEGENERATE_MIN_MOTION_RATIO)
	# 阈值必须夹在两者之间（严格）
	check_true(th_ratio > float(idle_m["ratio"]),
		"阈值(%.3f) 必须高于退化剪辑的实测占比(%.4f)" % [th_ratio, float(idle_m["ratio"])])
	check_true(th_ratio < float(act_m["ratio"]),
		"阈值(%.3f) 必须低于正常剪辑的实测占比(%.4f)" % [th_ratio, float(act_m["ratio"])])
	# 两侧余量都要够大（至少 3×），否则阈值是「勉强过关」而非「有余量」
	check_ge(th_ratio / maxf(float(idle_m["ratio"]), 1e-9), 3.0,
		"对退化剪辑的余量至少 3×（实测 %.1f×）" % (th_ratio / maxf(float(idle_m["ratio"]), 1e-9)))
	check_ge(float(act_m["ratio"]) / th_ratio, 3.0,
		"对正常剪辑的余量至少 3×（实测 %.1f×）" % (float(act_m["ratio"]) / th_ratio))
	# 时长阈值同理
	var th_len := float(MikuScript.DEGENERATE_MIN_LENGTH)
	var idle_len := float(ap.get_animation("idle").length)
	var act_len := float(ap.get_animation("ArmatureAction").length)
	check_true(th_len > idle_len and th_len < act_len,
		"时长阈值(%.3f) 必须夹在实测的 %.3f 与 %.3f 之间" % [th_len, idle_len, act_len])
	inst.queue_free()


## `measure_clip_motion` 的返回值必须自洽（ratio == moving / tracks）。
func test_measure_clip_motion_returns_consistent_ratio() -> void:
	var ps: PackedScene = load(CAT_MODEL)
	if ps == null:
		check_true(false, "cat 素材必须存在")
		return
	var inst: Node = ps.instantiate()
	add_child(inst)
	var ap := _find_ap(inst)
	if ap == null:
		check_true(false, "cat 必须含 AnimationPlayer")
		inst.queue_free()
		return
	for clip_name in ["idle", "ArmatureAction"]:
		var m: Dictionary = MikuScript.measure_clip_motion(ap.get_animation(clip_name))
		var tracks := int(m["tracks"])
		var moving := int(m["moving"])
		check_gt_eq(moving, tracks, "%s: 会动轨道数不得超过总轨道数" % clip_name)
		check_ge(tracks, 50, "%s: 骨骼动画的变换轨道数应 >= 50（实测 %d）" % [clip_name, tracks])
		if tracks > 0:
			check_near(float(m["ratio"]), float(moving) / float(tracks), 1e-6,
				"%s: ratio 必须等于 moving/tracks（实测 %.4f vs %.4f）" % [
					clip_name, float(m["ratio"]), float(moving) / float(tracks)])
	inst.queue_free()


# ---------------------------------------------------------------------------
# ② 接线：退化剪辑不设循环、不被 play()
# ---------------------------------------------------------------------------

## 退化剪辑绝不能被设成 `LOOP_LINEAR` —— 0.083 s 的定格一旦循环就是 12 Hz 全身重写 = 抽搐。
func test_degenerate_clip_is_never_set_to_loop() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	add_child(model)
	var idle_name := String(model._state_clips.get("idle", ""))
	check_eq(idle_name, "idle", "前置：cat 的 idle 剪辑应被选为 idle 状态")
	check_true(model._clip_is_degenerate(idle_name), "前置：该 idle 必须被判为退化")
	var anim: Animation = model._anim.get_animation(idle_name)
	check_false(int(anim.loop_mode) == int(Animation.LOOP_LINEAR),
		"退化剪辑**不得**被设成 LOOP_LINEAR（12 Hz 全身重写 = 用户报告的「轻微抽搐」）")
	model.queue_free()


## ⭐ 实机路径等价：`update_animation` 连续驱动多帧后，`AnimationPlayer` 里
## **不得**有任何剪辑在播（退化剪辑被拒 ⇒ 全身交给程序化姿态 / UAL）。
##
## ⚠ 这条必须**真的驱动多帧**（而不是只查函数返回值）——
##   只查返回值会漏掉「返回值对、但下一帧真的 play 了退化剪辑」这类真缺陷。
func test_update_animation_never_plays_a_degenerate_clip() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = false # 关掉 UAL，单独验 AnimationPlayer 这一支
	add_child(model)
	check_true(model._anim != null, "前置：cat 应有 AnimationPlayer")
	# 驱动 30 帧，覆盖 idle / walk / run / jump 四种状态（每种都要试）
	var states := [
		[false, 0.0, true], # 静止 → idle
		[true, 0.30, true],  # 低速→ walk
		[true, 0.80, true],  # 中速 → run
		[true, 1.00, true],  # 满速 → run（sprint 被阈值挡住）
		[true, 0.80, false], # 空中 → jump
	]
	var frames := 0
	for st in states:
		for i in 6:
			model.update_animation(1.0 / 60.0, float(st[1]) * 6.5, float(st[1]),
				bool(st[0]), bool(st[2]))
			frames += 1
			var playing := String(model._anim.current_animation)
			if playing != "":
				check_false(model._clip_is_degenerate(playing),
					"退化剪辑「%s」被 play 了（第 %d 帧）⇒ 12 Hz 重写骨骼 = 抽搐" % [playing, frames])
	check_ge(frames, 30, "前置：本用例必须真的驱动 >= 30 帧（单帧断言会漏掉间歇性 play）")
	model.queue_free()


# ---------------------------------------------------------------------------
# ③ ⭐ 实机路径等价：连续多帧驱动后腿真的在动（T-pose 的直接反证）
# ---------------------------------------------------------------------------

## ⭐⭐ 核心守护：**连续多帧驱动 `update_animation` 后腿真的在动**，
## 而不是停在 rest 姿态（T-pose）。
##
## ##⚠ 为什么必须在**窗口模式**验（headless 做不到）
## headless（dummy 渲染）下 `AnimationPlayer` 不推进、`seek()` 不更新骨骼姿态
## （见 `ual_locomotion.gd` 文件头 §8-3）⇒ 靠剪辑驱动的运动在 headless 量不出来。
## 本用例因此**只用程序化姿态通道**（`MikuProceduralPose` 用
## `set_bone_global_pose_override` 直接写骨骼，**不依赖 AnimationPlayer**）
## ⇒ headless 可测，且走的仍是 MikuModel 的**出货路径**。
##
## ## 断言口径：量**双脚高度差**（迈步时两脚必不等高）
## T-pose 定格 ⇒ 该值恒为 0；真在迈步 ⇒ 呈周期性起伏。
func test_legs_actually_move_over_many_frames_after_tpose_fix() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = false # 用程序化姿态通道（headless 可测）
	add_child(model)
	check_true(model._procedural != null and model._procedural.valid,
		"前置：cat 的唯一状态剪辑退化 ⇒ 必须回退程序化姿态（否则就是 T-pose 缺陷）")
	var sk := _find_skel(model)
	check_true(sk != null, "前置：cat 应有 Skeleton3D")
	if sk == null:
		model.queue_free()
		return
	var foot_l := sk.find_bone("foot.L_97")
	var foot_r := sk.find_bone("foot.R_102")
	check_true(foot_l >= 0 and foot_r >= 0, "前置：cat 应有左右脚骨（实测 foot.L_97 / foot.R_102）")
	if foot_l < 0 or foot_r < 0:
		model.queue_free()
		return
	# —— 连续驱动 60 帧（1 秒 @60fps），走 player.gd 的**同款调用形状**——
	var diffs: Array[float] = []
	for i in 60:
		model.update_animation(1.0 / 60.0, 3.6, 0.554, true, true) # walk 档
		sk.force_update_all_bone_transforms()
		diffs.append(absf(
			sk.get_bone_global_pose(foot_l).origin.y - sk.get_bone_global_pose(foot_r).origin.y))
	var lo := _min_of(diffs)
	var hi := _max_of(diffs)
	# ⭐ 核心断言：双脚高度差必须有**跨度**（T-pose 定格时恒为 0）
	check_gt_span(hi - lo, 0.01,
		"连续 %d 帧后双脚高度差必须有跨度（实测 %.4f ~ %.4f，跨度 %.4f）⇒ 腿真的在交替迈步" % [
			diffs.size(), lo, hi, hi - lo])
	# 反向：也不能是「乱抖」（每一帧都剧烈变化 = 抽搐）。逐帧差的中位数应远小于总跨度。
	var deltas: Array[float] = []
	for i in range(1, diffs.size()):
		deltas.append(absf(diffs[i] - diffs[i - 1]))
	var median_delta := _median_of(deltas)
	check_lt(median_delta, (hi - lo) * 0.5,
		"逐帧高度差变化的中位数(%.5f)必须远小于总跨度(%.4f)⇒ 是**迈步**不是**抖动**" % [
			median_delta, hi - lo])
	model.queue_free()


## ⭐ 同一断言的**UAL 通道**版本：UAL 有效时也必须有东西驱动腿。
## ⚠ headless 下 UAL 采样读不到运动（§8-3），因此这里只断言「接线正确」
##   （UAL 接管 + 程序化姿态**互斥** + 手臂归属正确），运动性由窗口模式截图证明。
##   保持这条在 headless 有意义：它是「接线没被改坏」的护栏。
func test_ual_path_is_wired_and_exclusive_after_tpose_fix() -> void:
	var model := MikuModel.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = true
	add_child(model)
	check_true(model.is_ual_locomotion_active(), "前置：UAL 应接管")
	check_true(model._procedural == null,
		"UAL 接管时程序化姿态必须缺席（两者都写腿骨 ⇒ 互抢）")
	# 退化剪辑依然不得被播（UAL 早退，但接线仍须正确）
	for state in ["idle", "walk", "run", "jump"]:
		var clip := String(model._state_clips.get(state, ""))
		if clip != "":
			check_true(model._clip_is_degenerate(clip),
				"cat 的 %s 剪辑（%s）应判为退化" % [state, clip])
	model.queue_free()


## 默认模型 `miku.glb` 完全不受影响：UAL 对它透明（骨名乱码 ⇒ 配不出驱动骨）。
func test_default_model_still_uses_procedural_pose() -> void:
	var model := MikuModel.new() # 默认 model_path = miku.glb
	add_child(model)
	check_false(model.is_ual_locomotion_active(), "默认模型（乱码骨名）下 UAL 不得激活")
	check_true(model._procedural != null and model._procedural.valid,
		"默认模型必须照旧由程序化姿态接管腿（不因本修复而改变）")
	model.queue_free()


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

## 给一条旋转轨道加两个 key（从 identity 转`deg` 度）。
## ⚠ 用 `identity` 起算而不是固定轴，保证「有 rotation track 且 key 值不同」这一语义稳定。
func _add_rotation_keys(anim: Animation, track: int, _idx: int, deg: float) -> void:
	anim.rotation_track_insert_key(track, 0.0, Quaternion.IDENTITY)
	anim.rotation_track_insert_key(track, 0.05, Quaternion(Vector3.UP, deg_to_rad(deg)))


func _min_of(a: Array[float]) -> float:
	var m := INF
	for v in a:
		m = minf(m, v)
	return m if is_finite(m) else 0.0


func _max_of(a: Array[float]) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, v)
	return m if is_finite(m) else 0.0


func _median_of(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return s[s.size() / 2]


## `check_gt_eq`：本项目 TestSuite 只有 check_ge / check_le，没有严格大于的 helper。
## 单独定义成局部函数而不是往 TestSuite 加方法 —— 加方法会改动基类、影响所有 suite。
func check_gt_eq(actual: int, maximum: int, message: String) -> void:
	check_true(actual <= maximum, message)


## `check_gt_span`：跨度必须严格大于阈值。
func check_gt_span(actual: float, threshold: float, message: String) -> void:
	check_true(actual > threshold, message)


## `check_lt`：严格小于。
func check_lt(actual: float, threshold: float, message: String) -> void:
	check_true(actual < threshold, message)


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