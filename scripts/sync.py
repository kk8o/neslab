# 把游戏里正在用的 NesLab 按白名单同步进这个仓库（开发用）。转好的游戏卡带（NesLab_<拼音>）一律不进仓库，
# 只带自己写的两张自检卡带。用法：python scripts/sync.py "<魔兽目录>\_forever_\Interface\AddOns"
import os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONS = sys.argv[1]

KEEP = {
    "NesLab": ["NesLab.toc", "Cpu.lua", "Ppu.lua", "Apu.lua", "Screen.lua", "Sound.lua", "Nes.lua", "Player.lua",
               "Binds.lua", "Minimap.lua", "sound/*.ogg",
               "tools/nes2cart.py", "tools/nescovers.py", "tools/names.py", "tools/blp.py", "tools/dmc2ogg.py",
               "tools/atlas.py", "tools/chrram.py", "tools/chrlearn.py",
               "tools/make_samples.py", "tools/make_demo.py", "tools/make_demo_mmc1.py", "tools/nesasm.py"],
    "NesLab_Dev": ["NesLab_Dev.toc", "NestestData.lua", "Nestest.lua", "Bench.lua"],
    "NesLab_demo": ["NesLab_demo.toc", "cart.lua", "tiles.blp"],
    "NesLab_mmc1": ["NesLab_mmc1.toc", "cart.lua", "tiles.blp"],
}

n = 0
for addon, files in KEEP.items():
    dst_root = os.path.join(ROOT, addon)
    if os.path.isdir(dst_root):
        shutil.rmtree(dst_root)
    for pat in files:
        d, name = os.path.split(pat)
        src_dir = os.path.join(ADDONS, addon, d)
        names = sorted(f for f in os.listdir(src_dir) if f.endswith(name[1:])) if name.startswith("*") else [name]
        for f in names:
            os.makedirs(os.path.join(dst_root, d), exist_ok=True)
            shutil.copy2(os.path.join(src_dir, f), os.path.join(dst_root, d, f))
            n += 1
print("同步了 %d 个文件" % n)
