extends TestSuite
## AC-1 · 出生点必须四角分散（阶段 4 回归基线）
##
## 需求出处：
##   design/gdd/03_map_encounter.md §6「AC-1（对应 C-8）· 出生点必须四角分散」
##   design/gdd/99_consistency_review.md C-8
## 判定方法（GDD §6 AC-1 原文）：
##   遍历 SpawnPoints 子节点，断言
##     ① abs(pos.x) ≥ 24 且 abs(pos.z) ≥ 24
##     ② 任意两点 distance ≥ 45
##     ③ 在边界内（|x|,|z| ≤ 40）
## 目标数值：Spawn1≈(-32,0.5,-32) / Spawn2≈(32,0.5,-32) / Spawn3≈(32,0.5,32) / Spawn4≈(-32,0.5,32)
##
## 实现说明：直接读场景资源结构（instantiate 但**不入树** → 不触发任何 _ready），
## 因此 headless 下零副作用、可重复；不依赖物理引擎与渲染后端。

const MAIN_SCENE := "res://scenes/main.tscn"
const SPAWN_CONTAINER := "SpawnPoints"
const CORNER_ABS := 32.0
const CORNER_TOLERANCE := 1.0
const MIN_AXIS_ABS := 24.0
const MIN_PAIR_DISTANCE := 45.0
const BOUNDARY := 40.0

## R1：出生点分配的稳定序号函数所在脚本（pure static）
const MAIN_SCRIPT := "res://scripts/main.gd"

var _spawns: Array[Vector3] = []
## 供「2 人 / 4 人得不同点」用例复用的确定性列表（刻意用 ENet 那种大随机 id）
var _main_script: GDScript


func _ready() -> void:
	var scene: PackedScene = load(MAIN_SCENE) as PackedScene
	if scene == null:
		return
	var root: Node = scene.instantiate()
	var container: Node = root.get_node_or_null(SPAWN_CONTAINER)
	if container == null:
		root.free()
		return
	for child in container.get_children():
		if child is Marker3D:
			_spawns.append((child as Marker3D).position)
	root.free()
	_main_script = load(MAIN_SCRIPT) as GDScript


func test_spawn_count_is_four() -> void:
	check_eq(_spawns.size(), 4, "SpawnPoints 下应有 4 个 Marker3D")


func test_each_spawn_is_in_a_corner_quadrant() -> void:
	for i in _spawns.size():
		var p: Vector3 = _spawns[i]
		check_true(absf(p.x) >= MIN_AXIS_ABS and absf(p.z) >= MIN_AXIS_ABS,
			"出生点 %d 应落在四角象限（|x|,|z| ≥ %.0f），实际 (%.1f, %.1f)" % [i + 1, MIN_AXIS_ABS, p.x, p.z])


func test_spawn_pairwise_distance_at_least_45() -> void:
	for i in _spawns.size():
		for j in range(i + 1, _spawns.size()):
			var d: float = _spawns[i].distance_to(_spawns[j])
			check_ge(d, MIN_PAIR_DISTANCE,
				"出生点 %d 与 %d 间距应 ≥ %.0f m，实际 %.2f m" % [i + 1, j + 1, MIN_PAIR_DISTANCE, d])


func test_spawns_within_arena_boundary() -> void:
	for i in _spawns.size():
		var p: Vector3 = _spawns[i]
		check_true(absf(p.x) <= BOUNDARY and absf(p.z) <= BOUNDARY,
			"出生点 %d 应在 80×80 边界内（|x|,|z| ≤ %.0f），实际 (%.1f, %.1f)" % [i + 1, BOUNDARY, p.x, p.z])


func test_spawn_corner_magnitude_is_32() -> void:
	for i in _spawns.size():
		var p: Vector3 = _spawns[i]
		check_near(absf(p.x), CORNER_ABS, CORNER_TOLERANCE,
			"出生点 %d 的 |x| 应为 %.0f ± %.0f" % [i + 1, CORNER_ABS, CORNER_TOLERANCE])
		check_near(absf(p.z), CORNER_ABS, CORNER_TOLERANCE,
			"出生点 %d 的 |z| 应为 %.0f ± %.0f" % [i + 1, CORNER_ABS, CORNER_TOLERANCE])


# ---------------------------------------------------------------------------
# R1 · 出生点稳定分配（对应 main.gd::spawn_index_for）
#
# 背景：旧的 `id % count` 对 ENet 的大随机 peer id（如 990798344 / 1900593455）
#   取模不可预测、也不保证两人不撞在同一点。改为「排序列表里的下标」后：
#     - 各端基于同一份排序列表 → 结果天然一致；
#     - 与 id 数值无关 → 大随机 id 不影响分配；
#     - 4 人必得 4 个不同下标，2 人必得下标 0/1 两个确定点。
# ---------------------------------------------------------------------------

## 4 人：排序列表 [1, 2, 3, 4] → 下标 = id-1 → 四人各得不同出生点索引
func test_four_players_get_four_distinct_spawns() -> void:
	var ordered: Array = [1, 2, 3, 4]
	var idxs: Array = []
	for id in ordered:
		idxs.append(_main_script.spawn_index_for(id, ordered, 4))
	check_eq(idxs, [0, 1, 2, 3], "4 人应分别落到出生点下标 0/1/2/3，实际 %s" % str(idxs))


## 2 人（含 ENet 大随机 id）：房主 id=1 与客户机 id=990798344（用户实测真实值）
## → 排序后 [1, 990798344] → 下标 0 / 1 → 两点不同。
func test_two_players_with_random_enet_ids_get_distinct_spawns() -> void:
	var ordered: Array = [1, 990798344]
	var i0: int = _main_script.spawn_index_for(1, ordered, 4)
	var i1: int = _main_script.spawn_index_for(990798344, ordered, 4)
	check_eq(i0, 0, "房主(id=1)应为下标 0，实际 %d" % i0)
	check_eq(i1, 1, "客户机(id=990798344)应为下标 1，实际 %d" % i1)
	check_true(i0 != i1, "两人必须落到不同出生点（禁止撞位），实际 i0=%d i1=%d" % [i0, i1])


## 顺序稳定：同一 id + 同一列表，多次调用结果不变（无随机 / 无抖动）
func test_assignment_is_stable_across_calls() -> void:
	var ordered: Array = [1, 990798344]
	var first: int = _main_script.spawn_index_for(990798344, ordered, 4)
	for _n in 5:
		check_eq(_main_script.spawn_index_for(990798344, ordered, 4), first,
			"同一输入多次调用应得到同一下标")


## 与 id 数值无关：把 id 换成另一对大随机数，只要列表顺序一致，分配顺序就一致
func test_assignment_independent_of_id_magnitude() -> void:
	var ordered: Array = [1900593455, 990798344]  # 排序后 = [990798344, 1900593455]
	# 排好序后：990798344 在前（下标 0）、1900593455 在后（下标 1）
	var sorted_ids: Array = ordered.duplicate()
	sorted_ids.sort()
	check_eq(_main_script.spawn_index_for(990798344, sorted_ids, 4), 0,
		"排序列表首元素应为下标 0")
	check_eq(_main_script.spawn_index_for(1900593455, sorted_ids, 4), 1,
		"排序列表次元素应为下标 1")


## 5 人 > 4 个出生点：超出部分按 count 环绕（第 5 人回到下标 0），不崩、不越界
func test_more_players_than_spawns_wraps_around() -> void:
	var ordered: Array = [1, 2, 3, 4, 5]
	check_eq(_main_script.spawn_index_for(5, ordered, 4), 0,
		"第 5 人应环绕回下标 0（5 % 4）")
	for id in ordered:
		var idx: int = _main_script.spawn_index_for(id, ordered, 4)
		check_true(idx >= 0 and idx < 4, "下标必须落在 [0,4)，实际 %d" % idx)


## 退化输入：count=0 返回 0；id 不在列表里走稳定回退（posmod），不报错
func test_degenerate_inputs_are_safe() -> void:
	check_eq(_main_script.spawn_index_for(1, [1, 2], 0), 0, "count=0 应返回 0")
	var fallback: int = _main_script.spawn_index_for(7, [1, 2], 4)
	check_eq(fallback, 3, "id 不在列表时应按 posmod(7,4)=3 稳定回退")


# ---------------------------------------------------------------------------
# §1.2 顺序依赖不变量（设计侧硬约束 · design-strategist 2026-10-06）
#
# `SpawnPoints` 的**子节点次序 = 出生点分配优先序**（R1 用 child index 分配）。
# 任何人重排/增删 Spawn1~4 都会**静默改变 2/3 人落点**（4 人仍四角、不受影响）。
# 下列断言把「子节点次序 → 落角映射」钉死，防未来静默回归。
# 出处：design/gdd/03_map_encounter.md §1.2（第 42~46 行）+ EP-1 ES-1.1。
# ---------------------------------------------------------------------------

## ① 子节点顺序恒为 (-32,-32) / (32,-32) / (32,32) / (-32,32)
func test_spawn_child_order_is_canonical() -> void:
	var expected: Array[Vector2] = [
		Vector2(-32.0, -32.0),
		Vector2(32.0, -32.0),
		Vector2(32.0, 32.0),
		Vector2(-32.0, 32.0),
	]
	check_eq(_spawns.size(), expected.size(), "出生点数量应与规范次序等长")
	var n := mini(_spawns.size(), expected.size())
	for i in n:
		var got := Vector2(_spawns[i].x, _spawns[i].z)
		check_true(got.is_equal_approx(expected[i]),
			"Spawn%d 子节点次序应为 %s，实际 %s（次序=分配优先序，改它会影响 2/3 人落点）"
			% [i + 1, str(expected[i]), str(got)])


## ② 2 人落点必共享一条边（相邻角，非对角）——idx 0/1 = (-32,-32)+(32,-32)，共用 z=-32
func test_two_player_spawns_share_an_edge_not_diagonal() -> void:
	if _spawns.size() < 2:
		return
	var i0: int = _main_script.spawn_index_for(1, [1, 2], _spawns.size())
	var i1: int = _main_script.spawn_index_for(2, [1, 2], _spawns.size())
	var a: Vector3 = _spawns[i0]
	var b: Vector3 = _spawns[i1]
	# 相邻角：恰有一个坐标轴相等（共享一条边）；对角则两轴都不同。
	var same_x := is_equal_approx(a.x, b.x)
	var same_z := is_equal_approx(a.z, b.z)
	check_true(same_x != same_z,
		"2 人落点应共享一条边（相邻角），实际 i0=%d i1=%d -> %s / %s" % [i0, i1, str(a), str(b)])
	var dist := a.distance_to(b)
	check_true(dist <= 90.0,
		"2 人落点应为相邻角（≤90m），实际 %.2f m" % dist)
