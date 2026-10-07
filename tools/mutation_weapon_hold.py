#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mutation_weapon_hold.py —— 变异测试：证明「双手持枪 IK」的回归防线是活的。

背景：本 spike 用 Godot 4.4+ 的 `TwoBoneIK3D` 把双臂拉到两个握持点，武器坐标系由两点推导。
「看起来能跑」与「真的对」之间没有自动保障，本脚本用变异测试回答。

纪律（control_checklist §4-13 / §4-16）：
  · 注入前确认锚点唯一命中；未命中 / 命中多处 → 非零退出（工具缺陷，不判存活）
  · 注入后校验源码确实变化
  · 注入 / 还原失败 → 非零退出（「全绿结论」比「红结论」危险得多）
  · 还原后逐字节比对，确保不留变异残留
  · **杀伤组 / 守恒对照组显式区分**：守恒组转红即判「误杀」并非零退出（§4-16 双向）

⚠ 弱断言有两个方向：漏杀（杀伤组）与误杀（守恒组）。两类都测。

⚠ 还原兜底（沿用 tools/mutation_combat_anim.py 的三层防线，见其文件头）：
   ① 启动自愈（读上次落盘的 PENDING.json + 固定目录字节备份）
   ② 外部字节备份（固定目录 `.mutation_backup_holdik/`，跨运行稳定）
   ③ atexit + try/finally 双保险
   还原目标是「本次启动时的原始字节」而非 HEAD（HEAD 是已提交态，工作区允许有正当未提交改动）。
   §4-11：还原**不用** `git checkout --` / `git restore`（本项目实测其「退出码 0 但没还原」）。

⚠ 不使用 `--import`（会触发编辑器布局加载，删掉 project.godot 的 Vulkan 行，§4-17）。
"""
import atexit
import hashlib
import io
import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
GODOT = r"C:\Users\Administrator\Desktop\Godot_v4.7.2-stable_win64_console.exe"

HOLD_IK = os.path.join("scripts", "entities", "weapon_hold_ik.gd")
MODEL = os.path.join("scripts", "entities", "miku_model.gd")

TARGETS = [HOLD_IK, MODEL]

_BACKUP_DIR = None
_ORIG_SHA = {}
_INJECTED = set()
_HEALED = []
_RESTORE_DONE = [False]


def _sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def _sha256_file(path):
    try:
        with io.open(path, "rb") as f:
            return _sha256_bytes(f.read())
    except (IOError, OSError):
        return None


def _backup_path(rel):
    return os.path.join(_BACKUP_DIR, rel.replace(os.sep, "__"))


def _backup_targets_quiet():
    global _BACKUP_DIR
    _BACKUP_DIR = os.path.join(ROOT, ".mutation_backup_holdik")
    if not os.path.isdir(_BACKUP_DIR):
        return False
    for rel in TARGETS:
        p = _backup_path(rel)
        if not os.path.isfile(p):
            return False
        with io.open(p, "rb") as f:
            _ORIG_SHA[rel] = _sha256_bytes(f.read())
    return True


def _backup_targets():
    global _BACKUP_DIR
    missing = [r for r in TARGETS if not os.path.isfile(os.path.join(ROOT, r))]
    if missing:
        print("  x 目标文件缺失，无法建立备份基线：%s" % ", ".join(missing))
        return False
    _BACKUP_DIR = os.path.join(ROOT, ".mutation_backup_holdik")
    try:
        if not os.path.isdir(_BACKUP_DIR):
            os.makedirs(_BACKUP_DIR)
    except OSError as e:
        print("  x 无法创建备份目录 %s：%s" % (_BACKUP_DIR, e))
        return False
    for rel in TARGETS:
        full = os.path.join(ROOT, rel)
        with io.open(full, "rb") as f:
            data = f.read()
        with io.open(_backup_path(rel), "wb") as f:
            f.write(data)
        _ORIG_SHA[rel] = _sha256_bytes(data)
    print("  o 已逐字节备份 %d 个目标文件到 %s" % (len(TARGETS), _BACKUP_DIR))
    return True


def _force_restore(rel, reason):
    full = os.path.join(ROOT, rel)
    base_sha = _ORIG_SHA.get(rel)
    if base_sha is None:
        return False, "无启动基线可还原"
    try:
        with io.open(_backup_path(rel), "rb") as f:
            want = f.read()
    except (IOError, OSError) as e:
        return False, "读取备份失败：%s" % e
    if _sha256_bytes(want) != base_sha:
        return False, "备份文件与基线 sha 不符（备份损坏）"
    try:
        with io.open(full, "wb") as f:
            f.write(want)
    except (IOError, OSError) as e:
        return False, "写回失败：%s" % e
    got = _sha256_file(full)
    if got != base_sha:
        return False, "写回后 sha256 复核不一致"
    return True, reason


def restore_all(reason):
    if _RESTORE_DONE[0]:
        return True
    problems = []
    for rel in sorted(_INJECTED):
        full = os.path.join(ROOT, rel)
        cur = _sha256_file(full)
        if cur == _ORIG_SHA.get(rel):
            _INJECTED.discard(rel)
            continue
        ok, detail = _force_restore(rel, reason)
        if ok:
            print("  o 已还原 %s（%s）" % (rel, detail))
            _HEALED.append(rel)
        else:
            print("  x 还原失败 %s：%s" % (rel, detail))
            problems.append(rel)
        _INJECTED.discard(rel)
    _RESTORE_DONE[0] = True
    return not problems


atexit.register(lambda: restore_all("atexit 退出清理"))


def _load_pending():
    p = os.path.join(ROOT, ".mutation_backup_holdik", "PENDING.json")
    try:
        with io.open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    except (IOError, OSError, ValueError):
        return None


def _save_pending(injected):
    p = os.path.join(ROOT, ".mutation_backup_holdik", "PENDING.json")
    try:
        with io.open(p, "w", encoding="utf-8") as f:
            json.dump({"injected": sorted(injected)}, f)
    except (IOError, OSError) as e:
        print("  x 无法写入注入态清单（强杀后将无法自愈）：%s" % e)


def startup_self_heal():
    print("启动自愈检查…")
    pending = _load_pending()
    if not pending or not pending.get("injected"):
        print("  o 上次运行无遗留注入态 —— 无需自愈")
        return True
    if not _backup_targets_quiet():
        print("  x 备份不可用，无法自愈（拒绝在可能污染的源码上跑测试）")
        return False
    for rel in pending.get("injected", []):
        if rel not in TARGETS:
            continue
        cur = _sha256_file(os.path.join(ROOT, rel))
        if cur == _ORIG_SHA.get(rel):
            continue
        print("  ! 检测到残留：%s" % rel)
        ok, detail = _force_restore(rel, "启动自愈")
        if not ok:
            print("  x 启动自愈还原失败：%s" % detail)
            return False
        _HEALED.append(rel)
    _save_pending(set())
    return True


# ── 变异体：每个都针对 test_weapon_hold_ik.gd 里真实存在的断言 ─────────────
MUTANTS = [
    # ① 武器坐标系推导（核心：朝向由握持决定）
    (
        "K1_barrel_axis_flipped",
        HOLD_IK,
        "\tvar barrel := left_grip - right_grip\n",
        "\tvar barrel := right_grip - left_grip\n",
        "枪身轴反向 → 断言「武器 +Z = 右手→左手连线」",
    ),
    (
        "K2_basis_left_handed",
        HOLD_IK,
        "\tvar x_axis := up.cross(barrel)\n",
        "\tvar x_axis := barrel.cross(up)\n",
        "改成左手性基（det=-1）→ 断言「必须右手性正交基」，且枪模型会镜像",
    ),
    (
        "K3_origin_no_retreat",
        HOLD_IK,
        "\treturn Transform3D(basis, right_grip - barrel * back_offset)\n",
        "\treturn Transform3D(basis, right_grip)\n",
        "武器原点不再沿枪身后退 → 断言「原点 = 右手点后退 back」",
    ),
    # ② 骨骼名解析
    (
        "K4_exclude_helper_bones_removed",
        HOLD_IK,
        "\t\tif _has_any(low, ARM_EXCLUDE):\n\t\t\tcontinue\n",
        "",
        "不再排除辅助骨 → 断言「上臂不得命中 shoulder/twist/ik」",
    ),
    # ③ 两骨链结构
    (
        "K5_chain_validation_always_true",
        HOLD_IK,
        "\treturn parents[lower] == upper and parents[hand] == lower\n",
        "\treturn true\n",
        "两骨链校验恒真 → 断言「hand 与 lower 平级必须判非法」",
    ),
    # ④ 握持点几何
    (
        "K6_grip_point_not_scaled_by_reach",
        HOLD_IK,
        "\t) * reach\n",
        "\t) * 1.0\n",
        "握持点不再按臂展缩放 → 断言「偏移与臂展成正比」",
    ),
    # ⑤ 启用开关语义
    (
        "K7_set_enabled_ignores_flag",
        HOLD_IK,
        "\t_enabled = on and valid\n",
        "\t_enabled = true\n",
        "set_enabled 忽略入参 → 断言「set_enabled(false) 后 is_enabled() 为 false」",
    ),
    (
        "K8_default_enabled_true",
        MODEL,
        "@export var hold_ik_enabled := false\n",
        "@export var hold_ik_enabled := true\n",
        "IK 默认开启 → 断言「默认必须 false（不破坏既有单臂行为 / 基线）」",
    ),
]

# ── 守恒性对照变异体：语义**等价**，期望测试仍然全绿 ───────────────────────
EXPECT_GREEN = {
    "C1_for_loop_range_form",
    "C2_grip_point_reassociated",
    "C3_chain_extra_bounds_check",
}

CONSERVATION = [
    (
        "C1_for_loop_range_form",
        HOLD_IK,
        "\tfor i in names.size():\n",
        "\tfor i in range(names.size()):\n",
        "`for i in n` 改写成 `for i in range(n)` → **必须仍然全绿**（语义等价）",
    ),
    (
        "C2_grip_point_reassociated",
        HOLD_IK,
        "\treturn shoulder + (\n\t\tfront * float(coeff[\"front\"]) + up * float(coeff[\"up\"]) + right * float(coeff[\"right\"])\n\t) * reach\n",
        "\treturn shoulder + (\n\t\tfront * (float(coeff[\"front\"]) * reach)\n\t\t+ up * (float(coeff[\"up\"]) * reach)\n\t\t+ right * (float(coeff[\"right\"]) * reach)\n\t)\n",
        "握持点求和改成分量各自乘 reach 再相加 → **必须仍然全绿**（代数等价）",
    ),
    (
        "C3_chain_extra_bounds_check",
        HOLD_IK,
        "\treturn parents[lower] == upper and parents[hand] == lower\n",
        "\treturn lower < parents.size() and hand < parents.size() and parents[lower] == upper and parents[hand] == lower\n",
        "两骨链校验加一条冗余边界检查 → **必须仍然全绿**（前面已挡越界，等价）",
    ),
]


def _read(p):
    with io.open(p, "r", encoding="utf-8", newline="") as f:
        return f.read()


def _write(p, t):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
        f.write(t)


def run_tests(root, timeout=420):
    cmd = [GODOT, "--headless", "--path", root, "res://tests/test_runner.tscn"]
    try:
        p = subprocess.run(cmd, cwd=root, capture_output=True, timeout=timeout)
        out = (p.stdout or b"").decode("utf-8", "replace") + \
              (p.stderr or b"").decode("utf-8", "replace")
        return p.returncode != 0, out, p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace")
        return True, out, -1


def main():
    print("=" * 74)
    print("mutation_weapon_hold ｜ 双手持枪 IK 回归防线守门自测")
    if not startup_self_heal():
        print("工具缺陷：启动自愈失败，拒绝在污染的源码上跑变异测试（非零退出）")
        return 2
    if not _backup_targets():
        return 2
    _save_pending(set())
    try:
        return _run_all()
    finally:
        if not restore_all("正常/异常退出清理"):
            print("工具缺陷：退出时还原失败 —— 工作区可能留有残缺变异体")
            sys.exit(2)
        _save_pending(set())


def _run_all():
    if not os.path.isfile(GODOT):
        print("FAIL 找不到 Godot: %s" % GODOT)
        return 2
    mutants = list(MUTANTS) + CONSERVATION
    survivors, tool_errors, false_kills = [], [], []
    for mid, rel, anchor, repl, desc in mutants:
        expect_green = mid in EXPECT_GREEN
        tag = "守恒对照" if expect_green else "杀伤"
        print("=" * 74)
        print("[%s][%s] %s" % (mid, tag, desc))
        full = os.path.join(ROOT, rel)
        if not os.path.isfile(full):
            print("  x 工具缺陷：文件不存在 %s" % rel)
            tool_errors.append(mid)
            continue
        src = _read(full)
        n = src.count(anchor)
        if n != 1:
            print("  x 锚点命中 %d 处（要求恰好 1）→ 工具缺陷，不判存活" % n)
            tool_errors.append(mid)
            continue
        mutated = src.replace(anchor, repl, 1)
        if mutated == src:
            print("  x 注入后源码未变化 → 工具缺陷")
            tool_errors.append(mid)
            continue
        pre_sha = _sha256_file(full)
        _write(full, mutated)
        post_sha = _sha256_file(full)
        if post_sha == pre_sha:
            print("  x 注入后 sha256 未变化 → 工具缺陷")
            tool_errors.append(mid)
            continue
        _INJECTED.add(rel)
        _save_pending(_INJECTED)
        print("  o 锚点唯一命中，注入成功（sha %s… → %s…）" % (pre_sha[:16], post_sha[:16]))
        try:
            red, out, rc = run_tests(ROOT)
        finally:
            _write(full, src)
            _INJECTED.discard(rel)
            _save_pending(_INJECTED)
            now_sha = _sha256_file(full)
            if now_sha != pre_sha:
                print("  x 还原失败（sha256 不一致）")
                tool_errors.append(mid)
                continue
        for ln in out.splitlines():
            if "test_weapon_hold_ik" in ln or "用例 " in ln:
                print("|%s" % ln.strip())
        if expect_green:
            if red:
                print("  -> x 误杀！等价改写被断言挡下 → 断言是字面量锁（弱）")
                false_kills.append(mid)
            else:
                print("  -> 等价改写仍全绿 o（断言按语义锁，未误杀）")
        else:
            if red:
                print("  -> 变异体被杀 o")
            else:
                print("  -> ! 存活（exit %s）" % rc)
                survivors.append(mid)
    print("=" * 74)
    if tool_errors:
        print("工具缺陷：%s" % ", ".join(tool_errors))
        return 2
    if survivors or false_kills:
        if survivors:
            print("存活（漏杀）%d：%s" % (len(survivors), ", ".join(survivors)))
        if false_kills:
            print("误杀 %d：%s" % (len(false_kills), ", ".join(false_kills)))
        return 1
    n_kill = len(mutants) - len(EXPECT_GREEN)
    print("杀伤组 %d/%d 全杀 o；守恒对照组 %d/%d 仍全绿 o —— 双手持枪 IK 守门能力完好"
          % (n_kill, n_kill, len(EXPECT_GREEN), len(EXPECT_GREEN)))
    return 0


if __name__ == "__main__":
    _code = main()
    if _HEALED:
        print("本次运行发生过启动自愈还原：是（%s）" % ", ".join(sorted(set(_HEALED))))
    else:
        print("本次运行发生过启动自愈还原：否")
    sys.exit(_code)
