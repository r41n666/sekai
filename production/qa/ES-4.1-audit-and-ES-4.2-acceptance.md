# ES-4.1 测试基线审计 + ES-4.2 验收清单

> **审计人**：严守真（quality-lead）｜**日期**：2026-10-06｜**审计对象**：commit `1ff2a62` feat(ES-4.1)
> **方法**：独立复跑 `tools/verify.sh` + **实测变异测试（12 个变异体）** + GDD 逐条对照 + 探针取证
> **性质**：**独立质量门复核**，非实现任务。本审计**未改动任何工程/测试代码**（变异仅在隔离 worktree 内进行）。

---

## 0. 质量门判定（先看结论）

# 🔶 CONCERNS（不阻塞 ES-4.1 收尾，但必须在ES-4.2 前补齐）

**一句话结论**：ES-4.1 的**纯逻辑层是可靠的**（7个纯函数的排序/守卫/边界实测全部被打红，锁得住），
但**渲染层与配置层存在 4 处「变异后仍全绿」的空洞**——它们恰好是用户眼睛能看到的那一层。

| 维度 | 判定 | 依据 |
| --- | --- | --- |
| 声称三元组复现 | ✅ **98 / 287 / 0** | 隔离 worktree 独立复跑一致 |
| 纯逻辑断言强度 | ✅ PASS | 12 变异中 7 个被打红，含排序反向 / 去守卫 / 不稳定排序 |
| 渲染层断言强度 | ⚠️ **CONCERNS** | 4 个变异存活（闪烁/截断/互斥/昵称） |
| headless 覆盖边界 | ⚠️ 已识别 | 见 §4，属结构性限制，非本次引入 |
| 工作区洁净度 | ✅ 干净 | 见 §6 |

**阻塞项（ES-4.2 开工前必须处理）**：**B1**、**B2**（详见 §3）。

---

## ① 变异测试结果表

隔离环境：`git worktree add /c/Users/Administrator/mutation_qa/iso 1ff2a62 --detach`（**不碰主工作区**）。
每个变异 = 改 1 处 → 跑完整 `verify.sh` → 记录 → 逐个还原（`还原: clean` 已逐条确认）。

| # | 变异体（最常见的错误写法） | 预期 | 实际失败数 | 结论 |
| --- | --- | --- | --- | --- |
| M1 | `build_rows` 排序 kills 降序 → **升序**（`>` 改`<`） | 打红 | **5** | ✅ **KILLED** |
| M2 | 移除**死亡数平局判据**（`if a.deaths != b.deaths` → `if false`），使排序口径与胜负脱钩 | 打红 | **1** | ✅ **KILLED** |
| M3 | `is_near_target` 去掉 `kills < target` **守卫**（已达标也闪） | 打红 | **1** | ✅ **KILLED** |
| M4 | `format_clock` `ceil` → **`floor`**（倒计时取整方向反） | 打红 | **0** | 🔴 **SURVIVED** |
| M5 | `is_leader` 去掉 `top_kills > 0` 守卫（0:0 全高亮） | 打红 | **2** | ✅ **KILLED** |
| M6 | `display_name_for` 昵称表守卫反转 | 打红 | — | ⚪ 未应用（pattern 未命中，见注1） | 
| M7 | `kd_text` 去掉 0杀0死占位符分支（`0/0` 打成 `0.0`） | 打红 | **2** | ✅ **KILLED** |
| M8 | `_blocked_by_other_ui` 去掉 `ui == self` 判断 | 打红 | **0** | 🔴 **SURVIVED** |
| M9 | `_rebuild_compact_rows` 去掉 `MAX_ROWS` 截断 | 打红 | **0** | 🔴 **SURVIVED** |
| M10 | `_apply_critical_flashing` 相位判断 `on := true`（**闪烁常亮不闪**） | 打红 | **0** | 🔴 **SURVIVED** |
| M11 | `refresh_names` 去掉 `is_online` 早退 | 打红 | **0** | 🔴 **SURVIVED** |
| M12 | 排序去掉 `peer_id` 兜底 → **不稳定排序**（跨端抖动） | 打红 | **1** | ✅ **KILLED** |

> 注1：M6 因源码含制表符缩进、正则未命中而未施加，**已还原，未污染工作区**；其等价守卫（`names.has`）已由
> `test_display_name_fallback` 的三条断言实际覆盖，故不重复变异。

**统计：12 个变异 → 7 KILLED / 4 SURVIVED / 1 未应用。**
存活率 33%，且**全部集中在渲染层与状态层**，纯逻辑层 100% 被锁。

### 存活体的性质区分（重要）

存活 ≠ 有Bug。经探针实测，**M8/M9/M10/M11 的产品代码行为是正确的**：

```
PROBE M9注入 11 人 → 紧凑条实际行数 = 8（MAX_ROWS=8）    ← 截断真的生效
PROBE M10 亮相位: 14杀(临界).modulate=(1,1,1,1)   3杀(非临界)=(1,1,1,1)
PROBE M10 灭相位: 14杀(临界).modulate=(0.62,0.68,0.74,1)  3杀(非临界)=(1,1,1,1)  ← 闪烁真的落到 Label 上
PROBE M8  假界面 is_open=true → show_full() 后 Full.visible=false      ← 互斥真的生效
PROBE M11 NetworkManager.is_online=false → refresh_names() 首行早退    ← 离线早退真的生效
PROBE M4  ceil 下: 0.2→00:01   59.5→01:00   204.4→03:25                ← 取整方向的差异证据
```

**结论：这是「测试没覆盖」，不是「代码写错了」。** 但按项目已两次栽在弱断言上的历史，
**未覆盖 == 未锁死 == 随时可能被下一次改动悄悄改坏**，必须补。

---

## ② 弱断言清单（含重写建议）

### 🔴 W1（高危）`test_format_clock`：只测整数秒，倒计时取整方向完全没锁

- **文件**：`tests/suites/test_scoreboard.gd:119`
- **现状**：`format_clock(204.0 / 300.0 / 59.0 / -5.0)` —— **四个输入全是整数**。
  整数上 `ceil(x) == floor(x)`，所以「向上取整还是向下取整」这条契约**一条断言都没锁**。
- **实测危害**：倒计时每帧递减、几乎必然出现小数。`ceil` 改成 `floor` 后，
  `0.2` 秒从 `00:01` 变 `00:00`、`59.5` 秒从 `01:00` 变 `00:59` —— **临近归零时反复跳变**，
  而这正是「最后 1 秒最该紧张」的临场感。**全仓 287 条断言一条都不会红。**
- **重写建议**：

```gdscript
func test_format_clock_rounds_up_not_down() -> void:
	# ⚠ 取整方向必须用**非整数**钉：整数上 ceil==floor，测不出方向。
	# 倒计时每帧递减必然产生小数，floor 会让「剩 0.2 秒」显示成00:00 并反复跳变。
	check_eq(_sb.format_clock(0.2), "00:01", "0.2 秒应向上进位到 00:01，不得显示 00:00（floor 会导致末秒跳变）")
	check_eq(_sb.format_clock(59.5), "01:00", "59.5 秒应为 01:00（floor 会得 00:59，少显示 1 秒）")
	check_eq(_sb.format_clock(204.4), "03:25", "204.4 秒应向上进位到 03:25")
	check_eq(_sb.format_clock(60.9), "01:01", "60.9 秒应为 01:01")
```
（变异 M4 已实测：该写法下 M4 会被打红。）

### 🟠 W2（中危）`_blocked_by_other_ui` / `show_full`：Tab 互斥零覆盖

- **位置**：`scripts/ui/scoreboard.gd:297`（`scripts/` 只读，仅记录）
- **现状**：GDD §3.1.1 明确「死亡界面 / 结算面板打开时，`Tab` 榜**不响应**」。
  该分支**没有任何测试**——既没测被阻塞时 `Full.visible` 保持 false，
  也没测 `ui == self` 这个「跳过自身」守卫（正是M8 变异体）。
- **重写建议**：需要一个 `tests/framework/` 下的**假 `game_ui` 成员**（带 `is_open()/close_ui()`），
  进组后断言 `show_full()` 不生效；再验 `close_ui()` 后能正常展开。

### 🟠 W3（中危）`MAX_ROWS` 截断零覆盖

- **现状**：`MAX_ROWS := 8`，`if i >= MAX_ROWS: break`。实测 11 人时确实只渲染 8 行，
  但**没有任何断言**。FFA 设计上限 4 人，而 `MAX_ROWS=8留余量`——一旦有人把它改成 4 或删掉，
  常驻条会静默截掉真实玩家。
- **重写建议**：注入 11 人 → 断言 `Compact/Box/Rows.get_child_count() == 8`（用探针已验证可行的写法）。

### 🟠 W4（中危）`_apply_critical_flashing`：闪烁只测了纯函数，没测「落到 Label 上」

- **现状**：`is_near_target()` 这个**纯函数**测得很好（M3 打红），但
  **「临界 → 该Label 的 `modulate` 被改暗」这条链路完全没测**（M10 存活）。
  §3.1 要求的是「该条目**闪烁**」，纯函数返回 true 不等于眼睛看到在闪。
- **重写建议**（探针已证可行）：设`_flash_phase = FLASH_INTERVAL`（灭相位）后调
  `_apply_critical_flashing()`，断言临界行 `modulate ≈ (0.62,0.68,0.74,1)`、非临界行 `== (1,1,1,1)`。

### 🟡 W5（低危）`refresh_names` 昵称热更新零覆盖

- **现状**：M11 存活。离线时首行即早退，而 headless 默认离线
  （实测 `is_online=false`）→ **离线路径在现有 harness 里根本不可达**。
- **重写建议**：改为可注入（`refresh_names(names: Dictionary = {})`），
  或在测试里直接断言 `build_rows(..., names)` 已覆盖昵称（当前已覆盖），
  并把「在线昵称后到」列为**窗口实测项**而非自动化项。

### 🟡 W6（低危·可维护性）`test_hud_connects_score_changed` 是**弱文本断言**

```gdscript
check_true(src.find("score_changed") >= 0 || src.find("_scoreboard.bind") >= 0, ...)
```
`||` 让两个条件任一满足即通过，**近乎恒真**——它无法区分「真的连上了」与
「注释里提到了这两个词」。建议改为断言 `hud.gd` 中存在 `_scoreboard.bind(` 调用（去掉 `||`），
或升级为**实例化 HUD + 注入假 ScoreManager，断言信号真的连上**（工程量更大但更硬）。

---

## ③ 覆盖缺口清单（按风险排序）

| # | 缺口 | GDD 依据 | 风险 | 证据 |
| --- | --- | --- | --- | --- |
| **B1** | **倒计时取整方向未锁** | §3.1「剩余 03:24」 | 🔴 **高**：末秒跳变，破坏临场感 | M4 存活 + `0.2→00:01` |
| **B2** | **Tab 榜互斥未测** | §3.1.1「死亡界面/结算面板打开时不响应」 | 🔴 **高**：ES-4.2 上线后**立刻成为真实场景**（结算面板常在`game_ui` 组） | M8 存活 |
| **B3** | 临界闪烁未测到 `modulate` | §3.1 临界提示① | 🟠 中：闪烁是规格明文要求 | M10 存活 |
| **B4** | `MAX_ROWS` 截断未测 | §3.1 布局 | 🟠 中：超员静默截断 | M9 存活 |
| **B5** | 「终局冲刺」≤30s 边界未测 | §3.1 临界提示② | 🟡 低：探针实测 `t=30.0→true`、`30.1→false` 行为正确，但无回归保护 | — |
| **B6** | `refresh_names` 昵称后到更新 | §3.1.1 数据同源 | 🟡 低 | M11 存活 |
| **B7** | 明度差 ≥0.3（AC-F4）未测 | §6/ ES-4.5 | 🟡 低：属ES-4.5 范围 | — |
| **B8** | `_rows_box` 重建时的 `queue_free` 泄漏 | 实现细节 | 🟢 极低 | — |

> **B2 为什么是阻塞项**：ES-4.2 结算面板**必然**加入 `game_ui` 组。
> 一旦结算面板打开而 Tab 榜仍能弹出，两个全屏面板会**叠加**——
> 这正是 §3.1.1「避免叠加」要防的情况，且**只有自动化测试能挡住**，肉眼极难发现。

---

## ④ headless 盲区清单 + 补验手段建议

`verify.sh` 走 `--headless`，**结构上**测不到下列内容。这是**架构性限制，不是本项目的疏漏**——
`test_render_driver.gd` 的文件头已把这条教训写得很清楚（「走 `--headless`，不经过渲染后端」）。

| 盲区 | 为什么 headless 测不到 | 补验手段（建议） |
| --- | --- | --- |
| **渲染后端** | `--headless` 不初始化渲染设备 | ✅ 已有 `test_render_driver.gd` 读 `project.godot` 文本兜底（**实测有效**：工作区污染时它真的转红了 3 条） |
| **真实字体渲染 / 字形** | 无字体光栅化 | 窗口实测 + 截图目视；或探针读 `font.get_string_size()` |
| **`_unhandled_input` 按键事件流** | headless 无输入设备；且**Runner 不 `await`**，`await` 写不出稳定断言 | 注入 `InputEventAction` 直调 `hud._unhandled_input(ev)`；或窗口实测 |
| **`CanvasLayer` 实际布局 / 遮挡** | 无窗口尺寸与绘制 | 窗口实测（`offset_top=72` 是否真的在指南针下方） |
| **`modulate` 的视觉显著性** | 值算得出，但看不见 | 探针断言数值 + 窗口目视确认「看得出在闪」 |
| **`get_tree().paused` 真实效果** | headless 无帧推进 | 自动化可断言 `paused == false`（见 ES-4.2 AC-N2） |
| **`NetworkManager.is_online = true` 路径** | 测试环境恒离线 | 假 `NetworkManager` 注入 / 双端窗口实测 |
| **`queue_free()` 真实释放** | 帧末才生效 | `await get_tree().process_frame` 后断言子节点数 |

> **⚠ 新发现（框架级）**：`TestSuite` 用例里**`await` 不可靠**——Runner 用`suite.call(name)`
> 同步调用，异步函数在首个 `await` 处返回，后续代码不执行。
> 实测两次探针的 `print` 无输出才发现。**任何需要帧推进的断言，必须用「同步改状态 + 立即断言」写法**
> （`_rebuild*` / `_apply_critical_flashing` 都是同步的，可直接断言），或改造 Runner 支持 `await`。
> **这条直接影响 ES-4.2 的自动化选型**（结算面板开合同理）。

---

## ⑤ ES-4.2 结算面板验收清单

**权威口径**：`04_ux_flow.md §3.2` + `EP-4-hud-and-ux.md §ES-4.2`。
**已勘察的既有范式**：`game_menu.gd`（`_close_other_uis()` + `open_ui/close_ui/is_open`）、
`death_screen.gd`（同类最小实现）、`ScoreManager`（`WINNER_TIE=-2` / `WINNER_UNSET=-1` /
`is_authority()` / `match_ended(winner_id, final_scores)`）。

### A栏 · 必须进自动化回归

| ID | 验收项 | 判定方式 | 依据 |
| --- | --- | --- | --- |
| **AC-A1** | `add_to_group(UI_GROUP)`，`UI_GROUP == "game_ui"` | 契约锁断言 | §3.2 互斥 |
| **AC-A2** | 实现 `open_ui()` / `close_ui()` / `is_open()` 三件套 | 契约锁 | EP-4.2 测试证据 |
| **AC-A3** | **打开时关闭组内其它已开界面**：遍历 `game_ui`，对 `is_open()==true` 的其它节点调 `close_ui()` | **假成员实测**（仿 `fake_ui` 探针法，断言 `close_ui` 被调用 /对方 `is_open()` 变 false） | §3.2 |
| **AC-A4** | **排序口径与 `Scoreboard.build_rows` 完全一致** | 断言两函数对同一 `scores` 输出**逐行 peer_id 序列相等**（≥3 组数据，含并列/同分/0:0） | ⚑两套口径打架是**已登记风险** |
| **AC-A5** | **UI 不得自行重算胜负** | 契约锁：源码内不得出现 `kills >` / `deaths <` / `func _evaluate_winner`；且**不得**出现 `net_match_ended`（只绑本地 signal） | 架构铁律 |
| **AC-A6** | 平局文案：`winner_id == ScoreManager.WINNER_TIE(-2)` → 显示平局，**不显示任何玩家名** | 纯函数断言（建议 `winner_caption(winner_id, names) -> String`） | §3.2 |
| **AC-A7** | 空表/未定：`winner_id == WINNER_UNSET(-1)` → 「无胜者」 | 同上 | `_evaluate_winner` 契约 |
| **AC-A8** | 房主视角：`is_authority()==true` → 按钮文案「再来一局」且**可点** | `button_caption` / `can_request_reset` 纯函数断言 | §3.2 |
| **AC-A9** | 客户端视角：`is_authority()==false` → 显示「等待房主…」且按钮 **disabled**（文案与可点性**必须同源**，避免两处口径打架） | 同上，两条断言都要 | §3.2 |
| **AC-A10** | **不暂停**：`open_ui()` 后 `get_tree().paused == false`，`close_ui()` 后仍 false | 直接断言 | §3.2 + §4 规则 4 |
| **AC-A11** | 完整比分表 5 列（排名/名字/击杀/死亡/KD），KD 口径复用 `Scoreboard.kd_text` | 断言复用同一函数（不复制粘贴实现） | §3.2 + 一致性 |
| **AC-A12** | 由 `match_ended(winner_id, final_scores)` 触发；`bind()` 首帧即刷新（不空窗） | 假 ScoreManager 注入 + 发信号 | 附录 A.5 |
| **AC-A13** | 场景可加载且 `@onready` 路径逐条对齐 | 仿 `test_scoreboard_scene_loadable` 的路径清单断言 | 防运行期空引用 |

### B 栏 · 只能靠窗口实测 / 手动

| ID | 验收项 | 手动 checklist |
| --- | --- | --- |
| **AC-B1** | 面板**全屏**、样式沿用 `game_menu.tscn` StyleBox | 目视：与 Esc 菜单观感一致 |
| **AC-B2** | 「🏆 {名字} 获胜」排版、emoji 在所选字体下**不 tofu** | 目视 + 字体回退检查 |
| **AC-B3** | 按钮**可点**（鼠标已释放） | 实际点一次 `[再来一局]` / `[返回大厅]` |
| **AC-B4** | `[返回大厅]`：联机走 `NetworkManager.leave_game()`，单机走 `change_scene_to_file(HUB_SCENE)` | 两条路径各实测一次 |
| **AC-B5** | 打开面板**不夺取**镜头控制、不冻结画面 | 目视：背景仍在渲染 |
| **AC-B6** | **与死亡界面互斥**的实机表现（B2 的端到端确认） | 死亡时打开结算，确认无叠加 |
| **AC-B7** | Tab 完整榜在结算面板打开时**确实不响应** | 按住 Tab 目视 |
| **AC-B8** | 双端联机：客户端真看到「等待房主…」 | 双窗口实测 |

### C 栏 · 提请注意的规格张力（需用户/主理人裁定）

| # | 张力 | 说明 | 建议 |
| --- | --- | --- | --- |
| **Q1** | **§3.2「不暂停」 vs §4 输入屏蔽矩阵把「结算面板」列为 ❌ 全屏蔽** | §4 规则 1说「任意**模态**界面 → `set_input_blocked(true)`」，但 §3.2 说**不暂停**。二者**不冲突**（`paused` 是场景树开关、`input_blocked` 是玩家输入开关），但很容易被实现成`get_tree().paused = true` | 明确采纳：**`paused` 恒 false + `set_input_blocked(true)`**（与 §4 矩阵一致）。已列入 AC-A10 |
| **Q2** | 房主判定口径 | 全仓**无** `NetworkManager.is_host`；权威口径是 `ScoreManager.is_authority()`（离线或 `NetworkManager.is_server`）。ES-4.2 必须复用它，**不要自造 `is_host`** | 建议 UI 层做纯函数 `can_request_reset(is_authority: bool)`，便于离线单测 |
| **Q3** | `request_reset()` 已有 `if not is_authority(): return` | 客户端按钮即使被误触发也会被权威侧挡下，但**UI 仍应 disabled**（双保险） | AC-A9 |

> **给 engineering-lead 的提示**：审计期间观察到 `scripts/ui/match_result.gd` 已开写，
> 且已采用与 ES-4.1 同构的「纯函数 + 渲染分离」+ `button_caption` / `can_request_reset` 同源设计，
> **方向正确**。请对照上表 A 栏自查，特别是 **AC-A4（排序口径逐行相等）** 与
> **AC-A10（paused 恒 false）** 两条必须进自动化。

---

## ⑥ 给主理人的质量门判定

# 🔶 CONCERNS

**可以放行 ES-4.1 的实现收尾**，理由：
1. 声称三元组**可复现**（98/287/0）；
2. 纯逻辑层断言**扎实**——12 变异中 7 个被打红，覆盖排序方向/去守卫/不稳定排序/取整占位符等最易错写法；
3. 4 处存活项经探针实测**产品代码行为正确**，属「未覆盖」而非「有Bug」；
4. 现有测试**没有引入假绿**——我用工作区污染（删掉 Vulkan 行）实测 `test_render_driver.gd` 真的转红，
   证明该防线**有效**，非摆设。

**但必须登记为阻塞项，ES-4.2 开工前处理**：
- **B1**：倒计时取整方向未锁（`ceil`→`floor` 全绿）——建议直接补 W1 那4 条断言，成本极低。
- **B2**：Tab 榜互斥未测——**ES-4.2 一上线这就会变成真实场景**，建议与ES-4.2 同批补（AC-A3/AC-B7）。

**建议但不阻塞**：B3 闪烁 modulate、B4 MAX_ROWS 截断补测（探针已证可行，模板现成）。

**质量门性质**：本判定为**建议性门控（advisory）**，最终放行由用户决定。

---

## ⑥ 工作区洁净度确认

- 变异测试**全程在隔离 worktree** `/c/Users/Administrator/mutation_qa/iso`（`--detach` 于 `1ff2a62`）进行。
- 隔离树已还原：`git status --short` 为**空**。
- 主工作区 `scripts/ui/scoreboard.gd`、`tests/suites/test_scoreboard.gd`、
  `tests/suites/test_render_driver.gd`：`git diff` 为**空**（逐条确认）。
- 审计期间发现 engineering-lead 在**同一工作区**并行实现 ES-4.2，
  故将变异测试**整体迁到隔离树**，避免 `cp` 还原误伤他人在制品。**已确认未破坏任何他人文件。**
- 未执行任何 `git commit`；未改动 `production/` 下进度表（本文件为新增，属审计产物）。