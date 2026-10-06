# EP-5 · 联机健壮性与工程基础

> **Phase 4 ｜ 优先级 P1（含 1 项 P3）｜ 负责人**：程基岩（engineering-lead）
> **上游**：`design/gdd/99_consistency_review.md §3`（C-3/C-6/C-11）、`01_core_loop.md §6`、`docs/architecture/adr/ADR-006`
> **目标**：修掉两个「联机场景会穿帮」的项（手雷权威 / 皮肤同步）+ 补受伤反馈，并把 **E4-01 的测试框架**固化为可持续的工程基础。
> **出口判据**：手雷各端一致；受伤有第二线索；`tests/test_runner.tscn` 纳入常规验证；headless 静默验证脚本可用。

---

## ES-5.1 · 手雷伤害「房主权威」结算（C-3）· M · ⏳ 待实施

- **目标**：手雷伤害从「只本地结算」改为房主权威，使各端状态一致。
- **验收标准**（`99_consistency_review §3` C-3）：联机时手雷爆炸后**各端 HP 一致**（不再出现「我端扣血、他端没扣」）。
- **依赖**：无（与 EP-2 路由改动独立，但都属「伤害同步」主题，建议同批评审）。
- **涉及文件**：`scripts/shooting/grenade_projectile.gd:69`（`_damage_nearby()` 现 `player.has_method("take_damage")` 本地调用）、`scripts/shooting/grenade.gd`。
- **测试证据**：契约锁——断言爆炸伤害走房主权威路径（`rpc_id(1, ...)` 或房主直接结算 + 广播）。

## ES-5.2 · 玩家受伤反馈：音效 + 第二线索（C-11）· S · ⏳ 待实施

- **目标**：`player.gd::take_damage()` 补 `hit_player` 占位音 + 屏幕边缘红色渐晕（vignette）。
- **验收标准**（`04_ux §6.3` / `AC-F5` / C-11）：受伤有**非颜色**的第二线索（音效优先，vignette 次选）。
- **依赖**：无。
- **涉及文件**：`scripts/player.gd:347-355`（`take_damage`，现仅相机震动 `add_trauma`+血条）；可复用 `scripts/entities/bot.gd::_setup_hit_audio()` 的合成方式。
- **测试证据**：契约锁——断言 `take_damage` 触发第二线索。
- **handoff**：`audio-director`（真实受伤音效素材）；本 Story 只做工程占位。

## ES-5.3 · 皮肤 / 角色 / 外观联机同步评估（C-6）· L · ⏳ 待评估

- **目标**：评估外观（皮肤/角色）是否/如何联机同步，使「表达」美学有社交意义。
- **验收标准**（`99_consistency_review §3` C-6）：给出**可行性结论 + 成本**（是否引入新 RPC / 是否复用变体组装管线 `ADR-003`）。
- **依赖**：无（**先评估、后实现**；与 ⚑E-5「纯装饰」定位不冲突）。
- **涉及文件**：`scripts/shooting/weapon_skin.gd`、`scripts/ui/game_menu.gd`、`scripts/shooting/weapon_variant.gd`（`apply_to()`）。
- **测试证据**：评估文档（写入 `production/epics/` 或 `docs/architecture/`），不要求本轮实现。

## ES-5.4 · 测试框架 + 首批回归基线 · S · ✅ 已完成（E4-01）

- **目标**：自研轻量 harness（`TestSuite` + `Runner` + 统一出口码）+ 首批 4 个 suite。
- **验收标准**：headless 可跑、出口码 0/1 明确；覆盖 AC-1 / AC-2 / AC-F2(pending) / 关键不变量。
- **依赖**：无。
- **涉及文件**：`tests/framework/test_suite.gd`、`tests/framework/test_runner.gd`、`tests/test_runner.tscn`、`tests/suites/*.gd`、`tests/README.md`。
- **测试证据**：**16 用例 / 52 断言 / 0 失败 / 1 pending suite**；`RUN_EXIT=0`（实测输出见 `tests/README.md §1`）。

## ES-5.5 · headless 静默验证脚本（导入 + check-only + tests）· S · ⏳ 待实施

- **目标**：把「`--import` → `--check-only` → `test_runner.tscn`」固化为一条可重复命令，供每次改动后自检。
- **验收标准**：脚本任一环节失败即非零退出；输出仅保留结论行（PASS/FAIL + 出口码）。
- **依赖**：ES-5.4。
- **涉及文件**：**新增** `tools/verify.sh`（或 `tools/verify.gd`）；`README.md`（追加用法）。
- **测试证据**：脚本自跑一次，PASS 时退出码 0。

---

## 依赖拓扑（EP-5 内部）

```
ES-5.4 ✅（测试框架）
   └─▶ ES-5.5（静默验证脚本）
ES-5.1（手雷权威）／ES-5.2（受伤反馈）／ES-5.3（外观同步·评估）  ← 相对独立
```

## 说明：为什么测试框架归入 EP-5 而非独立 Epic

测试框架是**工程基础**（infra），服务于 EP-1~EP-4 全部验收条款的**回归**；把它放在 EP-5 与其他工程基础（CI 脚本、健壮性）同组，逻辑内聚。
