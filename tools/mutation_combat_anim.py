#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mutation_combat_anim.py —— 变异测试：证明战斗动作（开火/受击/死亡/换弹）的回归防线是活的。

背景：本项目没有任何外部动画素材（18 个模型合计 4 条剪辑，默认模型 miku.glb 零剪辑），
四个战斗动作全部由 MikuCombatAnim（纯逻辑）+ MikuProceduralPose（骨骼摆放）程序化实现。
这套东西「看起来能跑」与「真的对」之间没有自动保障，本脚本用变异测试回答。

纪律（control_checklist §4-13 / §4-16）：
  · 注入前确认锚点唯一命中；未命中或命中多处 → 非零退出（工具缺陷，不判存活）
  · 注入后校验源码确实变化
  · 注入/还原失败 → 非零退出（「全绿结论」比「红结论」危险得多）
  · 还原后逐字节比对，确保不留变异残留
  · **杀伤组 / 守恒对照组显式区分**：守恒组转红即判「误杀」并非零退出（§4-16 双向）

⚠ 弱断言有两个方向，只测一个方向仍不够：
  · 漏杀：真缺陷改了却全绿 —— 下面的杀伤组。
  · 误杀：语义等价的改写被挡下 —— 下面的守恒对照组。
  故 EXPECT_GREEN 里的变异体是**语义等价**的改写，必须**仍然全绿**。

⚠ 本脚本**不使用 `--import`**：实测 `--import` 会触发 Godot 的编辑器布局加载，
  进而把 project.godot 里的 `rendering_device/driver.windows="vulkan"` 整块删掉
  （control_checklist §4-17 的第 5 次复发）。class_name 注册在首次导入后已写入
  .godot/global_script_class_cache.cfg，后续纯 --headless 运行即可。

⚠⚠ 还原兜底（2026-10-06 实测事故后新增，三层防线）：
  事故：Windows 上 `TerminateProcess`（SIGTERM）**不给 Python 跑 `finally` 的机会**，
  脚本在还原前被杀 → **工作区留下未写完的变异体**（实测残留是 miku_combat_anim.gd
  里一段缩进都没对齐的语法错误代码）。若不处理，下一次运行会拿被污染的源码跑测试，
  结论直接失效。

  三层防线：
   ① **启动自愈**（最强的兜底）：每次启动先读上次落盘的「注入中」清单
      （`.mutation_backup/PENDING.json`）+ 字节备份，发现「上次注入过但没还原」
      就**先自动还原 + 打印警告**再继续。这防的是「上次残留污染本次结论」。
   ② **外部字节备份**：启动时把 6 个文件**逐字节**备份到**项目内固定目录**
      `.mutation_backup/`（不能用 mkdtemp 随机名——被强杀后要找得到同一份备份）
      并记录启动基线 sha256。还原时逐字节校验，不依赖进程内存。
   ③ `atexit` + `try/finally` 双保险：正常结束 / 抛错都能还原；
      被强杀时这两层都失效，靠 ① 在**下次**运行时兜住。

  ⚠⚠ 还原目标是「**本次启动时的原始字节**」，**不是「HEAD 版本」**（实测踩坑）：
     早期实现拿 HEAD 当基线，结果把用户**正当的未提交改动**也当成残留 revert 掉了
     ——本次给 bot.gd 补的说明注释就是这样被抹掉的（HEAD 是「已提交状态」，
     而工作区允许有正在写的合法改动，两者不能混为一谈）。
     所以只有「本次确实注入过、且当前字节仍偏离启动基线」才还原；
     本脚本没碰过的文件一律不碰。
     （§4-11 纪律依然成立：还原**不用** `git checkout --` / `git restore`，
      写回后**立刻复核 sha256`。本脚本根本不需要 git 即可还原。）
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

COMBAT = os.path.join("scripts", "entities", "miku_combat_anim.gd")
POSE = os.path.join("scripts", "entities", "miku_procedural_pose.gd")
MODEL = os.path.join("scripts", "entities", "miku_model.gd")
PLAYER = os.path.join("scripts", "player.gd")
WEAPON = os.path.join("scripts", "shooting", "weapon.gd")
BOT = os.path.join("scripts", "entities", "bot.gd")

# 所有被本脚本改动的目标文件（备份 / 启动自愈 / 退出还原都以此为准）
TARGETS = [COMBAT, POSE, MODEL, PLAYER, WEAPON, BOT]

# ── 还原兜底机制（详见文件头「还原兜底」）────────────────────────────────
# 外部备份目录（逐字节备份 + 原始 sha256）——不依赖进程内存，被强杀后仍在
_BACKUP_DIR = None
_ORIG_SHA = {}      # rel -> 启动时的 sha256（十六进制）
_INJECTED = set()   # 当前已注入变异体、**尚未**还原的文件（rel 集合）
_HEALED = []        # 启动自愈时被发现并还原过的文件（用于结尾汇报）
_RESTORE_DONE = [False]


def _sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def _sha256_file(path):
    try:
        with io.open(path, "rb") as f:
            return _sha256_bytes(f.read())
    except (IOError, OSError):
        return None


def _git_head_bytes(rel):
    """用 `git show HEAD:<path>` 读出 HEAD 版本的**字节**内容。

    ⚠ 绝不用 `git checkout --` / `git restore`：§4-11 实测它们会「退出码 0
      但文件根本没还原」，是本项目已知的假成功陷阱。
    """
    try:
        p = subprocess.run(["git", "show", "HEAD:" + rel.replace("\\", "/")],
                           cwd=ROOT, capture_output=True, timeout=60)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if p.returncode != 0:
        return None
    return p.stdout or b""


def _backup_path(rel):
    return os.path.join(_BACKUP_DIR, rel.replace(os.sep, "__"))


def _backup_targets_quiet():
    """自愈专用：**复用上次留下的备份**建立基线（绝不覆盖备份成当前的污染内容）。"""
    global _BACKUP_DIR
    _BACKUP_DIR = os.path.join(ROOT, ".mutation_backup")
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
    """把 6 个目标文件逐字节备份到**项目内的固定目录**，并记录原始 sha256。

    ⚠ 备份目录必须**跨运行稳定**（固定路径，不能用 mkdtemp 随机名）：
      被强杀后进程内的引用全丢，只有「下次运行还能找到同一份备份」才可能真正自愈。
    """
    global _BACKUP_DIR
    missing = [r for r in TARGETS if not os.path.isfile(os.path.join(ROOT, r))]
    if missing:
        print("  x 目标文件缺失，无法建立备份基线：%s" % ", ".join(missing))
        return False
    _BACKUP_DIR = os.path.join(ROOT, ".mutation_backup")
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
    print("    启动基线 sha256（还原目标 = 这些字节，不是 HEAD）：")
    for rel in TARGETS:
        print("      %s  %s" % (_ORIG_SHA[rel][:16], rel))
    return True


def _backup_path(rel):
    return os.path.join(_BACKUP_DIR, rel.replace(os.sep, "__"))


def _force_restore(rel, reason):
    """把单个文件还原成**本脚本启动时的原始字节**（备份基线），并复核 sha256。

    ⚠ 关键设计：还原目标是「启动时的原始字节」，**不是「HEAD 版本」**。
      早期实现直接还原到 HEAD，结果把**合法的未提交改动**一起抹掉了
      （实测：本次给 bot.gd 补的说明注释被自愈当成「残留」revert 掉，
        而它其实是用户正当的编辑内容）。
      所以：只有「本次运行确实注入过、且当前字节仍偏离基线」才还原；
      本脚本没碰过的文件一律不碰。

    返回 (ok, detail)。ok=False 表示还原没能真正落地——此时必须非零退出。
    """
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
        return False, "备份文件与基线 sha 不符（备份损坏：%s）" % _backup_path(rel)
    try:
        with io.open(full, "wb") as f:
            f.write(want)
    except (IOError, OSError) as e:
        return False, "写回失败：%s" % e
    got = _sha256_file(full)
    if got != base_sha:
        return False, "写回后 sha256 复核不一致（期望 %s… 实得 %s…）" % (base_sha[:16], (got or "None")[:16])
    return True, reason


def restore_all(reason):
    """统一还原：只还原**本次运行注入过**、且当前字节仍偏离基线的文件。

    覆盖三条退出路径：正常结束 / 异常抛错（finally + atexit）/
    被强杀（下次运行时的启动自愈兜底）。

    ⚠ 绝不碰本次运行没注入过的文件——它们可能是用户正在写的合法改动。
    """
    if _RESTORE_DONE[0]:
        return True
    problems = []
    for rel in sorted(_INJECTED):
        full = os.path.join(ROOT, rel)
        cur = _sha256_file(full)
        if cur == _ORIG_SHA.get(rel):
            _INJECTED.discard(rel)
            continue  # 已回到基线，无需写回
        ok, detail = _force_restore(rel, reason)
        if ok:
            print("  o 已还原 %s（%s；残留 sha %s… → 基线 sha %s…）"
                  % (rel, detail, (cur or "None")[:16], (_sha256_file(full) or "")[:16]))
            _HEALED.append(rel)
        else:
            print("  x 还原失败 %s：%s" % (rel, detail))
            problems.append(rel)
        _INJECTED.discard(rel)
    _RESTORE_DONE[0] = True
    if not problems:
        print("  （本次运行结束：无处于注入态的残留文件）")
    return not problems


# atexit 注册：覆盖「抛了异常但没走到 finally」的路径
atexit.register(lambda: restore_all("atexit 退出清理"))

# ── 变异体：每个都针对 test_combat_anim.gd 里真实存在的断言 ─────────────────
MUTANTS = [
    # ── ① 包络（alpha envelope）──────────────────────────────────────────
    (
        "K1_fire_envelope_flipped_to_ramp",
        COMBAT,
        "\t\tAction.FIRE:\n\t\t\treturn pow(1.0 - t, FIRE_DECAY_POW)\n",
        "\t\tAction.FIRE:\n\t\t\treturn smoothstep(0.0, 1.0, t)\n",
        "开火包络被改成「渐入」（枪声一响角色先僵住才动）→ 断言「起于 1、终于 0、单调不增」",
    ),
    (
        "K2_death_envelope_became_decay",
        COMBAT,
        "\t\tAction.DEATH:\n\t\t\treturn smoothstep(0.0, 1.0, t)\n",
        "\t\tAction.DEATH:\n\t\t\treturn pow(1.0 - t, FIRE_DECAY_POW)\n",
        "死亡包络被改成衰减（先弹一下再倒）→ 断言「死亡单调不减」",
    ),
    (
        "K3_envelope_progress_unclamped",
        COMBAT,
        "\tvar t := clampf(u, 0.0, 1.0)\n",
        "\tvar t := u\n",
        "进度不再 clamp → 断言「越界进度被夹到端点」（负 delta / 超时 delta 会把骨骼拧坏）",
    ),
    (
        "K4_envelope_ceiling_removed",
        COMBAT,
        "\t\t\treturn 1.0 - smoothstep(RELOAD_PLATEAU, 1.0, t)\n",
        "\t\t\treturn 1.0 - smoothstep(0.0, 1.0, t)\n",
        "换弹去掉保持段 → 断言「起于 1」（t=0 处不再是满强度，手不会先离开弹匣）",
    ),
    # ── ② 死亡不可逆 ────────────────────────────────────────────────────
    (
        "D1_dead_flag_never_set",
        COMBAT,
        "\tif action == Action.DEATH:\n\t\t_dead = true\n",
        "\tif action == Action.DEATH:\n\t\tpass\n",
        "_dead 不再置位 → 断言「死亡后其它动作被拒」（死后还能开枪 / 起身）",
    ),
    (
        "D2_death_does_not_block_others",
        COMBAT,
        "\tif _dead:\n\t\treturn action == Action.DEATH\n",
        "\tif _dead:\n\t\treturn true\n",
        "死亡不再拦截其它动作 → 断言「fire/hit/reload 在死亡后被拒」",
    ),
    (
        "D3_reset_does_not_clear_dead",
        COMBAT,
        "func reset() -> void:\n\t_action = Action.NONE\n\t_elapsed = 0.0\n\t_dead = false",
        "func reset() -> void:\n\t_action = Action.NONE\n\t_elapsed = 0.0",
        "reset() 不清死亡标记 → 断言「reset 后 is_dead() 为 false」（重生后永远起不来）",
    ),
    (
        "D4_death_progress_not_saturated",
        COMBAT,
        "\tif _action == Action.DEATH:\n\t\t_elapsed = total # 倒地后停在「完全倒地」，进度不再无限增长\n\t\treturn\n",
        "\tif _action == Action.DEATH:\n\t\treturn\n",
        "死亡进度不封顶 → 断言「死亡进度封顶在 1.0」",
    ),
    (
        "D5_repeated_death_restarts_progress",
        COMBAT,
        "\t_dead = true\n\t\t_action = action\n\t\t_elapsed = 0.0\n\t\treturn true\n",
        "\tif _dead:\n\t\treturn action == Action.DEATH\n\t_dead = true\n\t\t_action = action\n\t\t_elapsed = 0.0\n\t\treturn true\n",
        "重复死亡会重置进度 → 断言「重复死亡幂等、不倒带重播」",
    ),
    # ── ③ 叠加量语义（纯逻辑 / 渲染分离的关键）──────────────────────────
    (
        "O1_fire_gains_position_channel",
        COMBAT,
        "\t\t\tout[CH_PITCH] = deg_to_rad(FIRE_TORSO_DEG) * w\n",
        "\t\t\tout[CH_PITCH] = deg_to_rad(FIRE_TORSO_DEG) * w\n\t\t\tout[CH_DROP] = -0.3 * w\n",
        "开火偷偷加了位移（下沉）→ 断言「开火不含位置通道」"
        "（位移后坐力归 RecoilSystem 管摄像机，重复表现）",
    ),
    (
        "O2_fire_moves_legs",
        COMBAT,
        "\t\t\tout[CH_PITCH] = deg_to_rad(FIRE_TORSO_DEG) * w\n",
        "\t\t\tout[CH_PITCH] = deg_to_rad(FIRE_TORSO_DEG) * w\n\t\t\tout[CH_LEG] = deg_to_rad(9.0) * w\n",
        "开火动了腿 → 断言「开火只动持械臂 + 躯干」",
    ),
    (
        "O3_hit_moves_legs",
        COMBAT,
        "\t\t\tout[CH_HEAD] = deg_to_rad(HIT_HEAD_DEG) * w\n",
        "\t\t\tout[CH_HEAD] = deg_to_rad(HIT_HEAD_DEG) * w\n\t\t\tout[CH_LEG] = deg_to_rad(12.0) * w\n",
        "受击动了腿 → 断言「受击可叠加在行走之上」（被打中时还在跑，步态不能被改）",
    ),
    (
        "O4_offsets_not_alpha_scaled",
        COMBAT,
        "\tvar w := maxf(alpha, 0.0)\n",
        "\tvar w := 1.0\n",
        "叠加量不再按 alpha 缩放（= 硬切，动作会抽搐）→ 断言「线性缩放」",
    ),
    (
        "O5_sum_offsets_missing_key_as_zero",
        COMBAT,
        "\t\tfor channel in CHANNELS:\n\t\t\ttotal[channel] = float(total[channel]) + float(one.get(channel, 0.0))\n",
        "\t\tfor channel in CHANNELS:\n\t\t\tif not one.has(channel):\n\t\t\t\tcontinue\n\t\t\ttotal[channel] = float(total[channel]) + float(one[channel])\n",
        "求和时改用 has 守卫跳过缺失通道 → **必须仍然全绿**（`get(k,0)` 与 has-守卫"
        "在结果上完全等价：都把缺失通道当0；区别只在防御性写法）",
    ),
    # ── ④ 降级 + 接线口径 ───────────────────────────────────────────────
    (
        "P1_valid_guard_removed_from_fire",
        POSE,
        "func trigger_fire() -> bool:\n\tif not valid:\n\t\treturn false\n",
        "func trigger_fire() -> bool:\n",
        "开火去掉 valid 守卫 → 断言「动作方法必须先判 valid」（无骨骼模型会被拧坏）",
    ),
    (
        "P2_combat_advance_after_valid_check",
        POSE,
        "\tcombat.advance(delta)\n\tif not valid:\n",
        "\tif not valid:\n\t\treturn\n\tcombat.advance(delta)\n\tif not valid:\n",
        "战斗计时挪到 valid 判断之后 → 断言「advance 必须在 valid 判断之前」"
        "（无效姿态下计时永不走，动作卡住）",
    ),
    (
        "R1_remote_death_from_display_health",
        PLAYER,
        "\t_apply_display_health(health_value)\n",
        "\t_apply_display_health(health_value)\n\tif _display_health <= 0.0:\n\t\t_model.play_death()\n",
        "射手端按 _display_health 播死亡 → 断言「远端死亡不得由显示副本驱动」"
        "（§4-9 同源：显示副本不是血量真值）",
    ),
    (
        "R2_combat_action_becomes_rpc",
        MODEL,
        "func play_fire() -> void:\n",
        "@rpc(\"any_peer\", \"call_remote\", \"unreliable\")\nfunc play_fire() -> void:\n",
        "开火动作改成 RPC → 断言「战斗动作不走 RPC」（纯视觉表现，各端本地播）",
    ),
    (
        "W1_fire_action_anchor_removed",
        WEAPON,
        "\t_play_character_fire()\n",
        "",
        "开火动作调用被删 → 断言「与枪声同帧的同步锚点」",
    ),
    (
        "B1_bot_death_action_removed",
        BOT,
        "\t\t_model.play_death()\n",
        "",
        "人机死亡动作被删 → 断言「bot.gd 归零时必须触发死亡动作」",
    ),
]

# ── 守恒性对照变异体：语义**等价**，期望测试仍然全绿 ───────────────────────
# 一个只会搜字面量的弱断言，既可能挡不住真缺陷（漏杀），也可能挡住等价改写（误杀）。
# 两者都是坏断言，故两类都要测（§4-16）。
EXPECT_GREEN = {
    # 「先取夹住的进度再clamp」改成「先 clamp 再算」—— 结果完全等价。
    "C1_clamp_reorder",
    # 触发死亡时改成先置 _action 再置 _dead（顺序不同，语义一致）。
    "C2_dead_flag_order_swap",
    # 缺失通道用 `get(k, 0.0)` 还是 `has` 守卫 —— 两种写法结果完全一致。
    # ⚠ 首轮曾把O5 当成「杀伤组」，结果**存活**：变异体其实与原实现语义等价，
    #   差别只在防御性写法（`get` 兜底 vs `has` 跳过）。
    #   按 §4-16「守恒组转红即误杀」的对称纪律，它属于**守恒对照组**：
    #   断言锁的是「求和结果必须包含全部通道、缺失按 0 处理」这一**语义**，
    #   而不是「必须用 get() 这个写法」。把它留在杀伤组 = 逼后人绕开断言。
    "O5_sum_offsets_missing_key_as_zero",
}


def _read(p):
    with io.open(p, "r", encoding="utf-8", newline="") as f:
        return f.read()


def _write(p, t):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
        f.write(t)


def run_tests(root, timeout=300):
    cmd = [GODOT, "--headless", "--path", root, "res://tests/test_runner.tscn"]
    try:
        p = subprocess.run(cmd, cwd=root, capture_output=True, timeout=timeout)
        out = (p.stdout or b"").decode("utf-8", "replace") + \
              (p.stderr or b"").decode("utf-8", "replace")
        return p.returncode != 0, out, p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace")
        return True, out, -1


def _load_pending():
    """读取上次运行遗留的「注入中」清单（被强杀时来不及清）。"""
    p = os.path.join(ROOT, ".mutation_backup", "PENDING.json")
    try:
        with io.open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    except (IOError, OSError, ValueError):
        return None


def _save_pending(injected):
    """把当前「注入中」清单落盘——被强杀后这就是自愈的证据。"""
    p = os.path.join(ROOT, ".mutation_backup", "PENDING.json")
    try:
        with io.open(p, "w", encoding="utf-8") as f:
            json.dump({"injected": sorted(injected)}, f)
    except (IOError, OSError) as e:
        print("  x 无法写入注入态清单（强杀后将无法自愈）：%s" % e)


def startup_self_heal():
    """启动自愈：只清理**上次运行确实注入过、但没来得及还原**的文件。

    判据是上次落盘的「注入中」清单（PENDING.json）+ 固定目录里的字节备份，
    **不是**「是否等于 HEAD」。原因（实测踩坑）：
      早期版本拿 HEAD 当基线，于是把用户**正当的未提交改动**也当成残留 revert 掉了
      ——本次给 bot.gd 补的说明注释就是这样被抹掉的。
      HEAD 是「已提交状态」，而工作区允许有正在写的合法改动，两者不能混为一谈。

    若发现残留 ⇒ 必须在继续前还原，否则本次结论会被上次的污染源码带偏。
    """
    print("启动自愈检查（读取上次运行的注入态清单）…")
    pending = _load_pending()
    if not pending or not pending.get("injected"):
        print("  o 上次运行无遗留注入态（或从未中断）——无需自愈")
        _HEALED.extend([])
        return True

    healed = []
    # 先用备份目录重建基线（_ORIG_SHA / _BACKUP_DIR），_force_restore 依赖它们
    if not _backup_targets_quiet():
        print("  x 备份不可用，无法自愈（拒绝在可能污染的源码上跑测试）")
        return False

    for rel in pending.get("injected", []):
        if rel not in TARGETS:
            continue
        full = os.path.join(ROOT, rel)
        cur = _sha256_file(full)
        base = _ORIG_SHA.get(rel)
        if cur == base:
            print("  · %s 已等于启动基线，无需处理" % rel)
            continue
        healed.append(rel)
        print("  ! 检测到残留：%s（现 sha %s… ≠ 基线 %s…）"
              % (rel, (cur or "None")[:16], (base or "None")[:16]))
        ok, detail = _force_restore(rel, "启动自愈")
        if not ok:
            print("  x 启动自愈还原失败：%s" % detail)
            return False
        print("  o 已自动还原到上次启动时的原始字节（sha %s…）｜%s"
              % ((_sha256_file(full) or "")[:16], detail))

    _save_pending(set())  # 自愈完成，清空清单
    if healed:
        print("  ⚠ 本次启动发生了**自愈还原**（%d 个文件）：%s"
              % (len(healed), ", ".join(healed)))
        print("    ⚠ 这说明上一次运行被强杀（SIGTERM/SIGKILL）并在工作区留下残缺变异体。")
        print("      本次测试结论基于还原后的干净源码。")
    _HEALED.extend(healed)
    return True


def main():
    print("=" * 74)
    print("mutation_combat_anim ｜ 战斗动作回归防线守门自测")

    # ── ① 启动自愈：先清掉上次被强杀留下的残留，再谈测试 ──────────────
    if not startup_self_heal():
        print("工具缺陷：启动自愈失败，拒绝在污染的源码上跑变异测试（非零退出）")
        return 2

    # ── ② 外部备份：逐字节 + 启动基线 sha256（不依赖进程内存）────────
    if not _backup_targets():
        return 2
    # 自愈已完成（或无需自愈）：重建基线后清空「注入中」清单，
    # 让下一次运行不会把本次的正常收尾误判成残留。
    _save_pending(set())

    # ── ③ 退出兜底：atexit 之外再加 try/finally（双保险）──────────────
    try:
        return _run_all()
    finally:
        if not restore_all("正常/异常退出清理"):
            # 还原失败比「红结论」危险得多（§4-13）→ 强制非零退出
            print("工具缺陷：退出时还原失败 —— 工作区可能留有残缺变异体")
            sys.exit(2)
        _save_pending(set())


def _run_all():
    if not os.path.isfile(GODOT):
        print("FAIL 找不到 Godot: %s" % GODOT)
        return 2

    # 守恒对照组以「等价改写」的形式追加（它们与杀伤组走同一注入机制）
    mutants = list(MUTANTS) + [
        (
            "C1_clamp_reorder",
            COMBAT,
            "\tvar t := clampf(u, 0.0, 1.0)\n",
            "\tvar t := clampf(maxf(u, 0.0), 0.0, 1.0)\n",
            "clamp 改写成「先抬下界再夹」→ **必须仍然全绿**（语义等价）",
        ),
        (
            "C2_dead_flag_order_swap",
            COMBAT,
            "\t_dead = true\n\t\t_action = action\n\t\t_elapsed = 0.0\n\t\treturn true\n",
            "\t_action = action\n\t\t_dead = true\n\t\t_elapsed = 0.0\n\t\treturn true\n",
            "死亡触发里 _dead / _action 赋值顺序调换 → **必须仍然全绿**（语义等价）",
        ),
    ]

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

        # 注入前记下当前 sha256（退出时统一逐字节比对并强制还原）
        pre_sha = _sha256_file(full)
        _write(full, mutated)
        # 注入生效校验：源码确实变了（diff 非空）
        post_sha = _sha256_file(full)
        if post_sha == pre_sha:
            print("  x 注入后 sha256 未变化 → 工具缺陷")
            tool_errors.append(mid)
            continue
        _INJECTED.add(rel)
        # 落盘「注入中」清单：被强杀时这就是下次启动自愈的**唯一证据**
        _save_pending(_INJECTED)
        print("  o 锚点唯一命中，注入成功（sha %s… → %s…）" % (pre_sha[:16], post_sha[:16]))
        try:
            red, out, rc = run_tests(ROOT)
        finally:
            # 单个变异体的即时还原（不等退出时统一还原）
            _write(full, src)
            _INJECTED.discard(rel)
            _save_pending(_INJECTED)
            now_sha = _sha256_file(full)
            if now_sha != pre_sha:
                print("  x 还原失败（sha256 %s… ≠ 注入前 %s…）"
                      % ((now_sha or "None")[:16], pre_sha[:16]))
                tool_errors.append(mid)
                continue
        hit = [ln.strip() for ln in out.splitlines()
               if "test_combat_anim" in ln]
        for h in hit[:3]:
            print("|%s" % h)
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
    print("杀伤组 %d/%d 全杀 o；守恒对照组 %d/%d 仍全绿 o —— 战斗动作守门能力完好"
          % (n_kill, n_kill, len(EXPECT_GREEN), len(EXPECT_GREEN)))
    return 0


if __name__ == "__main__":
    _code = main()
    # 结尾明确交代：本次运行是否发生过「启动自愈还原」（被强杀的痕迹）
    if _HEALED:
        print("本次运行发生过启动自愈还原：是（%d 个文件：%s）"
              % (len(_HEALED), ", ".join(sorted(set(_HEALED)))))
        print("  ⇒ 上一次运行被强杀（SIGTERM/SIGKILL）并在工作区留下残缺变异体；")
        print("    本次已自动还原，结论基于干净源码。")
    else:
        print("本次运行发生过启动自愈还原：否（启动时 %d 个目标文件均干净）" % len(TARGETS))
    sys.exit(_code)