extends Node3D
## 对局场景：离线单人 / 联机对局都用这里创建玩家。
##
## 联机时不用 MultiplayerSpawner —— 每个端都根据（服务端广播的）玩家列表在本地创建同一批玩家节点，
## 这样「对局进行中才加入」的玩家也能立刻看到所有人。节点名 = peer id，权限 = 对应 peer，
## 位置与模型朝向由 player.gd 按 ~30Hz 经 NetworkManager 的 RPC 广播同步（不依赖场景缓存）。
##
## 出生点分配（R1）：按「房间内已排序玩家列表的序号」稳定分配（见 spawn_index_for），
## 不用 `id % count`（ENet peer id 是大随机数，取模不可预测且可能撞位）。
##
## 离线时只创建一个本地玩家。

const PLAYER_SCENE := preload("res://scenes/player.tscn")

@onready var _players: Node3D = $Players
@onready var _spawn_points: Node3D = $SpawnPoints
@onready var _score: ScoreManager = $ScoreManager


func _ready() -> void:
	if NetworkManager.is_online:
		NetworkManager.room_changed.connect(_sync_players)
		_sync_players()
	else:
		_players.add_child(_make_player(1, NetworkManager.player_name))
	# EP-3 / ES-3.3：把本局玩家列表喂给 ScoreManager（A.9 迟到加入 / 中途离开的实际数据入口）。
	sync_scoreboard()
	# 对局加载完成 → 触发 COUNTDOWN（A.2 状态图「对局加载完成」的落点）。
	#   只由权威端推进；客户端等房主的 `sync_scores` / 状态同步。
	#   ⚠ 本端玩家节点已在上面创建完毕、`Players` 子节点就绪 → 此刻冻结输入才有对象可冻。
	_score.start_match()


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
	sync_scoreboard()


## EP-3 / ES-3.4：把玩家列表同步进 ScoreManager（登记新 peer / 移除离开的 peer）。
## 幂等：`register_player` 不会覆盖已有计分；`unregister_player` 只在条目存在时移除。
func sync_scoreboard() -> void:
	if _score == null:
		return
	var ids: Array = NetworkManager.get_players().keys() if NetworkManager.is_online else [1]
	for id in ids:
		_score.register_player(int(id))


func _make_player(id: int, player_name: String) -> Node:
	var player := PLAYER_SCENE.instantiate()
	player.name = str(id)
	player.player_name = player_name
	player.position = _spawn_point_for(id, _ordered_peer_ids())
	player.set_multiplayer_authority(id)
	return player


## 房间内已排序的 peer id 列表（所有端一致，作为出生点稳定分配的序号来源）。
## 离线单人返回 [1]，与联机分支共用同一条分配路径。
func _ordered_peer_ids() -> Array:
	if not NetworkManager.is_online:
		return [1]
	var ids: Array = NetworkManager.get_players().keys()
	ids.sort()
	return ids


## 按「房间内已排序玩家列表的序号」分配出生点。
##
## 为什么不用 `id % count`（R1 修复）：ENet 的 peer id 是 `990798344` / `1900593455`
## 这类大随机数，`%4` 的结果不可预测，既不保证分散、也无法避免两人撞在同一点
## （例如 id 差恰好是 count 的整数倍时会算出同一点）。改为用「排序后列表里的下标」
## 当序号：4 人开局必然落在 4 个不同角，2 人必然拿到下标 0/1 两个确定点，且**与 id
## 数值无关**——所有人基于同一份排序列表，因此各端算出的结果天然一致。
##
## 设计成静态纯函数（入参 id / ordered_ids / count），不读 NetworkManager 与场景节点，
## 便于 `tests/suites/test_spawn_points.gd` 直接构造输入做回归，不依赖联机会话。
static func spawn_index_for(id: int, ordered_ids: Array, count: int) -> int:
	if count <= 0:
		return 0
	var idx := ordered_ids.find(id)
	if idx < 0:
		# 列表里找不到（理论上不该发生：调用前已把本端登记进列表）——
		# 退回「按 id 稳定取模」，至少保证同一 id 每次得到同一点、不抖动。
		return posmod(id, count)
	return idx % count


func _spawn_point_for(id: int, ordered_ids: Array) -> Vector3:
	var count := _spawn_points.get_child_count()
	if count == 0:
		return Vector3.ZERO
	return (_spawn_points.get_child(spawn_index_for(id, ordered_ids, count)) as Node3D).position