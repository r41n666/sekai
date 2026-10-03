extends CanvasLayer
class_name DeathScreen
## 死亡界面（阶段 5）：玩家生命降到 0 时显示「你已阵亡」+ 重生按钮
##
## 玩家阵亡时 player.gd 已经屏蔽输入并释放鼠标，这里只负责显示与重生。

const UI_GROUP := "game_ui"

@onready var _respawn_button: Button = $Panel/VBox/RespawnButton

var _player: Node = null
var _bound := false


func _ready() -> void:
	add_to_group(UI_GROUP)
	visible = false
	_respawn_button.pressed.connect(_on_respawn_pressed)


func _process(_delta: float) -> void:
	if _bound:
		return
	var player := get_tree().get_first_node_in_group("player")
	if player == null or not player.has_signal("died"):
		return
	_player = player
	_player.died.connect(_on_player_died)
	_bound = true


func is_open() -> bool:
	return visible


func open_ui() -> void:
	visible = true


func close_ui() -> void:
	visible = false


func _on_player_died() -> void:
	for ui in get_tree().get_nodes_in_group(UI_GROUP):
		if ui != self and ui.has_method("close_ui") and ui.has_method("is_open") and ui.is_open():
			ui.close_ui()
	visible = true


## 重生：回满血 + 回出生点 + 恢复输入（player.gd 里实现）
func _on_respawn_pressed() -> void:
	visible = false
	if _player != null and is_instance_valid(_player) and _player.has_method("respawn"):
		_player.respawn()