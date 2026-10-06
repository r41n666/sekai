class_name MatchRuleset
extends RefCounted
## 规则集（配置真值 + 加载校验 + 回落；规格 §1.2/ §3.3）
##
## ## 形态（规格 §1.1 裁定：混合式）
##   本类持有**配置真值**（`config: Dictionary`，可 JSON 化 / 可 RPC 跨端）
##   与**编译产物**（`rule_set: RuleSet`，每端各编译一次、不传输）。
##   规则对象不可跨端传输，但**规则对象不需要传输** —— 传的是配置。
##
## ## ⚠ 内置默认规则集的阈值**必须读`ScoreManager` 字段**（规格 §7.1，本任务最容易踩的坑）
##   `builtin_default(kill_target, match_duration)` 把两个阈值从入参灌进配置，
##   `ScoreManager` 在 `kill_target` / `match_duration` 变化时**重建**默认规则集。
##   绝不能在配置里另写一份 15 / 300.0 —— 既有测试直接写 `mgr.kill_target = 3`
##   （`test_score_manager.gd:348`）、`mgr.match_duration = 10.0`（`:329`），
##   改成纯配置读取**当场转红**。
##
## ## 加载失败一律「回落默认 + push_warning」，**不允许静默失败**（规格 §3.3）
##   理由：联机 P2P 下，一端配置坏了就崩 = 房间直接炸；回落默认 = 至少还能打完这局。
##   但**必须可观测**。把未注册条件当 `false` 是典型的静默故障（规格 §3.3 第2 条）。

## 配置结构版本（本解析器只认这一个；不匹配即拒绝并回落，规格 §1.2.1）。
const SCHEMA_VERSION := 1
## 内置默认规则集 id（稳定标识，供跨端核对「我拿到的是同一份配置」）。
const DEFAULT_RULESET_ID := "ffa_kill15"

## 顶层组合算子的合法取值。
const VALID_COMBINES := [RuleSet.COMBINE_ALL, RuleSet.COMBINE_ANY]
## 胜者策略枚举（规格 §1.2.3）。本期只有 `MAX_KILLS` 真跑（= 现有 `_evaluate_winner()`）。
const WINNER_MAX_KILLS := "MAX_KILLS"
const WINNER_DECISIVE_OWNER := "DECISIVE_OWNER" # 注册但默认不用（kill_target 已能给归属）
const WINNER_LAST_SURVIVOR := "LAST_SURVIVOR" # ❌ 需「存活状态」字段，本期不可用
## 本期**可跑**的胜者策略（其余保留枚举位但不实现）。
const VALID_WINNER_POLICIES := [WINNER_MAX_KILLS]

## 配置真值（`schema_version` / `ruleset_id` / `combine` / `conditions` / …）。
var config: Dictionary = {}
## 编译产物（每端本地产物）。
var rule_set: RuleSet
## 加载过程中的问题（空 = 干净加载；非空 = 已回落默认，问题在此）。
var load_errors: Array[String] = []


## 构造 + 编译。`cfg` 为配置字典。
##   ⚠ **不**在这里回落：`MatchRuleset.new(cfg)` 是"照给定配置构造"，
##   回落是**加载器**的职责（`load_ruleset`）。两者分开是为了让
##   「我想就按这份配置构造、不fallback」也能做到（测试用）。
func _init(cfg: Dictionary = {}) -> void:
	config = cfg.duplicate(true)
	rule_set = _compile(config)


# ══════════════════════════════════════════════════════════════════════
#  内置默认规则集
# ══════════════════════════════════════════════════════════════════════

## 内置默认：FFA「先到 N 杀 / M 秒」，行为与迁移前**逐位等价**（规格 §7.2 M2）。
##   ⚠ `target_kills` ← `kill_target`、`duration_limit` ← `match_duration`
##   （**由入参灌入**，不是在函数里写死 15 / 300.0）。
static func builtin_default(kill_target: int, match_duration: float) -> MatchRuleset:
	var cfg := {
		"schema_version": SCHEMA_VERSION,
		"ruleset_id": DEFAULT_RULESET_ID,
		"label": "个人死斗 · 先到 %d 杀" % kill_target,
		"combine": RuleSet.COMBINE_ANY,
		"winner_policy": WINNER_MAX_KILLS,
		"duration_limit": float(match_duration),
		"conditions": [
			{"type": KillTargetRule.TYPE_ID, "enabled": true,
				"params": {"target_kills": int(kill_target)}},
			{"type": TimeLimitRule.TYPE_ID, "enabled": true, "params": {}},
		],
		"fail_conditions": [],
		"player_defaults": {},
	}
	return MatchRuleset.new(cfg)


# ══════════════════════════════════════════════════════════════════════
#  加载器（校验 + 回落，规格 §3.3）
# ══════════════════════════════════════════════════════════════════════

## 加载一份配置：校验 → 编译；**任何一项不过就整份回落内置默认**并 `push_warning`。
##   `fallback_kill_target` / `fallback_duration` 让回落仍读权威字段（规格 §7.1）。
##   ⚠ **整份回落**（不是「跳过那条继续」）：半份配置比全份默认更难排查，
##   且会让"我配了 X"与"实际生效的是 Y"之间的差异不可见。
static func load_ruleset(cfg: Dictionary, fallback_kill_target: int = 15,
		fallback_duration: float = 300.0) -> MatchRuleset:
	var errors := validate_config(cfg)
	if errors.is_empty():
		return MatchRuleset.new(cfg)
	# ── 回落（一次push_warning，把所有问题一次列全，不刷屏）──
	var fallback := builtin_default(fallback_kill_target, fallback_duration)
	fallback.load_errors = errors.duplicate()
	var reason := "；".join(errors)
	push_warning("MatchRuleset: 配置被拒绝，已回落到内置默认「%s」（ruleset_id=%s，阈值 %d 杀 / %.1f 秒）。原因：%s"
		% [DEFAULT_RULESET_ID, fallback.ruleset_id(), fallback_kill_target,
			fallback_duration, reason])
	return fallback


## 校验一份配置（规格 §3.3）。返回问题列表，空 = 通过。
##   ⚠ 这一层是「消除字典静默失效」的全部依托，**不允许**为了省事而跳过。
static func validate_config(cfg: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	# ① schema_version
	var version := int(cfg.get("schema_version", SCHEMA_VERSION))
	if version != SCHEMA_VERSION:
		errors.append("schema_version=%d 不可识别（本解析器只认 %d）"
			% [version, SCHEMA_VERSION])
	# ② ruleset_id（必填；缺失会导致跨端无法核对「是不是同一份配置」）
	if str(cfg.get("ruleset_id", "")).strip_edges() == "":
		errors.append("缺少 ruleset_id（跨端核对配置一致性的依据）")
	# ③ combine
	var combine := str(cfg.get("combine", RuleSet.COMBINE_ANY))
	if not VALID_COMBINES.has(combine):
		errors.append("combine=%s 非法（合法值：%s）" % [combine, str(VALID_COMBINES)])
	# ④ winner_policy
	var policy := str(cfg.get("winner_policy", WINNER_MAX_KILLS))
	if not VALID_WINNER_POLICIES.has(policy):
		errors.append("winner_policy=%s 本期不可用（本期仅 %s =现有 _evaluate_winner 口径）"
			% [policy, str(VALID_WINNER_POLICIES)])
	# ⑤ duration_limit（必须 > 0）
	var duration := float(cfg.get("duration_limit", 0.0))
	if duration <= 0.0:
		errors.append("duration_limit=%s 必须为正数" % str(cfg.get("duration_limit", "<缺失>")))
	# ⑥ conditions 逐条校验
	var conditions: Array = cfg.get("conditions", [])
	if not conditions is Array:
		errors.append("conditions 必须是 Array，实际 %s" % _value_kind(conditions))
		conditions = []
	else:
		errors.append_array(_validate_condition_list(conditions, "conditions"))
	# ⑦ ALL_OF + 空启用条件 = 开局即结束（规格 §4.1 明确要求拦掉）
	if combine == RuleSet.COMBINE_ALL and _count_enabled(conditions) == 0:
		errors.append("combine=ALL_OF 但没有任何启用条件 —— 语义是「开局即刻结束」，属配置错误")
	# ⑧ fail_conditions：本期无任何可用失败条件类型（规格 §4.4）
	#    「死亡即失败」会推翻已决⚑L-4（阵亡 3 s 自动重生），故**有意不内置**。
	var fail_conditions: Array = cfg.get("fail_conditions", [])
	if fail_conditions is Array and not fail_conditions.is_empty():
		errors.append("fail_conditions 本期不可用：现有可用条件类型里没有一个语义上适合当失败条件"
			+ "（kill_target 当失败条件毫无意义）；「死亡即失败」会推翻已决 ⚑L-4")
	# ⑨ player_defaults 的属性 id 必须登记在册
	var defaults: Dictionary = cfg.get("player_defaults", {})
	if not defaults is Dictionary:
		errors.append("player_defaults 必须是 Dictionary，实际 %s" % _value_kind(defaults))
	else:
		var unknown := PlayerStats.unknown_ids(defaults)
		if not unknown.is_empty():
			errors.append("player_defaults 含未登记的属性 id %s（在册：%s）"
				% [str(unknown), str(PlayerStats.stat_ids())])
	# ⑩ ⛔ 自相矛盾检测：`ALL_OF` 里塞两条 kill_target（阈值不同）——必须报错，不许静默取一个
	errors.append_array(_validate_no_contradiction(conditions, combine))
	return errors


## 逐条校验条件列表（含「类型未注册」「占位不可用」「参数缺失 / 非正」）。
static func _validate_condition_list(conditions: Array, field_name: String) -> Array[String]:
	var errors: Array[String] = []
	for i in conditions.size():
		var entry: Variant = conditions[i]
		if not entry is Dictionary:
			errors.append("%s[%d] 必须是 Dictionary，实际 %s" % [field_name, i, _value_kind(entry)])
			continue
		var cond: Dictionary = entry
		if not cond.has("type"):
			errors.append("%s[%d] 缺少 type" % [field_name, i])
			continue
		var type_id := str(cond["type"])
		var params: Dictionary = cond.get("params", {})
		if not params is Dictionary:
			errors.append("%s[%d] 的 params 必须是 Dictionary，实际 %s"
				% [field_name, i, _value_kind(params)])
			continue
		for msg: String in ConditionRegistry.validate(type_id, params):
			errors.append("%s[%d] %s" % [field_name, i, msg])
	return errors


## ⛔ **配置自相矛盾**检测（规格外的补充，但属同一纪律：宁报错也不静默取一个）。
##   典型形态：`ALL_OF` 里塞 `kill_target=3` + `kill_target=5`。
##   为什么必须拦：`ALL_OF` 的语义是「全部成立」，而「3 杀且 5 杀」永不可满足 →
##   对局**永不结束**且不报任何错（与「比分永远 0」同款静默失效，只是换了条件类型）。
##   裁决：**报错 + 整份回落默认**，不做「取最大/取最小/取第一个」的隐式裁决。
static func _validate_no_contradiction(conditions: Array, _combine: String) -> Array[String]:
	var errors: Array[String] = []
	if not conditions is Array:
		return errors
	# 同一 type 出现多次时，按 params 归组：不同阈值= 自相矛盾；相同阈值 = 冗余（放过）
	var by_type: Dictionary = {}
	for entry: Variant in conditions:
		if not entry is Dictionary:
			continue
		var cond: Dictionary = entry
		var type_id := str(cond.get("type", ""))
		if type_id == "":
			continue
		var params: Dictionary = cond.get("params", {})
		if not params is Dictionary:
			continue
		var fingerprint := _fingerprint(params)
		if not by_type.has(type_id):
			by_type[type_id] = {}
		(by_type[type_id] as Dictionary)[fingerprint] = true
	for type_id: String in by_type:
		var variants: Dictionary = by_type[type_id]
		if variants.size() > 1:
			errors.append("条件类型「%s」出现 %d 个互相冲突的阈值（%s）—— 自相矛盾配置，"
				% [type_id, variants.size(), str(variants.keys())]
				+ "语义上可能永不成立；请只保留一个")
	return errors


## params 的稳定指纹（键排序后拼串；用于「同一个type 的两个params 是否等价」）。
static func _fingerprint(params: Dictionary) -> String:
	var keys: Array = params.keys()
	keys.sort()
	var parts: Array[String] = []
	for k: Variant in keys:
		parts.append("%s=%s" % [str(k), str(params[k])])
	return "|".join(parts)


## 条件列表里 `enabled != false` 的条数。
static func _count_enabled(conditions: Array) -> int:
	var n := 0
	for entry: Variant in conditions:
		if entry is Dictionary and bool((entry as Dictionary).get("enabled", true)):
			n += 1
	return n


static func _value_kind(v: Variant) -> String:
	match typeof(v):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "bool"
		TYPE_STRING:
			return "String"
		TYPE_ARRAY:
			return "Array"
		TYPE_DICTIONARY:
			return "Dictionary"
	return "非预期类型"


# ══════════════════════════════════════════════════════════════════════
#  编译
# ══════════════════════════════════════════════════════════════════════

## 把配置编译成规则对象树（规格 §3.4）。
##   ⚠ `enabled = false` 的条目在**编译期**剔除（规格 §1.2.2：等价于从列表移除，
##     但保留在配置里便于「临时关掉某条」而不删配置）。
##   ⚠ 剔除**之后**的顺序就是求值顺序 = `decisive_type` 的判定顺序（规格 §4.2）。
static func _compile(cfg: Dictionary) -> RuleSet:
	var compiled: Array = []
	for entry: Variant in cfg.get("conditions", []):
		if not entry is Dictionary:
			continue
		var cond: Dictionary = entry
		if not bool(cond.get("enabled", true)):
			continue
		var type_id := str(cond.get("type", ""))
		var params: Dictionary = cond.get("params", {})
		if not params is Dictionary:
			params = {}
		compiled.append(ConditionRegistry.compile(type_id, params))
	return RuleSet.new(str(cfg.get("combine", RuleSet.COMBINE_ANY)), compiled)


# ══════════════════════════════════════════════════════════════════════
#  查询（供 UI / 网络下发使用）
# ══════════════════════════════════════════════════════════════════════

## 本局生效的击杀目标（HUD「先到 N 杀」文案的真值来源）。
##   ⚠ **不是** UI 里的硬编码常量 —— 配置成 3 杀时这里返回 3。
##   取不到时回落 `fallback`（默认 15，与既有 `scoreboard.is_near_target` 默认参数一致）。
func effective_kill_target(fallback: int = 15) -> int:
	for rule in rule_set.rules:
		if rule is KillTargetRule:
			return (rule as KillTargetRule).target_kills()
	return fallback


## 本局是否配了超时条件（决定要不要显示剩余时间 / 终局冲刺提示）。
func has_time_limit() -> bool:
	for rule in rule_set.rules:
		if rule.type_id == TimeLimitRule.TYPE_ID:
			return true
	return false


## 配置里的玩家属性覆盖集（已归一化：填默认值 + 夹取）。
func player_defaults() -> Dictionary:
	var raw: Dictionary = config.get("player_defaults", {})
	return PlayerStats.normalize(raw) if raw is Dictionary else {}


func ruleset_id() -> String:
	return str(config.get("ruleset_id", DEFAULT_RULESET_ID))


func label() -> String:
	return str(config.get("label", ""))


func combine_mode() -> String:
	return str(config.get("combine", RuleSet.COMBINE_ANY))


func duration_limit() -> float:
	return float(config.get("duration_limit", 0.0))


## 本局配置里是否有任何不可用条件（供HUD /诊断显示「本局规则不完整」）。
func has_unavailable_conditions() -> bool:
	for rule in rule_set.rules:
		if not rule.judgeable:
			return true
	return false


## 导出配置（供 `sync_ruleset` RPC 跨端下发 / 存档）。
##   ⚠ 返回**深拷贝** → 调用方改动返回值不会污染本对象的配置真值。
func to_dict() -> Dictionary:
	return config.duplicate(true)