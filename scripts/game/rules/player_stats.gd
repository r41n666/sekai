class_name PlayerStats
extends RefCounted
## 玩家属性规格表 + 应用入口（D2-04 · 规格 §6）
##
## ## 形态：属性 id（String）→ `{属性 id: float}` 的 Dictionary
## 元数据（默认值/ 区间 / 步进 / 是否战斗属性 / 落地目标）由本类**统一**定义，
## 不散落在 `@export` 里 —— 否则「默认值漂移」无法被钉死
## （用例 `test_player_stat_defaults_match_exports` 就是为此存在）。
##
## ## 与 `@export` 的优先级（规格 §6.3，低→ 高）
##   ① 本表 `default`（代码常量）
##      ↑ 被覆盖
##   ② `player.tscn` / `weapon.tscn` 的 `@export` 值（场景层，策划/美术仍能逐节点调）
##      ↑ 被覆盖
##   ③ `MatchRuleset.player_defaults`（配置层 · 本局）
## → 配置做在 `@export` **之上**而非替换它，三者共存，靠唯一应用入口。
##
## ## ⛔ 应用时机铁律（规格 §6.3，本任务最容易踩的坑）
##   属性必须在 **`add_child()` 之前**写入（`main.gd::_make_player()`内，
##   `instantiate()` 之后、`_players.add_child()` 之前）。
##   原因：`player.gd::_ready()` 第 120 行执行 `health = max_health`——
##   入树后再写 `max_health` 会表现为「改了血量上限但血条还是 100」，
##   **且不报任何错**。
##
## ## 公平性（规格 §6.2，⛔ 外挂面）
##   战斗属性（`affects_combat = true`）**只允许权威端写入**。
##   联机时客户端对战斗属性**只读**（属性由权威端`sync_ruleset` 下发后应用）。
##   理由：项目是 P2P 无服务器权威（ADR-006），`max_health` / `damage`
##   **没有任何一端做二次校验** —— 再开「客户端自选属性」等于在既有信任模型上
##   叠一个免费作弊面。本期连「请求-批准」通道都不做。

## 落地目标：写在 player 自身
const APPLY_PLAYER := "player"
## 落地目标前缀：写在某个武器槽上（后缀是槽名，如 `weapon:Rifle`）
const APPLY_WEAPON_PREFIX := "weapon:"

## 全部 7 项属性规格（规格 §6.1）。
##   ⚠ `default` 必须与对应 `@export var` 的当前值**逐字一致**（用例逐项钉死）。
##   ⚠ 只接**纯数值**属性：视角灵敏度（个人偏好，该留本地）、
##     姿态高度（`STANCE_HEIGHTS` 是 `const`，运行期不可改）、
##     特效时长（表现参数，不该让「规则配置」背上「美术配置」的锅）——本期一律不接。
const SPECS := {
	"max_health": {
		"default": 100.0, "min": 1.0, "max": 1000.0, "step": 10.0,
		"affects_combat": true, "apply": APPLY_PLAYER,
		"field": "max_health", "source": "player",
	},
	"walk_speed": {
		"default": 3.6, "min": 0.1, "max": 20.0, "step": 0.1,
		"affects_combat": true, "apply": APPLY_PLAYER,
		"field": "walk_speed", "source": "player",
	},
	"sprint_speed": {
		"default": 6.5, "min": 0.1, "max": 30.0, "step": 0.1,
		"affects_combat": true, "apply": APPLY_PLAYER,
		"field": "sprint_speed", "source": "player",
	},
	"jump_velocity": {
		"default": 5.0, "min": 0.1, "max": 30.0, "step": 0.1,
		"affects_combat": true, "apply": APPLY_PLAYER,
		"field": "jump_velocity", "source": "player",
	},
	"weapon_damage": {
		"default": 25.0, "min": 1.0, "max": 500.0, "step": 1.0,
		"affects_combat": true, "apply": APPLY_WEAPON_PREFIX + "Rifle",
		"field": "damage", "source": "weapon",
	},
	"weapon_magazine_size": {
		"default": 30.0, "min": 1.0, "max": 999.0, "step": 1.0,
		"affects_combat": true, "apply": APPLY_WEAPON_PREFIX + "Rifle",
		"field": "magazine_size", "source": "weapon",
	},
	"weapon_reload_time": {
		"default": 2.1, "min": 0.1, "max": 30.0, "step": 0.1,
		"affects_combat": true, "apply": APPLY_WEAPON_PREFIX + "Rifle",
		"field": "reload_time", "source": "weapon",
	},
}


## 该属性是否登记在册。
static func has_stat(stat_id: String) -> bool:
	return SPECS.has(stat_id)


## 全部属性 id（自省用：配置面板 / 未来校验页读它）。
static func stat_ids() -> Array:
	var ids: Array = SPECS.keys()
	ids.sort()
	return ids


## 取属性规格（副本）。
static func spec_for(stat_id: String) -> Dictionary:
	return (SPECS[stat_id] as Dictionary).duplicate(true) if SPECS.has(stat_id) else {}


## 该属性默认值（未登记 → 0.0）。
static func default_of(stat_id: String) -> float:
	return float((SPECS[stat_id] as Dictionary).get("default", 0.0)) if SPECS.has(stat_id) else 0.0


## 该属性是否战斗属性（受公平性约束；未登记 → true保守从严）。
static func affects_combat(stat_id: String) -> bool:
	return bool((SPECS[stat_id] as Dictionary).get("affects_combat", true)) if SPECS.has(stat_id) else true


## 夹取到 `[min, max]`（规格 §6.1：超出即夹取，**不报错**）。
##   ⚠ 夹取而非报错：属性是"用户输入"，报错会让UI 弹窗刷屏；越界值夹到边界是安全行为。
static func clamp_stat(stat_id: String, value: float) -> float:
	if not SPECS.has(stat_id):
		return value
	var spec := SPECS[stat_id] as Dictionary
	return clampf(value, float(spec.get("min", -INF)), float(spec.get("max", INF)))


## 把配置层的属性覆盖集**归一化**：填默认值 + 夹取 + 剔除未登记项。
##   返回 `{属性 id: float}`（只含登记在册的属性）。
##   ⚠ 剔除未登记项（而非静默忽略）：调用方应先 `unknown_ids()` 报警，
##     这里只负责不把垃圾带进应用阶段。
static func normalize(overrides: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for stat_id: Variant in overrides:
		var sid := str(stat_id)
		if not SPECS.has(sid):
			continue
		out[sid] = clamp_stat(sid, float(overrides[stat_id]))
	return out


## 配置里出现的、未登记的属性 id（诊断 / `push_warning` 用）。
static func unknown_ids(overrides: Dictionary) -> Array:
	var out: Array = []
	for stat_id: Variant in overrides:
		var sid := str(stat_id)
		if not SPECS.has(sid):
			out.append(sid)
	out.sort()
	return out


## ⚠ **入树前**应用入口（规格 §6.3）。
##   `player` 必须是 `PLAYER_SCENE.instantiate()` 的产物、**尚未 `add_child()`**。
##   `overrides`：配置层的属性覆盖集（只列出与默认值不同的项）。
##   `is_authority`：本端是否权威端 —— 决定战斗属性能否写入（规格 §6.2）。
##   返回实际写入的 `{属性 id: float}`（便于诊断 / 测试断言）。
##
##   ## 为什么必须入树前
##   `player.gd::_ready()` 执行 `health = max_health`。入树后再写 `max_health`
##   会表现为「改了上限但血条还是 100」，**不报任何错**。
##   → 本函数在写入 `max_health` 之后**额外**把 `health` 同步为同一值，
##     使得「万一被入树后调用」也不会静默半生效。但这**不是**推荐路径：
##     正确路径是入树前调用（`main.gd::_make_player()`）。
static func apply_player_stats(player: Node, overrides: Dictionary,
		is_authority: bool = true) -> Dictionary:
	var applied: Dictionary = {}
	if player == null:
		push_warning("PlayerStats.apply_player_stats: player 为 null，未应用任何属性")
		return applied
	var normalized := normalize(overrides)
	# ⚠ 未知属性 id：不静默忽略（配错键名是本项目反复出现的失效形态）
	var unknown := unknown_ids(overrides)
	if not unknown.is_empty():
		push_warning("PlayerStats: 配置含未登记的属性 id %s，已忽略（登记在册：%s）"
			% [str(unknown), str(stat_ids())])
	# 武器引用在**入树前**取不到（`player.gd::_build_weapons()` 在 `_ready()` 里跑，
	#   `_weapons` 那时才是空表）→ 必须走节点路径。
	#   `player.tscn` 的挂点固定为 `MikuModel/WeaponMount/<槽名>`（武器外观变体也按槽查表）。
	var weapon_cache: Dictionary = {}
	for stat_id: String in normalized:
		var spec := SPECS[stat_id] as Dictionary
		var sid := stat_id
		# ── 公平性闸门（规格 §6.2）：客户端不得自选战斗属性 ──
		if bool(spec.get("affects_combat", true)) and not is_authority:
			push_warning("PlayerStats: 非权威端试图写入战斗属性「%s」，已拒绝（规格 §6.2）" % sid)
			continue
		var value := float(normalized[sid])
		var target := _resolve_target(player, String(spec.get("apply", APPLY_PLAYER)), weapon_cache)
		if target == null:
			continue # 找不到落地目标：静默跳过（节点结构可能变了），已由 unknown 检查覆盖配错场景
		var field := String(spec.get("field", ""))
		if not _has_field(target, field):
			push_warning("PlayerStats: 属性「%s」的目标字段「%s」不存在（落地目标 %s），已跳过"
				% [sid, field, target.get_path()])
			continue
		target.set(field, value)
		applied[sid] = value
		# ⛔ `max_health` 必须连带同步 `health`（见文件头「应用时机铁律」）
		if sid == "max_health" and _has_field(player, "health"):
			player.set("health", value)
	return applied


## 解析落地目标节点：`"player"` → 自身；`"weapon:<槽>"` → 该槽武器节点。
static func _resolve_target(player: Node, apply: String, cache: Dictionary) -> Node:
	if apply == APPLY_PLAYER:
		return player
	if not apply.begins_with(APPLY_WEAPON_PREFIX):
		return null
	var slot := apply.substr(APPLY_WEAPON_PREFIX.length())
	if cache.has(slot):
		return cache[slot]
	var path := "MikuModel/WeaponMount/%s" % slot
	var node: Node = player.get_node_or_null(NodePath(path))
	cache[slot] = node
	return node


## 目标节点上是否存在该字段（`get_property_list` 查询，避免 `set` 静默新建属性）。
static func _has_field(target: Node, field: String) -> bool:
	if field == "":
		return false
	for info: Dictionary in target.get_property_list():
		if String(info.get("name", "")) == field:
			return true
	return false