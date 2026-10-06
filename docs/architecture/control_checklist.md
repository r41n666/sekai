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

11. **配置文件的「清理」必须先diff，且`git checkout --` 报告成功 ≠ 文件真的还原了**：
    `project.godot` 会被 Godot 自动写入（如 `[debug] file_logging/*`），看着像污染就用
    `git checkout -- project.godot` 还原 —— ⚠ **这条命令按文件整体还原，会把同一文件里
    已修复的配置一并回退**。本项目已踩过：commit `a3efe27` 为清理调试日志执行该命令，
    把第 10 条刚修好的 `rendering_device/driver.windows="vulkan"` 整块删掉，
    且因 `verify.sh` 走 headless 而**无人发现**。
    - 纪律：**清理前先 `git diff project.godot` 逐行确认**，只该留下污染行；
      若 diff 里混有本轮修好的内容，改用 `Edit` 精确删除单行。
    - 已加锁：`tests/suites/test_render_driver.gd` 直接读 `project.godot` 断言
      `driver.windows="vulkan"` 在位且带「勿改回」注释 —— 该行被删即测试转红。
    - ⚠⚠ **第二次复发（2026-10-06，Task #10 远程血量同步期间）——「还原」本身也会骗人**：
      同一行 `rendering_device/driver.windows="vulkan"` **又一次整块消失**（形态与 `a3efe27` 一致）。
      这次的教训在**更靠后的一步**：执行 `git checkout -- project.godot` 后，
      **命令报告成功，但文件里仍无 Vulkan 行**，且 `git status` 仍显示 `M`。
      真正生效的是 `git show HEAD:project.godot > project.godot`。
      - **纪律（本条真正要记的）**：**任何还原动作之后，必须用 `git diff` / `grep` 复核内容本身**，
        不能凭「命令没报错」判定还原成功。`git checkout --` 在本项目已至少一次
        **静默未还原**，若当时只看退出码就收工，会把一个 P0 渲染配置缺失当成已修复。
      - **配套元纪律**：**「谁删的」与「怎么复原」是两个独立问题，不要用后者的顺利掩盖前者的未知**。
        两次形态相同（整块消失）但来源不同 ⇒ 应按**独立事件**各自定位来源，
        不可因为「上次是 `a3efe27` 干的」就假定这次也是同一原因。
      - 已加**流程锁**（比断言更前置）：跑完窗口/双端实测后**必须**执行
        `git diff project.godot` + `grep -n rendering_device project.godot` 复核，
        **不靠记忆**。理由：跑过多次 Godot 进程本身就可能触发 `project.godot` 写入，
        收尾时「我以为没动过它」不是证据。

12. **UI 文案函数：格式串占位符数必须等于参数数**：
    GDScript 的 `"%s%s%d" % [a, b, c, d]` 在**运行期**报 "too many arguments"
    并返回**空串**（编译期无任何提示）。UI 上表现为「整条 Label 空白」，
    极难从日志定位。
    - 纪律：新增/修改任何 `return "..." % [...]` 时，先数一遍占位符；
      涉及多段可选前缀（如 `"▶ " if cond else ""`）时**尤其**容易漏。
    - 已加锁：`test_scoreboard.gd::test_compact_row_text_contains_name_and_kills`
      断言输出**含名字与击杀数**，而不是只断言标记存在 —— 只断言 `begins_with("▶ ")`
      这种会在空串上失败，但换种写法就可能变成弱断言。
    - 同类纪律：`test_*` 里写 `check_eq(s, "—")` 这类**精确文案断言**前，
      先确认被测函数的真实契约（本项目 `kd_text(15, 0) == "15.0"` 而非 `"—"`），
      不要按直觉写期望值 —— 测试写错和实现写错一样会拖慢收口。

---

13. **架构纪律锁必须「剥注释」再搜，且按语义而非字面量**：
    用 `src.find("kills >")` 这类**字面量**搜源码来锁架构纪律，存在两个已实测踩到的缺陷：
    - **(a) 搜到自己的注释**：纪律锁越是把纪律写清楚（注释里写「不得出现 `kills >`」），
      越会误报自己。**危险后果**：有人为了「让用例变绿」去删注释 →
      等于把纪律说明也删了，变成「为让测试通过而破坏可维护性」。
      → **纪律锁一律先剥注释**（逐行只保留 `#` 之前的部分）。
      ⚠ 剥注释时**只能保留 `#` 之前的代码**，不能「有 `#` 就整行丢」——
      那会把 `xxx(true) # 注释` 这类「代码 + 行尾注释」的**代码部分也丢掉**，
      导致代码明明在、纪律锁却报「没调用」（ES-4.2 实测）。
    - **(b) 换个写法就绕过**：只搜单条字面量时，把 `kills >` 改成
      `get("kills", 0) > 0` 即可**完全绕过**（ES-4.2 变异测试 M3 首轮即存活）。
      → **必须按语义锁**：如「代码中不得出现 `kills`/`deaths` 的**任意**比较运算」
      （字段 × 运算符的组合枚举），而不是枚举几条「看起来像」的写法。
    - 配套纪律：**变异测试脚本必须校验注入是否真的生效**（注入后源码要与备份不同），
      否则「锚点不匹配 → 什么都没注入」会被当成「变异体存活（弱断言）」，
      **把工具缺陷误报成测试缺陷**，险些去重写一条本来正确的断言。
      同理，**注入失败必须让脚本非零退出**——「全绿结论」比「红结论」危险得多。
    - 守护：`tools/mutation_es42.py`（7 变异体 / 0 存活）、
      `tests/suites/test_match_result.gd::test_does_not_reimplement_winner_evaluation`。
    - 同款判据已在 `test_scoreboard.gd` 生效（§4-12 末条「断言含名字与击杀数而非只断言标记存在」）。

14. **⚠️ `.gd` / `.tscn` 的 `.uid` 伴随文件必须入库**：
    Godot 4.4+ 会为每个脚本与场景生成同名 `<file>.gd.uid`。它是**资源身份的一部分**
    （场景文件里 `ext_resource` 按 uid 引用），漏提交会导致别人拉取后 **uid 失配 → 场景加载失败**，
    而本地因为 uid 还在 `.godot` 缓存里而完全看不出来（又是一个「本地绿、别人红」的陷阱，
    成因与第 10 条同款：`verify.sh` 走 headless 且用的是本地缓存）。
    - 纪律：`git status` 出现 `?? xxx.gd.uid` 时**必须**一并 `git add`，
      不要当成「Godot 生成的垃圾」而忽略或写进 `.gitignore`。
    - 自检：新增脚本/场景的 `.uid` 数量应与新增文件数一致。

15. **⚠️ 删除被守护的对象时，守护它的用例必须一起删——不能靠 `pending()` 兜底**：
    `pending()` **不是** suite 级开关。`test_suite.gd` 里两者是**独立**的：
    - `is_pending()`（默认 `return false`）→ **suite 级**，由 `test_runner.gd:54` 在跑任何用例**之前**询问；
      返回 true 则整个 suite 跳过、不计失败。
    - `pending(reason)`（`test_suite.gd:43`）→ **用例级**，只是往 `pending_notes` 塞一条 note，
      末尾打印成 `· skip ...`，**不影响任何断言计数、不影响其它用例、不影响退出码**。
    - **本项目实测踩过的坑**（2026-10-06，删除 G4 临时观测层时）：
      `test_kill_attribution.gd::test_probe_observes_kill_confirmation` 读
      `res://scripts/debug/match_debug_probe.gd`，文件被删后走
      `if f == null: pending(...); return`。结果是用例**照常计入总数**、断言少 2、
      汇总仍是 `0 失败` —— **基线数字看着完全正常，而这条用例已经什么都不验证了**。
      比「直接删掉」更危险：直接删会掉用例数、被人看见；空壳则**伪装成绿灯**。
    - **纪律**：删除某个文件/模块时，`rg` 它的路径找到**所有**引用点，
      测试里的引用**连同其注释块一并删除**（注释留着会让人以为还有第 4 条不变量）。
      若确实想保留「暂缺」语义，必须**重写 `is_pending()`**（suite 级、显式）而不是在用例里调`pending()`。
    - **配套元纪律（与第 13 条同源）**：断言/用例**数量突然变化时必须逐条解释**。
      「用例数没降」和「断言数变了」都是信号——前者可能是空壳，后者可能是漏删。
      本项目该次的实际数字：`136/441/0 → 135/439/0`（用例 -1、断言 -2）才对得上
      「删 1 个用例、该用例含 2 条断言」；若仍是 136/439/0 就是空壳。
    - 守护：`tests/suites/test_kill_attribution.gd`（C-18 三条不变量；
      观测层删除时9 → 8 用例，同日加固弱断言时新增 `test_net_confirm_kill_guards_invalid_victim_id`
      → 回到 **8 用例 / 21 断言**。其头部注释已写明第 4 条观测层随 EP-4 删除、
      以及**不要因为想看日志而加回来**）。

16. **⚠ 弱断言有**两个**方向，只测「漏杀」是不够的**：
    一条纪律锁若只搜字面量，会同时栽在两个方向，且**第二个方向更隐蔽**：
    - **漏杀**（真缺陷改了却全绿）：如只锁`var was_alive` 这个 token，
      把它改成 `:= false` 照样通过 —— 这类坑本项目已栽 **3 次**
      （ES-4.2 的 `kills >`、C-18 的 token 版 `was_alive`、EP-4 收尾的顺序版 `was_alive`）。
    - **误杀**（语义等价的改写被挡下）：断言若写死 `find("> 0")`，那么正确的
      `0.0 < health` 会被判失败。**误杀会逼着后人绕开断言**（改成 literal 值、
      用 `#` 注释藏 token），最终比漏杀更糟。
    - **纪律**：断言按**语义**写（字段 × 运算符 × 方向，正反两个方向都认）；
      写完必须跑**守恒对照**——把源码改成**语义等价**的另一种写法，断言必须**仍然通过**。
      变异脚本要显式区分「杀伤组」（期望转红）与「守恒对照组」（期望仍绿），
      守恒组转红即判「误杀」并非零退出。
    - **配套两个正则陷阱**（写「与 0 比较」类断言时必踩，均由本项目单元测试实测捕获）：
      ① `0` 会匹配 `0.5` 的**前缀** → 阈值改成 0.5 的变异会逃过，
      须写 `0(?:\.0+)?(?![\d.])` 断尾；
      ② 正则里的**变量名不能硬编码** —— 把校验 `health > 0` 的 helper 直接拿去校验
      `victim_id < 0`，会得到**恒假断言**、verify 当场转红（本项目实测踩过）。
    - 守护：`tools/mutation_c18_probe.py`（**15 变异体：13 杀伤 + 2 守恒对照 / 0 存活 0 误杀**）。
      helper `_has_cmp_zero(code, var_name = "health")` 带 `var_name` 参数即为此。

17. **⚠ C-19（Vulkan 锁）第四次复发 —— 根因已定位：Godot 编辑器进程本身会污染 `project.godot`**
    前三次复发分别归因于「我误用 `git checkout`」「工程侧清理」「Godot 编辑器」，始终没查清机制。
    本次（2026-10-06 23:53）拿到直接证据链：
    - `tasklist` 显示**两个 `Godot_v4.7.2-stable_win64` 进程在运行**；
    - `.godot/editor/editor_layout.cfg` 与 `filesystem_cache10` 的 mtime **在观测前 1~3 分钟内**；
    - `project.godot` 被删掉 14 行（整段 Vulkan 注释 + `rendering_device/driver.windows="vulkan"`）；
    - 同时 `scenes/hub/hub.tscn` 被改写成 4.7 新格式（加 `uid=` / `unique_id`、删 `load_steps`），
      而同目录 `scenes/main.tscn` 仍是 `load_steps=12` 旧格式 → **只有正被编辑器打开的场景被重写**。
    - **纪律**：
      ① **观测/测试前先 `tasklist | findstr Godot`**，有编辑器在跑就先问用户或改用 headless；
      ② `project.godot` **只在 headless 下被动重载**，编辑器打开时会主动写回；
      ③ 清理 `project.godot` 的调试日志污染，**只能用 `git show HEAD:project.godot > project.godot`**，
         绝不能用 `git checkout --`（第 11 条）；
      ④ 任何还原动作之后**必须 `grep` 复核内容本身**（本项目实测 `git checkout` 退出码 0 但文件没还原）。
    - 守护：`tests/suites/test_render_driver.gd` —— 本次该测试由红转绿，即为锁已回归的直接证明。
      **但注意它只在「锁已被删且已提交/可见」时转红**；若 `project.godot` 的改动未提交，
      `git checkout` 式的清理会把测试一起骗绿。

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
| 2026-10-06 | §4 增第 11 条：配置文件清理前必须先 diff（`git checkout -- project.godot` 曾把 C-19 的 Vulkan 修复整块回退，且 headless 自检无法发现）；增第 12 条：UI 文案格式串占位符数须等于参数数（GDScript 运行期静默返回空串） | 程基岩（EP-4 ES-4.1 收口） |
| 2026-10-06 | §4 增第 13 条：架构纪律锁须剥注释 + 按语义锁（字面量锁会被注释误伤、被 `get("kills",0) > 0` 绕过；变异脚本须校验注入生效、注入失败须非零退出）；增第 14 条：`.gd`/`.tscn` 的 `.uid` 必须入库（漏提交→别人拉取 uid 失配→场景加载失败） | 程基岩（EP-4 ES-4.2 收口） |
| 2026-10-06 | §4 增第 15 条：删除被守护对象时守护用例必须一并删除，**不能靠 `pending()` 兜底**——`pending()` 是用例级 note、`is_pending()` 才是 suite 级开关；实测该用例会在观测层删除后**静默退化为空壳**（用例数不变、断言 -2、汇总仍 0 失败，伪装成绿灯）。配套元纪律：用例/断言数量变化必须逐条解释 | 程基岩（EP-4 收尾 · 观测层删除） |
| 2026-10-06 | §4 增第 16 条：**弱断言有「漏杀」与「误杀」两个方向，只测漏杀不够**——字面量锁既会放过真缺陷（本项目已栽 3 次），也会挡住语义等价的正确改写、逼后人绕开断言（比漏杀更糟）。必须配**守恒对照组**（变异脚本里显式区分「杀伤组/守恒组」，守恒组转红即判误杀并非零退出）。附两个正则陷阱：`0` 会匹配 `0.5` 前缀（须 `0(?:\.0+)?(?![\d.])` 断尾）、校验用的变量名不能硬编码（否则恒假断言）。守护：`tools/mutation_c18_probe.py` 15 变异体（13 杀 + 2 守恒 / 0 存活 0 误杀） | 程基岩（C-18 弱断言加固） |
