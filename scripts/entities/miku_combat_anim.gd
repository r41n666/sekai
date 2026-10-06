class_name MikuCombatAnim
extends RefCounted
## 战斗动作（开火 / 受击 / 死亡 / 换弹）的**纯逻辑**部分：动作状态机 + alpha 包络 + 叠加量换算。
##
## 为什么独立成文件（纯逻辑 / 渲染分离）：本类**完全不碰骨骼、不碰场景、不碰引擎节点**，
## 所以可以在 headless 下逐值断言（`tests/suites/test_combat_anim.gd`）。
## 若把这些公式写进 `miku_procedural_pose.gd`，就只能靠「跑起来看」验证，成本高且极易漏。
## **骨骼摆放**（把叠加量变成 `set_bone_global_pose_override`）留在 MikuProceduralPose。
##
## 四条设计纪律：
##   ① **alpha 包络**：每个动作自 alpha=1 起、随时间衰减到 0，再**叠加**到行走步态上。
##      绝不用硬切换（硬切 = 抽搐）。
##   ② **死亡唯一不可逆**：`trigger(DEATH)` 之后其它动作一律被拒，直到 `reset()`。
##      倒地后不恢复——这是唯一会接管整个身体的动作。
##   ③ **动作可打断**：除死亡外，后触发的动作覆盖前一个（受击能盖住换弹、开火能盖住受击）。
##   ④ **只管上肢 / 躯干**：开火**不做位移后坐力**——三层后坐力由 `RecoilSystem` 作用于**摄像机**，
##      角色侧只做「持械臂后坐上抬 + 肘部收回 + 躯干轻微后仰」，两套系统各管各的、互不重复。
##
## 用法（MikuModel 转发，MikuProceduralPose 消费）：
##   var anim := MikuCombatAnim.new()
##   anim.trigger(MikuCombatAnim.Action.FIRE)
##   anim.advance(delta)
##   var offsets := MikuCombatAnim.combat_offsets(MikuCombatAnim.Action.FIRE, anim.alpha())

## 战斗动作枚举。NONE = 无动作（行走步态独占身体）。
enum Action { NONE = 0, FIRE = 1, HIT = 2, DEATH = 3, RELOAD = 4 }

# ── 时长（秒）──────────────────────────────────────────────────────────────
const FIRE_DURATION := 0.12## 开火：短促（一梭子点射的节奏）
const HIT_DURATION := 0.18## 受击：短促（比开火略长，要看得见）
const DEATH_FALL_TIME := 0.55## 倒地过渡时长（**不是**衰减时长，见下方「死亡包络」）
const RELOAD_DURATION := 1.2## 换弹：中等时长（与 weapon.reload_time 同量级）

# ── 包络形状 ───────────────────────────────────────────────────────────────
## 开火 / 受击的衰减指数：>1 让前段掉得更快（更「短促」）。
const FIRE_DECAY_POW := 2.0
const HIT_DECAY_POW := 1.4
## 换弹的「保持段」占比：前 70% 保持满 alpha（手一直搭在弹匣上），后 30% 平滑收回。
const RELOAD_PLATEAU := 0.7
## 换弹期间的移动速度系数（换弹时应该明显变慢，但不该完全定住）。
const RELOAD_SPEED_SCALE := 0.55

# ── 开火：持械臂后坐上抬 + 肘部收回 + 躯干轻微后仰（**不含任何位移**）──────
const FIRE_ARM_BACK_DEG := 16.0## 持械臂上臂绕 right 轴后坐（绕 front 正向 = 手臂前摆，反向 = 后坐）
const FIRE_ARM_UP_DEG := 7.0## 持械臂额外上抬（down 减小 = 抬起来）
const FIRE_ELBOW_DEG := 18.0## 持械肘部额外弯曲（手臂收回）
const FIRE_TORSO_DEG := 5.0## 躯干轻微后仰

# ── 受击：上身小幅后仰 / 侧倾 + 头微微后（可叠加在行走之上）──────────────
const HIT_TORSO_DEG := 11.0
const HIT_ROLL_DEG := 7.0## 绕 front 轴的侧倾
const HIT_HEAD_DEG := 9.0## 头部后仰

# ── 死亡：接管整个身体 ─────────────────────────────────────────────────────
const DEATH_FALL_DEG := 74.0## 前倒角度（绕 right 轴）
const DEATH_DROP_UNITS := 0.55## 整体下沉量（骨架空间单位，与 BOB_UNITS 同量纲）
const DEATH_LEG_DEG := 26.0## 松散的腿摆幅（倒地时腿不再交替迈步）
const DEATH_KNEE_DEG := 52.0## 屈膝（膝盖朝后弯 = 负号，见 combat_offsets）
const DEATH_ARM_EXTRA_DEG := 12.0## 手臂相对ARM_DOWN_DEG再垂下多少
const DEATH_ELBOW_DEG := 24.0## 肘部常态弯曲之外的松弛弯曲

# ── 换弹：左手离开护木去摸弹匣 + 右臂下压 ─────────────────────────────────
const RELOAD_LEFT_DOWN_DEG := 44.0## 左上臂下垂（手离开护木，往下摸）
const RELOAD_LEFT_SWING_DEG := 20.0## 左上臂略向前（探向弹匣井）
const RELOAD_LEFT_ELBOW_DEG := 52.0## 左肘弯曲（抓弹匣）
const RELOAD_RIGHT_DOWN_DEG := 16.0## 右臂下压（压住护木 / 保持枪身稳定）

## 叠加量通道名（`combat_offsets` 的返回键）。
const CH_PITCH := "pitch"## 绕 right 轴（俯仰）；**正值 = 后仰**，负值 = 前倾 / 前倒
const CH_ROLL := "roll"## 绕 front 轴（侧倾 / 肩歪）
const CH_DROP := "drop"## 沿 up 的下沉（**唯一的位置通道**，开火 / 受击 / 换弹恒为 0）
const CH_HEAD := "head"## 头部俯仰；**正值 = 头后仰**
const CH_ARM_R_SWING := "arm_r_swing"
const CH_ARM_R_DOWN := "arm_r_down"
const CH_ARM_R_ELBOW := "arm_r_elbow"
const CH_ARM_L_SWING := "arm_l_swing"
const CH_ARM_L_DOWN := "arm_l_down"
const CH_ARM_L_ELBOW := "arm_l_elbow"
const CH_LEG := "leg"## 大腿摆幅（额外量，叠加在步态之上）
const CH_KNEE := "knee"## 屈膝（额外量）

## 全部叠加通道（顺序固定，便于逐值断言与「不遗漏通道」自检）。
const CHANNELS: Array[String] = [
	CH_PITCH, CH_ROLL, CH_DROP, CH_HEAD,
	CH_ARM_R_SWING, CH_ARM_R_DOWN, CH_ARM_R_ELBOW,
	CH_ARM_L_SWING, CH_ARM_L_DOWN, CH_ARM_L_ELBOW,
	CH_LEG, CH_KNEE,
]

## 当前动作（Action.NONE = 无）
var _action: int = Action.NONE
## 当前动作已进行的时长（秒）
var _elapsed := 0.0
## 死亡不可逆标记：一旦为 true，除 DEATH 外全部动作被拒，直到 reset()
var _dead := false


# ── 包络（静态纯函数：可直接 headless 断言，不依赖任何实例状态）───────────

## 动作时长（秒）。DEATH 返回的是**倒地过渡时长**而非包络长度（死亡包络是渐入并保持）。
static func duration_of(action: int) -> float:
	match action:
		Action.FIRE:
			return FIRE_DURATION
		Action.HIT:
			return HIT_DURATION
		Action.DEATH:
			return DEATH_FALL_TIME
		Action.RELOAD:
			return RELOAD_DURATION
		_:
			return 0.0


## alpha 包络：把「归一化进度 u」换算成强度。
##
##   - `u` 会被clamp 到 [0,1]，所以进度越界不会得到 >1 或 <0 的强度（负 delta 也不会）。
##   - 开火 / 受击 / 换弹：**起始 alpha=1**，随时间衰减到 0（§4「alpha 包络」）。
##   - 换弹多一段**保持段**（前 RELOAD_PLATEAU 保持满强度，手一直搭在弹匣上），再平滑收回。
##   - 死亡是唯一**渐入并保持**的动作（alpha: 0→1 后不再变）：
##     它要表现的是「倒下去的过程」，不是「一下弹回来」；不可逆性由 `_dead` 保证。
static func envelope(action: int, u: float) -> float:
	var t := clampf(u, 0.0, 1.0)
	match action:
		Action.FIRE:
			return pow(1.0 - t, FIRE_DECAY_POW)
		Action.HIT:
			return pow(1.0 - t, HIT_DECAY_POW)
		Action.RELOAD:
			return 1.0 - smoothstep(RELOAD_PLATEAU, 1.0, t)
		Action.DEATH:
			return smoothstep(0.0, 1.0, t)
		_:
			return 0.0


## 某个动作的**叠加量**（弧度 / 骨架空间单位），按 alpha 线性缩放。
##
## 纯函数：不碰实例状态、不碰骨骼。返回的字典**总是包含全部 CHANNELS 通道**
##（未参与的动作一律为 0.0），这样「不遗漏通道」可以被直接断言。
##
## 符号约定（与 miku_procedural_pose.gd 里的骨骼摆放一致）：
##   - `pitch` 正 = 后仰（行走前倾 `lean` 是负向的，两个通道在 MikuProceduralPose 里相加）；
##   - `arm_*_down` 正 = 手臂**更垂**（`ARM_DOWN_DEG` 的方向）；
##   - `arm_*_swing` 正 = 手臂**前摆**（与 `HOLD_ARM_FORWARD_DEG` 同向）；
##   - `knee` 负 = 膝盖朝后弯（与步态里`-_knee_amplitude` 同向）；
##   - `drop` 是**唯一**的位置通道，开火 / 受击 / 换弹恒为 0（后坐力归 RecoilSystem 管摄像机）。
static func combat_offsets(action: int, alpha: float) -> Dictionary:
	var out := {}
	for channel in CHANNELS:
		out[channel] = 0.0
	var w := maxf(alpha, 0.0)
	match action:
		Action.FIRE:
			out[CH_ARM_R_SWING] = -deg_to_rad(FIRE_ARM_BACK_DEG) * w
			out[CH_ARM_R_DOWN] = -deg_to_rad(FIRE_ARM_UP_DEG) * w
			out[CH_ARM_R_ELBOW] = deg_to_rad(FIRE_ELBOW_DEG) * w
			out[CH_PITCH] = deg_to_rad(FIRE_TORSO_DEG) * w
		Action.HIT:
			out[CH_PITCH] = deg_to_rad(HIT_TORSO_DEG) * w
			out[CH_ROLL] = deg_to_rad(HIT_ROLL_DEG) * w
			out[CH_HEAD] = deg_to_rad(HIT_HEAD_DEG) * w
		Action.DEATH:
			out[CH_PITCH] = -deg_to_rad(DEATH_FALL_DEG) * w
			out[CH_DROP] = -DEATH_DROP_UNITS * w
			out[CH_LEG] = deg_to_rad(DEATH_LEG_DEG) * w
			out[CH_KNEE] = -deg_to_rad(DEATH_KNEE_DEG) * w
			out[CH_ARM_R_DOWN] = deg_to_rad(DEATH_ARM_EXTRA_DEG) * w
			out[CH_ARM_L_DOWN] = deg_to_rad(DEATH_ARM_EXTRA_DEG) * w
			out[CH_ARM_R_ELBOW] = deg_to_rad(DEATH_ELBOW_DEG) * w
			out[CH_ARM_L_ELBOW] = deg_to_rad(DEATH_ELBOW_DEG) * w
		Action.RELOAD:
			out[CH_ARM_L_DOWN] = deg_to_rad(RELOAD_LEFT_DOWN_DEG) * w
			out[CH_ARM_L_SWING] = deg_to_rad(RELOAD_LEFT_SWING_DEG) * w
			out[CH_ARM_L_ELBOW] = deg_to_rad(RELOAD_LEFT_ELBOW_DEG) * w
			out[CH_ARM_R_DOWN] = deg_to_rad(RELOAD_RIGHT_DOWN_DEG) * w
	return out


## 多个动作的叠加量之和（死亡会接管身体，但仍走同一条求和路径，便于统一测试）。
static func sum_offsets(offsets_list: Array) -> Dictionary:
	var total := {}
	for channel in CHANNELS:
		total[channel] = 0.0
	for one in offsets_list:
		if not (one is Dictionary):
			continue
		for channel in CHANNELS:
			total[channel] = float(total[channel]) + float(one.get(channel, 0.0))
	return total


# ── 动作状态机 ─────────────────────────────────────────────────────────────

## 触发一个动作。返回是否**被接受**（被拒时状态完全不变，调用方可据此决定要不要继续）。
##
## 拒绝的两种情况：
##   ① `action == Action.NONE`（无意义）；
##   ② 已死亡且不是 DEATH —— **死亡不可逆**。
##      重复触发 DEATH 视为幂等：返回 true 但**不重置进度**（否则第二次死亡通知会把倒地动画倒带重播）。
func trigger(action: int) -> bool:
	if action == Action.NONE:
		return false
	if _dead:
		return action == Action.DEATH
	if action == Action.DEATH:
		_dead = true
		_action = action
		_elapsed = 0.0
		return true
	# 非死亡动作之间允许互相打断：后触发者接管 alpha 包络
	_action = action
	_elapsed = 0.0
	return true


## 推进计时。`delta <= 0` 是安全的空操作（不会让 alpha 倒退或越界）。
func advance(delta: float) -> void:
	if _action == Action.NONE:
		return
	_elapsed += maxf(delta, 0.0)
	var total := duration_of(_action)
	if _elapsed < total:
		return
	if _action == Action.DEATH:
		_elapsed = total # 倒地后停在「完全倒地」，进度不再无限增长
		return
	_action = Action.NONE
	_elapsed = 0.0


## 当前动作（Action.NONE = 无动作）
func active_action() -> int:
	return _action


## 当前动作名（调试 / 断言用；NONE 返回 "none"）
func active_name() -> String:
	match _action:
		Action.FIRE:
			return "fire"
		Action.HIT:
			return "hit"
		Action.DEATH:
			return "death"
		Action.RELOAD:
			return "reload"
		_:
			return "none"


## 是否正在播放某个动作（含不可逆的死亡）
func is_active() -> bool:
	return _action != Action.NONE


## 指定动作当前的叠加 alpha；**该动作不是当前动作时返回 0**（便于「求和所有动作」）。
func overlay_alpha(action: int) -> float:
	if _action != action:
		return 0.0
	return alpha()


## 当前叠加强度（0 = 无动作 / 已结束）。
func alpha() -> float:
	if _action == Action.NONE:
		return 0.0
	var total := duration_of(_action)
	if total <= 0.0:
		return 0.0
	return envelope(_action, _elapsed / total)


## 当前动作的归一化进度（[0,1]；无动作时为 0）
func progress() -> float:
	if _action == Action.NONE:
		return 0.0
	var total := duration_of(_action)
	if total <= 0.0:
		return 1.0
	return clampf(_elapsed / total, 0.0, 1.0)


## 已进行的时长（秒；无动作时为 0）
func elapsed() -> float:
	return _elapsed if _action != Action.NONE else 0.0


## 是否已死亡（不可逆，reset() 前恒为 true）
func is_dead() -> bool:
	return _dead


## 当前动作对移动速度的影响系数（1 = 不影响）。
## 死亡 = 0（倒地不能走）；换弹 = RELOAD_SPEED_SCALE（变慢但不定住）。
func movement_scale() -> float:
	match _action:
		Action.DEATH:
			return 0.0
		Action.RELOAD:
			return RELOAD_SPEED_SCALE
		_:
			return 1.0


## 复位到初始状态（含死亡不可逆标记）——由 MikuModel.reset_pose() 在重生时调用。
func reset() -> void:
	_action = Action.NONE
	_elapsed = 0.0
	_dead = false