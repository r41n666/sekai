extends Node
## 【阶段 3 占位，未实现】局域网联机（蓝盾 VPN + ENetMultiplayerPeer）
##
## 计划：
##   - 主机：var peer = ENetMultiplayerPeer.new(); peer.create_server(PORT, MAX_CLIENTS)
##   - 客户端：peer.create_client("26.x.x.x", PORT)  # IP 由蓝盾 VPN 分配，通常 26 开头
##   - 玩家同步：给玩家场景挂 MultiplayerSynchronizer，同步 position / rotation
##   - 射击事件：@rpc("any_peer", "call_local", "reliable") func fire(...)
##   - 战术地图 / 小队 / 兵种 / 出生点：作为 Hub 场景（scenes/hub/）的联机大厅
##
## TODO(阶段3)：实现 host_game(port) / join_game(ip, port) / 断线重连 / 玩家列表。
## TODO(阶段3)：在 README 中补全蓝盾 VPN 使用步骤。