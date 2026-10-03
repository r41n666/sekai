# MikuHighQualityWalk

第三人称射击游戏原型（Godot 4 + Forward+）。角色暂用胶囊体占位，后续替换为初音未来 `.glb` 模型。

- **阶段 1（已完成）**：高画质 3D 小场景自由走动 + 本地 `.ogg` 歌单播放
- **阶段 2（已完成）**：战地 5 风格 HUD + 射击手感（三层后坐力 / 动态准星 / 相机摇晃 / 屏幕震动 / 3D 音效）
- **阶段 3（已完成·基础版）**：局域网联机（Hub 大厅建房/加入 + 玩家生成与位置同步 + 开火特效/伤害 RPC）
- **阶段 4（管线已就绪）**：初音未来模型 —— 把 `assets/models/miku/miku.glb` 放进去即自动替换占位胶囊，含 Idle/Walk/Run/Jump 动画与武器挂手

---

## 一、阶段划分与当前进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 阶段 1 | 高画质 3D 小场景自由走动 + 本地 `.ogg` 歌单 | ✅ 已完成 |
| 阶段 2 | 战地 5 风格 HUD + 射击手感 | ✅ 已完成（武器已换成真实模型：M4A4 / 粉色 USP / 青花瓷手雷；蝴蝶刀仍是占位） |
| 阶段 3 | 局域网联机（蓝盾 VPN + ENetMultiplayerPeer） | ✅ 已完成（基础版；断线重连等见 TODO） |
| 阶段 4 | 初音未来模型导入与动画替换 | 🟡 已接入 4 个模型（主模型 + 3 个 PMX 转换模型）；模型无动画剪辑，用程序化步态 |
| 阶段 5 | 菜单 / 死亡重生 / 人机系统（Esc 菜单、重生、H 人机） | ✅ 已完成（人机仅本端生成、不联机同步） |

---

## 二、快速开始

1. 安装 **Godot 4.3 或更高版本**（本项目在 **Godot 4.7.2 stable** 上验证通过；用旧版打开时若提示升级项目版本，按提示继续即可）。
2. 用 Godot 打开本目录下的 `project.godot`。
3. 按 **F5** 运行，进入**联机大厅（Hub）**：可以「单人试玩（离线）」，也可以「创建房间 / 加入房间」联机（用法见第八节）。

命令行验证（无需打开编辑器）：

```powershell
# 只导入资源并检查是否有解析/导入错误
godot --headless --path . --import

# 无窗口跑 300 帧，检查运行时错误
godot --headless --path . --quit-after 300
```

### 操作说明

| 按键 | 功能 |
| --- | --- |
| `W` `A` `S` `D` | 前后左右移动 |
| 鼠标移动 | 转动视角（第三人称轨道相机） |
| `Shift` | 加速跑 |
| `Space` | 跳跃 |
| **`Ctrl`（按住）** | **蹲下（移动变慢、镜头降低）** |
| **`Z`** | **趴下 / 起身（模型放平、移动最慢）** |
| **`V`** | **第一人称 / 第三人称切换** |
| **`Alt`（按住）** | **自由视角：只转镜头，不影响人物朝向** |
| **鼠标左键** | **开火 / 挥刀 / 投掷手雷（取决于当前武器）** |
| **鼠标右键** | **开镜（仅枪械；FOV 75→60、灵敏度降低）** |
| **`R`** | **换弹（2.2 秒，打空自动换弹）；长按 3 秒 = 备弹补满** |
| **`1` `2` `3` `4`** | **主武器 / 副武器 / 蝴蝶刀 / 手雷；同一键再按一次 = 空手** |
| **`Esc`** | **打开 / 关闭菜单（角色选择、退出游戏）；菜单打开时释放鼠标并屏蔽移动 / 开火** |
| **`H`** | **人机管理面板（增减 / 清空人机；打开时同样释放鼠标并屏蔽输入）** |
| `N` / `P` | 下一首音乐 / 暂停继续 |
| HUD 右上角「返回大厅」 | 退出对局回到 Hub（联机时同时退出房间） |

### 场景里有什么

- **白云蓝天 + 水面地面**（复刻 sky.jpeg 的构图）：400×400 的镜面水面（反射云层与角色）+ 程序化云层天空。
- 场景里没有其它实体（道具 / 训练靶 / 队友占位都已移除），只留风景和初音未来；联机时其他玩家照常生成。

---

## 三、项目结构

```text
MikuHighQualityWalk/
├── project.godot                          # 项目设置：项目名 / Forward+ / TAA / 输入映射 / Autoload
├── scenes/
│   ├── hub/
│   │   └── hub.tscn                       # ✅ 联机大厅：创建/加入房间、玩家列表、开始对战、单人试玩
│   ├── main.tscn                          # 对局场景：Environment + 平行光 + 水面地面 + 出生点 + HUD
│   ├── player.tscn                        # 玩家：移动体 + 占位胶囊 + 武器 + 摄像机链
│   ├── bot.tscn                           # ✅ 人机：CharacterBody3D + MikuModel + rifle 外观
│   ├── weapons/
│   │   ├── rifle.tscn                     # ✅ 主武器：MK-1 突击步枪（占位方块，700 发/分全自动）
│   │   ├── usp.tscn                       # ✅ 副武器：USP（12/24、半自动）
│   │   ├── knife.tscn                     # ✅ 蝴蝶刀（近战，挥砍）
│   │   ├── grenade.tscn                   # ✅ 手雷（手持模型）
│   │   └── grenade_projectile.tscn        # ✅ 手雷投掷物（引信 + 爆炸特效）
│   └── ui/
│       ├── hud.tscn                       # ✅ HUD：准星 / 小地图 / 指南针 / 队友图标 / 血条 / 弹药 / 击杀日志 / 返回大厅
│       ├── game_menu.tscn                 # ✅ Esc 菜单：角色选择（扫描 models/*/*.glb）/ 退出游戏
│       ├── death_screen.tscn              # ✅ 死亡界面：「你已阵亡」+ 重生按钮
│       └── bot_panel.tscn                 # ✅ H 键人机管理面板：增减 / 清空
├── scripts/
│   ├── main.gd                            # ✅ 对局场景：按玩家列表本地创建玩家（离线单人 / 联机共用）
│   ├── player.gd                          # ✅ 移动 / 视角 / 跳跃 / 生命值 / 开镜状态 / 驱动后坐力与摇晃 / 联机权威控制
│   ├── music_manager.gd                   # ✅ Autoload：扫描 music/ 下的 .ogg，N/P 控制
│   ├── entities/
│   │   ├── training_target.gd             # 训练靶（已从场景移除，脚本保留备用）
│   │   ├── miku_model.gd                  # ✅ 初音模型挂载点：加载 miku.glb + 尺寸适配 + 动画 / 武器挂手
│   │   ├── miku_procedural_pose.gd        # ✅ 无动画模型的程序化姿态（放下 T-pose、走/跑/跳摆动）
│   │   ├── bot.gd                         # ✅ 人机：追踪 / 周期射击 / 受击后仰 + 闪白 + 音效 / 倒地
│   │   └── bot_manager.gd                 # ✅ 人机刷新与数量管理（玩家周围 8~18 m，仅本端）
│   ├── shooting/
│   │   ├── weapon.gd                      # ✅ 射击流程：连发 / 弹匣 / 换弹（长按 R 补满）/ ADS / hitscan / 曳光弹
│   │   ├── knife.gd                       # ✅ 蝴蝶刀：近战挥砍 hitscan
│   │   ├── grenade.gd                     # ✅ 手雷：投掷 + 数量 + 长按 R 补满
│   │   ├── grenade_projectile.gd          # ✅ 投掷物：引信、爆炸特效与范围伤害
│   │   ├── recoil_system.gd               # ✅ 三层后坐力：视觉后坐力 + 弹道偏移模式 + 扩散值
│   │   ├── camera_sway.gd                 # ✅ 相机摇晃：鼠标惯性滞后 + 行走晃动 + 侧倾
│   │   ├── screen_shake.gd                # ✅ 屏幕震动：Trauma / FastNoiseLite 噪声
│   │   └── audio_3d.gd                    # ✅ 3D 枪声：音高/音量 ±5% 随机 + 程序化占位枪声
│   ├── ui/
│   │   ├── hub.gd                         # ✅ 联机大厅界面逻辑
│   │   ├── hud.gd                         # ✅ HUD 根：信号绑定与数据分发
│   │   ├── game_menu.gd                   # ✅ Esc 菜单：角色选择 / 退出游戏 / 屏蔽输入
│   │   ├── death_screen.gd                # ✅ 死亡界面：监听 died 信号 + 重生
│   │   ├── bot_panel.gd                   # ✅ H 键人机面板：增减 / 清空人机
│   │   ├── crosshair.gd                   # ✅ 动态准星（扩散缩放 / 命中标记 / 换弹环）
│   │   ├── minimap.gd                     # ✅ 小地图（_draw()：障碍物 / 敌我 / 视野扇形 / N 标记）
│   │   ├── compass.gd                     # ✅ 顶部指南针（N/E/S/W + 刻度）
│   │   └── teammate_icons.gd              # ✅ 队友图标（3D 投影 + 贴边）
│   └── network/
│       └── network_manager.gd             # ✅ Autoload：ENet 建房/加入/断开、玩家列表、开局与生成协调、伤害与击杀 RPC
├── assets/
│   ├── environments/
│   │   ├── high_quality_environment.tres  # ✅ 程序化云层天空 / ACES / Glow / SSAO / SSR / 体积雾
│   │   ├── grasslands_sunset_4k.hdr       # 备选 HDRI（草原黄昏，当前未启用，可自行换用）
│   │   └── sky.jpeg                       # 参考图（白云蓝天 + 水面反射构图）
│   └── models/
│       ├── miku/                          # 主模型 miku.glb（自动加载，见 miku_model.gd）
│       ├── miku_navy/                     # 小海军初音（由 PMX 转换，见 tools/pmx2glb.py）
│       ├── miku_maid/                     # 猫猫女仆 1 / 2（由 PMX 转换）
│       └── weapons/                       # ✅ M4A4 / 粉色 USP / 青花瓷手雷（glb）
├── tools/
│   ├── pmx2glb.py                         # ✅ PMX(MMD) → glb 转换器（BMP 贴图转 PNG / 野顶点剔除 / 贴图去重 / 朝向归一）
│   ├── obj2glb.py                         # ✅ OBJ → glb（武器模型用，含贴图内嵌）
│   └── blend2glb.py                       # ✅ Blender 无头模式导出 glb（备用管线）
├── music/
│   └── README.md                          # ✅ 歌单目录说明（把你的 .ogg 放这里）
└── README.md
```

---

## 四、高画质渲染配置

渲染后端：**Forward+**（`rendering/renderer/rendering_method="forward_plus"`）。

### Environment 参数（[high_quality_environment.tres](assets/environments/high_quality_environment.tres)）

| 类别 | 参数 | 值 |
| --- | --- | --- |
| Background | Background Mode / Material | Sky / `ProceduralSkyMaterial`（无 HDR 素材时的回退） |
| Ambient | Source / Energy | Sky / 1.0 |
| Tonemap | Mode / Exposure / White | **ACES** / 1.0 / 6.0 |
| Glow | Enabled / Bloom / HDR Threshold | ✅ / 0.2 / 0.9 |
| SSAO | Enabled / Radius / Intensity / Light Affect | ✅ / 0.5 / 2.0 / 1.0 |
| SSR | Enabled / Max Steps | ✅ / 96（水面反射用） |
| SDFGI | Enabled | ❌（场景只剩水面 + 角色，省性能） |
| Volumetric Fog | Enabled / Density | ✅ / 0.004 |

### 换成 HDR 天空（推荐）

1. 下载一张 `.hdr` 全景图（例如 [Poly Haven](https://polyhaven.com/hdris) 的 CC0 素材）。
2. 用 Godot 打开 `assets/environments/high_quality_environment.tres`。
3. 把 `Sky` 资源的 `Sky Material` 从 `ProceduralSkyMaterial` 改成 `PanoramaSkyMaterial`，拖入 `.hdr`。
4. （可选）把 `Sky.process_mode` 设为 `Realtime`。

### 天空与水面（sky.jpeg 效果）

- **天空**：`ProceduralSkyMaterial` —— 蓝天渐变 + **程序化云层**（`sky_cover` 用一张无缝噪声纹理做云量），
  想换照片级 HDRI：把 `Sky Material` 换成 `PanoramaSkyMaterial` 并拖入 `.hdr`
  （项目里自带的 `grasslands_sunset_4k.hdr` 是草原黄昏 HDRI，云不多）。
- **水面**：主场景地面是 400×400 的镜面平面（`metallic 1.0 / roughness 0.06`），靠天空辐射 + SSR 反射云层和角色；
  想调"水感"改 `scenes/main.tscn → Ground/MeshInstance3D` 的材质（金属度/粗糙度/水色）。

### 抗锯齿 / 性能

- **已开启 TAA**，**已关闭 MSAA**；8x 各向异性过滤；Jolt Physics。
- **FSR 2.2（可选）**：帧率不够时在 `项目设置 → Rendering → Scaling 3D` 里选 `FSR 2.2`、`Scale 0.77`
  （或取消注释 `project.godot` `[rendering]` 段的 `scaling_3d/mode=2` 与 `scaling_3d/scale=0.77`）。
- Windows 默认走 **D3D12** 驱动；如遇兼容问题，删掉 `project.godot` 里的 `rendering_device/driver.windows` 一行即可回退 Vulkan。

---

## 五、音乐系统（本地歌单）

`scripts/music_manager.gd` 作为 **Autoload**（`MusicManager`）随游戏自动加载，启动即播放。

1. 把 `.ogg` 歌曲文件放进 `music/` 目录。
2. 重启游戏（Godot 需要先导入音频资源）。
3. `N` 下一首，`P` 暂停 / 继续。默认音量 **-6 dB**。

细节、格式转换（ffmpeg 命令）、顺序/随机/循环切换见 **[music/README.md](music/README.md)**。

---

## 六、HUD 与射击手感（阶段 2）

### 6.1 HUD 元件

| 屏幕位置 | 元件 | 实现 | 数据来源 |
| --- | --- | --- | --- |
| 中心 | 动态准星 | `crosshair.gd` | `RecoilSystem.get_spread()` → 间距 5→34 px；开镜收缩；命中标记；换弹进度环 |
| 左上 | 小地图 | `minimap.gd`（`_draw()`） | 玩家 `player` 组、摄像机 `camera` 组、`enemy`/`friendly` 组、`minimap_obstacle` 组的 BoxShape3D |
| 顶部 | 指南针 | `compass.gd`（`_draw()`） | 摄像机偏航角（-Z 为北、+X 为东） |
| 屏幕边缘 | 队友图标 | `teammate_icons.gd` | `friendly` 组，3D 投影 + 出屏贴边，显示名字与距离 |
| 底部中央 | 生命值 | `hud.gd` | `PlayerController.health_changed` 信号 |
| 右下 | 弹药 / 装备 | `hud.gd` | `Weapon.ammo_changed` / `reload_*` 信号 |
| 右上 | 击杀日志 | `hud.gd` | `Weapon.hit_confirmed` 信号（击杀时写入，4.5 秒淡出） |

HUD 与游戏逻辑**不做硬引用**，全部通过场景组（`player` / `weapon` / `recoil` / `camera` / `enemy` / `friendly`）
与信号连接，方便后续联机时替换或增加数据源。HUD 已实例化在 `main.tscn` 中。

### 6.2 三层后坐力（[recoil_system.gd](scripts/shooting/recoil_system.gd)）

摄像机链：
`CameraPivot(鼠标 yaw) → RecoilPivot(后坐力) → SwayPivot(摇晃) → SpringArm3D(鼠标 pitch) → Camera3D(屏幕震动)`
各层只写自己的节点变换，互不干扰（叠加关系）。

| 层 | 作用 | 关键参数（默认值） |
| --- | --- | --- |
| 1 · 视觉后坐力 | 每发瞬时上抬 + 随机左右抖动，快速 lerp 归零 | `visual_kick_pitch 0.55°`、`visual_kick_yaw 0.22°`、`visual_recovery 14` |
| 2 · 弹道偏移模式 | 固定可学习的喷射弹道：先垂直爬升再左右漂移，停火后归零 | `pattern_length 30`、`pattern_kick_start 0.22°`、`pattern_kick_end 0.5°`、`pattern_side_kick 0.3°`、`pattern_seed 20260930` |
| 3 · 扩散值 | 连射/移动增大、开镜/静止减小；同时驱动**准星大小**与**实际弹道随机散布** | `base_spread 0.12`、`per_shot_spread 0.16`、`spread_recovery 3`、`ads_spread_scale 0.4`、`move_spread 0.45`、`spread_deg_max 3.6°` |

手感要点：

- 第 3 层用**指数收敛**（`lerpf(_spread, target, 1-exp(-k·dt))`），停火后先快后慢地回正。
- 开镜时**每发增量也乘 `ads_spread_scale`**，所以连射时开镜明显更精准（腰射平衡值约 0.74，开镜约 0.30）。
- 弹道模式用固定种子生成，**同一把枪每一轮喷射弹道一致**，可以像战地/CS 那样背弹道。
- 后坐力直接作用在摄像机旋转上：开枪会真的把镜头顶起来，需要手动压枪。

调参入口：在 Godot 里选中 `scenes/player.tscn → CameraPivot/RecoilPivot`，Inspector 里改 `RecoilSystem` 的导出参数，运行时立刻生效。

### 6.3 相机摇晃 / 屏幕震动 / 3D 音效

| 系统 | 文件 | 说明 |
| --- | --- | --- |
| 相机摇晃 | [camera_sway.gd](scripts/shooting/camera_sway.gd) | 鼠标转动的惯性滞后（转动带拖尾、停下缓慢回正）+ 行走上下晃动 + 横向移动侧倾；接口与 DampedSprings 插件兼容，替换实现即可 |
| 屏幕震动 | [screen_shake.gd](scripts/shooting/screen_shake.gd) | Trauma 系统：`add_trauma()` 累加，幅度 = trauma²，用 `FastNoiseLite` 采样平滑噪声驱动 `h_offset / v_offset / roll`（不是简单随机抖动） |
| 3D 音效 | [audio_3d.gd](scripts/shooting/audio_3d.gd) | `AudioStreamPlayer3D` 播放，每发音高 ±5%、音量 ±5% 随机；**枪声是程序化合成的占位音**（噪声爆音 + 低频冲击 + 余响），换成真实 `.ogg` 采样只需替换 `_build_gunshot()` |

### 6.4 武器与装备槽

`1` 主武器（**M4A4 突击步枪**：700 发/分全自动、30/120）｜ `2` 副武器（**粉色 USP**）｜ `3` **蝴蝶刀**（近战，模型待接入）｜ `4` **青花瓷手雷**（3 颗）
同一键再按一次 = **空手**（收起武器）。`R` 换弹对所有枪械生效；**长按 R 3 秒把备弹 / 手雷数量补满**。

| USP 参数 | 默认值 |
| --- | --- |
| 射速 / 模式 | 400 发/分 · 半自动（按住只打一发） |
| 伤害 / 射程 | 34 · 200 米 hitscan |
| 弹匣 / 备弹 / 换弹 | 12 / 24 / 2.2 秒（打空自动换弹） |
| 开镜 | FOV 75 → 60，灵敏度 ×0.6，移动 ×0.55 |

| 近战 / 投掷 | 参数 |
| --- | --- |
| 蝴蝶刀 | 2.2 米内 65 伤害，约 0.3 秒一刀，无弹药 |
| 手雷 | 3 颗，左键投掷，1.6 秒引信，6 米内最高 70 伤害（爆炸带闪光 / 冲击波 / 低频声 / 屏幕震动） |

> 武器场景都在 `scenes/weapons/`，结构 = 根节点（`weapon.gd`）+ `Model`（真实 glb 实例，位置 / 缩放在这个节点上调）+
> `Muzzle` / `MuzzleLight` / `MuzzleFlash` / `GunAudio` 四个功能节点（`Muzzle` 要对准枪口）。模型在 `assets/models/weapons/`：
> M4A4（0.90 m，`Model` 无需缩放，Muzzle 在 z=0.557 正好是枪口）、粉色 USP（0.19 m，`Model` 缩放 0.08）、青花瓷手雷（`Model` 缩放 0.6）。
> 数值都是节点导出参数，`display_name` 会显示到 HUD。

---

## 七、初音未来模型（阶段 4）

`MikuModel` 节点（`scripts/entities/miku_model.gd`）会**自动加载** `res://assets/models/miku/miku.glb`：

1. 准备 `.glb` 模型，把文件放到 `assets/models/miku/miku.glb`
   （想用别的路径就在 Inspector 里改 `MikuModel.model_path`）。
2. 重新打开项目让 Godot 导入 `.glb`，运行即自动替换占位胶囊（`Placeholder` 隐藏）。
3. **尺寸自动适配**：默认把模型缩放到 1.75 m 高（FBX/MMD 转出的模型常常是几十米的“巨人”）并让脚底对齐胶囊底部；
   想调大小改 `auto_fit_height` / `model_scale`，位置不对就用 `position_offset` 平移。
   同时自动清理 mmd_tools 导出时混进来的物理刚体 / 关节占位网格（否则会渲染成白盒子）。
4. **朝向**：模型正面应为 +Z（`player.gd` 的转向基准）；不是的话改 `MikuModel.yaw_offset_deg`（朝 -Z 填 180）。
5. **动画**：模型自带的动画按关键字自动匹配 —— `idle/stand/wait`、`walk/move`、`run/sprint`、`jump/fall/air`，
   按移动速度与是否离地自动切换（带淡入淡出）；名字对不上时改节点上的四个 `*_keys` 关键字即可。
   **模型没有动画剪辑时自动启用「程序化步态」**（`miku_procedural_pose.gd`）：
   站立时把 T-pose 的手臂放下来；行走/跑步是完整步态循环 —— 大腿前后摆 + **摆动期屈膝抬脚** + 脚掌角度补偿
   + 身体起伏与前倾 + 手臂反相摆动（肘部自然弯曲），并且**步频按实际速度自适应**（步幅由腿长和摆幅推算），基本不滑步；
   骨骼是启发式识别的（脚→大腿→膝→踝、手→上臂→肘沿父链定位，骨骼名乱码也能用），识别失败保持原姿态；
   幅度 / 步频区间等常量在该脚本顶部。
6. **武器**：模型带 `Skeleton3D` 且能匹配到右手骨骼（关键字 `hand_r/right_hand/...`）时，
   `Rifle` 自动挂到 `BoneAttachment3D` 上，位置用 `MikuModel.hand_offset` 调；匹配不到（例如骨骼名是乱码）就保持挂在模型节点下。
7. **关闭 MMD 物理**（头发/裙摆刚体、关节），否则容易掉帧。

> 没有放模型时一切照旧：占位胶囊继续可用，移动 / 射击 / 联机全部不受影响。

---

## 八、菜单 / 死亡重生 / 人机（阶段 5）

### 8.1 Esc 菜单（[game_menu.tscn](scenes/ui/game_menu.tscn)）

- **角色选择**：扫描 `assets/models/*/*.glb` 生成按钮列表，点击即切换本地玩家的 `MikuModel`（自动重载模型 + 尺寸适配 + 武器挂手）；
- **退出游戏**：联机时先 `NetworkManager.leave_game()` 退出房间，再 `get_tree().quit()`；
- **输入屏蔽**：菜单打开时释放鼠标，并屏蔽移动 / 跳跃 / 开火 / 开镜（`PlayerController.set_input_blocked` + 武器 `set_trigger_enabled`；已开始的换弹计时继续走）；
- 与死亡界面 / 人机面板互斥：三者都在 `game_ui` 组，打开一个会自动关掉其它界面。

### 8.2 死亡与重生（[death_screen.tscn](scenes/ui/death_screen.tscn)）

- 玩家 `died` 信号 → 显示「你已阵亡」+「重生」按钮（此时已释放鼠标、屏蔽输入）；
- 重生 = 回满血 + 回到出生点 + 清除趴下状态 + 恢复输入并重新锁定鼠标（`PlayerController.respawn()`）。

### 8.3 人机系统（[bot.tscn](scenes/bot.tscn)、[bot.gd](scripts/entities/bot.gd)、[bot_manager.gd](scripts/entities/bot_manager.gd)）

- **面板**：`H` 开关，增减 / 清空人机（上限 8，见 `bot_manager.gd` 的 `max_bots`）；
- **刷新**：在本地玩家周围 **8~18 m** 的随机方向生成（不会刷在脸上），模型从已有 4 个 `.glb` 里随机挑一个；
- **AI**：保持 7 m 交战距离（超出就靠近，>15 m 跑步），始终面向玩家，按 `fire_interval`（默认 1.5 s，±35% 随机）射击；
  射击是真实的 raycast（带 `fire_spread_deg` 散布），命中带 `take_damage()` 的碰撞体才扣血（默认 11）；
- **受击反馈**：后仰（模型旋转）+ 闪白（`material_overlay` 白材质淡出）+ 程序化受击音效（下滑音 + 噪声质感）；
- **击杀**：被玩家打死 → 倒地后移除、数量自动扣减、击杀日志写入「你 ➤ 人机」；
- 人机在 `enemy` 组（小地图红点），**仅本端生成、不参与联机同步**（见已知限制）；
- 速度 / 距离 / 射速 / 散布 / 伤害 / 后仰 / 闪白都是 `bot.gd` 顶部导出参数，Inspector 里可直接调。

### 8.4 顺带修复：程序化姿态的骨骼识别

支持角色切换后暴露出程序化姿态在「骨骼名正常的 PMX 模型」上会认错骨骼（旧启发式是按 miku.glb 的乱码骨骼名调教的）。
现在**先按标准 MMD 骨骼名匹配**（右足/左足、右ひざ/左ひざ、右足首/左足首、右腕/左腕、右ひじ/左ひじ、腰），
名字对不上（如 miku.glb 的乱码名）再回退到原启发式；同时给「找不到的骨骼」加了兜底，不再出现 -1 越界报错。

---

## 九、联机（阶段 3）与后续阶段 TODO

### 阶段 3：局域网联机（蓝盾 VPN）

已实现（基础版）：

- **Hub 大厅**（`scenes/hub/hub.tscn`）：创建房间（端口默认 7777）/ 输入房主 IP 加入 / 玩家列表（最多 4 人）/ 房主「开始对战」/「单人试玩（离线）」。
- **NetworkManager**（Autoload）：`host_game()` / `join_game()` / `leave_game()`；主机 `create_server(7777, 3)`，客户端 `create_client("26.x.x.x", 7777)` 直连。
- **对局**：各端按玩家列表在本地创建同一批玩家节点（迟到加入也能立刻看到所有人），节点名 = peer id、权限 = 对应 peer；
  位置与模型朝向由 `player.gd` 按 ~30Hz 经 NetworkManager 的普通 RPC 广播（不依赖场景缓存），远端节点平滑跟随。
- **联机射击**：开火特效（枪口火光 / 曳光弹 / 3D 枪声）通过 `@rpc` 同步；训练靶伤害在所有端一起结算，玩家伤害只发给被击中的一端。
- **进出对局**：HUD 右上角「返回大厅」；房主离开 = 解散房间，客户端会自动回到大厅。

**TODO(阶段3+)**：断线重连 / 重进对局、小队 / 兵种 / 出生点选择、观战、服务器列表、命中判定的服务器权威化。

**蓝盾 VPN 使用步骤（阶段 3 联机时）**

1. 双方都安装蓝盾 VPN 客户端。
2. 其中一方创建虚拟局域网（网络），把朋友拉进来。
3. 朋友加入该网络，双方获得 `26.x.x.x` 网段的虚拟 IP。
4. **主机**在游戏里点“创建房间”，并把自己的 **26 开头 IP** 复制发给朋友。
5. **客户端**在游戏里输入这个 IP + 端口（默认 `7777`）后连接。
6. 连不上时排查：蓝盾是否显示已连接、Windows 防火墙是否放行 Godot、双方网段是否一致。

### 阶段 2 剩余的 TODO

- **武器模型**：✅ 已接入真实模型（M4A4 / 粉色 USP / 青花瓷手雷）；蝴蝶刀仍是方块占位，模型在 `D:\sekai\assets\models\hudidao`（待转换接入）。
- **枪声素材**：用真实 `.ogg` 枪声替换 `audio_3d.gd::_build_gunshot()` 的程序化占位音。
- **角色持枪姿态**：人物与武器现已始终朝向准星水平方向（不再随移动键转动）；接入真实模型后可再做上半身朝向混合。
- **伤害来源**：`PlayerController.take_damage()` 已实现并会触发屏幕震动与血条更新，但场景里暂时没有会还击的敌人。
- **相机摇晃增强**：可接入 DampedSprings 插件做二阶弹簧版惯性。
- **小地图增强**：地形贴图（SubViewport）、缩放档位、只在被发现时显示敌人。

### 阶段 4：初音未来模型

见上一节。

---

## 十、验证记录

使用本机 Godot **4.7.2 stable** 命令行实测。

### 阶段 1（13 项）

| 项目 | 结果 |
| --- | --- |
| `godot --headless --path . --import` 无错误 | ✅ |
| `--quit-after` 运行无脚本错误 | ✅（仅“music/ 无歌”提示） |
| 12 个输入动作匹配（`InputMap.event_is_action`） | ✅ 全部 |
| Environment 11 项参数（Sky/ACES/Glow/SSAO/SSR/SDFGI/体积雾） | ✅ 全部生效 |
| 主场景结构（阴影 Parallel 4 Splits、ReflectionProbe Once、Props 20 子节点） | ✅ |
| 第三人称相机在玩家身后 `(0, 1.6, 3.5)` | ✅ |
| 音乐：扫描 / 播放 / -6 dB / 暂停 / N 切歌 / 播完自动下一首 | ✅（用真实 .ogg 验证） |
| 音乐：无歌 / 坏文件时只警告不崩溃 | ✅ |

### 阶段 2（34 项）

| 项目 | 结果 |
| --- | --- |
| HUD 接入主场景、7 个元件齐全、信号绑定成功 | ✅ |
| 初始弹匣/血量显示与数据一致 | ✅ |
| 小地图收集 10 个障碍物；坐标换算（正前方在上、东侧在右） | ✅ |
| 敌人（3 训练靶）/ 队友（2 占位）数据源存在 | ✅ |
| 按住左键连发：0.9 秒 11 发（700 RPM ≈ 10 发） | ✅ |
| 开火消耗弹药 + HUD 弹药同步 | ✅ |
| 第 3 层：连射使扩散值升到 0.73，准星同步张开 | ✅ |
| 第 1/2 层：镜头被顶起（pitch ≈ 3.6°、yaw ≈ 5.6°）+ RecoilPivot 旋转生效 | ✅ |
| 屏幕震动 trauma 升到 0.98 | ✅ |
| 枪声音高随机化在 ±5% 内（实测 0.956 / 1.028） | ✅ |
| 开镜：FOV 75 → 55、玩家进入瞄准态、扩散 0.73 → 0.11 | ✅ |
| 换弹：R 触发、进度条显示、完成后弹匣补满（30）、备弹扣减、进度条隐藏 | ✅ |
| 停火后扩散回落至基础值 0.12 | ✅ |
| 命中训练靶：4 发击杀（hp=0、alive=false）、击杀日志 +1 条 | ✅ |
| 指南针随视角转动（朝北 0° → 朝东 90°） | ✅（含 ±2° 容差） |

**未能在 headless 验证的部分**（需要真实窗口）：

- `_draw()` 的实际观感：小地图、指南针、准星、队友图标的视觉效果（headless 无渲染后端时队友图标会主动跳过绘制）。
- 帧率：请在本机 F5 后看 `调试 → 监视器 → FPS`，不够时按第四节开 FSR 2.2 或关 SDFGI。
- 音效听感：程序化枪声的实际音色与 3D 衰减。

### 阶段 3（联机，headless 双进程实测）

| 项目 | 结果 |
| --- | --- |
| 大厅建房 / 输入 IP 加入 / 玩家昵称与房间人数同步 | ✅ |
| 房主「开始对战」→ 所有端切到对局场景 | ✅ |
| 4 个出生点按 peer 生成玩家（节点名 = peer id，权限正确） | ✅ |
| 位置 / 朝向双向同步（客户端移动，主机端看到 x 从 -8 → -17；主机移动，客户端同样实时看到） | ✅ |
| 对局中迟到加入：立刻看到已有玩家，且双方实时位置照常同步 | ✅ |
| 开火特效 RPC（枪口火光 / 曳光弹 / 枪声）无报错 | ✅ |
| 训练靶伤害在所有端一起结算（A 靶 100 → 75） | ✅ |
| 玩家掉线：各端移除其节点；房主离开 → 客户端自动返回大厅 | ✅ |
| 单机（离线）回归：生成玩家 / HUD 绑定 / 开火扣弹（30 → 24） | ✅ |

### 阶段 4（模型管线：临时骨架模型 + 真实 miku.glb 实测）

| 项目 | 结果 |
| --- | --- |
| 真实 miku.glb：自动缩放适配（骨骼高度 23.5 m → 1.75 m）+ 脚底对齐胶囊底部 | ✅ |
| 真实 miku.glb：自动清理 56 个 mmd_tools 物理占位网格 | ✅ |
| 真实 miku.glb：用脚尖骨骼数据确认模型原生朝 +Z（`yaw_offset_deg` 修正为 0，避免背对镜头） | ✅ |
| 行走步态（程序化）：抬脚 0.17 m、步幅 0.89 m、起伏 0.033 m；步频与速度匹配（走 2.0 Hz / 跑 2.7 Hz），骨盆-大腿距离恒定不撕开身体 | ✅ |
| 没有 miku.glb 时回退占位胶囊（不影响移动 / 射击 / 联机） | ✅ |
| 放入模型后自动替换：占位隐藏、模型实例化、朝向补正生效 | ✅ |
| 动画关键字匹配 + 状态切换：Idle / Walk / Run / Jump 全部命中对应片段 | ✅ |
| `player.gd` 自动驱动：角色腾空时自动切到 Jump | ✅ |
| 武器自动挂到 `hand_r` 骨骼（BoneAttachment3D `WeaponHand`） | ✅ |
| 主场景离线回归：玩家生成 / 武器查找（find_child）/ 开火扣弹（30→24）/ HUD 绑定 | ✅ |

| 操作与装备（headless 实测） | 结果 |
| --- | --- |
| 武器槽切换与空手：Rifle ↔ USP ↔ Knife ↔ Grenade，同键再按收起，HUD 重绑与弹药显示正确 | ✅ |
| 长按 R 3 秒补满备弹（3 → 24）；手雷 3 颗、投掷物生成与爆炸无报错 | ✅ |
| Ctrl 蹲下（胶囊 1.2 m / 镜头 1.05 m）、Z 趴下（0.8 m / 0.35 m / 模型放平 -83°） | ✅ |
| V 第一人称（模型隐藏、弹簧臂 0 m）；Alt 自由视角（headless 无法捕获鼠标，需在窗口里实测） | ✅ |

### 阶段 4 补充：PMX → glb 批量转换（[tools/pmx2glb.py](tools/pmx2glb.py)）

修复了解析错位 bug：骨骼 flag 只有**高位**带数据（`0x0100/0x0200` 旋转/移动付与、`0x0400` 轴固定、`0x0800` 局部轴、`0x2000` 外部亲、`0x0020` IK 块），
低位只是布尔标记；另外补上了组形态系数、材质形态字段、关节段 24 个 float。现在 4 个 PMX 全部**精确解析到文件尾**（结束偏移 == 文件大小）。

| 模型 | 解析（剔除野顶点后） | 产物 | Godot 导入验证（headless） |
| --- | --- | --- | --- |
| YYB式改变miku.pmx | 41168 顶点 / 704 骨骼 / 189417 索引 | `miku_navy.glb`（11 MB） | 23 表面 / 704 骨骼 / AABB 高 20.1 / 23 个材质全部有贴图 ✅ |
| YYB 猫猫女仆.pmx | 61985 顶点 / 922 骨骼 / 285420 索引 | `miku_maid.glb`（11 MB） | 49 表面 / 922 骨骼 / AABB 高 21.1 / 44 个材质有贴图 ✅ |
| YYB 猫猫女仆2.pmx | 61087 顶点 / 525 骨骼 / 290922 索引 | `miku_maid2.glb`（11 MB） | 52 表面 / 525 骨骼 / AABB 高 21.1 / 48 个材质有贴图 ✅ |
| RM/Frilly Ankle Boots_White.pmx | 4292 顶点 / 14 骨骼 | （仅验证解析，未使用） | — |

- 贴图按**实际文件**去重内嵌（同一个模型里的 `tex/body.png` 与 `tex\body.png` 只嵌一次），体积 90 MB → 32 MB；
- `.bmp` 漫反射贴图（猫猫女仆尾巴）自动转 PNG 内嵌（glTF 只接受 PNG/JPEG）；
- 猫猫女仆有 176 个 Y≈-30000 的隐藏残骸顶点（MMD 常见写法），会把包围盒撑到 3 万单位、破坏剔除与阴影，
  转换时按 1000 单位阈值剔除并重映射索引（各剔除 160 个三角形）；
- 模型朝向：转换时统一绕 Y 轴旋转 180°（PMX 原文件面朝 **-Z**），使正面朝 **+Z**（项目约定，详见下方「朝向修正」）；尺寸由 `MikuModel` 自动适配到 1.75 m。

### 阶段 5（菜单 / 死亡重生 / 人机，headless 实测 37 项）

| 项目 | 结果 |
| --- | --- |
| 按 `Esc` 打开菜单 / 再按关闭；菜单打开时屏蔽输入、释放鼠标 | ✅ |
| 按 `H` 打开人机面板；面板打开时按 `Esc` 关闭（校验了 project.godot 的输入映射） | ✅ |
| 菜单 / 人机面板互斥（打开一个自动关掉另一个） | ✅ |
| 角色列表扫描到 4 个 glb；点击切换后本地玩家模型重载成功（miku_navy） | ✅ |
| 玩家阵亡 → 死亡界面显示 + 屏蔽输入；重生 → 回满血、回出生点（距离 0.00 m）、输入恢复 | ✅ |
| 人机刷新在玩家周围 8~18 m、在 enemy 组、复用 MikuModel + rifle 外观 + 受击音效节点 | ✅ |
| 人机受击：闪白 + 后仰生效 | ✅ |
| 人机追踪（14.1 m → 5.9 m）并按周期射击命中玩家（100 → 0） | ✅ |
| 玩家开火击杀人机（hitscan → take_damage），数量自动扣减，击杀日志 +1 | ✅ |
| 程序化姿态：4 个模型全部认出骨骼（新模型走名字匹配，miku.glb 走启发式），无 -1 越界报错 | ✅ |
| 大厅场景回归：`--quit-after 300` 运行无脚本错误 | ✅ |

> 阶段 5 的验证脚本用「临时场景 + Runner 节点」跑：`-s`（SceneTree 脚本）模式下 autoload 不会注册，
> 直接用它会连 `NetworkManager` 都找不到、依赖它的脚本会编译失败。

### 阶段 5 补充：真实武器模型移植 + 模型朝向修正（headless + 离屏渲染实测 28 项）

| 项目 | 结果 |
| --- | --- |
| rifle / usp / grenade 场景改成「`Model` 子节点 + 真实 glb」（从 feat 分支移植） | ✅ |
| M4A4：长 0.897 m、1 个材质带贴图、`Muzzle` 正好在枪口（z=0.557） | ✅ |
| 粉色 USP：长 0.193 m、24 个表面全部有贴图 | ✅ |
| 青花瓷手雷：长 0.067 m、贴图正常（glb 里原本缺 `material` 引用，已修补，`obj2glb.py` 也修了） | ✅ |
| 武器槽 1~4 装备正常；M4A4 开火消耗弹药（30 → 23） | ✅ |
| 人机刷新 / 菜单 / 重生等阶段 5 功能回归通过 | ✅ |
| 3 个 PMX 模型朝向修正：脚尖在足首的 +Z（Δz≈+2.1），离屏渲染确认正面朝向镜头 | ✅ |

> 朝向问题是本轮新发现的：PMX 原文件面朝 **-Z**，与项目约定（+Z）相反（用离屏渲染才看出来——人物背对镜头）。
> 现在 `tools/pmx2glb.py` 转换时统一绕 Y 轴旋转 180°，三份 glb 已重新生成并验证。

**自动缩放修复（人机 / 角色选择都会用到）**：小海军模型把物理骨骼放在离身体很远的位置（前髪先 Y≈-74、パンツ Y≈+100），
`MikuModel` 按骨骼量身高会得到 155 单位 → 自动缩放后变成 0.23 m 的玩偶（人机随机选中时肉眼可见）。
`_measure_bounds` 改为「网格 AABB 与骨骼包围盒各算一份、取更矮的」，小海军恢复 ~1.7 m；离屏实拍主模型 / 小海军 / 猫猫女仆尺寸一致。

> 验证用的临时脚本、联机自测钩子与临时骨架模型均已在验证完成后删除，仓库里只留项目文件。

---

## 十一、当前迭代完成状态

### 阶段 1

- [x] `project.godot`：项目名、Forward+、TAA 开 / MSAA 关、主场景、Autoload、输入映射
- [x] `scenes/main.tscn`：WorldEnvironment + 阴影平行光 + 50×50 地面 + 10 个柱体 + ReflectionProbe(Once) + Player
- [x] `scenes/player.tscn`：CharacterBody3D + 胶囊 + 占位模型 + SpringArm3D(3.5)
- [x] `scripts/player.gd`：WASD / 鼠标视角 / Shift / Space / Esc
- [x] `scripts/music_manager.gd`：Autoload、扫描 `music/*.ogg`、N/P 控制、-6 dB
- [x] `assets/environments/high_quality_environment.tres`
- [x] `README.md`、`music/README.md`、预留目录全部就位

### 阶段 2

- [x] `scenes/ui/hud.tscn` + `scripts/ui/*.gd`：动态准星、小地图、生命值、弹药与装备、击杀日志、指南针、队友图标
- [x] HUD 接入 `main.tscn`，信号与场景组解耦
- [x] `scripts/shooting/recoil_system.gd`：三层后坐力（视觉 / 弹道模式 / 扩散），lerp 平滑恢复
- [x] `scripts/shooting/camera_sway.gd`：惯性平滑 + 行走晃动 + 侧倾
- [x] `scripts/shooting/screen_shake.gd`：Trauma + Noise 屏幕震动
- [x] `scripts/shooting/audio_3d.gd`：3D 枪声 + 音高/音量 ±5% 随机
- [x] `scripts/shooting/weapon.gd` + `scenes/weapons/rifle.tscn`：连发 / 弹匣 / 换弹 / 开镜 / hitscan / 曳光弹 / 命中反馈
- [x] `scripts/entities/training_target.gd`：训练靶（可击毁 + 自动复活，供 HUD / 手感验证）
- [x] 输入映射 `shoot` / `aim` / `reload` 已接入（阶段 1 预留的动作现在生效）

### 阶段 3

- [x] `scripts/network/network_manager.gd`：ENet 建房/加入/退出、玩家列表、开局切场景、生成协调、伤害与击杀 RPC
- [x] `scenes/hub/hub.tscn` + `scripts/ui/hub.gd`：联机大厅（创建/加入/玩家列表/开始对战/单人试玩）
- [x] 对局：4 个出生点；各端按玩家列表本地创建玩家节点（不用 Spawner，对局中迟到加入也能看到所有人）；位置/朝向 RPC 广播同步（~30Hz）
- [x] 联机射击：开火特效 RPC（枪口火光/曳光弹/枪声）+ 训练靶全端结算 + 玩家伤害发给本人
- [x] HUD「返回大厅」；`project.godot` 主场景改为 Hub、新增 NetworkManager Autoload

### 阶段 4

- [x] `scripts/entities/miku_model.gd`：自动加载 `assets/models/miku/miku.glb`，没有模型时回退占位胶囊
- [x] 尺寸自动适配：缩放到 1.75 m + 脚底落地 + 清理 mmd_tools 物理占位网格；`auto_fit_height` / `model_scale` / `position_offset` 可调
- [x] 动画状态机：按移动速度 / 是否离地切换 Idle / Walk / Run / Jump（关键字匹配 + 淡入淡出）
- [x] 模型带骨骼时武器自动挂到右手骨骼（`BoneAttachment3D`），支持 `yaw_offset_deg` / `hand_offset` 调参
- [x] 无动画模型自动启用程序化步态：放下 T-pose（手 1.39 m → 0.91 m）；行走循环含屈膝抬脚（0.17 m）、步幅 0.89 m、身体起伏，步频与速度匹配（走 2.0 Hz / 跑 2.7 Hz，基本不滑步）
- [ ] 给模型补真实动画剪辑（程序化姿态只是兜底，动作较生硬）；骨骼名是损坏编码，武器未自动挂手
- [ ] 场景观感：把程序化云层换成更接近 sky.jpeg 的云层贴图 / HDRI（可选）

### 操作与装备（补充）

- [x] 武器槽：`1` 主武器 / `2` 副武器 / `3` 蝴蝶刀 / `4` 手雷；同一键再按 = 空手（HUD 自动重绑并刷新弹药显示）
- [x] 蹲下（按住 `Ctrl`）/ 趴下（`Z` 切换，模型放平）：移动速度、碰撞高度与镜头高度平滑过渡
- [x] 第一人称 / 第三人称（`V`）；自由视角（按住 `Alt`，松开自动回正）
- [x] 长按 `R` 3 秒补满备弹 / 手雷数量；手雷投掷与爆炸（闪光 / 冲击波 / 低频声 / 震动）

### 阶段 5

- [x] `scenes/ui/game_menu.tscn` + `game_menu.gd`：Esc 菜单（角色选择扫描 `assets/models/*/*.glb`、退出游戏先退房间）
- [x] 菜单打开时释放鼠标并屏蔽移动 / 跳跃 / 开火 / 开镜（换弹计时继续），关闭后恢复并重新锁定鼠标
- [x] `scenes/ui/death_screen.tscn` + `death_screen.gd`：`died` → 「你已阵亡」+ 重生（回满血 / 回出生点 / 恢复输入）
- [x] `scenes/bot.tscn` + `bot.gd` + `bot_manager.gd` + `bot_panel.tscn`：H 面板增减人机、8~18 m 随机刷新、
      追踪 + 周期射击（散布 / 伤害可调）+ 受击后仰 / 闪白 / 程序化音效 + 倒地移除
- [x] 人机在 `enemy` 组（小地图红点），被击杀写入击杀日志；仅本端生成、不走联机 RPC
- [x] 程序化姿态新增「标准 MMD 骨骼名」识别 + 找不到骨骼时的兜底（角色切换不再报 -1 越界）

### 验收标准

- [x] 战地 5 风格 HUD：动态准星、小地图、生命值、弹药、击杀日志、指南针、队友图标
- [x] 三层后坐力：视觉后坐力 / 弹道偏移模式 / 扩散值，同时作用于摄像机与准星
- [x] 动态准星随扩散缩放；相机摇晃；Trauma/Noise 屏幕震动；3D 音效（音高音量 ±5% 随机）
- [x] 联机 / Hub / 初音模型位置已预留
- [ ] 1080p 中端 GPU 60 FPS（需在真实 GPU 上确认）
- [ ] 真实观感与手感需在本机 F5 体验后微调参数

---

## 十二、已知限制

- 尚未放入 `miku.glb` 时角色仍是占位胶囊；武器是方块占位；场景里没有道具 / 靶子 / 队友，也没有胜负设计
  （阶段 5 的人机是练习对手，不是正式的敌人 AI 与关卡设计）。
- 当前 `miku.glb` 没有动画剪辑，行走 / 跑步由「程序化步态」合成（屈膝、起伏、自适应步频，基本不滑步），
  观感自然但没有转身 / 急停之类的过渡动作；骨骼名为损坏编码，武器未自动挂手（枪挂在模型节点下，可手动拖动到骨骼）。
- 3 个 PMX 转换模型（小海军初音 / 猫猫女仆 ×2）同样没有动画剪辑、走程序化步态；MMD 的卡通贴图（toon）与球面贴图（spa）未参与渲染，
  只有漫反射贴图 + 材质基础色，观感比 MMD 里"平"一些。
- 武器只跟随准星的水平方向，尚未跟随俯仰角度；上下半身分层朝向留待真实模型阶段。
- 联机为**基础版**：最多 4 人；没有断线重连、队伍/兵种/胜负；远端玩家的后坐力与镜头震动动画不显示（只同步位置与朝向）。
- 玩家位置同步走普通 RPC（~30Hz + 本端平滑），局域网够用；没有服务器回滚 / 延迟补偿，高延迟下会有轻微抖动。
- 训练靶的复活计时在各端独立进行（击杀结算同步，复活各自等 3 秒）；玩家伤害只发给被击中的一端。
- 房主离开 = 解散房间，客户端会自动回到大厅（无断线重连）。
- 蹲 / 趴 / 第一人称 / 自由视角与武器槽都只在本端表现（联机不同步）；远端玩家固定显示主武器、不做蹲趴姿态。
- 手雷的爆炸伤害只结算爆点附近的**本地玩家**（原型简化，没有服务器权威结算）。
- 训练靶只会挨打不会还击，所以血条暂时不会掉（`take_damage()` 接口已就绪）；阶段 5 的人机会还击并扣玩家血。
- 人机**仅在本端生成、不参与联机同步**：联机时每端各自刷自己的人机，互相看不见，也不计入对方的击杀 / 伤害；
  人机对玩家的伤害同样只在本端结算（玩家武器打人机时也跳过了联机 RPC）。
- 角色选择（Esc 菜单）只影响**本端玩家自己**的外观，不会同步给其他玩家。
- 菜单 / 死亡界面 / 人机面板打开时**游戏不暂停**（人机照常行动），没有暂停 / 观战功能。
- 蝴蝶刀还是方块占位：蝴蝶刀模型在 `D:\sekai\assets\models\hudidao`（还没进仓库），接入方式与其它武器一致（转成 glb → 替换 `knife.tscn` 的 `Model` 节点）。
- M4A4 是从 Source 2 的「第一人称视模型」转出来的：模型里还留着 43 个手部 / 手指空骨骼节点（不参与蒙皮、不影响显示），
  枪身 0.90 m 偏长，握持位置没有逐模型调过，必要时用 `MikuModel.hand_offset` 或武器场景里微调。
- 武器只有「渲染网格 + 枪口 / 曳光弹 / 枪声」是对齐的，第三人称下的握持姿势还没有专门适配（会有轻微悬空）。
- 角色列表靠扫描 `res://assets/models/*/*.glb` 生成（自动跳过 `weapons/` 武器目录）；导出发行版时如果 `.glb` 不随包导出，需要改成固定列表（目前只在源码运行下验证）。
- `music/` 只在启动时扫描一次，运行中加歌需要重启；`reload_playlist()` 已备好接口。
- 反射探针为 `Once` 模式，场景静态物体变化后需要手动重新烘焙。