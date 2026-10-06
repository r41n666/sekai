# 控制清单（Control Checklist）

> **Task ID**：E3-01 ｜ **作者**：程基岩（Cheng Jiyan）· 工程负责人 ｜ **状态**：draft
> **上游依赖**：`project.godot` 的 `[input]` 段（`project.godot:35-141`）、`README §二`、`README §6.1`、`README §8.1`
> **用途**：把「每个输入动作在哪一层被消费」固化成一张**可立即执行的规则表**，避免后加功能时出现
> 「两个脚本抢同一个动作」或「菜单打开了某个输入没被屏蔽」。

---

## 0. 一句话规则

> **移动/姿态类输入 → `player.gd`；射击/换弹/开镜类输入 → **当前武器**脚本；菜单类输入 → 各 UI 脚本；
> 音乐 → `MusicManager`。所有「玩家侧」输入的统一闸门是 `player.input_blocked` 与武器的 `_trigger_enabled`。**

---

## 1. 输入动作总表

> 「消费层」= `L1 player` / `L2 weapon` / `L3 ui` / `L0 MusicManager`。
> 「闸门」= 该输入生效前必须满足的条件。

| # | 动作 | 按键 | 消费层 | 脚本 · 函数 | 闸门 / 备注 |
| --- | --- | --- | --- | --- | --- |
| 1 | `move_forward` | `W` | L1 player | `player.gd::_physics_process`（`Input.get_vector`，`player.gd:201`） | `is_multiplayer_authority()` 且 `not input_blocked` |
| 2 | `move_back` | `S` | L1 player | 同上 | 同上 |
| 3 | `move_left` | `A` | L1 player | 同上 | 同上 |
| 4 | `move_right` | `D` | L1 player | 同上 | 同上 |
| 5 | `jump` | `Space` | L1 player | `player.gd:198` | `not input_blocked` 且 `is_on_floor()` |
| 6 | `sprint` | `Shift` | L1 player | `player.gd:204`（`Input.is_action_pressed`） | 权威（**注意**：`sprint` 未单独判 `input_blocked`，但被 `input_dir` 归零间接限制；见 §3 注） |
| 7 | `crouch` | `Ctrl`（按住） | L1 player | `player.gd::_update_stance`（`player.gd:240`） | `not input_blocked` |
| 8 | `prone` | `Z`（切换） | L1 player | `player.gd::_unhandled_input`（`player.gd:181`） | `not input_blocked`；切换 `_prone` |
| 9 | `view_toggle` | `V` | L1 player | `player.gd::_unhandled_input`（`player.gd:177`） | `not input_blocked` |
| 10 | `free_look` | `Alt`（按住） | L1 player | `player.gd::_unhandled_input`（`player.gd:159`）+ `_update_free_look`（`player.gd:263`） | 需 `Input.mouse_mode == CAPTURED`；松开自动回正 |
| 11 | `weapon_1` | `1` | L1 player | `player.gd::_unhandled_input` → `_equip_slot("Rifle")`（`player.gd:172-176`） | `not input_blocked`；同键再按 = 空手 |
| 12 | `weapon_2` | `2` | L1 player | `player.gd::_equip_slot("USP")` | 同上 |
| 13 | `weapon_3` | `3` | L1 player | `player.gd::_equip_slot("Knife")` | 同上 |
| 14 | `weapon_4` | `4` | L1 player | `player.gd::_equip_slot("Grenade")` | 同上 |
| 15 | `shoot` | 鼠标左键 | L2 weapon | `weapon.gd::_update_trigger`（`weapon.gd:251`）/ `knife.gd:63` / `grenade.gd:84` | `is_multiplayer_authority()` 且 `active` 且 `_trigger_enabled` |
| 16 | `aim` | 鼠标右键 | L2 weapon | `weapon.gd::_update_aiming`（`weapon.gd:238`） | 同上（仅枪械；近战/手雷无开镜） |
| 17 | `reload` | `R`（短按） | L2 weapon | `weapon.gd::start_reload`（`weapon.gd:181/213`） | `_trigger_enabled`（菜单/死亡时被屏蔽） |
| 17b | `reload` | `R`（**长按 3 s**） | L2 weapon | `weapon.gd:171-179` / `grenade.gd:76-83` | 补满备弹 / 手雷数量（"补给站式重置"，⚑E-4 保留） |
| 18 | `ui_cancel` | `Esc` | L3 ui | `game_menu.gd::_unhandled_input`（`game_menu.gd:38`）→ 开关菜单；`bot_panel.gd:36` 关闭人机面板 | 见 §2 互斥表 |
| 19 | `bot_panel` | `H` | L3 ui | `bot_panel.gd::_unhandled_input`（`bot_panel.gd:29`） | 开关人机面板 |
| 20 | `music_next` | `N` | L0 MusicManager | `music_manager.gd::_unhandled_input`（`music_manager.gd:61`） | 无闸门（Autoload，始终响应） |
| 21 | `music_pause` | `P` | L0 MusicManager | `music_manager.gd::_unhandled_input`（`music_manager.gd:64`） | 无闸门 |

> **鼠标移动**（非 `[input]` 动作，走 `InputEventMouseMotion`）：`player.gd::_unhandled_input`（`player.gd:158`）消费，
> 仅当 `Input.mouse_mode == CAPTURED`。转镜头（`_rotate_camera`）+ 惯性（`_sway.add_look_delta`）；
> 按住 `Alt` 时改为自由视角（只转镜头、不影响人物朝向，`player.gd:159-162`）。

---

## 2. 界面互斥关系（`game_ui` 组）

三个界面**同属 `game_ui` 组**（`game_menu.gd:27` / `death_screen.gd:16` / `bot_panel.gd:20`），
**同一时刻最多开一个**。打开任意一个时，它会遍历组、关闭其它已打开的成员。

| 界面 | 打开 | 关闭 | 打开的触发 | 互斥实现 |
| --- | --- | --- | --- | --- |
| **Esc 菜单** `game_menu` | `open_ui()` | `close_ui()` | `Esc`（`game_menu.gd:38`） | `_close_other_uis()`（`game_menu.gd:78`） |
| **死亡界面** `death_screen` | `open_ui()`（`visible=true`） | `close_ui()` | `player.died` 信号（`death_screen.gd:44`） | `_on_player_died` 里关其它（`death_screen.gd:45`） |
| **人机面板** `bot_panel` | `open_ui()` | `close_ui()` | `H`（`bot_panel.gd:29`） | `open_ui` 里关其它（`bot_panel.gd:46`） |

**互斥矩阵**（行 = 当前已开，列 = 新触发）：

| 已开 \ 触发 | Esc | H | 死亡 |
| --- | --- | --- | --- |
| 无 | 开菜单 | 开人机面板 | 开死亡界面 |
| 菜单 | 关菜单 | **关菜单 + 开人机面板** | **关菜单 + 开死亡界面** |
| 人机面板 | **关人机面板 + 开菜单** | 关人机面板 | **关人机面板 + 开死亡界面** |
| 死亡界面 | 不响应（`game_menu.gd:43` 有其它 UI 打开时不开；`open_ui` 里 `health<=0` 直接 return，`game_menu.gd:55`） | 不响应（同上） | —（已开） |

**特殊规则**：
1. **死亡状态优先**：`game_menu.open_ui()` 先查 `player.get_health() <= 0` → return（`game_menu.gd:55`）——
   阵亡时按 `Esc` **不会**打开菜单。
2. **关闭时恢复鼠标**：三者的 `close_ui()` 都会调 `player.set_input_blocked(false)` + `player.capture_mouse()`
   （`game_menu.gd:72-74`、`bot_panel.gd:60-63`；死亡界面重生走 `player.respawn()`）。
3. **打开时释放鼠标**：三者的 `open_ui()` 都会调 `player.set_input_blocked(true)`（内部 `release_mouse`）。

---

## 3. 输入屏蔽行为矩阵（菜单 / 死亡 / 人机面板打开时）

`player.set_input_blocked(true)`（`player.gd:375`）→ `release_mouse()`（`player.gd:461`）→ 当前武器 `set_trigger_enabled(false)`（`weapon.gd:104`）。
两个闸门分别作用：

| 输入 / 行为 | 闸门 | 屏蔽时的表现 | 出处 |
| --- | --- | --- | --- |
| 移动（`move_*`） | `player.input_blocked` | `input_dir = ZERO` → 停下 | `player.gd:201` |
| 跳跃 | `player.input_blocked` | 不响应 | `player.gd:198` |
| 蹲 | `player.input_blocked` | `_stance` 强制回 0 | `player.gd:240` |
| 趴 / 视角切换 / 武器槽 | `player.input_blocked`（`_unhandled_input` 早退） | 不响应 | `player.gd:156` |
| 开火 | `weapon._trigger_enabled` | 不响应，`_trigger_held` 清空 | `weapon.gd:166-168/252` |
| 开镜 | `weapon._trigger_enabled` | 自动**收镜**（`_cancel_aim`） | `weapon.gd:104-108` |
| **换弹计时** | —（**不被屏蔽**） | **继续走完**（`_update_reload` 仍被调用） | `weapon.gd:167`（README §8.1 明确要求） |
| 长按 R 补满 | `weapon._trigger_enabled` | 不响应 | `weapon.gd:166` 早退 |
| 音乐（N/P） | — | **不受影响**（Autoload，独立） | `music_manager.gd:58` |
| 鼠标重新锁定 | — | 点击画面（`MOUSE_MODE_VISIBLE`）会 `capture_mouse()` | `player.gd:186-188` |

> **注（`sprint` 的边界）**：`player.gd:204` 读 `sprint` 时**未单独判 `input_blocked`**，但因为
> `input_dir` 被置零、且 `velocity` 水平分量在 `set_input_blocked(false)` / 摩擦下会收敛，实际不会「菜单里冲刺」。
> 这是可接受的现状；若追求严格，建议把 `speed` 计算也纳入 `input_blocked` 判断。
> **注（`crouch` 的边界）**：`_update_stance` 的蹲下分支已判 `not input_blocked`（`player.gd:240`），
> 因此菜单里不会保持蹲姿。

---

## 4. 关键不变量（改代码时必须保持）

1. **`input_blocked` 必须"双闸门"同步**：任何新增「打开即屏蔽输入」的界面，都必须调用
   `player.set_input_blocked(true)`（它内部会连带 `release_mouse` → 武器 `set_trigger_enabled(false)`），
   **不要只调其中一半**，否则会出现「菜单里还能开枪」。
2. **换弹计时在屏蔽期间继续**（`weapon.gd:167`）—— 这是 `README §8.1` 的明确行为，不是 bug。
3. **`ui_cancel` 的归属**：`Esc` 由 `game_menu` 优先处理（`_unhandled_input`），`bot_panel` 额外监听
   `ui_cancel` 用于关闭自己（`bot_panel.gd:36`）。**新增 UI 时不要再抢 `ui_cancel`**，除非纳入 `game_ui` 组并遵循互斥。
4. **武器自己读 `shoot`/`aim`/`reload`**：不要把这些动作转发到 `player.gd`，否则会与「武器各自管自己的开火语义」冲突。
5. **`MusicManager` 的 N/P 始终可用**：音乐控制独立于游戏输入闸门（`process_mode = ALWAYS`，`music_manager.gd:43`）。
6. **`free_look` 只在鼠标被捕获时生效**（`player.gd:158`），且不影响人物朝向（只写 `FreeLookPivot`）。
7. **改组归属前，必须先 `grep` 全项目 `is_in_group` / `get_nodes_in_group` 的全部消费点。**
   组是**隐式接口**（无类型保护），一个组名可能同时被多个系统当不同语义使用 —— 改一处归属会静默打断别处。
   本条的由来：`friendly` 组同时是**伤害路由键**（`weapon.gd:353` / `knife.gd:100`）与**显示阵营键**
   （`minimap.gd:20` / `teammate_icons.gd:48`）；FFA 下要把它改成"敌对显示"时，若只改分组会**直接弄坏联机伤害**。
   详见 `adr/ADR-007-group-as-implicit-interface.md`（统一收录 C-16 / AC-F2 / AC-A3b）。
   命令：`rg "is_in_group|get_nodes_in_group|add_to_group" scripts/` —— 先看全，再改。
8. **改 `main.tscn` 的 `SpawnPoints` 子节点（增/删/重排 `Spawn1~4`）前，必须先核对 `design/gdd/03_map_encounter.md §1.2`。**
   **`SpawnPoints` 的「子节点次序」就是「出生点分配优先序」**：`main.gd::spawn_index_for()` 用
   `_spawn_points.get_child(下标)` 取点，而下标来自「房间内排序玩家列表的序号 % 子节点数」。
   因此**重排 `Spawn1~4` 不会报错、不会崩、也可能跑绿现有几何测试，但会静默改变 2/3 人开局落点**
   （4 人恒取四角、不受影响；2 人取 idx `0/1`、3 人取 idx `0/1/2`，落点是哪几个角**完全由子节点次序决定**）。
   规范次序（**不要动**）：`(-32,-32)` → `(32,-32)` → `(32,32)` → `(-32,32)`；
   由此 2 人 = `(-32,-32)+(32,-32)`（相邻角、共用 `z=-32` 边、64 m，已枚举确认为唯一 64 m 最优对）。
   检查动作：改 `SpawnPoints` 前后跑 `tests/suites/test_spawn_points.gd`（含 `test_spawn_child_order_is_canonical`
   与 `test_two_player_spawns_share_an_edge_not_diagonal` 两条守护用例）；
   任何红线 = 你改动了分配优先序，必须回头核对 §1.2 并同步 `EP-1 ES-1.1`。
   详见 `tests/suites/test_spawn_points.gd`（守护测试）与 `adr/` 中出生点相关记录。
9. **⚠️ 判定「某个远程对象是否已死/已归零」时，只能用「该对象自己那一端」的值，绝不能用本端缓存的副本。**
   联机里`apply_network_damage` / `apply_network_state` 都是 `call_remote`：
   **受害者的血量只在受害者自己的端递减，从不回传射手端** → 射手端 `collider.health` 恒为初始值。
   本条的由来（C-18，2026-10-06 第二次 G4 实测）：`weapon.gd::_deal_damage()` 曾用
   `var killed := hp_before - damage <= 0.0` 判死 → 射手端算`100-25<=0` **恒假** →
   `_report_kill_if_player()` 从不执行 → **比分永远 {kills:0,deaths:0}、15 杀永不 `match_ended`**，
   而日志里扣血/阵亡全部正常，**极具迷惑性**（看着像"打不到人"）。
   正确口径：**致死判定归血量真值那一端**（`player.gd::apply_network_damage`），
   归零时 `net_confirm_kill.rpc_id(射手 peer id)` 回传，射手端再走既有上报路径。
   自检动作：凡写出`collider.get("health")` / 依赖某个 `xxx_before` 变量做阈值判断，先问
   「这个值在本端会真的变吗？」—— 不会就是埋雷。
   守护测试：`tests/suites/test_kill_attribution.gd`。
   ⚠️ 附带一条通用纪律：**新增 suite 必须手动登记到 `tests/framework/test_runner.gd` 的
   `SUITE_SCRIPTS` 数组**（该数组不自动发现文件）——漏登记会静默不跑，让人误以为"测试全绿"。
10. **⛔ 禁止把 `rendering_device/driver.windows` 改回 `"d3d12"`（`project.godot` 必须保持 `"vulkan"`）。**
    本条由来（2026-10-06 G4 崩溃）：改回 D3D12 后，游戏启动即崩（编辑器表现为
    `--- Debugging process stopped ---`），且**崩在计分逻辑之前**（一行 `[MBDBG]` 都没有）。
    错误级联（首因在 Godot D3D12 后端，非本项目代码）：
    ```
    ERROR: CreateResource failed with error 0x80070057.       ← E_INVALIDARG
       at: texture_create (drivers/d3d12/rendering_device_driver_d3d12.cpp:1404)
    ERROR: Condition "!texture.driver_id" is true. Returning: RID()
    ERROR: Attempting to use an uninitialized RID → Parameter "tex" is null.
    ```
    渲染器拿到空 RID 后继续走后续纹理操作 → 进程死掉。
    同款级联见 `godot#117115`（报告者同为 AMD 显卡，明确「仅 D3D12 复现、Vulkan 正常」）。
    - 本机实测对照（RX 6750GRE）：**D3D12 = 9 条错误；Vulkan = 0 条、exit 0**。
    - 复现命令（改回d3d12 后应打出 9 条）：`godot --path . --rendering-driver d3d12 --quit-after 120 res://scenes/main.tscn`
    - 排查纪律：**看到 `0x80070057` / `uninitialized RID` / `texture_set_size_override` 就想到本条**，
      不要去翻业务代码 —— 这些是渲染后端栈帧，`miku_model.gd` 等业务脚本根本不碰纹理。
    - 换驱动后必须重跑一次窗口双端G4（headless 自检 `--headless` 不走渲染后端，
      **因此 verify PASS 并不能证明渲染没问题** —— 这是本条能潜伏至今的原因）。

---

## 5. HUD 提示条与真实按键的一致性

`hud.tscn` 底部的 `Hint` 标签（`hud.tscn:199`）列出了当前操作提示：
`WASD 移动 | Space 跳跃 | Ctrl 蹲 / Z 趴 | 左键开火 | 右键开镜 | R 换弹（长按 3 秒补满） | 1~4 武器（同键再按=空手） | V 第一/第三人称 | Alt 自由视角 | Esc 菜单 | H 人机 | N/P 音乐`。

> 该提示条**未列出**：`Shift` 加速跑、`weapon` 槽的「空手」语义之外的细节。
> 每次改输入映射，应同步核对：`project.godot [input]` ↔ 本清单 ↔ `hud.tscn Hint` ↔ `README §二 操作说明`（四处）。

---

## 6. 变更记录

| 日期 | 变更 | 作者 |
| --- | --- | --- |
| 2026-10-06 | 初版：21 个输入动作 + 3 界面互斥 + 屏蔽矩阵 | 程基岩（E3-01） |
| 2026-10-06 | §4 增第 7 条：改组归属前先 grep 全部 `is_in_group` 消费点（配 ADR-007） | 程基岩（E4-01 补录） |
| 2026-10-06 | §4 增第 8 条：改 `SpawnPoints` 子节点次序前核对 §1.2（次序=分配优先序，配 `test_spawn_points.gd` 守护测试） | 程基岩（R1/R2 收口） |
