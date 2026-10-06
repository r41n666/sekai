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
	# D2-04：规则集到手（含**客户端**收到 `sync_ruleset` 之后）→ 补应用一次属性。
	#   ⚠ 为什么 `_make_player` 的「入树前应用」还不够：客户端的玩家节点在
	#     本函数里就建好了，而 `sync_ruleset` 是 COUNTDOWN 前才到的
	#     —— 客户端**根本没机会**在入树前应用。
	#   ⚠ 不补这一条的后果（ADR-008 冲突 1，规格 §6.4）：客户端 `max_health`
	#     停留在场景默认值 100，房主配 200 时客户端会把血量广播
	#     判成「超max_health = 协议污染」→ **永久丢弃 → 血条永远不动且不报错**。
	if _score.has_signal("ruleset_applied"):
		_score.ruleset_applied.connect(_on_ruleset_applied)
	# EP-3 / ES-3.3：把本局玩家列表喂给 ScoreManager（A.9 迟到加入 / 中途离开的实际数据入口）。
	sync_scoreboard()
	# 对局加载完成 → 触发 COUNTDOWN（A.2 状态图「对局加载完成」的落点）。
	#   只由权威端推进；客户端等房主的 `sync_scores` / 状态同步。
	#   ⚠ 本端玩家节点已在上面创建完毕、`Players` 子节点就绪 → 此刻冻结输入才有对象可冻。
	_score.start_match()


## D2-04：规则集生效 → 把属性补应用到**已存在**的玩家节点（补上「入树前应用」覆盖不到的那条路径）。
##   ⚠ 入树后补应用时 `PlayerStats` 会连带同步 `health`（规格 §6.3），
##     因此不会出现「改了上限但血条还是旧值」。
func _on_ruleset_applied(_ruleset_id: String) -> void:
	var overrides := _player_stat_overrides()
	if overrides.is_empty():
		return
	var can_configure := _can_configure_stats()
	for child in _players.get_children():
		PlayerStats.apply_player_stats(child, overrides, can_configure)


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
	# ── D2-04：玩家属性应用（**必须在 add_child 之前**）──
	#   ⚠⚠ 时机铁律（规格 §6.3）：`player.gd::_ready()` 第 120 行执行
	#     `health = max_health`。若在 `add_child()` **之后**才写属性，
	#     `health` 已被定死 → 表现为「改了血量上限但血条还是 100」，**且不报任何错**。
	#   ⚠ 客户端对**战斗属性只读**（规格 §6.2）：属性由权威端配置并经
	#     `sync_ruleset` 下发，本端不是权威时 `apply_player_stats` 会拒绝写入。
	#     —— 这不是"客户端不能配血量"的小限制，而是 P2P 无服务器权威（ADR-006）下
	#     `max_health` / `damage` **没有任何一端做二次校验**的开作面闸门。
	PlayerStats.apply_player_stats(player, _player_stat_overrides(), _can_configure_stats())
	return player


## 本局玩家属性覆盖集（配置层）。
##   本期无房主配置面板（规格 §9 Q4 用户已拍板不做），故读权威端已下发的规则集
##   —— 未来接上 UI 时，只需改这一个函数的来源，属性应用链路无需改动。
func _player_stat_overrides() -> Dictionary:
	if _score == null:
		return {}
	return _score.active_ruleset().player_defaults()


## 本端能否配置玩家属性（规格 §6.2 公平性分档）。
##   离线 / 训练模式、联机房主 → 可以；联机客户端 → 只读。
func _can_configure_stats() -> bool:
	if _score == null:
		return true
	return _score.is_authority()


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