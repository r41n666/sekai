extends Node3D
class_name BotManager
## 人机管理（阶段 5）：在本地玩家周围 8~18 m 随机刷新，供 H 键面板增减数量。
##
## 人机仅在本端生成、**不参与联机同步**（联机时每端各自刷，见 README 已知限制）。

signal count_changed(alive: int, maximum: int)

const BOT_SCENE := preload("res://scenes/bot.tscn")

@export var max_bots := 8
## 刷新距离范围（米）：太近会直接刷在玩家脸上
@export var spawn_min_distance := 8.0
@export var spawn_max_distance := 18.0

var _bots: Array[Node] = []
var _model_paths: Array[String] = []


func _ready() -> void:
	add_to_group("bot_manager")
	_model_paths = MikuModel.list_available_models()


## 增（delta > 0）/ 减（delta < 0）人机；给很大的负数 = 清空
func change_count(delta: int) -> void:
	if delta > 0:
		for i in mini(delta, max_bots - _bots.size()):
			_spawn_one()
	elif delta < 0:
		for i in mini(-delta, _bots.size()):
			_remove_last()
	count_changed.emit(_bots.size(), max_bots)


func get_alive_count() -> int:
	return _bots.size()


## 在指定位置生成一个人机（也便于测试直接调用）
func spawn_bot_at(spawn_position: Vector3) -> Node:
	var bot := BOT_SCENE.instantiate() as CharacterBody3D
	bot.position = spawn_position
	if not _model_paths.is_empty():
		# 随机挑一个模型，人机之间外观有区分（资源会被缓存，重复加载不贵）
		bot.set("model_path", _model_paths[randi() % _model_paths.size()])
	bot.connect("died_bot", _on_bot_died)
	add_child(bot)
	_bots.append(bot)
	count_changed.emit(_bots.size(), max_bots)
	return bot


## 在玩家周围随机方向刷新（地面是 y=0 的水面，抬高一点点避免卡进地面）
func _random_spawn_position() -> Vector3:
	var origin := Vector3.ZERO
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player != null and is_instance_valid(player):
		origin = player.global_position
	var angle := randf() * TAU
	var distance := randf_range(spawn_min_distance, spawn_max_distance)
	return origin + Vector3(cos(angle) * distance, 0.05, sin(angle) * distance)


func _spawn_one() -> void:
	spawn_bot_at(_random_spawn_position())


func _remove_last() -> void:
	if _bots.is_empty():
		return
	var bot: Node = _bots.pop_back()
	if is_instance_valid(bot):
		bot.queue_free()


func _on_bot_died(bot: Node) -> void:
	_bots.erase(bot)
	count_changed.emit(_bots.size(), max_bots)