extends TestSuite
## 战斗动作（开火 / 受击 / 死亡 / 换弹）回归基线
##
## 背景：本项目**没有任何外部动画素材可用**（18 个模型合计只有 4 条剪辑、只有 1 个模型
## 匹配到行走剪辑，默认模型 `miku.glb` 是 0 剪辑 + 554 骨骼），因此战斗动作全部
## 由`MikuProceduralPose` 的**程序化 overlay** 实现，状态机 / 包络 / 叠加量换算在
## `MikuCombatAnim`（纯逻辑，可headless 逐值断言）。
##
## 本suite 锁四组不变量：
##   ① **alpha 包络**：四个动作都自alpha=1 起、随时间衰减到 0（死亡是唯一「渐入并保持」，
##      因为它要表现「倒下去的过程」且**不可逆**）；进度越界 /负 delta 不得越界。
##   ② **死亡不可逆**：死亡后其它动作一律被拒，`reset()` 才恢复；死亡是唯一接管整个身体的动作。
##   ③ **叠加而非硬切**：叠加量按 alpha 线性缩放、各通道相加，且开火 / 受击 / 换弹
##     **不含任何位置通道**（后坐力位移归 `RecoilSystem` 管摄像机，角色侧只做上肢）。
##   ④ **安全降级 + 接线口径**：`valid=false` 时所有动作静默跳过；联机下动作**不走 RPC**，
##     且射手端**不得**按 `_display_health` 播死亡（那是显示副本，不是血量真值，§4-9）。
##
## 断言口径（§4-16弱断言双向）：
##   包络类断言一律按**语义**写（单调性/ 端点值 / 越界安全），不写死字面量；
##   方向上既锁「漏杀」（如把 DEATH 包络改成衰减）也交给 `tools/mutation_combat_anim.py`
##   的**守恒对照组**验证「不误杀」（如等价改写成 `1.0 - u` 仍须全绿）。

const COMBAT_ANIM_SRC := "res://scripts/entities/miku_combat_anim.gd"
const POSE_SRC := "res://scripts/entities/miku_procedural_pose.gd"
const MIKU_MODEL_SRC := "res://scripts/entities/miku_model.gd"
const WEAPON_SRC := "res://scripts/shooting/weapon.gd"
const BOT_SRC := "res://scripts/entities/bot.gd"
const PLAYER_SRC := "res://scripts/player.gd"


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## 剥掉行尾注释，只保留 `#` 之前的代码部分（§4-13(a) / §4-16）。
## ⚠ 不能「有 `#` 就整行丢」——那会把 `xxx(true) # 注释` 的代码也丢掉。
func _strip_comment(line: String) -> String:
	var i := line.find("#")
	if i < 0:
		return line
	return line.substr(0, i)


## 返回第一条（已剥注释的）含 `token` 的单行代码；找不到返回 ""。
func _line_with(src: String, token: String) -> String:
	for raw in src.split("\n"):
		var code := _strip_comment(raw)
		if code.find(token) >= 0:
			return code
	return ""


## 在 [0,1] 上采样包络，返回是否**单调不增**（衰减包络的语义）。
## ⚠ 这里刻意**不**写死「必须是 pow(1-u, 2.0)」这类实现细节：
##   任何满足「起于 1、终于 0、单调不增」的包络都是合法实现（本项目换弹用的就是
##   平台 + smoothstep 形状，同样单调不增）→ 这样断言才不会被等价改写误杀（守恒）。
static func _envelope_is_monotonic(action: int, increasing: bool = false, samples: int = 48) -> bool:
	# ⚠ 初值必须取 u=0 处的真实值，不能用 INF：
	#   「单调不减」的首个样本必然 <= INF，会被误判为下降（实测踩过）。
	var previous := MikuCombatAnim.envelope(action, 0.0)
	for i in range(1, samples + 1):
		var u := float(i) / float(samples)
		var value := MikuCombatAnim.envelope(action, u)
		if increasing:
			if value < previous - 0.0001:
				return false
		elif value > previous + 0.0001:
			return false
		previous = value
	return true


# ---------------------------------------------------------------------------
# ① alpha 包络
# ---------------------------------------------------------------------------

## 四个动作的时长必须符合规格（开火/受击短促、换弹中等）。
## 这是「动作节奏」的产品契约：开火再慢就不同步枪声，换弹再快就抓不住弹匣。
func test_action_durations_match_spec() -> void:
	check_near(MikuCombatAnim.duration_of(MikuCombatAnim.Action.FIRE), 0.12, 0.001,
		"开火约 0.12 s（短促）")
	check_near(MikuCombatAnim.duration_of(MikuCombatAnim.Action.HIT), 0.18, 0.001,
		"受击约 0.18 s（短促，但比开火长一点，要看得见）")
	check_near(MikuCombatAnim.duration_of(MikuCombatAnim.Action.RELOAD), 1.2, 0.01,
		"换弹约 1.2 s（中等时长）")
	check_true(MikuCombatAnim.duration_of(MikuCombatAnim.Action.DEATH) > 0.0,
		"死亡必须有正的倒地过渡时长")
	check_near(MikuCombatAnim.duration_of(MikuCombatAnim.Action.NONE), 0.0, 0.0001,
		"无动作的时长应为 0")


## 除死亡外的每个动作：包络**起于 1、终于 0**（alpha=1 起、随时间衰减）。
## 死亡单独在下一条用例里锁（它是渐入并保持）。
func test_transient_actions_start_at_one_and_end_at_zero() -> void:
	for action in [MikuCombatAnim.Action.FIRE, MikuCombatAnim.Action.HIT,
			MikuCombatAnim.Action.RELOAD]:
		check_near(MikuCombatAnim.envelope(action, 0.0), 1.0, 0.0001,
			"%s 的包络必须起于 1" % MikuCombatAnim.new().active_name())
		check_near(MikuCombatAnim.envelope(action, 1.0), 0.0, 0.0001,
			"%s 的包络必须终于 0" % MikuCombatAnim.new().active_name())


## 三个瞬时动作的包络必须**单调不增**——这才是「随时间衰减」的语义。
## ⚠ 不锁具体曲线形状（pow / 平台 / smoothstep 都合法）→ 避免误杀等价改写。
## ⚠ 死亡**不在此列**：它是「渐入并保持」（见下一条），方向相反。
func test_transient_envelopes_are_monotonically_non_increasing() -> void:
	for action in [MikuCombatAnim.Action.FIRE, MikuCombatAnim.Action.HIT,
			MikuCombatAnim.Action.RELOAD]:
		check_true(_envelope_is_monotonic(action),
			"动作 %d 的包络必须单调不增（alpha 只能随时间衰减，不能先扬后抑）" % action)


## 死亡的包络必须**单调不减**（渐入并保持）：倒地是「逐渐倒下去」，不是「先弹一下再倒」。
## ⚠ 方向与上面三个相反，因此单独锁——把死亡错写成衰减包络正是本条要拦的缺陷。
func test_death_envelope_is_monotonically_non_decreasing() -> void:
	check_true(_envelope_is_monotonic(MikuCombatAnim.Action.DEATH, true),
		"死亡包络必须单调不减（渐入并保持，不能先扬后抑）")


## 死亡是唯一「渐入并保持」的动作：起于 0、终于 1。
## ⚠ 方向很关键：若有人把死亡也写成衰减包络（起于 1），倒地动画会变成「先弹一下再倒」。
func test_death_envelope_ramps_up_and_holds() -> void:
	check_near(MikuCombatAnim.envelope(MikuCombatAnim.Action.DEATH, 0.0), 0.0, 0.0001,
		"死亡包络应起于 0（还没开始倒）")
	check_near(MikuCombatAnim.envelope(MikuCombatAnim.Action.DEATH, 1.0), 1.0, 0.0001,
		"死亡包络应终于 1（完全倒地并保持）")


## 换弹必须有**保持段**：手在前70% 一直搭在弹匣上（alpha 保持满强度），最后30% 才收回。
## ⚠ 这条与「起于 1 / 单调不增」是**不同**的语义：
##   去掉保持段（`1 - smoothstep(0,1,t)`）后，包络仍然起于 1、终于 0、仍然单调不增——
##   三条弱断言**照样全绿**，但换弹动画会变成「手立刻离开弹匣又慢慢回来」。
##   故必须单独锁「保持段确实存在」。
func test_reload_holds_full_strength_during_plateau() -> void:
	#保持段内（取 10% / 30% / 60% 三个点）都应仍是满强度
	for u in [0.1, 0.3, 0.6]:
		check_near(MikuCombatAnim.envelope(MikuCombatAnim.Action.RELOAD, u), 1.0, 0.0001,
			"换弹在 u=%.1f（保持段内）应仍为满强度 1（手一直搭在弹匣上）" % u)
	# 保持段之后必须真的开始收回（否则动作永远不结束）
	check_true(MikuCombatAnim.envelope(MikuCombatAnim.Action.RELOAD, 0.9) < 1.0,
		"换弹在 u=0.9（收回段）应已开始衰减")


## 死亡的**内部计时**必须有界：`elapsed()` 不得超过倒地过渡时长。
## ⚠ 上一条「进度封顶」用 progress() 断言，而 progress() 自身带clamp——
##   所以「advance 里不再封顶 _elapsed」这个变异体**照样全绿**（progress 仍被夹到 1）。
##   真正的差别在 elapsed()：不封顶时它会随时间无限增长（浮点精度丢失 / 难以断言）。
func test_death_elapsed_is_bounded() -> void:
	var anim := MikuCombatAnim.new()
	anim.trigger(MikuCombatAnim.Action.DEATH)
	for i in 100:
		anim.advance(MikuCombatAnim.DEATH_FALL_TIME * 0.5)
	check_le(anim.elapsed(), MikuCombatAnim.DEATH_FALL_TIME + 0.0001,
		"死亡后elapsed() 必须封顶在倒地时长（不得无限增长）")


## 无动作时包络恒为 0（不能让残留的动作在idle 里继续影响骨骼）。
func test_none_action_envelope_is_zero() -> void:
	check_near(MikuCombatAnim.envelope(MikuCombatAnim.Action.NONE, 0.0), 0.0, 0.0001,
		"无动作的包络恒为 0")
	check_near(MikuCombatAnim.envelope(MikuCombatAnim.Action.NONE, 0.5), 0.0, 0.0001,
		"无动作的包络恒为 0（中段也是）")


## 进度越界必须被 clamp：u<0 / u>1 都不得产生负强度或 >1 强度。
## ⚠ 这条守的是「负 delta / 超时 delta」不会把骨骼旋转推到荒谬角度。
func test_envelope_clamps_out_of_range_progress() -> void:
	for action in [MikuCombatAnim.Action.FIRE, MikuCombatAnim.Action.HIT,
			MikuCombatAnim.Action.RELOAD]:
		check_true(MikuCombatAnim.envelope(action, -5.0) >= 0.0,
			"负进度不得产生负强度（动作 %d）" % action)
		check_true(MikuCombatAnim.envelope(action, 9.0) <= 1.0,
			"超界进度不得产生 >1 强度（动作 %d）" % action)
		# clamp 后应与端点完全一致
		check_near(MikuCombatAnim.envelope(action, -5.0),
			MikuCombatAnim.envelope(action, 0.0), 0.0001,
			"负进度应被 clamp 到 0（动作 %d）" % action)
		check_near(MikuCombatAnim.envelope(action, 9.0),
			MikuCombatAnim.envelope(action, 1.0), 0.0001,
			"超界进度应被 clamp 到 1（动作 %d）" % action)


## 实例层的包络：刚触发时 alpha=1，走完时长后 alpha=0 且动作自动结束。
func test_instance_alpha_starts_at_one_and_ends_when_time_is_up() -> void:
	var anim := MikuCombatAnim.new()
	check_near(anim.alpha(), 0.0, 0.0001, "未触发时 alpha=0")
	anim.trigger(MikuCombatAnim.Action.FIRE)
	check_near(anim.alpha(), 1.0, 0.0001, "刚触发开火时 alpha=1（与枪声同帧）")
	anim.advance(MikuCombatAnim.FIRE_DURATION)
	check_false(anim.is_active(), "走完时长后开火动作应自动结束")
	check_near(anim.alpha(), 0.0, 0.0001, "动作结束后 alpha 回到 0（融回步态）")


## 负delta 不得让alpha 倒退或越界（`advance` 必须是 no-op）。
func test_negative_delta_does_not_regress_alpha() -> void:
	var anim := MikuCombatAnim.new()
	anim.trigger(MikuCombatAnim.Action.HIT)
	anim.advance(0.05)
	var before := anim.alpha()
	anim.advance(-1.0)
	check_near(anim.alpha(), before, 0.0001, "负 delta 不得让 alpha 倒退")
	check_true(anim.alpha() >= 0.0 and anim.alpha() <= 1.0,
		"alpha 必须恒在 [0,1] 内")


# ---------------------------------------------------------------------------
# ② 死亡不可逆
# ---------------------------------------------------------------------------

## 死亡后 fire / hit / reload 一律被拒（死亡是唯一不可逆动作）。
func test_death_blocks_all_other_actions() -> void:
	var anim := MikuCombatAnim.new()
	anim.trigger(MikuCombatAnim.Action.DEATH)
	check_true(anim.is_dead(), "触发死亡后 is_dead() 必须为 true")
	for action in [MikuCombatAnim.Action.FIRE, MikuCombatAnim.Action.HIT,
			MikuCombatAnim.Action.RELOAD]:
		check_false(anim.trigger(action),
			"死亡后动作 %d 必须被拒（死亡不可逆）" % action)
		check_eq(anim.active_action(), MikuCombatAnim.Action.DEATH,
			"被拒的动作不得改变当前动作（仍是 death）")


## 重复触发死亡是幂等的：接受但不重置进度（否则第二次死亡通知会把倒地动画倒带重播）。
func test_repeated_death_is_idempotent_and_does_not_restart() -> void:
	var anim := MikuCombatAnim.new()
	anim.trigger(MikuCombatAnim.Action.DEATH)
	anim.advance(MikuCombatAnim.DEATH_FALL_TIME * 0.5)
	var mid := anim.progress()
	check_true(anim.trigger(MikuCombatAnim.Action.DEATH), "重复死亡应被接受（幂等）")
	check_near(anim.progress(), mid, 0.0001,
		"重复死亡不得重置进度（否则倒地动画会倒带重播）")


## 死亡后进度封顶在 1.0（不会无限增长），且alpha 稳定在 1。
func test_death_progress_saturates_and_holds() -> void:
	var anim := MikuCombatAnim.new()
	anim.trigger(MikuCombatAnim.Action.DEATH)
	anim.advance(MikuCombatAnim.DEATH_FALL_TIME * 10.0)
	check_near(anim.progress(), 1.0, 0.0001, "死亡进度应封顶在 1.0")
	check_near(anim.alpha(), 1.0, 0.0001, "倒地完成后 alpha 应稳定在 1（保持不动）")
	check_true(anim.is_dead(), "死亡标记应保持（不可逆）")


## reset() 才解除死亡不可逆（重生时由 MikuModel.reset_pose() 调用）。
func test_reset_clears_death_and_all_actions() -> void:
	var anim := MikuCombatAnim.new()
	anim.trigger(MikuCombatAnim.Action.DEATH)
	anim.reset()
	check_false(anim.is_dead(), "reset() 后 is_dead() 必须为 false")
	check_false(anim.is_active(), "reset() 后不应还有活动动作")
	check_near(anim.alpha(), 0.0, 0.0001, "reset() 后 alpha=0")
	check_true(anim.trigger(MikuCombatAnim.Action.FIRE),
		"reset() 后应能重新触发开火（重生后还能开枪）")


## 非死亡动作之间允许互相打断（受击能盖住开火 / 换弹）。
func test_non_death_actions_interrupt_each_other() -> void:
	var anim := MikuCombatAnim.new()
	anim.trigger(MikuCombatAnim.Action.FIRE)
	anim.advance(0.05)
	check_true(anim.trigger(MikuCombatAnim.Action.HIT), "开火途中应能被受击打断")
	check_eq(anim.active_action(), MikuCombatAnim.Action.HIT, "当前动作应变为受击")
	check_near(anim.alpha(), 1.0, 0.0001, "打断后新动作重新从 alpha=1 起")
	check_true(anim.trigger(MikuCombatAnim.Action.RELOAD), "受击途中应能被换弹打断")
	check_eq(anim.active_action(), MikuCombatAnim.Action.RELOAD, "当前动作应变为换弹")


## 触发 NONE 必须被拒（无意义调用不得改变状态）。
func test_triggering_none_is_rejected() -> void:
	var anim := MikuCombatAnim.new()
	check_false(anim.trigger(MikuCombatAnim.Action.NONE), "NONE 不应被接受为动作")
	check_false(anim.is_active(), "被拒的 NONE 不得让状态机进入活动态")


## overlay_alpha：非当前动作恒返回 0（保证「求和所有动作」不会误叠加）。
func test_overlay_alpha_is_zero_for_inactive_actions() -> void:
	var anim := MikuCombatAnim.new()
	anim.trigger(MikuCombatAnim.Action.FIRE)
	check_true(anim.overlay_alpha(MikuCombatAnim.Action.FIRE) > 0.0,
		"当前动作的 overlay_alpha 应 > 0")
	for action in [MikuCombatAnim.Action.HIT, MikuCombatAnim.Action.DEATH,
			MikuCombatAnim.Action.RELOAD, MikuCombatAnim.Action.NONE]:
		check_near(anim.overlay_alpha(action), 0.0, 0.0001,
			"非当前动作 %d 的 overlay_alpha 应为 0" % action)


## 移动速度系数：换弹变慢、死亡为 0、其余为 1。
func test_movement_scale_per_action() -> void:
	var anim := MikuCombatAnim.new()
	check_near(anim.movement_scale(), 1.0, 0.0001, "无动作时移动速度不受影响")
	anim.trigger(MikuCombatAnim.Action.FIRE)
	check_near(anim.movement_scale(), 1.0, 0.0001, "开火时移动速度不受影响")
	anim.trigger(MikuCombatAnim.Action.RELOAD)
	check_true(anim.movement_scale() < 1.0 and anim.movement_scale() > 0.0,
		"换弹期间移动速度应变慢但不该完全定住")
	anim.trigger(MikuCombatAnim.Action.DEATH)
	check_near(anim.movement_scale(), 0.0, 0.0001, "死亡后移动速度为 0（不能走着倒）")


# ---------------------------------------------------------------------------
# ③ 叠加而非硬切 + 通道语义
# ---------------------------------------------------------------------------

## 叠加量字典必须**总是包含全部通道**（未参与的动作一律 0.0）——
## 否则调用方读一个不存在的键会拿到 null 并参与运算，静默出错。
func test_offsets_always_contain_every_channel() -> void:
	for action in [MikuCombatAnim.Action.FIRE, MikuCombatAnim.Action.HIT,
			MikuCombatAnim.Action.DEATH, MikuCombatAnim.Action.RELOAD, MikuCombatAnim.Action.NONE]:
		var off := MikuCombatAnim.combat_offsets(action, 1.0)
		for channel in MikuCombatAnim.CHANNELS:
			check_true(off.has(channel),
				"动作 %d 的叠加量必须包含通道 %s" % [action, channel])
			check_true(off[channel] is float,
				"通道 %s 的值必须是 float（不能是 null）" % channel)


## 叠加量必须按 alpha **线性缩放**（这是「叠加 / 混合」而不是「硬切」的前提）。
func test_offsets_scale_linearly_with_alpha() -> void:
	for action in [MikuCombatAnim.Action.FIRE, MikuCombatAnim.Action.HIT,
			MikuCombatAnim.Action.DEATH, MikuCombatAnim.Action.RELOAD]:
		var full := MikuCombatAnim.combat_offsets(action, 1.0)
		var half := MikuCombatAnim.combat_offsets(action, 0.5)
		var zero := MikuCombatAnim.combat_offsets(action, 0.0)
		for channel in MikuCombatAnim.CHANNELS:
			check_near(float(half[channel]), float(full[channel]) * 0.5, 0.00001,
				"通道 %s 在 alpha=0.5 时应是满强度的一半（线性）" % channel)
			check_near(float(zero[channel]), 0.0, 0.0001,
				"通道 %s 在 alpha=0 时必须为 0（动作完全融回步态）" % channel)


## ⛔ 开火 / 受击 / 换弹**不含任何位置通道**——后坐力位移是 RecoilSystem 对**摄像机**做的，
## 角色侧只做上肢。若有人在这里加`drop`，就会与三层后坐力系统重复表现（角色与镜头双重后坐）。
func test_transient_actions_have_no_position_channel() -> void:
	for action in [MikuCombatAnim.Action.FIRE, MikuCombatAnim.Action.HIT,
			MikuCombatAnim.Action.RELOAD]:
		var off := MikuCombatAnim.combat_offsets(action, 1.0)
		check_near(float(off[MikuCombatAnim.CH_DROP]), 0.0, 0.00001,
			"动作 %d 不得含位置（下沉）量——位移后坐力归 RecoilSystem 管摄像机" % action)


## 开火只动**持械臂 + 躯干**（不得动腿 / 头）。
func test_fire_only_moves_weapon_arm_and_torso() -> void:
	var off := MikuCombatAnim.combat_offsets(MikuCombatAnim.Action.FIRE, 1.0)
	check_true(float(off[MikuCombatAnim.CH_ARM_R_ELBOW]) > 0.0, "开火应弯曲持械肘（手臂收回）")
	check_true(float(off[MikuCombatAnim.CH_ARM_R_SWING]) < 0.0, "开火应使持械臂后坐")
	check_true(float(off[MikuCombatAnim.CH_PITCH]) > 0.0, "开火应使躯干轻微后仰")
	check_near(float(off[MikuCombatAnim.CH_LEG]), 0.0, 0.00001, "开火不应动腿")
	check_near(float(off[MikuCombatAnim.CH_KNEE]), 0.0, 0.00001, "开火不应动膝")
	check_near(float(off[MikuCombatAnim.CH_HEAD]), 0.0, 0.00001, "开火不应动头")
	check_near(float(off[MikuCombatAnim.CH_ARM_L_ELBOW]), 0.0, 0.00001,
		"开火不应动非持械臂的肘")


## 受击动上身 + 头，**不动手臂与腿**（可叠加在行走之上：腿继续走）。
func test_hit_moves_torso_and_head_only() -> void:
	var off := MikuCombatAnim.combat_offsets(MikuCombatAnim.Action.HIT, 1.0)
	check_true(float(off[MikuCombatAnim.CH_PITCH]) > 0.0, "受击应使上身后仰")
	check_true(float(off[MikuCombatAnim.CH_ROLL]) != 0.0, "受击应使上身侧倾")
	check_true(float(off[MikuCombatAnim.CH_HEAD]) > 0.0, "受击应使头微微后")
	check_near(float(off[MikuCombatAnim.CH_LEG]), 0.0, 0.00001,
		"受击不应动腿（被打中时还在跑，步态要继续）")
	check_near(float(off[MikuCombatAnim.CH_ARM_R_ELBOW]), 0.0, 0.00001, "受击不应动肘")
	check_near(float(off[MikuCombatAnim.CH_DROP]), 0.0, 0.00001, "受击不应含位移量")


## 换弹动**左手 + 右臂**，且不含躯干俯仰（换弹时身体不该后仰）。
func test_reload_moves_left_hand_and_right_arm() -> void:
	var off := MikuCombatAnim.combat_offsets(MikuCombatAnim.Action.RELOAD, 1.0)
	check_true(float(off[MikuCombatAnim.CH_ARM_L_DOWN]) > 0.0, "左手应离开护木下垂")
	check_true(float(off[MikuCombatAnim.CH_ARM_L_ELBOW]) > 0.0, "左肘应弯曲（抓弹匣）")
	check_true(float(off[MikuCombatAnim.CH_ARM_R_DOWN]) > 0.0, "右臂应下压")
	check_near(float(off[MikuCombatAnim.CH_PITCH]), 0.0, 0.00001, "换弹不应使躯干后仰")
	check_near(float(off[MikuCombatAnim.CH_LEG]), 0.0, 0.00001, "换弹不应动腿")


## 死亡是唯一**接管整个身体**的动作：同时动躯干 / 头 / 双臂 / 双腿，且是唯一含位移量的。
func test_death_takes_over_the_whole_body() -> void:
	var off := MikuCombatAnim.combat_offsets(MikuCombatAnim.Action.DEATH, 1.0)
	check_true(float(off[MikuCombatAnim.CH_PITCH]) != 0.0, "死亡应使躯干倒向")
	check_true(float(off[MikuCombatAnim.CH_DROP]) < 0.0, "死亡应整体下沉")
	check_true(float(off[MikuCombatAnim.CH_LEG]) != 0.0, "死亡应接管腿部")
	check_true(float(off[MikuCombatAnim.CH_KNEE]) != 0.0, "死亡应接管膝盖")
	check_true(float(off[MikuCombatAnim.CH_ARM_R_DOWN]) != 0.0, "死亡应接管右臂")
	check_true(float(off[MikuCombatAnim.CH_ARM_L_DOWN]) != 0.0, "死亡应接管左臂")


## 负 alpha 不得产生反向旋转（包络只降不升，绝不该「倒放」动作）。
func test_negative_alpha_does_not_invert_offsets() -> void:
	var off := MikuCombatAnim.combat_offsets(MikuCombatAnim.Action.FIRE, -1.0)
	for channel in MikuCombatAnim.CHANNELS:
		check_near(float(off[channel]), 0.0, 0.00001,
			"负 alpha 下通道 %s 应夹到 0（不得反向旋转）" % channel)


## sum_offsets：逐通道求和，且忽略非法输入（不是 Dictionary 就跳过）。
func test_sum_offsets_sums_per_channel_and_tolerates_junk() -> void:
	var a := MikuCombatAnim.combat_offsets(MikuCombatAnim.Action.HIT, 1.0)
	var b := MikuCombatAnim.combat_offsets(MikuCombatAnim.Action.RELOAD, 1.0)
	var total := MikuCombatAnim.sum_offsets([a, b, "不是字典", null])
	check_near(float(total[MikuCombatAnim.CH_PITCH]),
		float(a[MikuCombatAnim.CH_PITCH]), 0.00001,
		"pitch 应等于 HIT 的 pitch（RELOAD 的 pitch 为 0）")
	check_near(float(total[MikuCombatAnim.CH_ARM_L_DOWN]),
		float(a[MikuCombatAnim.CH_ARM_L_DOWN]) + float(b[MikuCombatAnim.CH_ARM_L_DOWN]), 0.00001,
		"通道求和应把两个动作的量加起来")
	check_near(float(total[MikuCombatAnim.CH_HEAD]), float(a[MikuCombatAnim.CH_HEAD]), 0.00001,
		"非法输入项应被跳过而不是崩溃")


## sum_offsets([]) 必须给出全 0 字典（不是空字典）——否则调用方读键会拿到 null。
func test_sum_offsets_of_empty_list_is_all_zero() -> void:
	var total := MikuCombatAnim.sum_offsets([])
	for channel in MikuCombatAnim.CHANNELS:
		check_true(total.has(channel), "空求和也必须包含通道 %s" % channel)
		check_near(float(total[channel]), 0.0, 0.0001, "空求和的通道 %s 应为 0" % channel)


## 求和必须容忍**残缺的字典**：缺通道按 0 处理，而不是把该通道整个丢掉。
## ⚠ 与上一条不同：上一条查的是「结果字典有全部通道」，而本条查的是
##   「**输入**缺某个通道时，结果里那个通道仍然是 0、而不是不存在」。
##   变异测试实测：把 `one.get(channel, 0.0)` 改成「has 就加、否则 continue」后，
##   前者全绿、后者才会转红——两者对 combat_offsets() 的返回值**没有区别**
##   （它总是返回全部通道），区别只在**降级路径**上。
func test_sum_offsets_tolerates_partial_dicts() -> void:
	var partial := {"pitch": 0.5} # 只给一个通道，其余全缺
	var total := MikuCombatAnim.sum_offsets([partial])
	for channel in MikuCombatAnim.CHANNELS:
		check_true(total.has(channel),
			"输入残缺时结果仍必须包含通道 %s（缺输入 ≠ 缺输出）" % channel)
	check_near(float(total[MikuCombatAnim.CH_PITCH]), 0.5, 0.0001,
		"输入给了 pitch=0.5，结果 pitch 应为 0.5")
	for channel in MikuCombatAnim.CHANNELS:
		if channel == MikuCombatAnim.CH_PITCH:
			continue
		check_near(float(total[channel]), 0.0, 0.0001,
			"输入未给的通道 %s 应按 0 处理（而不是从结果里消失）" % channel)


# ---------------------------------------------------------------------------
# ④ 降级 + 接线口径
# ---------------------------------------------------------------------------

## 没setup（valid=false）的程序化姿态：四个动作**静默跳过**（返回 false，不崩）。
##这是硬降级要求——找不到关键骨骼的模型必须保持原姿态，而不是报错或把骨骼拧坏。
func test_actions_silently_skip_when_pose_is_invalid() -> void:
	var pose := MikuProceduralPose.new()
	check_false(pose.valid, "未 setup 的姿态 valid 应为 false")
	check_false(pose.trigger_fire(), "valid=false 时开火应被静默跳过")
	check_false(pose.trigger_hit(), "valid=false 时受击应被静默跳过")
	check_false(pose.trigger_death(), "valid=false 时死亡应被静默跳过")
	check_false(pose.trigger_reload(), "valid=false 时换弹应被静默跳过")
	check_false(pose.combat.is_dead(), "被跳过的死亡不得留下不可逆标记")
	# reset_pose / movement_scale 在无效姿态上也不得崩
	pose.reset_pose()
	check_near(pose.movement_scale(), 1.0, 0.0001, "无效姿态的移动系数应为 1（不影响移动）")


## 无效姿态下update() 不得崩（advance 在 valid 判断之前推进计时，但绝不碰骨骼）。
func test_update_on_invalid_pose_does_not_crash() -> void:
	var pose := MikuProceduralPose.new()
	pose.trigger_fire()
	for i in 10:
		pose.update(0.016, 3.0, true, true, true)
	check_true(true, "无效姿态下反复 update 不应崩溃（骨骼完全不被触碰）")


## MikuModel 必须暴露四个公开动作方法（外部触发源只认这四个）。
func test_miku_model_exposes_four_public_actions() -> void:
	var src := _read_source(MIKU_MODEL_SRC)
	for method in ["func play_fire", "func play_hit", "func play_death", "func play_reload"]:
		check_true(src.find(method) >= 0, "MikuModel 必须公开 %s()" % method)
	check_true(src.find("func reset_pose") >= 0,
		"MikuModel 必须公开 reset_pose()（死亡不可逆，重生时要复位）")


## ⚠ 架构纪律：战斗动作**不得**用 RPC 传输（A.4：RPC 只做传输，且动作是纯视觉表现，
## 各端本地根据收到的位置 / 血量自行播放即可）。新增 RPC 会让动作受网络时序影响。
func test_combat_actions_are_not_rpc_driven() -> void:
	for path in [COMBAT_ANIM_SRC, POSE_SRC, MIKU_MODEL_SRC]:
		var src := _read_source(path)
		for raw in src.split("\n"):
			var code := _strip_comment(raw)
			check_false(code.find("@rpc") >= 0,
				"%s 不得含 @rpc：战斗动作是纯视觉表现，不走 RPC" % path.get_file())


## 死亡动作只能由**受害端**播放：player.gd 的 take_damage 里调 play_death()。
## ⛔ 且 apply_network_state / _apply_display_health 里**不得**出现play_death——
##   射手端的 `_display_health` 是显示副本、不是血量真值（§4-9 同源纪律）。
func test_remote_death_is_not_driven_by_display_health() -> void:
	var src := _read_source(PLAYER_SRC)
	var i := src.find("func apply_network_state")
	check_true(i >= 0, "player.gd 应有 apply_network_state（远端状态接收端）")
	if i >= 0:
		var body := src.substr(i, src.find("\nfunc ", i + 1) - i)
		for code in body.split("\n"):
			var stripped := _strip_comment(code)
			check_false(stripped.find("play_death") >= 0,
				"apply_network_state 不得播死亡动作（_display_health 只是显示副本）")
			check_false(stripped.find("play_hit") >= 0,
				"apply_network_state 不得播受击动作（伤害只在受害端结算）")


## 受击 / 死亡动作必须接在 take_damage 的**权威判定点**上。
func test_take_damage_triggers_hit_and_death() -> void:
	var src := _read_source(PLAYER_SRC)
	var i := src.find("func take_damage")
	check_true(i >= 0, "player.gd 应有 take_damage")
	if i < 0:
		return
	var body := src.substr(i, src.find("\nfunc ", i + 1) - i)
	var i_hit := body.find("play_hit()")
	var i_death := body.find("play_death()")
	var i_zero := body.find("health <= 0.0")
	check_true(i_hit >= 0, "take_damage 必须触发受击动作")
	check_true(i_death >= 0, "take_damage 必须在归零时触发死亡动作")
	if i_death >= 0 and i_zero >= 0:
		check_true(i_death > i_zero,
			"死亡动作必须在 health <= 0.0 的判定之后（未死不该播倒地）")


## 开火动作必须与枪声**同帧**触发（动作与音的天然同步锚点）。
func test_fire_action_is_anchored_to_the_shot_sound() -> void:
	var src := _read_source(WEAPON_SRC)
	var i := src.find("func _fire()")
	check_true(i >= 0, "weapon.gd 应有 _fire()")
	if i < 0:
		return
	var body := src.substr(i, src.find("\nfunc ", i + 1) - i)
	var i_sound := body.find("play_shot()")
	var i_anim := body.find("_play_character_fire()")
	check_true(i_sound >= 0 and i_anim >= 0, "_fire 必须同时有枪声与开火动作")
	if i_sound >= 0 and i_anim >= 0:
		check_true(absi(i_sound - i_anim) < 120,
			"开火动作应紧邻 play_shot()（同帧同步锚点，不可靠网络事件）")


## 换弹动作接在既有的 start_reload 上（不是新造一套换弹逻辑）。
func test_reload_action_is_wired_to_existing_reload_logic() -> void:
	var src := _read_source(WEAPON_SRC)
	var i := src.find("func start_reload")
	check_true(i >= 0, "weapon.gd 应有 start_reload")
	if i < 0:
		return
	var body := src.substr(i, src.find("\nfunc ", i + 1) - i)
	check_true(body.find("play_reload()") >= 0,
		"start_reload 必须触发换弹动作（复用既有换弹逻辑，不新造一套）")


## 人机也要有开火 / 受击 / 死亡动作（bot.gd 是独立的一套射击逻辑，不走 weapon.gd）。
func test_bot_has_fire_hit_and_death_actions() -> void:
	var src := _read_source(BOT_SRC)
	check_true(src.find("play_fire()") >= 0, "bot.gd 开火处必须调play_fire()")
	var i := src.find("func take_damage")
	check_true(i >= 0, "bot.gd 应有 take_damage")
	if i < 0:
		return
	var body := src.substr(i, src.find("\nfunc ", i + 1) - i)
	check_true(body.find("play_hit()") >= 0, "bot.gd take_damage 必须触发受击动作")
	var i_hit := body.find("play_hit()")
	var i_zero := body.find("health <= 0.0")
	check_true(i_zero < 0 or i_hit < i_zero,
		"bot.gd 受击动作应在归零判定之前（活着就该有受击反应）")
	check_true(body.find("play_death()") >= 0, "bot.gd 归零时必须触发死亡动作")


## 程序化姿态必须在 valid 判断之前推进战斗计时，但绝不碰骨骼（降级安全）。
func test_combat_timer_advances_before_valid_check() -> void:
	var src := _read_source(POSE_SRC)
	var i := src.find("func update(")
	check_true(i >= 0, "miku_procedural_pose 应有 update()")
	if i < 0:
		return
	var body := src.substr(i, src.find("\nfunc ", i + 1) - i)
	var i_advance := body.find("combat.advance(delta)")
	var i_valid := body.find("if not valid")
	check_true(i_advance >= 0, "update() 必须推进战斗动作计时")
	if i_advance >= 0 and i_valid >= 0:
		check_true(i_advance < i_valid,
			"combat.advance 必须在 valid 判断**之前**（否则无效姿态下计时永不走，动作卡住）")


## 死亡必须接管步态：死亡后步频目标归零（倒地姿态不会还在原地迈步）。
func test_death_takes_over_gait_frequency() -> void:
	var src := _read_source(POSE_SRC)
	var i := src.find("func update(")
	if i < 0:
		check_true(false, "miku_procedural_pose 应有 update()")
		return
	var body := src.substr(i, src.find("\nfunc ", i + 1) - i)
	check_true(body.find("combat.is_dead()") >= 0,
		"update() 必须读 combat.is_dead()（死亡接管步态的唯一入口）")
	var decl := _line_with(body, "frequency_target :=")
	check_true(decl.find("dead") >= 0,
		"步频目标必须由死亡状态决定（`frequency_target := 0.0 if dead else 1.2`）")


## 程序化姿态的四个动作方法必须存在，且都必须先判 valid（降级）。
func test_pose_action_methods_guard_valid() -> void:
	var src := _read_source(POSE_SRC)
	for method in ["func trigger_fire", "func trigger_hit", "func trigger_death",
			"func trigger_reload"]:
		var i := src.find(method)
		check_true(i >= 0, "miku_procedural_pose 应有 %s()" % method)
		if i < 0:
			continue
		var body := src.substr(i, 200)
		check_true(body.find("if not valid") >= 0 and body.find("return false") >= 0,
			"%s() 必须先判 valid 并返回 false（降级不崩）" % method)