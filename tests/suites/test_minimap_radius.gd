extends TestSuite
## AC-2 · 小地图显示半径须覆盖整张地图（阶段 4 回归基线）
##
## 需求出处：design/gdd/03_map_encounter.md §6「AC-2（对应 C-5）」+ ⚑M-5（用户已决 = 60）
## 几何：80×80 m 竞技场的对角半长 = √(40² + 40²) ≈ 56.5686 m
## 判定方法（GDD §6）：断言 minimap.gd 的 world_radius ≥ 56.6（当前 60 ✅）

const MINIMAP_SRC := "res://scripts/ui/minimap.gd"
const ARENA_HALF := 40.0
## 对角半长（严格值，非四舍五入；= √(40²+40²)）
const MAP_DIAGONAL_HALF := 56.5686
const TARGET_RADIUS := 60.0

var _radius := -1.0


func _ready() -> void:
	var script: GDScript = load(MINIMAP_SRC) as GDScript
	if script == null:
		return
	var minimap: Minimap = script.new() as Minimap
	if minimap == null:
		return
	_radius = minimap.world_radius
	minimap.free()


func test_minimap_script_loaded() -> void:
	check_true(_radius >= 0.0, "minimap.gd 应可加载并暴露 world_radius")


func test_radius_covers_map_diagonal() -> void:
	check_ge(_radius, MAP_DIAGONAL_HALF,
		"world_radius 必须覆盖 80×80 对角半长 %.4f m（当前 %.1f）" % [MAP_DIAGONAL_HALF, _radius])


func test_radius_meets_target_60() -> void:
	check_ge(_radius, TARGET_RADIUS,
		"world_radius 应对齐 ⚑M-5 目标值 %.0f（当前 %.1f）" % [TARGET_RADIUS, _radius])


func test_diagonal_constant_is_self_consistent() -> void:
	# 自检：确认对角半长常量与 80×80 自洽（防止日后改地图尺寸时此处失配）
	var derived: float = sqrt(ARENA_HALF * ARENA_HALF * 2.0)
	check_near(derived, MAP_DIAGONAL_HALF, 0.001, "对角半长常量应与 √(40²+40²) 自洽")
