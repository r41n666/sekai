#!/usr/bin/env python3
"""PMX(MMD) → glb 极简转换器（供本项目把 MMD 模型接入 Godot）。

支持：网格（位置/法线/UV）、蒙皮（BDEF1/2/4；SDEF 近似 BDEF2、QDEF 近似 BDEF4）、
骨骼层级、按材质分组的索引、漫反射贴图（内嵌进 glb）。
忽略：变形(morph)/显示枠/物理刚体/关节/附加 UV（不影响静态外观）。

坐标保持 PMX 原样（Y 上，模型面向 +Z，和本项目约定一致；身高由 Godot 侧自动适配）。

用法：python tools/pmx2glb.py <model.pmx> <out_dir>
"""
import json
import struct
import sys
from pathlib import Path

ENCODINGS = {0: "utf-16-le", 1: "utf-8"}
COMP_U16, COMP_U32, COMP_F32 = 5123, 5125, 5126
TARGET_ARRAY = 34962
TARGET_ELEMENT = 34963


class Reader:
    def __init__(self, data: bytes):
        self.d = data
        self.o = 0

    def u8(self):
        v = self.d[self.o]
        self.o += 1
        return v

    def i8(self):
        v = struct.unpack_from("<b", self.d, self.o)[0]
        self.o += 1
        return v

    def u16(self):
        v = struct.unpack_from("<H", self.d, self.o)[0]
        self.o += 2
        return v

    def i16(self):
        v = struct.unpack_from("<h", self.d, self.o)[0]
        self.o += 2
        return v

    def u32(self):
        v = struct.unpack_from("<I", self.d, self.o)[0]
        self.o += 4
        return v

    def i32(self):
        v = struct.unpack_from("<i", self.d, self.o)[0]
        self.o += 4
        return v

    def f32(self):
        v = struct.unpack_from("<f", self.d, self.o)[0]
        self.o += 4
        return v

    def vec(self, n):
        return [self.f32() for _ in range(n)]

    def text(self, enc):
        n = self.i32()
        raw = self.d[self.o:self.o + n]
        self.o += n
        return raw.decode(enc, errors="replace")

    def index(self, size):
        if size == 1:
            return self.i8()
        if size == 2:
            return self.i16()
        return self.i32()

    def skip(self, count):
        self.o += count


def read_pmx(path: Path):
    """解析 PMX；材质变形（type 8）在 2.0 与 2.1 里字段不同，这里两种都试，取能完整解析到文件尾的那种。"""
    best = None
    errors = []
    for tint in (True, False):
        try:
            model = _read_pmx(path, tint)
        except Exception as exc:  # 中途失步会读越界，换另一种布局再试
            errors.append(exc)
            continue
        model["material_morph_tint"] = tint
        if model["end"] == model["size"]:
            return model
        if best is None or abs(model["size"] - model["end"]) < abs(best["size"] - best["end"]):
            best = model
    if best is not None:
        return best
    raise errors[0]


def _read_pmx(path: Path, material_morph_tint: bool):
    r = Reader(path.read_bytes())
    magic = r.d[0:4]
    if magic != b"PMX ":
        raise SystemExit("不是 PMX 文件：%s" % path)
    r.skip(4)
    version = r.f32()
    globals_count = r.u8()
    g = [r.u8() for _ in range(globals_count)]
    enc = ENCODINGS.get(g[0], "utf-16-le")
    extra_uv = g[1]
    sizes = {"vertex": g[2], "texture": g[3], "material": g[4], "bone": g[5], "morph": g[6], "rigid": g[7]}

    r.text(enc)
    r.text(enc)
    r.text(enc)
    r.text(enc)

    # 顶点
    vertices = []
    for _ in range(r.u32()):
        pos = r.vec(3)
        normal = r.vec(3)
        uv = r.vec(2)
        if extra_uv:
            r.vec(4 * extra_uv)
        skin = r.u8()
        if skin == 0:
            bones = [r.index(sizes["bone"])]
            weights = [1.0]
        elif skin == 1:
            bones = [r.index(sizes["bone"]), r.index(sizes["bone"])]
            weights = [r.f32(), 0.0]
            weights[1] = 1.0 - weights[0]
        elif skin == 2:
            bones = [r.index(sizes["bone"]) for _ in range(4)]
            weights = [r.f32() for _ in range(4)]
        elif skin == 3:  # SDEF → 近似 BDEF2
            bones = [r.index(sizes["bone"]), r.index(sizes["bone"])]
            weights = [r.f32(), 0.0]
            weights[1] = 1.0 - weights[0]
            r.vec(9)
        else:  # QDEF → 近似 BDEF4
            bones = [r.index(sizes["bone"]) for _ in range(4)]
            weights = [r.f32() for _ in range(4)]
        r.f32()  # edge scale
        total = sum(weights)
        if total > 0:
            weights = [w / total for w in weights]
        vertices.append((pos, normal, uv, bones, weights))

    # 面
    index_count = r.u32()
    faces = [0] * index_count
    for i in range(index_count):
        faces[i] = r.u32() if sizes["vertex"] == 4 else (r.u16() if sizes["vertex"] == 2 else r.u8())

    # 贴图路径
    textures = [r.text(enc) for _ in range(r.u32())]

    # 材质
    materials = []
    for _ in range(r.u32()):
        name = r.text(enc)
        r.text(enc)
        diffuse = r.vec(4)
        r.vec(3)
        r.f32()
        r.vec(3)
        r.u8()
        r.vec(4)
        r.f32()
        tex_index = r.index(sizes["texture"])
        r.index(sizes["texture"])
        r.u8()
        toon_flag = r.u8()
        if toon_flag == 0:
            r.index(sizes["texture"])
        else:
            r.u8()
        r.text(enc)
        face_count = r.u32()
        materials.append({"name": name, "diffuse": diffuse, "texture": tex_index, "faces": face_count})

    # 骨骼（标志位按 PMX 2.0 规范：位0 接续先 / 位5 IK / 位8-9 付与 / 位10 轴固定 / 位11 局部轴 / 位13 外部亲）
    bones = []
    for _ in range(r.u32()):
        name = r.text(enc)
        r.text(enc)
        pos = r.vec(3)
        parent = r.index(sizes["bone"])
        r.i32()  # 变形阶（layer）
        flags = r.u16()
        if flags & 0x0001:  # 接续先 = 骨骼索引（否则是坐标偏移）
            r.index(sizes["bone"])
        else:
            r.vec(3)
        if flags & 0x0020:  # IK
            r.index(sizes["bone"])  # 目标骨骼
            r.u32()  # 循环次数
            r.f32()  # 单位角限制
            for _ in range(r.u32()):  # 链接骨骼
                r.index(sizes["bone"])
                if r.u8():
                    r.vec(6)  # 角度限制 min / max
        if flags & 0x0100 or flags & 0x0200:  # 回転付与 / 移動付与（共用一个付与亲）
            r.index(sizes["bone"])
            r.f32()
        if flags & 0x0400:  # 轴固定
            r.vec(3)
        if flags & 0x0800:  # 局部轴
            r.vec(6)
        if flags & 0x2000:  # 外部亲
            r.i32()
        bones.append({"name": name, "pos": pos, "parent": parent})

    # 变形（跳过）
    for _ in range(r.u32()):
        r.text(enc)
        r.text(enc)
        r.u8()
        morph_type = r.u8()
        count = r.u32()
        for _ in range(count):
            if morph_type == 0:
                r.index(sizes["morph"])
                r.f32()  # 影响权重
            elif morph_type == 1:
                r.index(sizes["vertex"])
                r.vec(3)
            elif morph_type == 2:
                r.index(sizes["bone"])
                r.vec(7)
            elif 3 <= morph_type <= 7:
                r.index(sizes["vertex"])
                r.vec(4)
            elif morph_type == 8:
                r.index(sizes["material"])
                r.u8()
                r.vec(4)
                r.vec(3)
                r.f32()
                r.vec(3)
                r.vec(4)
                r.f32()
                if material_morph_tint:  # PMX 2.1 风格：贴图/环境/卡通的 tint
                    r.vec(12)
                else:  # PMX 2.0 风格：贴图 / 环境 / 卡通索引
                    r.index(sizes["texture"])
                    r.index(sizes["texture"])
                    r.u8()
                    if r.u8() == 0:  # 卡通参照 0 = 按索引，1 = 内置卡通
                        r.index(sizes["texture"])
                    else:
                        r.u8()
            elif morph_type == 9:
                r.index(sizes["morph"])
                r.f32()
            else:
                r.index(sizes["rigid"])  # 刚体变形（type 10）
                r.u8()  # 本地标志
                r.vec(3)  # 移动速度
                r.vec(3)  # 旋转扭矩

    # 显示枠（跳过）
    for _ in range(r.u32()):
        r.text(enc)
        r.text(enc)
        r.u8()
        for _ in range(r.u32()):
            item_type = r.u8()
            r.index(sizes["morph"] if item_type else sizes["bone"])

    # 刚体（跳过）
    for _ in range(r.u32()):
        r.text(enc)
        r.text(enc)
        r.index(sizes["bone"])
        r.u8()
        r.u16()
        r.u8()
        r.vec(3)
        r.vec(3)
        r.vec(3)
        r.vec(5)
        r.u8()

    # 关节（跳过）
    for _ in range(r.u32()):
        r.text(enc)
        r.text(enc)
        r.u8()
        r.index(sizes["rigid"])
        r.index(sizes["rigid"])
        r.vec(24)  # 位置 / 旋转 / 移动限制上下限 / 旋转限制上下限 / 弹簧移动 / 弹簧旋转

    return {
        "version": version, "vertices": vertices, "faces": faces, "textures": textures,
        "materials": materials, "bones": bones, "end": r.o, "size": len(r.d),
    }


def load_image_bytes(pmx_dir: Path, rel: str):
    clean = rel.replace("\\", "/").lstrip("/")
    candidate = pmx_dir / clean
    if not candidate.exists():
        # 有些模型贴图路径区分大小写 / 有多余前缀，退化为按文件名在模型目录里找
        for found in pmx_dir.rglob(Path(clean).name):
            candidate = found
            break
    if not candidate.exists():
        return None, None
    data = candidate.read_bytes()
    suffix = candidate.suffix.lower()
    mime = "image/png" if suffix == ".png" else ("image/jpeg" if suffix in (".jpg", ".jpeg") else None)
    if mime is None:
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            mime = "image/png"
        elif data[:3] == b"\xff\xd8\xff":
            mime = "image/jpeg"
    return data, mime


def pack_glb(model: dict, pmx_dir: Path, out_path: Path):
    vertices = model["vertices"]
    faces = model["faces"]
    bones = model["bones"]

    bin_parts = []
    buffer_views = []
    accessors = []

    def add_view(data: bytes, target=None):
        offset = sum(len(p) for p in bin_parts)
        while offset % 4:
            bin_parts.append(b"\x00")
            offset += 1
        bin_parts.append(data)
        view = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target:
            view["target"] = target
        buffer_views.append(view)
        return len(buffer_views) - 1

    def add_accessor(view, comp, count, kind, minmax=None, normalized=False):
        acc = {"bufferView": view, "componentType": comp, "count": count, "type": kind}
        if normalized:
            acc["normalized"] = True
        if minmax:
            acc["min"], acc["max"] = minmax
        accessors.append(acc)
        return len(accessors) - 1

    # 位置 / 法线 / UV / 蒙皮
    pos_bytes = b"".join(struct.pack("<3f", *v[0]) for v in vertices)
    pos_min = [min(v[0][i] for v in vertices) for i in range(3)]
    pos_max = [max(v[0][i] for v in vertices) for i in range(3)]
    pos_acc = add_accessor(add_view(pos_bytes, TARGET_ARRAY), COMP_F32, len(vertices), "VEC3",
                           (pos_min, pos_max))
    nrm_acc = add_accessor(add_view(b"".join(struct.pack("<3f", *v[1]) for v in vertices), TARGET_ARRAY),
                           COMP_F32, len(vertices), "VEC3")
    uv_bytes = b"".join(struct.pack("<2f", v[2][0], 1.0 - v[2][1]) for v in vertices)
    uv_acc = add_accessor(add_view(uv_bytes, TARGET_ARRAY), COMP_F32, len(vertices), "VEC2")

    joint_bytes = b""
    weight_bytes = b""
    for _, _, _, vbones, vweights in vertices:
        j = list(vbones) + [0] * (4 - len(vbones))
        w = list(vweights) + [0.0] * (4 - len(vweights))
        joint_bytes += struct.pack("<4H", *[max(0, x) for x in j[:4]])
        weight_bytes += struct.pack("<4f", *w[:4])
    joint_acc = add_accessor(add_view(joint_bytes, TARGET_ARRAY), COMP_U16, len(vertices), "VEC4")
    weight_acc = add_accessor(add_view(weight_bytes, TARGET_ARRAY), COMP_F32, len(vertices), "VEC4")

    # 按材质切分索引
    use_u32 = len(vertices) > 65535
    primitives = []
    cursor = 0
    for mat in model["materials"]:
        count = mat["faces"]
        chunk = faces[cursor:cursor + count]
        cursor += count
        if not chunk:
            continue
        if use_u32:
            data = struct.pack("<%dI" % len(chunk), *chunk)
            comp = COMP_U32
        else:
            data = struct.pack("<%dH" % len(chunk), *chunk)
            comp = COMP_U16
        acc = add_accessor(add_view(data, TARGET_ELEMENT), comp, len(chunk), "SCALAR")
        primitives.append({"material": len(primitives), "attributes": {
            "POSITION": pos_acc, "NORMAL": nrm_acc, "TEXCOORD_0": uv_acc,
            "JOINTS_0": joint_acc, "WEIGHTS_0": weight_acc,
        }, "indices": acc})

    # 材质 + 贴图（内嵌）
    gltf_materials = []
    images = []
    gltf_textures = []
    samplers = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
    for mat in model["materials"]:
        entry = {
            "name": mat["name"] or "material",
            "pbrMetallicRoughness": {
                "baseColorFactor": [mat["diffuse"][0], mat["diffuse"][1], mat["diffuse"][2], mat["diffuse"][3]],
                "metallicFactor": 0.0,
                "roughnessFactor": 0.85,
            },
            "doubleSided": True,
        }
        if mat["diffuse"][3] < 0.999:
            entry["alphaMode"] = "BLEND"
        tex_index = mat["texture"]
        if 0 <= tex_index < len(model["textures"]):
            data, mime = load_image_bytes(pmx_dir, model["textures"][tex_index])
            if data and mime:
                view = add_view(data)
                images.append({"bufferView": view, "mimeType": mime, "name": Path(model["textures"][tex_index]).name})
                gltf_textures.append({"source": len(images) - 1, "sampler": 0})
                entry["pbrMetallicRoughness"]["baseColorTexture"] = {"index": len(gltf_textures) - 1}
        gltf_materials.append(entry)

    # 骨骼节点 + 逆绑定矩阵
    node_index = []
    nodes = []
    for i, bone in enumerate(bones):
        parent = bone["parent"]
        parent_pos = bones[parent]["pos"] if 0 <= parent < len(bones) else [0.0, 0.0, 0.0]
        local = [bone["pos"][k] - parent_pos[k] for k in range(3)]
        nodes.append({"name": bone["name"] or ("bone_%d" % i), "translation": local})
        node_index.append(i)
    children = [[] for _ in bones]
    roots = []
    for i, bone in enumerate(bones):
        parent = bone["parent"]
        if 0 <= parent < len(bones):
            children[parent].append(i)
        else:
            roots.append(i)
    for i, kids in enumerate(children):
        if kids:
            nodes[i]["children"] = kids

    world_pos = [None] * len(bones)

    def resolve(i):
        if world_pos[i] is not None:
            return world_pos[i]
        bone = bones[i]
        parent = bone["parent"]
        if 0 <= parent < len(bones):
            base = resolve(parent)
        else:
            base = [0.0, 0.0, 0.0]
        world_pos[i] = [base[k] + bone["pos"][k] - (bones[parent]["pos"][k] if 0 <= parent < len(bones) else 0.0)
                        for k in range(3)]
        return world_pos[i]

    ibm = []
    for i in range(len(bones)):
        p = resolve(i)
        ibm.append([
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            -p[0], -p[1], -p[2], 1,
        ])
    ibm_bytes = struct.pack("<%df" % (16 * len(ibm)), *[v for m in ibm for v in m])
    ibm_acc = add_accessor(add_view(ibm_bytes), COMP_F32, len(ibm), "MAT4")
    skin = {"joints": node_index, "inverseBindMatrices": ibm_acc, "skeleton": roots[0] if roots else 0}

    mesh_node = len(nodes)
    nodes.append({"name": "mesh", "mesh": 0, "skin": 0})
    for r in roots:
        nodes[mesh_node].setdefault("children", []).append(r)
    scene_nodes = [mesh_node]

    gltf = {
        "asset": {"version": "2.0", "generator": "pmx2glb (trae)"},
        "scene": 0,
        "scenes": [{"name": "Scene", "nodes": scene_nodes}],
        "nodes": nodes,
        "meshes": [{"name": "mesh", "primitives": primitives}],
        "skins": [skin],
        "materials": gltf_materials,
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": 0}],
    }
    if images:
        gltf["images"] = images
        gltf["textures"] = gltf_textures
        gltf["samplers"] = samplers

    bin_blob = b"".join(bin_parts)
    gltf["buffers"][0]["byteLength"] = len(bin_blob)
    json_blob = json.dumps(gltf, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    while len(json_blob) % 4:
        json_blob += b" "
    while len(bin_blob) % 4:
        bin_blob += b"\x00"

    with out_path.open("wb") as f:
        f.write(b"glTF" + struct.pack("<II", 2, 12 + 8 + len(json_blob) + 8 + len(bin_blob)))
        f.write(struct.pack("<I", len(json_blob)) + b"JSON" + json_blob)
        f.write(struct.pack("<I", len(bin_blob)) + b"BIN\x00" + bin_blob)

    return len(vertices), len(bones), len(primitives), len(images)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    pmx = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    model = read_pmx(pmx)
    if model["end"] != model["size"]:
        print("[pmx2glb] 警告：解析结束位置 %d != 文件大小 %d（格式可能有出入）" % (model["end"], model["size"]))
    name = pmx.stem
    safe = "".join(ch for ch in name if ch.isascii() and (ch.isalnum() or ch in "._- ")).strip() or "model"
    out_path = out_dir / ("%s.glb" % safe)
    stats = pack_glb(model, pmx.parent, out_path)
    print("[pmx2glb] %s -> %s | 顶点=%d 骨骼=%d 图元=%d 贴图=%d" % (pmx.name, out_path.name, *stats))


if __name__ == "__main__":
    main()