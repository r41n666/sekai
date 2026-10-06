# 00 · 主架构文档（Architecture Overview）

> **Task ID**：E3-01 ｜ **作者**：程基岩（Cheng Jiyan）· 工程负责人（主程序） ｜ **状态**：draft（回溯式架构）
> **上游依赖**：`README.md`（§3 结构 / §6 HUD 与射击手感 / §9 联机 / §12 已知限制）、`HANDOFF.md`、`design/pillars.md`、`design/gdd/01_core_loop.md`、`03_map_encounter.md`、`99_consistency_review.md`
> **文档性质**：本项目在补此文档之前**已有 5,788 行 GDScript、零架构文档**。本文是**回溯式（as-built）架构梳理**——所有结论都指向 `scripts/` 下的真实文件与行号，不臆造、不描述未实现的代码。
> **相关 ADR**：`adr/ADR-001`（Jolt）、`ADR-002`（网络同步）、`ADR-003`（武器外观装配）、`ADR-004`（程序化姿态降级）、`ADR-005`（模型目录名注册表）、`ADR-006`（无服务器权威取舍）

---

## 0. 一页速览

| 维度 | 结论 |
| --- | --- |
| 引擎 / 栈 | Godot **4.7.2 stable** / Forward+ / GDScript / Jolt Physics / D3D12（Windows） |
| 代码规模 | `scripts/` 下 **30 个 `.gd`**（实际，非 29；其中 `training_target.gd` 为已移出场景的遗留脚本） |
| 架构风格 | **场景组合 + 场景组（group）+ 信号** 的松耦合；无 DI 框架、无 ECS、无全局事件总线 |
| 解耦主轴 | **HUD / UI 与游戏逻辑之间不做硬引用**（`README §6.1`）—— 靠「组查找 + signal」双向解耦 |
| 唯一权威出口 | 所有网络 RPC 只由 `NetworkManager`（Autoload）中转 |
| 唯一摄像机持有者 | 摄像机链只挂在 `player.tscn` / `bot.tscn` 的 `MikuModel` 与 `CameraPivot` 下，由 `player.gd` 驱动 |
| 数据/表现分层 | 逻辑节点只写**自己的变换**；表现系统只读**别人暴露的接口**（详见 §3） |
| 网络模型 | 节点名 = peer id、`set_multiplayer_authority(id)`、~30 Hz 普通 RPC 位置同步 + 本端平滑（见 §7） |
| 主要结构缺口 | 无胜负 / 比分 / 结算（阶段 4 工程任务）、无掩体（地图是空水面）、无测试框架 |

---

## 1. 技术栈与运行配置

来源：`project.godot`、`README §4`。

| 项 | 值 | 出处 |
| --- | --- | --- |
| 引擎版本 | 4.7.2 stable（`config/features = ("4.7","Forward Plus")`） | `project.godot:20` |
| 主场景 | `res://scenes/hub/hub.tscn`（大厅，非直接进对局） | `project.godot:19` |
| 渲染后端 | Forward+ | `project.godot:20` |
| 视口 | 1920×1080，`canvas_items` 拉伸 / `expand` 纵横 | `project.godot:30-33` |
| 物理引擎 | `physics/3d/physics_engine = "Jolt Physics"` | `project.godot:145` |
| Windows 驱动 | `rendering_device/driver.windows = "d3d12"` | `project.godot:149` |
| 抗锯齿 | TAA 开、MSAA 关、各向异性 ×8 | `project.godot:150-151`、`README §4` |
| Environment | `high_quality_environment.tres`：ACES / Glow / SSAO / **SSR 96**（水面反射）/ 体积雾；**SDFGI 关闭** | `assets/environments/high_quality_environment.tres`、`README §4` |
| Autoload | `MusicManager`、`NetworkManager` | `project.godot:25-26` |

> **架构含义**：Forward+ 是 SSR / 体积雾 / SDFGI 的前提；本项目**关掉 SDFGI** 换取性能，把反射预算全给水面的 `SSR`。Jolt 的选择理由见 `ADR-001`。

---

## 2. 模块划分与依赖方向

### 2.1 分层（自下而上）

```
L3 表现 / UI      ui/*            （hud / game_menu / death_screen / bot_panel / minimap /
                                    crosshair / compass / teammate_icons / weapon_preview / hub）
                          ▲ 只读组 + 连信号，不 import 玩法类
L2 玩法 / 手感    shooting/*      （weapon / knife / grenade / grenade_projectile /
                                    recoil_system / camera_sway / screen_shake / audio_3d /
                                    weapon_skin / weapon_variant）
                          ▲ 由 player 注入依赖（setup）
L1 核心运行时     main.gd, player.gd, entities/*（bot / bot_manager / miku_model /
                                    miku_idle_motion / miku_procedural_pose）
                          ▲ 调用
L0 平台 / 服务    project.godot, music_manager.gd(Autoload), network/network_manager.gd(Autoload)
```

### 2.2 依赖方向规则（当前代码已遵守，后续改动须保持）

1. **UI 不得硬引用玩法类**。`hud.gd` / `minimap.gd` / `compass.gd` / `teammate_icons.gd` / `death_screen.gd` 全部通过
   `get_tree().get_first_node_in_group("player")` 等**组查找**拿到数据源，通过 `has_signal()` / `has_method()` 的
   **鸭子类型**连接，不 `preload` 具体的 `Weapon` / `PlayerController`。证据：`hud.gd:74-108`（全部走 `has_signal`/`has_method`）。
   > 例外（**允许**）：`hud.gd:23` / `minimap.gd:2` / `crosshair.gd:2` 等对**自身类型**与**同层 UI 类**的 `class_name` 引用（`DynamicCrosshair` 等），
   > 属 UI 内部耦合，不违反规则。
2. **玩法层由 `player.gd` 注入依赖**，不反向查找。`weapon.gd::setup(player, camera, recoil, shake)`（`weapon.gd:95`）由
   `player.gd::_build_weapons()`（`player.gd:117-120`）调用 —— 武器不知道玩家在哪，玩家把引用递过去。
3. **RPC 只有 `NetworkManager` 一个出口**。`weapon.gd` / `player.gd` / `grenade.gd` 都通过
   `NetworkManager.net_*.rpc(...)` 广播（`weapon.gd:290`、`player.gd:235`、`grenade.gd:98`），**不自己持有 `multiplayer` 连接**。
4. **`main.gd` 是对局编排者**，只依赖 `NetworkManager` 与 `player.tscn`，不依赖任何 UI。
5. **层内直连（$ 路径）是允许的**：`player.gd` 用 `$CameraPivot/RecoilPivot/...` 固定路径拿自己的子系统（`player.gd:52-58`）。
   代价是 `player.tscn` 节点结构是「隐式契约」，改结构必须同步改脚本 —— 详见 §3.4。

### 2.3 现状结构 vs 目标结构

| 模块 | 文件 | 现状职责 | 目标结构（Phase 4+） |
| --- | --- | --- | --- |
| `main.gd` | 1 | 对局场景编排：按玩家列表创建/移除玩家节点、分配出生点 | **+** 开局倒计时、比分初始化；把「胜负/比分」抽到 `scripts/game/score_manager.gd`（见 `01_core_loop.md §6`） |
| `player.gd` | 1 | 移动 / 视角 / 生命 / 开镜 / 权威控制 / 网络广播 | 保持；把 RPC 广播频率与插值参数外置（可选） |
| `music_manager.gd` | 1（Autoload） | 扫描 `music/*.ogg`，N/P 控制 | 无（已稳定） |
| `entities/` | 6 | bot / bot_manager / miku_model / miku_idle_motion / miku_procedural_pose / training_target(遗留) | bot 若进正式对局需联机同步（见 ADR-006 边界）；`training_target.gd` 已从场景移除，待删或归档 |
| `shooting/` | 10 | 四把武器 + 三层后坐力 + 摇晃 + 震动 + 音效 + 皮肤 + 外观 | 新增武器时按 `VARIANTS` / `SLOTS` 表扩展，不改框架 |
| `network/` | 1（Autoload） | ENet 建房/加入/断开、玩家列表、开局、伤害与位置 RPC | **+** `ScoreManager` 的 RPC 权威归属；掩体/人机的边界校验（见 §2.4） |
| `ui/` | 10 | HUD 7 元件 + Esc 菜单 + 死亡界面 + 人机面板 + 大厅 + 3D 检视 | **+** 比分板、结算面板 `match_result.tscn`（`01_core_loop.md §6`） |

> **计数说明**：任务书说「29 个脚本」，实测 `scripts/` 下为 **30 个 `.gd`**（`training_target.gd` 已从场景移除、脚本保留，
> 见 `README §3`）。此处按实测记录。

### 2.4 设计侧要求的工程接缝（来自 `99_consistency_review.md §4`）

| 优先级 | 工程项 | 关联 CONCERN | 本文档给出的架构落点 |
| --- | --- | --- | --- |
| P0 | 出生点四角化 | C-8 | ✅ **本次已改**（`scenes/main.tscn`，见 §5.4） |
| P1 | `Obstacles` 掩体 + `minimap_obstacle` 组 | `03_map` | 架构约定见 §4 / §5.3；具体摆放交 art-director（A4-01） |
| P2 | 小地图 `world_radius` | C-5 | ✅ **本次已改**（`minimap.gd`） |
| P3 | 掩体碰撞层规划 | C-9 | 决策见 `ADR-001` 关联影响 + 本文 §8.4 |
| — | 手雷服务器权威 | C-3 | 决策见 `ADR-006` |
| — | 人机刷新边界校验 | C-10 | 决策见 `ADR-006 §Consequences` |

---

## 3. 场景树与节点职责

### 3.1 `scenes/hub/hub.tscn`（大厅 · `project.godot` 主场景）

```
Hub (Control)
└── Center/Card/VBox
    ├── NameRow/NameEdit              昵称输入
    ├── HostRow/{HostPortEdit, HostButton}   建房（默认端口 7777）
    ├── JoinRow/{JoinIpEdit, JoinPortEdit, JoinButton}
    ├── StatusLabel / LocalIpLabel     状态与「本机 IP」提示（蓝盾 VPN 的 26.x 会出现在这里）
    ├── RoomPanel/{RoomTitle, PlayerList, StartButton, WaitLabel, LeaveButton}
    └── SoloButton                     单人试玩（离线直接进 main.tscn）
```
职责：纯 UI，全部逻辑转发给 `NetworkManager`（`hub.gd:47-76`）。**无游戏逻辑**。

### 3.2 `scenes/main.tscn`（对局场景）

```
Main (Node3D, main.gd)
├── WorldEnvironment            high_quality_environment.tres
├── DirectionalLight3D          阴影 4 Splits（directional_shadow_mode=2）、max_distance 100
├── Ground (StaticBody3D, layer=2, mask=0)      ← 400×400 水面（metallic 1.0 / roughness 0.06）
│   ├── CollisionShape3D (BoxShape3D 400×1×400)
│   └── MeshInstance3D (PlaneMesh 400×400 + water 材质)
├── SpawnPoints (Node3D)         ← 4 个 Marker3D（四角，见 §5.4）
├── Players (Node3D)             ← 运行期由 main.gd 按玩家列表填充（节点名 = peer id）
├── Bots (Node3D, bot_manager.gd) ← 运行期填充人机（仅本端）
├── HUD (CanvasLayer, hud.gd)
├── GameMenu (CanvasLayer, game_menu.gd)
├── BotPanel (CanvasLayer, bot_panel.gd)
└── DeathScreen (CanvasLayer, death_screen.gd)
```
**注意**：`Players` / `Bots` 是**空容器**，节点在运行期动态创建 —— 这是「迟到加入可见所有人」机制的基础（`main.gd::_sync_players`，`main.gd:25`）。

### 3.3 `scenes/player.tscn` 与摄像机链（架构核心）

```
Player (CharacterBody3D, layer=1, mask=3, player.gd)
├── CollisionShape3D            CapsuleShape3D 1.8 m（蹲/趴时改 height）
├── MikuModel (Node3D, miku_model.gd)      ← 站/蹲/趴的旋转与高度写在这里
│   ├── Placeholder (MeshInstance3D)        没有 .glb 时的占位胶囊
│   ├── WeaponMount (Node3D)                武器挂点（路径固定，绝不移动）
│   │   ├── Rifle   (rifle.tscn 实例)
│   │   ├── USP     (usp.tscn 实例)
│   │   ├── Knife   (knife.tscn 实例)
│   │   └── Grenade (grenade.tscn 实例)
│   └── [IdleMotion]                        ← 运行期由 MikuModel 插入（待机微动作）
│       └── [载入的 .glb 实例]
└── CameraPivot (Node3D, y=1.6)
    └── RecoilPivot (Node3D, recoil_system.gd)      ← 只写 rotation（三层后坐力）
        └── SwayPivot (Node3D, camera_sway.gd)      ← 只写 rotation/position（惯性 + bob）
            └── FreeLookPivot (Node3D)              ← 只写 rotation（Alt 自由视角）
                └── SpringArm3D (spring_length=3.5, collision_mask=2)
                    └── Camera3D (fov=75, screen_shake.gd)  ← 只写 h_offset/v_offset/rotation.z
```

**摄像机链的「各层只写自己的变换」契约**（`README §6.2`、`player.gd:8`）：

| 层 | 谁在写 | 写什么 | 谁在读 |
| --- | --- | --- | --- |
| `CameraPivot` | `player.gd::_rotate_camera()`（`player.gd:325`） | `rotation.y`（鼠标 yaw） | `player.gd::_get_move_direction()` / `_feed_subsystems()` |
| `RecoilPivot` | `recoil_system.gd::_process()` | `rotation = (visual+pattern pitch, yaw, 0)` | 无（纯表现） |
| `SwayPivot` | `camera_sway.gd::_process()`（`camera_sway.gd:67-68`） | `rotation` + `position.y`（bob） | 无 |
| `FreeLookPivot` | `player.gd::_update_free_look()`（`player.gd:268`） | `rotation`（Alt 视角） | 无 |
| `SpringArm3D` | `player.gd::_rotate_camera()`（`player.gd:327-328`） | `rotation.x`（鼠标 pitch，clamp） | 无 |
| `Camera3D` | `screen_shake.gd::_process()`（`screen_shake.gd:55-57`） | `h_offset` / `v_offset` / `rotation.z` | `hitscan` 方向（`weapon.gd:314`）、`compass`、`minimap`、`teammate_icons` |

> **关键不变量**：每层只动自己的节点，**互不叠加写同一个属性** → 后坐力 / 摇晃 / 震动可并行且可独立调参。
> `Camera3D` 既是「屏幕震动」的宿主，又是所有 hitscan 的**射线原点与朝向**来源（`weapon.gd:313-315`），
> 因此移动端平滑（`player.gd:283`）与震动不会污染射击方向（震动只写 offset，不写 basis）。

### 3.4 `scenes/bot.tscn`（人机）

```
Bot (CharacterBody3D, layer=1, mask=3, bot.gd)
├── CollisionShape3D
└── MikuModel (miku_model.gd)
    ├── Placeholder
    └── WeaponMount/Rifle (rifle.tscn 实例，仅作外观)
```
`bot.gd:69-72` 在 `_ready` 里**关掉 weapon 的 `process`/`physics_process` 并 `set_trigger_enabled(false)`** ——
武器只当外观，开火由 `bot.gd::_shoot()`（`bot.gd:144`）接管。这是「一套武器资源、两种使用者」的复用策略。

### 3.5 武器场景（`scenes/weapons/*.tscn`）

统一结构（`README §6.4`、`rifle.tscn` / `usp.tscn`）：

```
<Weapon> (Node3D, weapon.gd)          根：射击流程 + 导出数值
├── Model  (glb 实例)                   运行期由 WeaponVariant 替换
├── Muzzle (Marker3D)                   枪口（曳光弹 / 火光 / 音效的锚点）
├── MuzzleLight (OmniLight3D)
├── MuzzleFlash (MeshInstance3D)
└── GunAudio (AudioStreamPlayer3D, audio_3d.gd)
```
`knife.tscn` / `grenade.tscn` 结构相同但用 `knife.gd` / `grenade.gd`（无弹匣/开镜）。

### 3.6 `scenes/ui/*.tscn`

| 场景 | 根 | 结构要点 |
| --- | --- | --- |
| `hud.tscn` | `CanvasLayer`(`hud.gd`) | `Crosshair` / `Minimap` / `Compass` / `TeammateIcons` / `HealthRoot` / `AmmoPanel` / `KillFeed` / `Hint` / `LeaveButton`（`hud.tscn:26-210`） |
| `game_menu.tscn` | `CanvasLayer`(`game_menu.gd`) | `Panel/HBox/{LeftVBox(ModelList,Resume,Quit), RightVBox(WeaponButtons, ListsRow(VariantBox,SkinBox), Preview)}` |
| `death_screen.tscn` | `CanvasLayer`(`death_screen.gd`) | `Panel/VBox/RespawnButton` |
| `bot_panel.tscn` | `CanvasLayer`(`bot_panel.gd`) | `Panel/VBox/{CountLabel,Buttons(Add,Sub),ClearButton,CloseButton}` |

---

## 4. 组（group）契约表

> 项目的解耦全靠「场景组」。**任何组都是隐式接口**：写组的一方必须在文档里承诺「成员何时进/出、暴露什么」。

| 组名 | 成员（谁 add） | 谁读 | 契约（成员必须提供） | 生命周期 |
| --- | --- | --- | --- | --- |
| `player` | 本地玩家 `player.gd:125` | HUD / Minimap / Compass(经 camera) / GameMenu / DeathScreen / Bot / BotManager / BotPanel / GrenadeProjectile | `health_changed`·`died`·`weapon_changed` 信号；`get_health()`·`take_damage()`·`respawn()`·`set_input_blocked()`；`is MultiplayerAuthority` 唯一 | 对局内常驻 1 个（本端） |
| `recoil` | 本地玩家 `player.gd:126` | HUD（`hud.gd:75`） | `get_spread()` | 随本地玩家 |
| `camera` | 本地玩家 `player.gd:127` | Minimap（`minimap.gd:58`） / Compass（`compass.gd:30`） / TeammateIcons（`teammate_icons.gd:25`） | 是 `Camera3D`（读 `global_transform.basis` / `unproject_position`） | 随本地玩家 |
| `weapon` | 本地玩家**在装备时** add / 收起时 remove（`player.gd:420-433`） | HUD（`hud.gd:87`） | `ammo_changed`·`aiming_changed`·`reload_started/finished`·`hit_confirmed` 信号；`get_mag()`·`get_reserve()`·`is_reloading()`·`get_reload_progress()`·`display_name` | 随「当前武器」动态变（空手时无成员） |
| `friendly` | 远端玩家 `player.gd:138` | Minimap（绿点，`minimap.gd:116`） / TeammateIcons（`teammate_icons.gd:48`） / Weapon·Knife 伤害路由（`weapon.gd:353`、`knife.gd:100`） | Node3D；可带 `player_name`（图标显示） | 每个远端玩家 1 个 |
| `enemy` | 人机 `bot.gd:66`（死亡时 `remove`，`bot.gd:192`）/ 训练靶 `training_target.gd:32` | Minimap（红点，`minimap.gd:116`） | Node3D；可带 `alive`（false 则跳过绘制） | 人机存活期间 |
| `bot` | 人机 `bot.gd:67` | Weapon 伤害路由（跳过 RPC，`weapon.gd:351`） | 标记「本端独有的本地对象，伤害不走 RPC」 | 人机存活期间 |
| `bot_manager` | `bot_manager.gd:21` | BotPanel（`bot_panel.gd:68`） | `count_changed` 信号；`change_count()`·`get_alive_count()`·`max_bots` | 对局场景 1 个 |
| `hud` | `hud.gd:40` | NetworkManager（`network_manager.gd:260`，推送联机击杀信息） | `push_kill(text, is_kill)` | 对局场景 1 个 |
| `game_ui` | `game_menu.gd:27` / `death_screen.gd:16` / `bot_panel.gd:20` | 三者互相（互斥，见 §6.3） | `is_open()` / `open_ui()` / `close_ui()` | 对局场景 3 个 |
| `minimap_obstacle` | **当前无成员**（掩体未创建） | Minimap（`minimap.gd:43`） | 节点下需有 `CollisionShape3D` + `BoxShape3D`（读位置与 XZ 尺寸） | 掩体创建后（P1 工程项） |

> **契约要点**：
> 1. `weapon` 组**故意不自动注册**（`weapon.gd:90` 注释）—— 只有**本地玩家**在装备时把武器 `add_to_group("weapon")`，
>    否则远端玩家的武器会被 HUD 找到，导致 HUD 显示别人的弹药。`recoil` 组同理（`recoil_system.gd:73` 注释）。
> 2. `enemy` 与 `friendly` 都是「小地图数据源」，**没有敌我判定语义**（FFA 模式：所有其他玩家都在 `friendly` 组）。
>    这也是 `99_consistency_review.md` C-2（无队伍系统）的架构根源。
> 3. `game_ui` 是**互斥组**：任一成员 `open_ui` 时会遍历组关闭其它成员（`game_menu.gd:78`、`bot_panel.gd:46`、`death_screen.gd:45`）。

---

## 5. 关键数据流

### 5.1 输入 → 移动/武器 → 表现 → HUD（主数据流）

```
InputMap(action)                                    project.godot:35-141
   │
   ├─ 玩家移动类（move_* / jump / sprint / crouch / prone / view_toggle / free_look）
   │     └─ player.gd::_physics_process()  player.gd:191   （先判 is_multiplayer_authority + input_blocked）
   │           ├─ 速度积分 + move_and_slide()               player.gd:203-219
   │           ├─ _feed_subsystems() → recoil.set_movement_amount / sway.set_motion   player.gd:302-309
   │           ├─ _update_stance() → 胶囊/镜头高度 + 模型姿态  player.gd:239-259
   │           └─ _model.update_animation() → MikuModel        player.gd:228
   │
   ├─ 开火 / 开镜（shoot / aim）  → 武器脚本自读 Input（不是 player 转发）
   │     ├─ weapon.gd::_process()  weapon.gd:145   （先判 authority、active、_trigger_enabled）
   │     │     ├─ _update_trigger() → _fire()        weapon.gd:251/275
   │     │     │     ├─ _recoil.fire_shot()          三层同时生效   recoil_system.gd:78
   │     │     │     ├─ _shake.add_trauma(shake_per_shot)          screen_shake.gd:37
   │     │     │     ├─ _audio.play_shot()           音高/音量 ±5%  audio_3d.gd:47
   │     │     │     └─ _hitscan() → _deal_damage()  weapon.gd:311/346
   │     │     ├─ _update_aiming() → camera.fov + player.set_aiming()   weapon.gd:238
   │     │     └─ _update_reload()                   weapon.gd:223
   │     ├─ knife.gd::_process()   knife.gd:56
   │     └─ grenade.gd::_process() grenade.gd:69
   │
   ├─ 换弹（reload）→ 当前武器的 `_process` 自读 Input（长按 3 s 补满，weapon.gd:171 / grenade.gd:76）
   │
   ├─ 菜单类（ui_cancel / bot_panel）→ game_menu.gd:38 / bot_panel.gd:29 的 _unhandled_input
   │
   └─ 音乐（music_next / music_pause）→ MusicManager._unhandled_input  music_manager.gd:58

         ── 表现层轮询/信号 ──
HUD：hud.gd::_process() 每帧读 recoil.get_spread()（hud.gd:61）→ crosshair.set_spread()
     hud.gd::_bind() 连 player.health_changed / weapon_changed / weapon.ammo_changed/...  hud.gd:73-108
Minimap / Compass / TeammateIcons：各自 _process 里组查找 camera/player/enemy/friendly 后 queue_redraw()
```

**关键设计点**：
- **武器自己读 Input**（`weapon.gd:171/181/252`），不是 `player.gd` 把输入转给武器。好处：四把武器各自管自己的
  「开火语义」（连发 / 半自动 / 挥砍 / 投掷）；代价：`input_blocked` 必须**同时**作用于 player 与武器
  （`player.gd::set_input_blocked` 释放鼠标 → `capture_mouse/release_mouse` → `set_trigger_enabled`，`player.gd:455-464`）。
- **表现系统读的是「接口」而非「数据」**：HUD 每帧 `recoil.get_spread()`，不订阅 recoil 的每发事件 —— 因为扩散是连续量。

### 5.2 三层后坐力 → 摄像机 + 准星（P1「每一发都能被感受到」的架构落点）

```
weapon._fire()  →  recoil.fire_shot()  recoil_system.gd:78
                       ├─ 第1层 视觉后坐力：_visual_pitch/yaw（每发瞬时 + 快速归零）
                       ├─ 第2层 弹道模式：_pattern_pitch/yaw（固定种子、可背）
                       └─ 第3层 扩散 _spread（连射/移动涨，静止/开镜缩）
                                   │
     ┌─────────────────────────────┼──────────────────────────────┐
     ▼                             ▼                              ▼
RecoilPivot.rotation        crosshair 间距（5→34 px）       actual bullet deviation
（镜头真的被顶起来）          hud.gd:61 → crosshair          weapon._hitscan() 用
（recoil_system.gd:129）     set_spread()                    recoil.get_bullet_deviation_radians()（weapon.gd:318）
```
> **同源**：准星大小与实际散布都来自**同一个 `_spread`** —— 这是「准星不说谎」的架构保证（P1）。

### 5.3 武器外观 / 皮肤装配链（详见 ADR-003）

```
player._equip_slot(slot)                        player.gd:412
  └─ apply_variant(WeaponVariant.get_selected)  player.gd:427  → WeaponVariant.apply_to()  weapon_variant.gd:169
        ├─ 换 Model 子节点（load glb → 设 transform → hide/trim → 替换）
        ├─ 搬 Muzzle/MuzzleLight/MuzzleFlash/GunAudio
        └─ **最后**重新 apply_skin(WeaponSkin.get_selected)  weapon_variant.gd:228
  └─ apply_skin(WeaponSkin.get_selected)        player.gd:431  （换外观已重套过，这里再保一次）
```
> **顺序不变量**：换外观 → 重建网格 → **必须**重套皮肤（`weapon_variant.gd:227-229`），否则皮肤丢失。见 ADR-003。

### 5.4 出生点分配（本次修正后）

```
main.gd::_make_player(id)  main.gd:39    → position = _spawn_point_for(id)
main.gd::_spawn_point_for(id)  main.gd:48 → SpawnPoints.get_child(id % count).position
```
**修正后** `scenes/main.tscn` 的 4 个 Marker3D（四角、与 `03_map §5.2` 分区 A/B/C/D 对齐）：

| 节点 | 位置 (x, y, z) | 对应分区 |
| --- | --- | --- |
| `Spawn1` | `(-32, 0.5, -32)` | A · 西北 |
| `Spawn2` | `(32, 0.5, -32)` | B · 东北 |
| `Spawn3` | `(32, 0.5, 32)` | C · 东南 |
| `Spawn4` | `(-32, 0.5, 32)` | D · 西南 |

满足 `03_map §6 AC-1`：各轴 `|坐标| ≥ 24`、任意两点间距 ≥ 45 m、对角线 ≈ **90.5 m**（≥ 90）、离边界 ≥ 8 m。
轮转逻辑 `id % count` **未改动**（任务硬约束）。

---

## 6. 交互与输入屏蔽模型

### 6.1 谁消费哪个输入（详见 `control_checklist.md`）

| 输入 | 消费层 | 脚本 |
| --- | --- | --- |
| `move_*` / `jump` / `sprint` / `crouch` / `prone` / `view_toggle` / `free_look` | player | `player.gd`（`_physics_process` / `_unhandled_input`） |
| `shoot` / `aim` / `reload` | 当前武器 | `weapon.gd` / `knife.gd` / `grenade.gd`（各自 `_process`） |
| `weapon_1~4` | player | `player.gd::_unhandled_input` → `_equip_slot` |
| `ui_cancel` | game_menu（优先）/ bot_panel | `game_menu.gd:38` / `bot_panel.gd:36` |
| `bot_panel`（H） | bot_panel | `bot_panel.gd:29` |
| `music_next` / `music_pause` | MusicManager | `music_manager.gd:58` |

### 6.2 `input_blocked` 双闸门

菜单 / 死亡界面 / 人机面板打开时调用 `player.set_input_blocked(true)`（`player.gd:375`）：
- **玩家侧**：`_physics_process` 与 `_unhandled_input` 直接 return（`player.gd:156/198/201`）；
- **武器侧**：`set_input_blocked` 内部会 `release_mouse()` → 当前武器 `set_trigger_enabled(false)`（`player.gd:461-464`），
  武器 `_process` 里 `if not _trigger_enabled: _update_reload(delta); return`（`weapon.gd:166-168`）
  → **屏蔽射击/开镜/换弹，但换弹计时继续走**（README §8.1 明确要求的行为）。

### 6.3 三界面互斥（`game_ui` 组）

`game_menu` / `death_screen` / `bot_panel` 都在 `game_ui` 组；任一个 `open_ui()` 时遍历组关闭其它成员。
**特殊**：`game_menu.open_ui()` 会先查 `player.get_health() <= 0` 则 return（`game_menu.gd:55`）—— 死亡时 Esc 不由菜单接管。

---

## 7. 网络模型（阶段 3）

### 7.1 拓扑与权限

| 项 | 结论 | 出处 |
| --- | --- | --- |
| 拓扑 | 房主 = 服务器（`create_server(7777, MAX_PLAYERS-1)`），客户端直连 | `network_manager.gd:51` |
| 上限 | 4 人（`MAX_PLAYERS := 4`） | `network_manager.gd:22` |
| 玩家列表 | **服务器权威**：`_players` 字典（peer_id → 昵称），服务器广播 `_sync_player_list.rpc` | `network_manager.gd:35/190` |
| 节点创建 | 各端**各自本地创建**同一批玩家节点（不用 `MultiplayerSpawner`），节点名 = `str(peer_id)` | `main.gd:39-44` |
| 权限 | `player.set_multiplayer_authority(id)` —— 每个玩家节点由**它自己那端**做主 | `main.gd:44` |
| 「我是不是权威」 | `is_multiplayer_authority()` 门控输入、摄像机、网络广播 | `player.gd:104/154/192` |

> **为什么不用 `MultiplayerSpawner`**：`main.gd:4-6` 注释 —— 各端按玩家列表本地建节点，
> 「对局进行中才加入」的玩家也能**立刻**看到所有人（迟到加入），而不用等 spawner 复制。
> 代价：节点生成是**确定性重建**（各端跑同一段代码），不是增量复制 —— 这是本作有意的简单化。见 `ADR-002`。

### 7.2 RPC 清单（时序）

| RPC | 注解 | 语义 | 出处 |
| --- | --- | --- | --- |
| `_register_name` | `any_peer, call_remote, reliable` | 客户端 → 服务器：上报昵称 | `network_manager.gd:175` |
| `_sync_player_list` | `authority, call_remote, reliable` | 服务器 → 全体：广播玩家列表 | `network_manager.gd:190` |
| `_start_match` | `authority, call_remote, reliable` | 服务器 → 全体：切到对局场景 | `network_manager.gd:197` |
| `_join_game_in_progress` | `authority, call_remote, reliable` | 服务器 → 单人：对局已开始，直接进场景 | `network_manager.gd:205` |
| `net_player_state` | `any_peer, call_remote, unreliable_ordered` | 每 ~30 Hz：位置 + 模型 yaw + **血量显示值**（ADR-008：搭既有广播的便车，不新开 RPC） | `network_manager.gd:213` |
| `net_fire_effects` | `any_peer, call_remote, unreliable` | 开火：枪口火光 / 曳光弹 / 枪声 | `weapon.gd:303` |
| `net_grenade` | `any_peer, call_remote, unreliable` | 手雷：投掷物的 origin + velocity（各端各自模拟） | `network_manager.gd:224` |
| `apply_network_damage` | `any_peer, call_remote, reliable` | 对**玩家**的伤害：只发给被击中的那一端 | `player.gd:342` |
| `apply_damage_to_target` | `any_peer, call_local, reliable` | 对**场景物件**（训练靶）的伤害：所有端一起结算 | `network_manager.gd:237` |

### 7.3 位置同步时序（~30 Hz + 本端平滑）

```
本端 player._physics_process  player.gd:231-235
   every NET_SYNC_INTERVAL (0.033 s) →  NetworkManager.net_player_state.rpc(pos, yaw)
                                          network_manager.gd:213（unreliable_ordered）
远端：
   收到 → 找到 scene/Players/<sender_id>  →  node.apply_network_state(pos, yaw)   player.gd:295
   每帧 player._physics_process（非权威分支）  player.gd:283
        →  global_position.lerp(_net_target_position, 1-exp(-NET_SMOOTH_SPEED*dt))  NET_SMOOTH_SPEED=14
        →  按位移估算速度驱动模型姿态（update_animation）
```
> **性质**：这是**状态广播 + 客户端插值**，不是服务器权威 / 回滚。高延迟下会抖动（`README §12` 已记录），
> 局域网 / 蓝盾 VPN 场景够用。决策过程见 `ADR-002`。

### 7.4 伤害时序的分流（重要）

`weapon.gd::_deal_damage()`（`weapon.gd:346`）按目标类型分三路：

| 目标 | 条件 | 行为 |
| --- | --- | --- |
| 人机（`bot` 组） | `collider.is_in_group("bot")` | **纯本地结算**，不走 RPC（人机各端独立） |
| 其他玩家（`friendly` 组） | 联机时 | `apply_network_damage.rpc_id(对方 authority, damage, 我的名字)` —— **只让被打的那端扣血** |
| 场景物件（训练靶等） | 联机时 | `NetworkManager.apply_damage_to_target.rpc(...)` —— **所有端一起结算** |

> **已知不一致**：手雷爆炸走 `grenade_projectile.gd::_damage_nearby()`，**只结算爆点附近的本地玩家**（`grenade_projectile.gd:67`），
> 会产生「我端扣血、他端没扣」的穿帮。这是有意保留的简单化，见 `ADR-006`。

---

## 8. 渲染 / 物理配置与架构约束

### 8.1 渲染

- **Forward+**（`project.godot:20`）：SSR、体积雾、SDFGI 的前提。
- **Environment**（`high_quality_environment.tres`）：ACES tonemap（white 6.0）、Glow（HDR threshold 0.9）、
  SSAO（radius 0.5 / intensity 2.0）、**SSR max_steps 96**（水面反射）、体积雾 density 0.004。**SDFGI 关闭**。
- **TAA 开 / MSAA 关 / 各向异性 ×8**（`project.godot:150-151`）。
- **水面**：`main.tscn` 的 `Ground/MeshInstance3D`，400×400 `PlaneMesh` + `StandardMaterial3D`（`metallic 1.0` / `roughness 0.06`）。
  靠天空辐射 + SSR 反射云层与角色。
- **可选 FSR 2.2**：`README §4` 记录 `scaling_3d/mode=2, scale=0.77`（当前未启用）。

### 8.2 物理

- **Jolt Physics**（`project.godot:145`）—— 见 `ADR-001`。
- 碰撞层现状：

| 层 | 谁用 | 说明 |
| --- | --- | --- |
| layer 1 | 玩家 / 人机（`player.tscn:22`、`bot.tscn:16`） | `collision_mask = 3`（撞 ground + 自身层） |
| layer 2 | `Ground`（`main.tscn:39`）、`SpringArm3D.collision_mask=2`（`player.tscn:61`） | 地面 + 相机遮挡层 |

- **已知隐患（C-9）**：若掩体放在 **layer 2**，`SpringArm3D`（mask=2）会在贴墙时收缩相机；
  若不放在 layer 2，掩体挡不住相机（穿墙视角）。**决策建议见 §8.4 / ADR-001 关联**。

### 8.3 音频

- 全项目音效均为**代码程序化合成**（`audio_3d.gd::_build_gunshot`、`bot.gd::_build_hit_sound`、
  `grenade_projectile.gd::_build_boom`），无外部音频素材；`music/*.ogg` 仅作 BGM。
- 已知缺口：玩家自己受伤**无音效**（`README §12`、`99_review C-11`）。

### 8.4 待评估架构项（未在本次改动内，供 Phase 4）

1. **掩体碰撞层**（C-9）：建议新增 **layer 3 = 「掩体」**，`SpringArm3D.collision_mask` 增加该位（或掩体同时放 layer 2+3），
   玩家 `collision_mask` 增加该位。需 art-director 掩体规格（A4-01）落地后实测。
2. **人机刷新边界校验**（C-10）：`bot_manager.gd::_random_spawn_position()`（`bot_manager.gd:55`）当前无边界判断，
   应加「在 80×80 内 + 不在掩体内」的校验。
3. **`ScoreManager` 权威归属**（C-1）：建议房主（`peer_id=1`）为比分权威，客户端只上报「我击杀了 X」意图 —— 见 `01_core_loop.md §6`。

---

## 9. 已知架构缺口（与设计文档对齐）

| 缺口 | 架构根源 | 计划 |
| --- | --- | --- |
| 无胜负 / 比分 / 结算 | `main.gd` / `hud.gd` 无此状态；`network_manager.gd` 无 RPC | Phase 4：`scripts/game/score_manager.gd` + HUD 比分板 + `match_result.tscn` |
| 无队伍系统（C-2） | `player._setup_remote_player()` 把所有远端玩家放进 `friendly`（`player.gd:138`）；伤害判定按 `friendly` 组 | MVP 用 FFA 规避；TDM 需引入 `team` 字段贯穿伤害 |
| 掩体缺失 | `main.tscn` 无 `Obstacles` 节点；`minimap_obstacle` 组为空 | P1 工程项 + art-director 规格 |
| 皮肤 / 外观 / 角色仅本端 | `WeaponSkin` / `WeaponVariant` 的选择是**本端静态字典**，不走 RPC | 见 `ADR-003` / `ADR-006` 边界 |
| 人机仅本端 | `bot_manager.gd` 无 RPC；`weapon._deal_damage` 对 `bot` 组跳过 RPC | 见 `ADR-006` |
| 无测试框架 | 全项目无 `tests/` | Phase 4（主理人另派） |
| `training_target.gd` 遗留 | 已从场景移除，脚本保留 | 待删或归档 |

---

## 10. 变更记录

| 日期 | 变更 | 作者 |
| --- | --- | --- |
| 2026-10-06 | 初版（回溯式架构）+ 出生点四角化 + 小地图半径 + README 换弹口径 | 程基岩（E3-01） |
