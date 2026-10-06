# 设计支柱（Design Pillars）

> **Task ID**：D2-01 ｜ **作者**：文策渊（Vince Coyer）· 设计策略师 ｜ **状态**：draft
> **上游依赖**：`README.md`（第二节操作、第六节 HUD/射击手感、第十二节已知限制）、`HANDOFF.md`、`scripts/shooting/recoil_system.gd`、`scripts/player.gd`、`scripts/network/network_manager.gd`
> **产品定位（用户已确认，不可更改）**：联机对战小游戏 —— 快节奏多人对枪，设计重心 = **射击手感** + **网络同步**。

---

## 0. 一页速览

| # | 支柱 | 一句话定义 | 换取了什么 | 放弃了什么 |
| --- | --- | --- | --- | --- |
| P1 | **每一发都能被感受到** | 枪械的反馈（后坐力 / 准星 / 震动 / 音效）必须帧级可读、可学习 | 极致的单发手感与技巧上限 | 武器种类数量、写实弹道物理 |
| P2 | **三秒进场，三分钟一局** | 从打开游戏到开打不超过 3 步，单局时长压制在 3~5 分钟 | 即开即玩的低摩擦节奏 | 匹配 / 排位 / 大房间 / 复杂进度 |
| P3 | **明亮舞台上的快节奏对枪** | 干净、高可视性的 Miku 主题水面竞技场，让对枪「看得清、打得爽」 | 辨识度高、上手快的画面基调 | 军事拟真、复杂战术层 |

---

## 1. 支柱一 · 每一发都能被感受到（Sensation-First Gunfeel）

**一句话定义**：任何一次扣动扳机，玩家都必须能「看到、听到、感觉到」——后坐力把镜头顶起来、准星随扩散张开、屏幕轻微震动、枪声带 ±5% 随机化——且这些反馈是**可学习、可利用**的（弹道可背、压枪可练）。

**取舍（放弃什么换什么）**：
- 换到：**技巧深度**。三层后坐力（视觉 / 弹道模式 / 扩散）构成一条清晰的能力曲线——新手凭运气对枪，老手背弹道、控扩散。
- 放弃：**武器阵容的广度**。当前只有 4 个槽位（步枪 / 手枪 / 近战 / 手雷）、步枪槽 2 个外观共用同一套数值。我们**不**追求「几十把枪」的内容量，而把预算全部押在「同几把枪的手感打磨」上。

**现有代码实现证据**（可直接对照）：
| 证据 | 文件 / 参数 |
| --- | --- |
| 三层后坐力结构 | `scripts/shooting/recoil_system.gd`：`visual_kick_pitch 0.55°` / `visual_kick_yaw 0.22°` / `visual_recovery 14`；`pattern_length 30` / `pattern_kick_start 0.22°` / `pattern_kick_end 0.5°` / `pattern_side_kick 0.3°` / `pattern_seed 20260930`；`base_spread 0.12` / `per_shot_spread 0.16` / `spread_recovery 3` |
| 弹道可背（固定种子） | `recoil_system.gd::_build_pattern()`，`rng.seed = pattern_seed` → 同一把枪每轮喷射弹道一致 |
| 后坐力真的作用在镜头上 | `recoil_system.gd::_process()` 写 `rotation = Vector3(_visual_pitch + _pattern_pitch, ...)`，需手动压枪（README §6.2） |
| 准星与扩散同源 | `scripts/ui/crosshair.gd`：`min_gap 5` / `max_gap 34` / `ads_gap 2`，由 `RecoilSystem.get_spread()` 驱动 |
| 屏幕震动 | `scripts/shooting/screen_shake.gd`：Trauma 系统，幅度 = `trauma²`，`trauma_decay 1.4` / `max_offset 0.035` / `max_roll 1.6` |
| 3D 音效随机化 | `scripts/shooting/audio_3d.gd`：每发音高 ±5%、音量 ±5% 随机 |
| 相机惯性 | `scripts/shooting/camera_sway.gd`：鼠标惯性滞后 + 行走晃动 + 侧倾 |

---

## 2. 支柱二 · 三秒进场，三分钟一局（Instant-On, Short-Session）

**一句话定义**：从 Hub 大厅到「正在对枪」≤ 3 步（建房 → 开始对战 → 出生）；单局目标时长 **3~5 分钟**，死亡后可在 2~3 秒内重新投入交火。

**取舍（放弃什么换什么）**：
- 换到：**低摩擦、高复玩**。一局短、重开快，适合「小游戏」定位与局域网聚会场景（蓝盾 VPN 直连，见 README §9）。
- 放弃：**匹配 / 排位 / 大房间 / 断线重连 / 观战 / 服务器权威**。`network_manager.gd` 的 `MAX_PLAYERS := 4`、`ServerDisconnected` 直接回大厅、手雷伤害只本地结算——这些都是**有意保留的简单化**，不是缺陷。

**现有代码实现证据**：
| 证据 | 文件 / 参数 |
| --- | --- |
| 三步进场 | `scripts/ui/hub.gd`：建房 / 加入 / 单人试玩三个按钮；`NetworkManager.host_start_match()` 一键切场景 |
| 4 人上限 | `network_manager.gd`：`MAX_PLAYERS := 4`，`create_server(port, MAX_PLAYERS - 1)` |
| 即刻重生 | `scripts/ui/death_screen.gd` + `player.gd::respawn()`：回满血 / 回出生点 / 恢复输入 |
| 离线也有对手 | `scripts/entities/bot_manager.gd`（H 面板，`max_bots 8`），`bot.gd` 追 7 m 交战 |
| 低成本同步 | `player.gd`：`NET_SYNC_INTERVAL 0.033`（~30Hz 普通 RPC），`NET_SMOOTH_SPEED 14` 平滑跟随 |

> ⚠ **本支柱的硬约束**：任何新设计（胜负条件、目标点、经济）都**不得**把「进场到开打」的步骤增加到 3 步以上，也不得把单局时长拉到 8 分钟以上。这是 MVP 的护栏。

---

## 3. 支柱三 · 明亮舞台上的快节奏对枪（A Bright, Readable Arena）

**一句话定义**：在一片镜面水面上打——背景干净、角色/敌人高辨识、无视觉噪声，玩家的注意力 100% 留给「枪线、掩体、敌人位置」。

**取舍（放弃什么换什么）**：
- 换到：**可读性与美术降本**。程序化云层天空 + 400×400 镜面水面（`main.tscn` 的 `Ground`，`metallic 1.0 / roughness 0.06`）+ 程序化云。没有写实贴图、没有破碎地形，渲染预算省下来全给 TAA + SSR 反射。
- 放弃：**军事拟真与战术深度**。不做弹道下坠、不做复杂破坏、不引入「匍匐潜伏」这类慢节奏战术（`Z` 趴下保留为可选姿态，而非核心战术）。

**现有代码实现证据**：
| 证据 | 文件 / 参数 |
| --- | --- |
| 明亮水面舞台 | `scenes/main.tscn`：`PlaneMesh_water` 400×400，`StandardMaterial3D_water`（`metallic 1.0` / `roughness 0.06`） |
| 高画质但轻量 | `assets/environments/high_quality_environment.tres`：ACES / Glow / SSAO / SSR(96) / 体积雾，**SDFGI 关闭**（README §4） |
| Miku 主题载体 | `scripts/entities/miku_model.gd` 扫描 9 个模型；程序化步态 `miku_procedural_pose.gd`、待机微动作 `miku_idle_motion.gd` |
| 视觉辨识（敌我） | `scripts/ui/minimap.gd`：`enemy` 组红点 / `friendly` 组绿点；`teammate_icons.gd` 屏幕边缘队友图标 |

---

## 4. 目标体验与反目标

### 4.1 目标体验（玩家应该感受到什么）
1. **「这把枪是我的」**——压住一梭子后坐力、把准星压回敌人头上，是肌肉记忆而非运气。
2. **「再来一局只花三秒」**——死亡不是惩罚，是下一次交火的入场券。
3. **「我看得清、打得爽」**——画面亮、敌人清楚、击杀反馈响（命中标记 + 击杀日志 + 震屏）。

### 4.2 反目标（明确**不**做什么）
- ❌ **不做慢节奏战术射击**：没有匍匐侦察、没有 60 秒架枪、没有经济崩盘的雪球（见 `02_combat_economy.md` 的「经济不设崩盘」决策）。
- ❌ **不做内容量竞赛**：不靠「50 把枪 / 20 张图 / 30 个兵种」堆时长。
- ❌ **不做硬核拟真**：无弹道下坠、无穿墙弹道计算、无受伤部位系统。
- ❌ **不做重度成长 / 付费**：皮肤是**纯装饰 + 全解锁**（见 `02_combat_economy.md`），不做数值成长。
- ❌ **不做大房间 / 匹配 / 排位**：上限 4 人、房主即服务器，保持局域网级别的简单。

---

## 5. MDA · Aesthetics 八类盘点（本作主打 3 类）

Mechanics（机制）→ Dynamics（动态）→ Aesthetics（美学）在 `00_concept_mda.md` 展开；此处只做**美学取向判定**。

| Aesthetics 类型 | 本作权重 | 判定理由（对应支柱） |
| --- | --- | --- |
| **① Sensation（感官）** | ★★★ 主打 | 三层后坐力 / 震屏 / 3D 枪声 / 动态准星 —— 整个阶段 2 就是在做感官（P1） |
| **② Challenge（挑战）** | ★★★ 主打 | 对枪胜负、压枪技巧、弹道可背 —— 玩家对抗是核心（P1/P2） |
| **③ Fellowship（社交）** | ★★★ 主打 | 4 人联机 / 击杀日志 / 队友图标 / 局域网聚会 —— 联机对战小游戏的底色（P2/P3） |
| ④ Narrative（叙事） | ★☆ 弱 | Miku 主题是**氛围**而非剧情；无战役、无角色弧 |
| ⑤ Discovery（探索） | ★☆ 弱 | 无开放地图、无隐藏要素；地图是纯竞技空间 |
| ⑥ Expression（表达） | ★★ 辅助 | 技能表达（操作）+ 外观表达（角色模型 / 武器外观 / 皮肤），但装饰不同步 |
| ⑦ Fantasy（幻想） | ☆ 无 | 不做角色扮演 / 代入 |
| ⑧ Submission（休闲/放空） | ★ 弱 | 单局短、可挂机刷人机，但不作为设计目标 |

> **主打三类结论**：**Sensation + Challenge + Fellowship**。三者正是「射击手感（Sensation）+ 多人对枪（Challenge）+ 网络同步联机（Fellowship）」，与用户定位**完全一致**。
> **⚠ 支柱漂移风险**：若后续为追求「内容丰富」而加剧情 / 开放玩法 / 探索元素，会稀释这三类主打美学 —— 见 `99_consistency_review.md` 的对应 CONCERNS。
