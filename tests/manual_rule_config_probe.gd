extends Node
## D2-04 规则配置化 · **双端窗口实测探针**（启动器）
##
## ## 为什么必须双端窗口（不能用 headless 冒充）
##  ① `tools/verify.sh` 走 `--headless`，**不经过渲染后端**（`control_checklist §4-10`）。
##     本次要验的是「配置下发链路」—— 房主配的规则能不能**跨端送达**并生效。
##  ② 更根本：这是**跨端**行为。缺陷形态是「房主正常、客户端卡死」
##     —— 单端跑绿对这类缺陷**没有任何证明力**。
## → 必须两个真实窗口：一个建房、一个加入，走真实 ENet + 真实渲染。
##
## ## 验证目标（逐条对应用户需求）
##  1. 房主把规则配成 **3 杀**（非默认 15）→ 开局
##  2. **两端比分板都显示「先到 3 杀」**（证明 `sync_ruleset` 跨端送达 + 文案读实际值）
##  3. 打完 3 杀 → **两端都触发结算**（证明判定用配置后的阈值，且结算广播跨端）
##  4. 两端 `effective_kill_target()` 相等（配置跨端一致的直接证据）
##
## ## 关键设计：不动 `main.tscn`（ES-4.2 教训③）
##  探针**自带场景**、只做启动器：调 `NetworkManager.host_game/join_game`，
## 房主等齐人后调 `host_start_match()`，由 `NetworkManager` 自己切到 `main.tscn`。
## 观察者挂在 `get_tree().root` 下（不在探针场景下）→ **能活过场景切换**。
## → 收尾零残留，无需清理 `main.tscn`。
##
## ## ⚠ 房主如何「配规则」（本期无 UI，规格 §9 Q4 用户已拍板不做）
## 直接调 `ScoreManager.set_ruleset(cfg)` —— 它**就是**未来配置面板的同一入口
## （权威端设置 + `sync_ruleset` 下发），与 UI 点击走同一条代码路径，
## 只跳过「用鼠标点面板」这一步。
##
## ## 用法（**窗口模式**，加 --headless 就测不到渲染）：
##   godot --path . res://tests/manual_rule_config_probe.tscn -- --role=host --port=7801
##   godot --path . res://tests/manual_rule_config_probe.tscn -- --role=join --port=7801
## 退出码：0 = 本端全部断言通过。

const ROLE_HOST := "host"
const ROLE_JOIN := "join"
## 本探针专用端口（避开 7890 / 7795 —— 已被其它探针占用，`control_checklist` 教训）
const DEFAULT_PORT := 7801
## 房主配的目标杀数（**故意用 3 而不是默认 15**，才能证明配置真的生效）
const TARGET_KILLS := 3

var _role := ROLE_HOST
var _port := DEFAULT_PORT
var _observer: Node


func _ready() -> void:
	_parse_args()
	print("[RC] ==== 规则配置化 · 双端窗口实测（role=%s port=%d 目标=%d 杀）===="
		% [_role, _port, TARGET_KILLS])
	# 观察者挂到 root 下 → 活过 NetworkManager 的 change_scene_to_file
	_observer = preload("res://tests/manual_rule_config_observer.gd").new()
	_observer.name = "RuleConfigObserver"
	_observer.setup(_role, TARGET_KILLS)
	get_tree().root.add_child.call_deferred(_observer)

	if _role == ROLE_HOST:
		if not NetworkManager.host_game(_port):
			print("[RC] FAIL host_game 失败（端口 %d 可能被占用）" % _port)
			get_tree().quit(1)
			return
		print("[RC] HOST 已建房，等待客户端加入…")
	else:
		if not NetworkManager.join_game("127.0.0.1", _port):
			print("[RC] FAIL join_game 失败")
			get_tree().quit(1)
			return
		print("[RC] CLIENT 已发起加入 127.0.0.1:%d…" % _port)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			_role = arg.substr(7)
		elif arg.begins_with("--port="):
			_port = int(arg.substr(7))