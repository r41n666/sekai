class_name ConditionRegistry
extends RefCounted
## 条件类型注册表（规格 §3.1）—— 规则求值层的**唯一扩展点**
##
## ## 为什么用注册表而不是 `if/elif` 链
## 若判定写在 `if/elif` 里，加第 6 种条件就要改判定函数本体 → 用户明确要求的
## 「方便后续扩展」收益归零。注册表让「新增条件 = 新增一个文件 + 一次注册」。
##
## ## 形态（规格 §1.1 裁定：混合式）
##   · **传输层是 `Dictionary`**（可 RPC 跨端、可 JSON 化、headless 可构造）
##   · **求值层是规则对象**（每端各自 `compile()` 一次，**不传输**）
##   → 规则对象不需要跨端传输这一点，是本方案成立的关键。
##
## ## 静态表 + 惰性自举（**不用 Autoload**）
## 与 A.1 同理：规则注册是纯数据/纯逻辑，不需要跨场景生命周期，
## 多一个全局单例只会增加状态面。用 `static var` + 首次访问时自举。
## ⚠ 因此本类**没有** `_ready()` 可依赖 —— 所有公开方法都先 `_ensure_booted()`。

## 参数规格：某类型需要哪些 params 键（规格 §2.6）
##   · `required: Array[String]` —— 必填键，缺失 → **加载失败并回落默认**（不静默）
##   · `optional: Dictionary` —— 可选键 → 默认值
##   · `numeric_positive: Array[String]` —— 必须为正数的键，0 / 负数 → **加载失败**
##
## ⚠ 这一层直接消除「字典配置」的最大风险：`cfg["targt_kills"]`（拼错）与
## `cfg["target_kills"]` 在 GDScript 里**都是合法读取**，只是都返回 `null` →
## 静默退化成「阈值为 null」，条件永不成立，**编译期不报、运行期不炸**。

static var _factories: Dictionary = {}
static var _specs: Dictionary = {}
static var _booted := false

## 重复注册时的告警次数（测试用来确认「覆盖并告警」确实发生；不靠抓 stderr）。
static var duplicate_register_warnings := 0


## 首次访问时集中注册全部内置类型（幂等）。
static func _ensure_booted() -> void:
	if _booted:
		return
	register_all()


## 集中注册内置类型（规格 §3.1）。
##   ⚠ **必须**在函数开头就置 `_booted = true`：本函数会调用 `register`，
##   若此时 `_booted` 仍为false，`register` 内的自举检查会**递归回本函数**，
##   造成「注册两遍 + 刷一堆重复注册告警」。
static func register_all() -> void:
	_booted = true
	# ① 占位（用户点名但项目无支撑系统的 4 种，规格 §8.2）
	for type_id: String in UnavailableRule.placeholder_types():
		var tid := type_id
		register(tid,
			func(params: Dictionary) -> MatchRule: return UnavailableRule.new(tid, params),
			_unavailable_spec(tid))
	# ② 真实现（本期 2 种，规格 §8.1）
	register(KillTargetRule.TYPE_ID,
		func(params: Dictionary) -> MatchRule: return KillTargetRule.new(params),
		{
			"required": ["target_kills"],
			"optional": {},
			"numeric_positive": ["target_kills"],
		})
	register(TimeLimitRule.TYPE_ID,
		func(params: Dictionary) -> MatchRule: return TimeLimitRule.new(params),
		{"required": [], "optional": {}, "numeric_positive": []})


## 占位类型的参数规格：只声明 `required`（阈值键名由将来的实现自己定），
##   但**仍然登记在注册表里** → `validate` 能报「这个类型名认识，但实现是占位」。
static func _unavailable_spec(type_id: String) -> Dictionary:
	return {
		"required": [],
		"optional": {},
		"numeric_positive": [],
		"unavailable": true,
		"reason": UnavailableRule.reason_for(type_id),
	}


## 注册一个条件类型。
##   ⚠ 同名重复注册 → **覆盖 + 告警**（规格 §3.1：便于测试用替身条件做白盒验证）。
##   ⚠ 本方法**不自举**（调用方 `register_all` 已置 `_booted`）——
##   若外部直接调本函数，走`reset_for_test` 之后的空表注册，符合测试意图。
static func register(type_id: String, factory: Callable, spec: Dictionary = {}) -> void:
	if type_id.strip_edges() == "":
		push_error("ConditionRegistry: type_id 不能为空")
		return
	if _factories.has(type_id):
		duplicate_register_warnings += 1
		push_warning("ConditionRegistry: 类型「%s」重复注册，已覆盖（便于测试替身，勿在生产路径重复注册）"
			% type_id)
	_factories[type_id] = factory
	_specs[type_id] = spec.duplicate(true)


## 该类型是否已注册。
static func has_type(type_id: String) -> bool:
	_ensure_booted()
	return _factories.has(type_id)


## 全部已注册类型 id（自省用：校验器 / 未来的配置预览页读它）。
static func registered_types() -> Array:
	_ensure_booted()
	var ids: Array = _factories.keys()
	ids.sort()
	return ids


## 该类型的参数规格（副本；未注册返回 `{}`）。
static func spec_for(type_id: String) -> Dictionary:
	_ensure_booted()
	return (_specs[type_id] as Dictionary).duplicate(true) if _specs.has(type_id) else {}


## 该类型是否**可判定**（= 已注册 且 不是占位）。
##   ⚠ 这是「有没有支撑系统」的静态事实，供加载期给出明确拒绝理由。
static func is_judgeable(type_id: String) -> bool:
	_ensure_booted()
	return has_type(type_id) and not bool(spec_for(type_id).get("unavailable", false))


## 校验一批 params（规格 §2.6）。返回**错误信息数组**，空数组 = 通过。
##   校验项：① 类型已注册 ② 不是占位（占位 → 明确报错而非放行）
##   ③ 必填键齐全 ④ 数值键为正且确实是数值。
##   ⚠ 返回错误**字符串数组**而不是 bool：调用方需要把原因写进 `push_warning`，
##   否则用户只会看到「配置无效」却不知哪个键。
static func validate(type_id: String, params: Dictionary) -> Array[String]:
	_ensure_booted()
	var errors: Array[String] = []
	if not _factories.has(type_id):
		errors.append("未注册的条件类型「%s」（已注册：%s）" % [type_id, str(registered_types())])
		return errors
	var spec := _specs[type_id] as Dictionary
	if bool(spec.get("unavailable", false)):
		errors.append("条件类型「%s」在本项目**不可用**：%s"
			% [type_id, String(spec.get("reason", "占位类型"))])
		return errors
	for key: Variant in spec.get("required", []):
		if not params.has(key):
			errors.append("条件类型「%s」缺少必填参数 `%s`" % [type_id, str(key)])
	for key: Variant in spec.get("numeric_positive", []):
		if not params.has(key):
			continue # 缺必填键已单独报过，不重复
		var raw: Variant = params[key]
		# ⚠ 非数值也归入此处：`null`（键名拼错是 Dictionary 最常见的静默失效来源）
		if not (raw is int or raw is float):
			errors.append("条件类型「%s」的参数 `%s` 必须是数值，实际取到 %s（键名拼错？）"
				% [type_id, str(key), _value_kind(raw)])
			continue
		if float(raw) <= 0.0:
			errors.append("条件类型「%s」的参数 `%s` 必须为正数，实际 %s" % [type_id, str(key), str(raw)])
	return errors


## 值的类型名（不依赖引擎 API 的小helper；刻意不用 `type_string()` 以免把
##   规则层与引擎全局函数绑死—— 规则层要能纯 headless 断言）。
static func _value_kind(v: Variant) -> String:
	match typeof(v):
		TYPE_NIL:
			return "null（键不存在或拼错）"
		TYPE_BOOL:
			return "bool"
		TYPE_STRING:
			return "String"
		TYPE_ARRAY:
			return "Array"
		TYPE_DICTIONARY:
			return "Dictionary"
	return "非数值类型"


## 编译出规则对象（工厂 + 参数校验）。
##   ⚠ 校验失败**不抛异常、不返回 null**，而是返回一个恒 `UNAVAILABLE` 的规则对象
##   —— 调用方（`MatchRuleset.load_ruleset`）据此回落默认配置并 `push_warning`。
##   绝不允许「编译失败 → 返回一个永不成立的规则」：那正是本项目栽过的静默失效形态。
static func compile(type_id: String, params: Dictionary) -> MatchRule:
	_ensure_booted()
	if not validate(type_id, params).is_empty():
		return UnavailableRule.new(type_id, params)
	var factory: Callable = _factories[type_id]
	var rule: MatchRule = factory.call(params.duplicate(true))
	if rule == null:
		push_error("ConditionRegistry: 类型「%s」的工厂返回了 null，回落为不可用占位" % type_id)
		return UnavailableRule.new(type_id, params)
	if rule.type_id != type_id:
		# 不静默接受「工厂说自己是别的类型」—— 那会让 decisive_type 报出错的 id
		push_error("ConditionRegistry: 类型「%s」的工厂自报 type_id=「%s」，已强制对齐"
			% [type_id, rule.type_id])
		rule.type_id = type_id
	return rule


## 仅供测试重置（把注册表清回「未自举」状态）。
##   ⚠ 生产代码**禁止**调用：清空后自举会重新注册内置类型，测试注册的替身会丢
##   —— 变异测试用它保证每个用例从干净状态起步。
static func reset_for_test() -> void:
	_factories.clear()
	_specs.clear()
	_booted = false
	duplicate_register_warnings = 0