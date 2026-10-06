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

var _spawns: Array[Vector3] = []


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
