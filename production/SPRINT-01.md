# SPRINT-01 · 「能打完一局」

> **Task ID**：S1 ｜ **作者**：游承峰（team-lead · 主理人汇编）｜ **状态**：待启动
> **上游**：`production/epics/README.md`（依赖拓扑）、`design/gdd/`（全部）、`docs/architecture/`（ADR-001~007）
> **汇编依据**：EP-1~EP-5 / 24 Story 的依赖拓扑 + 用户已拍板的 23 项设计决策
> **评审强度**：lean（单人原型，不设 full 评审门；出口判据以「可自动验证」为硬要求）

---

## 1. 冲刺目标（一句话）

> **让 4 人 FFA 对局能完整跑通并正确判定胜负——且阵营显示与伤害路由不再互相牵制。**

选这个目标的理由：项目**唯一的结构性阻塞 C-1（无胜负条件）**至今未落地。比赛能打完之前，
竞技场场地（EP-1）和 HUD 表现（EP-4）都缺少可验证的对象——先让规则跑起来，再让场地和表现跟上。

---

## 2. 范围（本冲刺的 Story）

| 顺序 | Story | Epic | 规模 | 依赖 | 关键产出 |
| --- | --- | --- | --- | --- | --- |
| 1 | **ES-3.1** | EP-3 | M | — | `ScoreManager` 节点 + 数据契约落地（按 `01_core_loop.md` 附录 A） |
| 2 | **ES-2.1 + ES-2.2**（**必须同批**） | EP-2 | S+S | — | 伤害路由改能力探测（`has_method("apply_network_damage")`）+ 远程玩家归 `enemy` |
| 3 | **ES-2.3** | EP-2 | S | ES-2.2 | 显示侧 FFA 敌对渲染；`teammate_icons` 停用 |
| 4 | **ES-3.2 / ES-3.3 / ES-3.4** | EP-3 | M+M+S | ES-3.1 | 击杀上报 RPC + 状态机（`IDLE→COUNTDOWN→LIVE→ENDED`）+ 计时/胜负 + 同步信号总线 |
| 5 | **ES-2.4** | EP-2 | S | ES-2.1~2.3 | 启用 `test_damage_routing` |
| 6 | **ES-3.5** | EP-3 | S | ES-3.1~3.4 | 新建 `test_score_manager.gd` |
| 7 | **ES-5.5** | EP-5 | S | ES-5.4 ✅ | headless 静默验证脚本（把「跑一遍测试」变成一条命令） |

**为什么 2 和 3 排在 EP-3 之前**：EP-2 是 P0 关键回归（`test_damage_routing` 目前是唯一的 pending 套件），
且它与 EP-3 无依赖关系——**先清掉这个「改了会静默弄坏联机伤害」的雷**，后续所有涉及玩家的改动才安全。

---

## 3. 出口判据（全部必须满足）

| # | 判据 | 验证方式 |
| --- | --- | --- |
| G1 | `tests/suites/test_damage_routing.gd` 由 `○ PENDING` 转为 `✓`，**4 用例全绿**（含 AC-F1 运行时断言 `test_friendly_group_empty_in_ffa`） | 跑 `tests/test_runner.tscn` 看汇总 |
| G2 | 新建 `test_score_manager.gd` 覆盖「15 杀触发 / 5 分钟超时 / 平分比 deaths / 中途离开」四路径 | 同上 |
| G3 | **全量回归 0 失败**（含既有 16 用例 / 52 断言） | 退出码 = 0 |
| G4 | 两人联机实测：击杀计数全端一致、15 杀触发 `match_ended`、伤害只结算在受害者端 | 双进程 headless 实测 |
| G5 | `control_checklist §4` 的 7 条不变量全部未被破坏 | `test_invariants.gd` |

> ⚠ **G4 是硬要求**。C-16 的风险正是「只改一半会静默弄坏联机伤害」——单机跑绿**不能**证明 EP-2 正确。

---

## 4. 执行顺序与并行机会

```
 阶段 A（无依赖，可并行）
 ┌─────────────────────────────┐   ┌─────────────────────────────┐
 │ ES-3.1 ScoreManager + 契约   │   │ ES-2.1+ES-2.2 路由+组归属    │
 │ （新增文件为主，风险低）      │   │ （四文件同改，必须一次成型）  │
 └──────────────┬──────────────┘   └──────────────┬──────────────┘
                │                                 │
 阶段 B          ▼                                 ▼
 ┌─────────────────────────────┐   ┌─────────────────────────────┐
 │ ES-3.2/3.3/3.4 RPC+状态机    │   │ ES-2.3 显示侧 → ES-2.4 启用  │
 └──────────────┬──────────────┘   └──────────────┬──────────────┘
                │                                 │
 阶段 C          └────────────┬────────────────────┘
                              ▼
              ES-3.5 + ES-5.5（回归与静默验证）
                              ▼
                     G1~G5 出口评审
```

**并行建议**：阶段 A 的两条线**文件集不重叠**（EP-3 主要新增 `score_manager.gd`；EP-2 改
`player.gd` / `weapon.gd` / `knife.gd` / `minimap.gd` / `teammate_icons.gd`）→ 可由两个 worker 并行。
阶段 B 起两条线开始收敛，建议串行。

---

## 5. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| **EP-2 只改一半**（`player.gd` 改了、`weapon.gd` 没改） | 玩家伤害落到广播分支 → **联机伤害损坏**，且单机测不出来 | ES-2.1+ES-2.2 **强制同批提交**；ADR-007 的 Consequences 已列全 5 个文件；G1+G4 双闸门 |
| 能力探测 `has_method("apply_network_damage")` 被未来非玩家节点命中 | 误判为「玩家」走 rpc_id | 在 `player.gd:342` 该方法处注释标注为「玩家身份契约」（EP-2 已列） |
| ScoreManager 权威归属设计不当（房主 = peer 1） | 迟到加入 / 房主中途离开时计分错乱 | `01_core_loop.md` 附录 A.9 已列 6 类边界；G2 要求覆盖其中 4 类 |
| `hit_confirmed` 现状只给名字不给 peer id | 击杀归因拿不到 victim_id | EP-3 已识别（附录 A 标注「需工程补」），属 ES-3.2 范围 |
| 冲刺范围膨胀（顺手做 EP-1/EP-4） | 出口判据失焦，回归变慢 | 明确排除（见 §6）；EP-1/EP-4 留到 S2 |

---

## 6. 明确不在本次范围

- **EP-1 竞技场几何**（ES-1.3 12 掩体 / ES-1.4 碰撞层 / ES-1.5 人机刷新校验）—— 不阻塞胜负逻辑，留 S2
- **EP-4 HUD / UX**（比分板 / 结算面板 / 重生倒计时 / 加载倒计时）—— 依赖 ES-3.4 完成，留 S2
- **EP-5 其余**（ES-5.1 手雷权威 / ES-5.2 受伤音效 / ES-5.3 外观同步评估）—— 留 S3
- 任何**新玩法/新系统**：本冲刺不新增设计决策，严格按已拍板的 23 项执行

---

## 7. 后续冲刺预告（仅路线示意，细节待 S1 后重排）

| 冲刺 | 主题 | 主要内容 |
| --- | --- | --- |
| **S2** | 「场地与表现成型」 | EP-4 HUD/UX 全部（比分板 / 结算 / 重生倒计时 / 加载倒计时）+ EP-1 竞技场（12 掩体 + 碰撞层）→ **此时可玩性首次完整**。✅ **ES-4.4（加载倒计时 + 冻结输入）前置已定稿**：EP-3 补状态同步 RPC `sync_match_state`（`01_core_loop.md` 附录 A.4 已由 design-strategist 正式裁定；UI 规格见 `04_ux_flow.md §3.4`），客户端据此获知 COUNTDOWN 触发时机 |
| **S3** | 「打磨与可访问性」 | EP-4.5 FFA 显示一致性 + EP-5 手雷权威 / 受伤音效 / 外观同步评估 + EP-1.5 |
| **S4（候选）** | 「可读性修复」 | EP-4 的 H1 描边 / H2 假接触阴影（⚠ 实现方式待工程验证，降级路径见 `asset_spec_arena.md §6.5`），验收底线 **SR-4「25 m 可识别」** |
| **S5（候选）** | 「发布准备」 | 构建/版本/补丁说明（阶段 7，`release-ops-lead`） |

> ⚠ **可读性修复（S4）不是可选装饰**。支柱 P3 是「明亮舞台上的快节奏对枪」，而现状实测
> 角色躯干与背景明度差 **< 0.05**（SR-1 要求 ≥ 0.25）——**对枪的前提取决于 1 秒内认得出人**。
> 之所以排到 S4 而不是 S1：它不阻塞规则跑通，但**必须在对外发布前完成**。

---

## 8. 起始状态基线

> ⚠ **本节是 S1 启动时的历史快照（kickoff baseline），非当前状态**——保留原值供审计对照。
> **当前状态见 §9 变更记录末尾「S1 收口」条目。**

| 项目 | 值（S1 启动时） |
| --- | --- |
| 代码 | 30 个 `.gd` / 13 场景 / 5,788 行 GDScript，功能阶段 1~5 已落地 |
| 文档 | `design/` 2,046 行 / 10 份 + `docs/architecture/` 1,034 行 / 8 份（含 7 条 ADR）+ `production/` |
| 测试 | `tests/` 框架已就绪：16 用例 / 52 断言 / 0 失败 / 1 pending 套件（`test_damage_routing`） |
| 设计决策 | 23 项全部拍板，0 待决 |
| 已知缺口 | C-16（唯一功能性待实现）/ C-3 / C-6 / C-9（待评估）/ C-10 / C-11（低风险修正） |
| 未提交 | 本轮全部文档 + 3 处代码修正（`README.md` / `minimap.gd` / `main.tscn`）**均未 git commit** |

> 📌 **C-16 的当前状态**：**已实现**（`e5fae14` / `d5104de`：`player.gd::_setup_remote_player()` 已改 `add_to_group("enemy")`，伤害路由改用能力探测 `has_method("apply_network_damage")`，`ADR-007` 固化，`test_damage_routing.gd::test_friendly_group_empty_in_ffa` 覆盖 AC-F1）。上表「已知缺口」一行**仅为启动时快照，不再代表现状**。

---

## 9. 变更记录

| 日期 | 变更 | 作者 |
| --- | --- | --- |
| 2026-10-06 | 初版汇编：S1 范围 / 出口判据 G1~G5 / 执行顺序 / 风险 / S2~S5 路线 | 游承峰（主理人） |
| 2026-10-06 | G1 判据补注：第 4 用例为 AC-F1 运行时断言 `test_friendly_group_empty_in_ffa`（此前 suite 只有 3 个源码字符串用例，运行时缺口已补）；EP-2 实测 `test_damage_routing` 4 用例 / 8 断言全绿 | 程基岩（engineering-lead） |
| 2026-10-06 | G2 判据补充：`test_score_manager.gd` 随 EP-3/ES-3.2~3.4 扩至 **30 用例 / 115 断言**（原 12 / 32），覆盖「15 杀触发 / 5 分钟超时 / 平分比 deaths / 中途离开」四路径 **+** 击杀上报核心 / 归因安全解析 / 状态机迁移 / 同步应用 / 信号双路径；G2 的用例数基线由 12 提至 30。全量回归 **50 用例 / 175 断言 / 0 失败 / exit 0** | 程基岩（engineering-lead） |
| 2026-10-06 | **S2 前置依赖登记**：ES-4.4（加载 3-2-1 倒计时 + 冻结输入）依赖 EP-3 补一条状态同步 RPC `sync_match_state`（房主→全端，载荷 `state, countdown_remaining`）——`01_core_loop.md` 附录 A.4 已提增补建议（待 design-strategist 确认），A.9.1 记录了客户端临时推断规则；**手雷击杀缺口**登记进 EP-5 ES-5.1（手雷击杀不计入比分，依赖权威结算落地后接入 `report_kill`） | 程基岩（engineering-lead） |
| 2026-10-06 | **S2 前置已定稿**：design-strategist 裁定认可 `sync_match_state`（方向 A）——`01_core_loop.md` 附录 A.4 该行转正式契约、A.9.1 近似解作废（改「客户端状态跟随规则」）；新增 `01_core_loop.md §5.1` 与 `04_ux_flow.md §3.4` 倒计时 UI 规格；EP-4 ES-4.4 前置改「已确认」；`99_consistency_review.md` 追加流程教训（跨端要求须写信息来源） | 文策渊（design-strategist） |
| 2026-10-06 | **A.5 信号形态裁定（team-lead 裁决）**：倒计时 UI 的数据源定为**新增独立信号 `countdown_updated(remaining: float)`**，**不扩** `match_state_changed` 签名。两方案曾分歧（设计侧主张扩签名 `(state, countdown_remaining)`，工程侧主张独立信号）；裁定取独立信号——既有签名是对 HUD 的契约，扩签名属破坏性变更，且状态迁移（稀疏）与倒计时（高频）语义频率不同不应共用一条信号。设计侧「信号 = 本地通知总线、UI 只绑信号不绑 RPC」的洞察予以保留。同步 `01_core_loop.md §5.1/A.5`、`04_ux_flow.md §3.4`、EP-4 ES-4.4 | 游承峰（team-lead） |
| 2026-10-06 | **G4 观测层（临时）**：`score_manager` 4 条信号全工程零消费者 + 无任何 `print` → G4 三条断言在运行时可观测性为零。新增旁路 `scripts/debug/match_debug_probe.gd`（`MBDBG=1` 启用，默认静默、生产零副作用）+ `main.tscn` 挂节点。**S2 的 EP-4 HUD 落地后须整体删除** | 程基岩（engineering-lead） |
| 2026-10-06 | **C-17 收口（G4 阻塞项 · 已解除）**：用户双端实测报「看不见其他玩家」。诊断（证据链排除相机/渲染/同步）确证根因为**可定位性缺失**——2 人出生相距 64m（对角 90.5m）> `world_radius 60`，而 `minimap.gd::_draw_group()` 对超距敌人 `continue` **直接丢弃**，HUD 又无方向指示。① **R1 `7923b68`**：`main.gd::spawn_index_for()` 改用「房间内排序列表下标 % count」，弃用 `id % count`（后者在 id 差为 4 倍数时**必撞同点**）；② **R2 `b370974`**：AC-3 超距敌人改为在**圆周边缘画三角箭头 ▲**（只给方位、不给距离），`world_radius` 保持 60。设计裁定：出生点按人数自适应（4=四角/3=三角/2=相邻角 64m），**雷达外敌人一律靠 AC-3**（3 人对角 90.5m 数学上不可消除）。**C-16 同步确认已实现**（`e5fae14`/`d5104de`）。测试基线 **67 用例 / 213 断言 / 0 失败**。**G4 尚待用户重跑双端实测** | 游承峰（team-lead） |
| 2026-10-06 | **C-18 修复（比分恒 0 的根因）**：第二次 G4 实测暴露「两端扣血/阵亡全对，但 `scores` 永远 `{kills:0,deaths:0}`」。根因：`weapon.gd::_deal_damage()` 用**射手端本地**的 `collider.health` 判生死，而远程玩家血量走 `apply_network_damage`（`call_remote`）**只在受害端结算、不回传** → 射手端对方血量恒为满值 100 → `killed` 恒假 → `_report_kill_if_player()` 从不执行。修复：致死判定归血量真值那一端（`player.gd::apply_network_damage` 归零时 `net_confirm_kill.rpc_id(射手 peer id)` 回传，射手端再走 A.4 原路径），`was_alive` 守卫保证只回传一次。新增 `test_kill_attribution.gd`（9 用例）+ 观测层 `kill_confirmed` 事件（此前该缺陷在日志里零可见性，连躲两轮 G4）。`67/213 → 75/231` | 程基岩（engineering-lead） |
| 2026-10-06 | **C-19 修复（渲染驱动崩溃）**：G4 第三次实测时窗口模式**启动即崩**（`Debugging process stopped`），且崩在计分逻辑之前。根因为 `project.godot`锁死 `rendering_device/driver.windows="d3d12"`，而 D3D12 后端在本机 AMD RX 6750 GRE 上初始化纹理必失败（`CreateResource failed 0x80070057` → `!texture.driver_id` → `uninitialized RID` → `tex is null`），渲染器拿空 RID 继续走 → 进程死。同款级联见 godot#117115（报告者同为 AMD，明确「仅 D3D12 复现、Vulkan 正常」）。实测对照 **D3D12=9 条错误 / Vulkan=0 条**。改 `"vulkan"` + `control_checklist §4-10` 锁死。**元教训：`verify.sh` 走 `--headless` 不经过渲染后端 ⇒自检全绿不能证明渲染可用**，渲染缺陷只能靠窗口实测发现 | 程基岩（engineering-lead） |
| 2026-10-06 | ✅ **G4 判定通过（双端窗口实测· 用户执行 · peer 1 vs 627787033）**：三条判据逐条命中日志证据——① **计数全端一致**：房主 `kill_confirmed victim=627787033` → 比分 1→15 递增，客户端 `(via sync_scores)` 收到完全相同的 `{1:{kills:15,deaths:0}, 627787033:{kills:0,deaths:15}}`，kills/deaths 严格互补；② **15 杀触发 `match_ended`**：第 15 次确认后 `match_state_changed ENDED` + `match_ended winner=1`，**房主与客户端两端都收到同一次结算**；③ **伤害只结算在受害端**：房主日志只出现 `peer=1` 掉血、客户端日志只出现 `peer=627787033` 掉血，`hp=75→50→25→0` 序列互不串端。**附带验证两条加分路径**（原计划外）：④ **结算后比分冻结正确** —— `match_ended` 后房主仍收到 2 次 `kill_confirmed`，比分保持 15不动（`_apply_kill` 在 `ENDED` 早退）；⑤ **反向击杀也通** —— 客户端日志末尾出现 `kill_confirmed victim=1`，证明归因链路**双向**可用（非仅房主→客户端单向）。⚠️用户同时反馈「没有计分板/ 没有 15 杀胜利提示」——经核为**预期**：`score_changed` / `match_ended` 全工程**零消费者**，计分板与结算面板是 **EP-4 ES-4.1 / ES-4.2（⏳ 待实施，S2 范围）**，不在 G4 判据内。**S1 出口判据 G1~G5 至此全部关闭** | 游承峰（team-lead） |
| 2026-10-06 | ✅ **ES-4.1 实现（HUD 比分板）**：新增 `scripts/ui/scoreboard.gd` + `scenes/ui/scoreboard.tscn`，`hud.gd` 接线 `` 并在 `_unhandled_input` 处理 `scoreboard` 动作（Tab / `4194306`），`project.godot` 注册该动作。实现取舍与 `ScoreManager` 同构：**纯逻辑 / 渲染分离**（7 个静态纯函数`build_rows`/`display_name_for`/`format_clock`/`kd_text`/`is_near_target`/`compact_row_text`/`full_row_text`），headless 可直接断言。排序口径**与 `_evaluate_winner()` 对齐**（击杀降序→死亡升序→peer_id 升序，末位保证跨端不抖动）；领先者取「击杀并列最高」全部行且**0:0 时无人领先**；**不自行判定胜负**（纪律锁）。Tab 完整榜为**非模态**覆盖层（不进 `game_ui`），被其它 `game_ui` 界面屏蔽。测试 `test_scoreboard.gd` **20 用例**，全量 **98 用例 / 287 断言 / 0 失败**。**修C-20（`compact_row_text` 格式串漏 `%s`）** —— 4 参数喂 3 占位符，GDScript 运行期静默返回空串，UI 表现为整条条目空白；已加`control_checklist §4-12`。**修 C-21（C-19 回退）** —— 发现 `commit a3efe27` 用 `git checkout -- project.godot` 清理调试日志时，把 C-19 刚修好的 `driver.windows="vulkan"` 整块删掉了，因 `verify.sh` 走 headless 而**一直无人发现**；已恢复并新增 `test_render_driver.gd`（3 用例）+ `§4-11` 锁死。窗口实测（Vulkan / RX 6750 GRE，300 帧）0 错误，实测文案 `▶ 玩家1  0`、`1　玩家1　0　0　—`、Tab 切换正常| 程基岩（engineering-lead） |
| 2026-10-06 | ✅ **ES-4.2 实现（结算面板 match_result）**：新增 `scripts/ui/match_result.gd` + `scenes/ui/match_result.tscn`（`CanvasLayer` layer=4，`panel` 结构参照 `death_screen.tscn`，底衬沿用 §3.1 `#050F1A @ 0.45`），挂进 `hud.tscn` 并在 `hud.gd` 按 ES-4.1 同构方式接线（`_bind_match_result()`：按节点名取 `ScoreManager` + 每帧重试兜底）。**沿用 ES-4.1「纯逻辑/渲染分离」取舍**：`title_for` / `winner_text` / `format_duration` / `elapsed_seconds` / `build_standings` / `row_text` / `button_caption` / `can_request_reset` 全部静态纯函数，headless 可断言。**排序与文案一律复用 `Scoreboard`**（`build_rows`/`full_row_text`/`display_name_for`/`format_clock`），避免「比分板第一名 ≠ 结算面板第一名」。**本局时长** = `match_duration - time_remaining`（提前结束不谎报），**不显示小时**（上限 300 s→ 小时位永不可达，且与比分板 `MM:SS` 同格式），`3600s → "60:00"` 已钉测试。**「不暂停」与「屏蔽输入」分别加锁**：面板全程不碰 `get_tree().paused`（§3.2 覆盖层），但**要** `set_input_blocked(true)`（释放鼠标才能点按钮 + §4-1 双闸门连带关武器触发器），`close_ui` 对称恢复。客户端 `[再来一局]` 显示「等待房主…」且 `disabled`，文案与可点性同源派生（`request_reset()` 客户端本就 `return`）。只绑 `match_ended` 本地信号、**零 RPC**、**零胜负重算**。新增 `test_match_result.gd` **36 用例 / 148 断言**（含互斥实测、`paused` 运行时断言、QA AC-A4 排序逐行序列相等、**QA B2/AC-B7「Tab 榜在结算面板打开时不响应」端到端实测**）。**变异测试 7/7 全杀**（`tools/mutation_es42.py`）——其中 M3「面板自行按 kills 重算胜负」**首轮存活**，因纪律锁只搜`"kills >"` 单条字面量被 `get("kills",0) > 0` 换写法绕过，已改为语义级锁（代码中不得出现 `kills`/`deaths` 任意比较运算 + `winner_id` 形参不得被赋值）。**窗口实测**（Vulkan，非 headless）13/13 断言通过、**渲染 0 错误**，面板实测文本 `对局结束` / `🏆 你 获胜` / `本局时长 03:24` / `1　玩家1　15　3　5.0`。回归基线 **98/287/0 → 134/435/0** | 程基岩（engineering-lead）|
| 2026-10-06 | 🧹 **G4 观测层按约删除（EP-4 落地收尾）**：兑现第 141 行「S2 的 EP-4 HUD 落地后须整体删除」的立项约定，删除 `scripts/debug/match_debug_probe.gd` + `.uid`（`scripts/debug/` 目录随之整体移除）、`main.tscn` 的 `MatchDebugProbe` 节点与 `ext_resource`（`load_steps` 13 → 12）。**为什么现在能删**：观测层当初是为「EP-4 未落地、`ScoreManager` 5 条信号全工程零消费者」而加的旁路，其观测职责已全部由 UI 接管——`score_changed` → 比分板（ES-4.1）、`match_ended` → 结算面板（ES-4.2）、`died` → 死亡界面 + 击杀日志（ES-4.3）、`health_changed` → 血条（既有HUD）。**信号已从「人肉看 stdout」转为「玩家看得见的 UI」，可观测性不降反升**。**测试随之调整**：`test_kill_attribution.gd::test_probe_observes_kill_confirmation` 整体删除（其唯一守门对象就是那个观测层，对象不存在则用例无意义）。⚠️ 关键教训：该用例原本写了 `pending()` 兜底，但 `pending()` 只是**记一条 note**、**不会**让 suite 被跳过（`is_pending()` 才是 suite 级开关且本 suite 未重写）——所以文件删除后它**静默退化成一个什么都不验证的空壳**：用例数仍显示 136、断言少 2，看着一切正常而守门能力已名存实亡。**这比直接删掉更危险，已加 `control_checklist §4-15`**。回归基线 **136/441/0 → 135/439/0**（用例 -1，断言 -2） | 程基岩（engineering-lead）|
