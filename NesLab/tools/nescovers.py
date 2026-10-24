# 封面对齐：一堆按编号命名的截图（<编号>a.png 标题画面、<编号>b.png 游戏画面，256×240）↔ 一堆 .nes。
# 截图按 8×8 切格，每格换成「颜色按出现顺序编号」的形状（和调色板无关），再和每个 ROM 图案里图块的形状比；
# 少见的形状分量重（log(ROM 数 / 含它的 ROM 数)），得分最高的 ROM 就是这组截图的游戏。
# 图案运行时才写入的卡带（CHR RAM）拿程序区按 16 字节对齐当图块比，图案压缩过的对不上。
# 结果写进截图文件夹的 covers.json（ROM 文件名 → 编号、得分），nes2cart.py --covers 读它。
# 用法：python nescovers.py <ROM 文件夹> <截图文件夹>
import collections, json, math, os, sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import numpy as np
from PIL import Image

MIN_SCORE = 30                       # 得分至少这么多才算对上（这组截图里这个 ROM 还得是第一名）


def canon_tile(b):
    out, m = [], {}
    for r in range(8):
        p0, p1 = b[r], b[r + 8]
        for c in range(8):
            v = ((p0 >> (7 - c)) & 1) | (((p1 >> (7 - c)) & 1) << 1)
            if v not in m:
                m[v] = len(m)
            out.append(m[v])
    return bytes(out)


def rom_tiles(path):
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] != b"NES\x1a":
        return None
    off = 16 + (512 if d[6] & 4 else 0)
    prg = d[off:off + d[4] * 16384]
    chr_ = d[off + len(prg):off + len(prg) + d[5] * 8192]
    src = chr_ or prg
    return {canon_tile(src[t:t + 16]) for t in range(0, len(src) - 15, 16)}


def cells_at(a, oy, ox):
    res = []
    for y0 in range(oy, a.shape[0] - 7, 8):
        for x0 in range(ox, a.shape[1] - 7, 8):
            u, first, inv = np.unique(a[y0:y0 + 8, x0:x0 + 8].ravel(), return_index=True, return_inverse=True)
            if 2 <= len(u) <= 4:
                res.append(np.argsort(np.argsort(first))[inv].astype(np.uint8).tobytes())
    return res


def cells(path, index):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.int32)
    a = a[:, :, 0] * 65536 + a[:, :, 1] * 256 + a[:, :, 2]
    res = cells_at(a, 0, 0)
    hit = sum(1 for s in res if s in index)
    if hit * 3 < len(res):                       # 对得少：画面可能卷过，试别的偏移
        for oy in range(8):
            for ox in (range(1, 8) if oy == 0 else (0,)):
                r = cells_at(a, oy, ox)
                h = sum(1 for s in r if s in index)
                if h > hit:
                    hit, res = h, r
    return set(res)


def main(rom_dir, img_dir):
    index, names = collections.defaultdict(set), []
    for fn in sorted(os.listdir(rom_dir)):
        tiles = rom_tiles(os.path.join(rom_dir, fn))
        if tiles is None:
            continue
        for s in tiles:
            if len(set(s)) > 1:
                index[s].add(len(names))
        names.append(fn)
    print("ROM %d 个，图块形状 %d 种" % (len(names), len(index)))

    ids = sorted({f[:-5] for f in os.listdir(img_dir) if f.endswith(("a.png", "b.png"))}, key=lambda x: (len(x), x))
    best = {}                                     # ROM → (得分, 编号, 第二名得分)
    for n, g in enumerate(ids):
        score = collections.Counter()
        for suf in "ab":
            p = os.path.join(img_dir, g + suf + ".png")
            if os.path.exists(p):
                for s in cells(p, index):
                    r = index.get(s)
                    if r:
                        w = math.log(len(names) / len(r))
                        for x in r:
                            score[x] += w
        # 截图常有同一游戏的好几个汉化版：并列第一的 ROM 都算，每个 ROM 最后取得分最高的那组截图
        top = score.most_common()
        if top and top[0][1] >= MIN_SCORE:
            s1 = top[0][1]
            s2 = next((s for _, s in top if s < s1 * 0.99), 0)
            for rom, s in top:
                if s < s1 * 0.99:
                    break
                if names[rom] not in best or s > best[names[rom]][0]:
                    best[names[rom]] = (s, g, s2)
        if (n + 1) % 200 == 0:
            print("  截图 %d / %d" % (n + 1, len(ids)))
    out = {k: {"img": v[1], "score": round(v[0], 1), "second": round(v[2], 1)} for k, v in sorted(best.items())}
    json.dump(out, open(os.path.join(img_dir, "covers.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("对上 %d / %d 个 ROM，写进 %s" % (len(out), len(names), os.path.join(img_dir, "covers.json")))
    for fn in names:
        if fn not in out:
            print("  没对上：" + fn)


if __name__ == "__main__":
    main(*sys.argv[1:3])
