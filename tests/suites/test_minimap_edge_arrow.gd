extends TestSuite
## AC-3 · 小地图边缘方向箭头（阶段 4 回归基线）
##
## 需求出处：design/gdd/04_ux_flow.md §3.5 + design/gdd/03_map_encounter.md §6「AC-3」
## 规则：超出 world_radius(=60) 的敌人 → 圆周边缘画三角箭头（只给方位）；范围内仍画方点 □。
##
## 判定方法（AC-3 原文）：
##   ① 敌人距玩家 70 m（> 60）→ 该方向上出现边缘箭头、半径内不出现该点；
##   ② 敌人距玩家 50 m（< 60）→ 范围内方点 □、无箭头。
##
## 实现说明：绘制逻辑抽为纯静态函数 `Minimap.edge_marker_for(pos, center, radius)`，
##   标题断言「是否箭头 / 箭头边缘坐标 / 方位角」——全部纯值，headless 可跑、零副作用。
##   这会真实几何推算（视角旋转、像素换算都在 _to_map 里，测试用直接像素输入绕过），
##   但**不影响 _draw_group 的绘制路径**：`test_minimap_radius.gd` 另守 world_radius=60。
##
## 「箭头真的是三角形」这一形状层面无法 headless 断言 → 由纯函数输出 + 手动窗口截图确认
##   （见本任务回报，不假装测过像素形状）。

const MINIMAP_SRC := "res://scripts/ui/minimap.gd"
## 地图中心（模拟 _draw() 里的 size*0.5；取任意正值即可，几何自洽）
const CENTER := Vector2(100.0, 100.0)
## 半径（模拟 _draw() 里的 min(size)*0.5 - 2；与 world_radius=60 同量级）
const RADIUS := 58.0

var _minimap: GDScript


func _ready() -> void:
	_minimap = load(MINIMAP_SRC) as GDScript


## 把「距中心 dist 米、方位 angle」折算成像素坐标（像素半径 RADIUS ↔ 世界半径 60）。
## 只用于构造测试输入；真正判定全在 edge_marker_for 里。
func _pos_at(dist_meters: float, angle: float) -> Vector2:
	var pixels := dist_meters / 60.0 * RADIUS
	return CENTER + Vector2(cos(angle), sin(angle)) * pixels


# ---------------------------------------------------------------------------
# AC-3 ①：70 m 敌人（超范围）→ 出现边缘箭头、半径内不出现该点
# ---------------------------------------------------------------------------

func test_far_enemy_produces_edge_arrow() -> void:
	var pos := _pos_at(70.0, 0.0)
	var d: Dictionary = _minimap.edge_marker_for(pos, CENTER, RADIUS)
	check_true(bool(d["out_of_range"]), "70m 敌人应判定为超范围（应画箭头）")


func test_far_enemy_arrow_is_within_radius_and_near_edge() -> void:
	var pos := _pos_at(70.0, 0.0)
	var d: Dictionary = _minimap.edge_marker_for(pos, CENTER, RADIUS)
	var edge: Vector2 = d["edge_pos"]
	# 箭头落在半径内（不会画到圆外），且贴近边缘（>= RADIUS - inset - 1）
	var edge_dist: float = edge.distance_to(CENTER)
	check_le(edge_dist, RADIUS, "箭头应落在半径内（≤ %.1f），实际 %.2f" % [RADIUS, edge_dist])
	check_ge(edge_dist, RADIUS - 3.0, "箭头应贴圆周边缘（≥ %.1f），实际 %.2f" % [RADIUS - 3.0, edge_dist])


func test_far_enemy_point_itself_is_not_inside_radius() -> void:
	var pos := _pos_at(70.0, 0.0)
	# 原始点确实超出半径（这就是「半径内不出现该点」的几何来源）
	check_true(pos.distance_to(CENTER) > RADIUS,
		"70m 敌人的原始像素点必须在半径外（%.2f > %.2f）" % [pos.distance_to(CENTER), RADIUS])


func test_far_enemy_arrow_preserves_direction() -> void:
	# 多个方位的方位角应正确（右 / 下 / 左上）
	check_near(float(_minimap.edge_marker_for(_pos_at(70.0, 0.0), CENTER, RADIUS)["angle"]),
		0.0, 0.01, "右侧 70m 敌人方位角应为 0")
	check_near(float(_minimap.edge_marker_for(_pos_at(70.0, PI * 0.5), CENTER, RADIUS)["angle"]),
		PI * 0.5, 0.01, "下方 70m 敌人方位角应为 +90°")
	check_near(float(_minimap.edge_marker_for(_pos_at(70.0, PI), CENTER, RADIUS)["angle"]),
		PI, 0.01, "左侧 70m 敌人方位角应为 180°")


# ---------------------------------------------------------------------------
# AC-3 ②：50 m 敌人（范围内）→ 无箭头（走方点路径）
# ---------------------------------------------------------------------------

func test_near_enemy_does_not_produce_arrow() -> void:
	var pos := _pos_at(50.0, 0.0)
	var d: Dictionary = _minimap.edge_marker_for(pos, CENTER, RADIUS)
	check_false(bool(d["out_of_range"]), "50m 敌人不应判定为超范围（画方点、非箭头）")


func test_near_enemy_keeps_original_position() -> void:
	var pos := _pos_at(50.0, 0.0)
	var d: Dictionary = _minimap.edge_marker_for(pos, CENTER, RADIUS)
	check_eq(d["edge_pos"], pos, "范围内目标不应被挪到边缘（edge_pos == 原点）")


# ---------------------------------------------------------------------------
# 边界与退化
# ---------------------------------------------------------------------------

func test_exactly_on_radius_is_in_range() -> void:
	# 恰好 = radius → 判定为范围内（不画箭头；与旧行为 `> radius` 取一致）
	var pos := CENTER + Vector2(RADIUS, 0.0)
	var d: Dictionary = _minimap.edge_marker_for(pos, CENTER, RADIUS)
	check_false(bool(d["out_of_range"]), "恰好落在圆周（dist == radius）应在范围内（非超范围）")


func test_enemy_at_center_is_not_arrow() -> void:
	# 目标恰在地图中心（自身位置）→ 无方位可指，不应画箭头
	var d: Dictionary = _minimap.edge_marker_for(CENTER, CENTER, RADIUS)
	check_false(bool(d["out_of_range"]), "恰在中心的目标不应产生无意义的箭头")


func test_arrow_inset_constant_is_sane() -> void:
	# 内缩量应 > 0 且 < radius，保证箭头既贴边又不跑到圆外
	var inset: float = float(_minimap.EDGE_ARROW_INSET)
	check_true(inset > 0.0 and inset < RADIUS, "EDGE_ARROW_INSET 应在 (0, radius) 内，实际 %.1f" % inset)
