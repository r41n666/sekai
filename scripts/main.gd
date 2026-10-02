extends Node3D
## 对局场景：离线单人 / 联机对局都用这里创建玩家。
##
## 联机时不用 MultiplayerSpawner —— 每个端都根据（服务端广播的）玩家列表在本地创建同一批玩家节点，
## 这样「对局进行中才加入」的玩家也能立刻看到所有人。节点名 = peer id，权限 = 对应 peer，
## 位置与模型朝向由 player.gd 按 ~30Hz 经 NetworkManager 的 RPC 广播同步（不依赖场景缓存）。
##
## 离线时只创建一个本地玩家。

const PLAYER_SCENE := preload("res://scenes/player.tscn")

@onready var _players: Node3D = $Players
@onready var _spawn_points: Node3D = $SpawnPoints


func _ready() -> void:
	if NetworkManager.is_online:
		NetworkManager.room_changed.connect(_sync_players)
		_sync_players()
	else:
		_players.add_child(_make_player(1, NetworkManager.player_name))


## 按最新玩家列表补齐 / 移除玩家节点（所有端一致，幂等）
func _sync_players() -> void:
	if not NetworkManager.is_online or not is_inside_tree():
		return
	var ids: Array = NetworkManager.get_players().keys()
	ids.sort()
	for child in _players.get_children():
		if not ids.has(int(child.name)):
			child.queue_free()
	for id in ids:
		if _players.has_node(str(id)):
			continue
		_players.add_child(_make_player(id, NetworkManager.get_player_name(id)))


func _make_player(id: int, player_name: String) -> Node:
	var player := PLAYER_SCENE.instantiate()
	player.name = str(id)
	player.player_name = player_name
	player.position = _spawn_point_for(id)
	player.set_multiplayer_authority(id)
	return player


func _spawn_point_for(id: int) -> Vector3:
	var count := _spawn_points.get_child_count()
	if count == 0:
		return Vector3.ZERO
	return (_spawn_points.get_child(id % count) as Node3D).position