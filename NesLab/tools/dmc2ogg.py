# DMC 采样还原：游戏里用到、还没有声音文件的 DMC 采样会记进存档 NesLabDB.dmcWanted（卡带 id → "字节号_字节数_速率"）。
# 退出游戏（存档写盘）后跑这个：按 NES 的 1 位增量解码从卡带程序里还原成 ogg，放到卡带文件夹 dmc\ 里，
# 下次启动游戏就放原声（鼓点、人声）。已经有的跳过。要 ffmpeg（带 libvorbis）。
# 用法：python dmc2ogg.py
import glob, os, re, struct, subprocess, sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ADDONS = os.path.dirname(os.path.dirname(HERE))
GAME = os.path.dirname(os.path.dirname(ADDONS))
PERIOD = [428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54]
CPU_HZ = 1789773
OUT_HZ = 44100


def wanted():
    """存档里的 dmcWanted：{卡带 id: {key, ...}}（所有账号合在一起）"""
    out = {}
    for sv in glob.glob(os.path.join(GAME, "WTF", "Account", "*", "SavedVariables", "NesLab.lua")):
        text = open(sv, encoding="utf-8", errors="replace").read()
        m = re.search(r'\["dmcWanted"\] = \{(.*?)\n\t\},', text, re.S)
        if not m:
            continue
        for cart, body in re.findall(r'\["([^"]+)"\] = \{(.*?)\}', m.group(1), re.S):
            out.setdefault(cart, set()).update(re.findall(r'\["([0-9a-f]+_\d+_\d+)"\]', body))
    return out


def cart_folders():
    out = {}
    for d in os.listdir(ADDONS):
        toc = os.path.join(ADDONS, d, d + ".toc")
        if d.startswith("NesLab_") and os.path.exists(toc):
            m = re.search(r"^## X-NesLab-Id: (\S+)", open(toc, encoding="utf-8").read(), re.M)
            if m:
                out[m.group(1)] = os.path.join(ADDONS, d)
    return out


def decode(prg, off, length, rate):
    """1 位增量：每位 1 加 2、0 减 2（0-127 之内），每位一个采样点，再重采样到 44.1 kHz"""
    level, raw = 64, []
    for i in range(length):
        b = prg[(off + i) % len(prg)]
        for bit in range(8):
            if (b >> bit) & 1:
                if level <= 125:
                    level += 2
            elif level >= 2:
                level -= 2
            raw.append(level)
    src_hz = CPU_HZ / PERIOD[rate]
    mean = sum(raw) / len(raw)
    n = int(len(raw) * OUT_HZ / src_hz)
    pcm = []
    for i in range(n):
        v = (raw[min(len(raw) - 1, int(i * src_hz / OUT_HZ))] - mean) / 64.0
        fade = min(1.0, (n - i) / 200.0)                     # 尾巴 200 个采样点淡出，免得咔哒一声
        pcm.append(int(max(-1.0, min(1.0, v * 0.9 * fade)) * 32767))
    return struct.pack("<%dh" % len(pcm), *pcm)


def main():
    todo, folders, made, skipped = wanted(), cart_folders(), 0, 0
    if not todo:
        print("存档里没有要还原的 DMC 采样（先玩用到 DMC 的游戏，再退出游戏让存档写盘）")
        return
    for cart, keys in sorted(todo.items()):
        folder = folders.get(cart)
        if not folder:
            print("找不到卡带 " + cart)
            continue
        m = re.search(r'prg = "([0-9A-F]+)"', open(os.path.join(folder, "cart.lua"), encoding="utf-8").read())
        prg = bytes.fromhex(m.group(1))
        out_dir = os.path.join(folder, "dmc")
        os.makedirs(out_dir, exist_ok=True)
        for key in sorted(keys):
            dst = os.path.join(out_dir, key + ".ogg")
            if os.path.exists(dst):
                skipped += 1
                continue
            off, length, rate = key.split("_")
            pcm = decode(prg, int(off, 16), int(length), int(rate))
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "s16le", "-ar", str(OUT_HZ),
                            "-ac", "1", "-i", "-", "-c:a", "libvorbis", "-q:a", "4", dst], input=pcm, check=True)
            made += 1
        print("%s：%d 段" % (os.path.basename(folder), len(keys)))
    print("新还原 %d 段，已有 %d 段。重启游戏后生效。" % (made, skipped))


if __name__ == "__main__":
    main()
