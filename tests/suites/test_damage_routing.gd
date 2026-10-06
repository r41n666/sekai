extends TestSuite
## AC-F2 / AC-A3b · FFA 阵营与伤害路由解耦（依赖 EP-2，当前整体 pending）
##
## 需求出处（同一要求的三处编号，统一收录于 ADR-007）：
##   design/gdd/99_consistency_review.md   C-16
##   design/gdd/04_ux_flow.md   §6.4  AC-F2（关键回归）
##   design/art/accessibility.md   §7  AC-A3b
##
## 背景：`friendly` 组被同时当作「伤害路由键」（weapon.gd:353 / knife.gd:100）与
##        「显示阵营键」（minimap.gd:20/92 / teammate_icons.gd:48）——TDM 下重合，
##        FFA 下背离。解耦方案见 ADR-007（推荐：路由改能力探测 has_method("apply_network_damage")）。
##
## ⚠ 本 suite 目前 pending：EP-2（production/epics/EP-2-ffa-faction-decoupling.md）尚未实施。
##    EP-2 落地后，把 EP2_IMPLEMENTED 置为 true，下面 4 个用例立即生效，成为该解耦的回归基线。

const EP2_IMPLEMENTED := true

const WEAPON_SRC := "res://scripts/shooting/weapon.gd"
const KNIFE_SRC := "res://scripts/shooting/knife.gd"
const PLAYER_SRC := "res://scripts/player.gd"


func is_pending() -> bool:
	return not EP2_IMPLEMENTED


func _read_source(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## 路由改能力探测后：weapon.gd 不再靠显示组 friendly 判断，而靠显式声明的玩家方法
func test_weapon_routing_uses_capability_probe() -> void:
	var src := _read_source(WEAPON_SRC)
	check_true(src.find("has_method(\"apply_network_damage\")") >= 0,
		"weapon.gd 伤害路由应改为能力探测 has_method(\"apply_network_damage\")")
	check_true(src.find("is_in_group(\"friendly\")") < 0,
		"weapon.gd 路由不应再依赖显示语义组 friendly")


## knife.gd 与 weapon.gd 必须保持同一路由判据（否则近战与枪械行为分叉）
func test_knife_routing_uses_capability_probe() -> void:
	var src := _read_source(KNIFE_SRC)
	check_true(src.find("has_method(\"apply_network_damage\")") >= 0,
		"knife.gd 伤害路由应改为能力探测 has_method(\"apply_network_damage\")")


## 显示侧：FFA 下远程玩家进入 enemy 组（friendly 组为空），使 enemy 渲染统一
func test_remote_player_joins_enemy_group_in_ffa() -> void:
	var src := _read_source(PLAYER_SRC)
	var i := src.find("func _setup_remote_player")
	check_true(i >= 0, "player.gd 应有 _setup_remote_player()")
	if i >= 0:
		var body := src.substr(i, 400)
		check_true(body.find("add_to_group(\"enemy\")") >= 0,
			"FFA 下远程玩家应加入 enemy 组（而非 friendly）")
