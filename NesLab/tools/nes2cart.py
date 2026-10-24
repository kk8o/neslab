# .nes（iNES）→ 一张「卡带插件」：Interface\AddOns\NesLab_<游戏名拼音>\（按需加载，选中游戏时才读进来；
# 文件夹名见 names.py，插件文件夹名不能有中文。<id> 是卡带编号，存档、游戏记录都按它存，跟文件夹名无关）
#   NesLab_<id>.toc  游戏名、卡带类型、大小写在 X-NesLab-* 字段里，游戏库不加载卡带也能列出来
#   cart.lua         程序（PRG）、图案（CHR）十六进制，镜像方式、mapper，每个图块用到哪几种颜色
#   tiles.blp        图块贴图：每个图块拆成颜色 1 / 2 / 3 三张白色蒙版（游戏里分别着色），一格 8×8，一行 32 格；
#                    BLP（DXT1，只有白和透明，原样无损，是 32 位 TGA 的八分之一；tools/blp.py）
# 声音用 NesLab\sound 里的共用音色库（所有游戏通用）；还没生成就顺手生成（要 ffmpeg）。
# 支持 mapper 0 NROM、1 MMC1、2 UxROM、3 CNROM、4 MMC3、66 GxROM、140 Jaleco，图案要写死在卡带里（CHR ROM）。带电池的卡带存档进 NesLabDB。
# 转换完要重启游戏，游戏库里才看得到。
# 封面（可选）：--cover 标题画面.png，或 --covers 截图文件夹（按 nescovers.py 写的 covers.json 找这个 ROM 的截图，
# 没有 covers.json 就先生成）。封面存成卡带里的 cover.tga（256×256，上面 240 行是画面），游戏库拿它当图标。
# 用法：python nes2cart.py 游戏.nes <id> "显示名" [--cover 图.png | --covers 截图文件夹]
import os, re, struct, sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # 管道里默认 GBK，游戏名里的生僻字会让 print 报错

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.normpath(os.path.join(HERE, ".."))           # Interface\AddOns\NesLab
ADDONS = os.path.dirname(CORE)

if len(sys.argv) < 4:
    sys.exit('用法：python nes2cart.py 游戏.nes <id> "显示名" [--cover 图.png | --covers 截图文件夹]')
src, rid, name = sys.argv[1:4]
opts = dict(zip(sys.argv[4::2], sys.argv[5::2]))
if not re.fullmatch(r"[A-Za-z0-9]+", rid):
    sys.exit("id 只能用字母和数字")
data = open(src, "rb").read()
if data[:4] != b"NES\x1a":
    sys.exit("不是 iNES（.nes）文件")
prg_banks, chr_banks, f6, f7 = data[4], data[5], data[6], data[7]
if f7 & 0x0C != 0x08 and data[12:16] != bytes(4):     # 老工具在 7-15 字节写过垃圾（如 "DiskDude!"）：高四位不可信
    f7 = 0
mapper = (f6 >> 4) | (f7 & 0xF0)
KINDS = {0: "NROM", 1: "MMC1", 2: "UxROM", 3: "CNROM", 4: "MMC3", 66: "GxROM", 140: "Jaleco"}
if mapper not in KINDS:
    sys.exit("暂时只支持 NROM / MMC1 / UxROM / CNROM / MMC3 / GxROM / Jaleco（mapper 0-4、66、140），这个是 mapper %d" % mapper)
if chr_banks == 0:
    sys.exit("这个卡带的图案在运行时才写进去（CHR RAM），图块贴图没法预先烘，暂不支持")
off = 16 + (512 if f6 & 0x04 else 0)
prg = data[off:off + prg_banks * 16384]
chr_ = data[off + len(prg):off + len(prg) + chr_banks * 8192]
mirror = "V" if f6 & 0x01 else "H"
battery = bool(f6 & 0x02)
tiles = len(chr_) // 16

# 图块贴图：一行 32 格起，图案多就加宽，让高度不超过 2048
SLOTS_PER_ROW = 32
while (tiles * 3 + SLOTS_PER_ROW - 1) // SLOTS_PER_ROW * 8 > 2048 and SLOTS_PER_ROW < 256:
    SLOTS_PER_ROW *= 2
W, H = SLOTS_PER_ROW * 8, 8
while H < (tiles * 3 + SLOTS_PER_ROW - 1) // SLOTS_PER_ROW * 8:
    H *= 2
pix = bytearray(W * H * 4)
used = []
for t in range(tiles):
    p0, p1 = chr_[t * 16:t * 16 + 8], chr_[t * 16 + 8:t * 16 + 16]
    mask = 0
    for r in range(8):
        for c in range(8):
            bit = 7 - c
            v = ((p0[r] >> bit) & 1) | (((p1[r] >> bit) & 1) << 1)
            if v == 0:
                continue
            mask |= 1 << (v - 1)
            s = t * 3 + (v - 1)
            x, y = (s % SLOTS_PER_ROW) * 8 + c, (s // SLOTS_PER_ROW) * 8 + r
            i = (y * W + x) * 4
            pix[i:i + 4] = b"\xff\xff\xff\xff"
    used.append("%d" % mask)

sys.path.insert(0, HERE)
from names import folder_name


def toc_id(d):
    toc = os.path.join(ADDONS, d, d + ".toc")
    if not os.path.exists(toc):
        return None
    m = re.search(r"^## X-NesLab-Id: (\S+)", open(toc, encoding="utf-8").read(), re.M)
    return m and m.group(1)


folder = folder_name(name, rid)
if os.path.isdir(os.path.join(ADDONS, folder)) and toc_id(folder) not in (None, rid):
    folder = folder + "_" + rid                              # 重名的别的游戏：后面加编号
for d in os.listdir(ADDONS):                                 # 同一个编号以前转在别的文件夹（旧名字）：删掉
    if d.startswith("NesLab_") and d != folder and toc_id(d) == rid:
        import shutil
        shutil.rmtree(os.path.join(ADDONS, d))
        print("删掉旧文件夹 " + d)
out = os.path.join(ADDONS, folder)
os.makedirs(out, exist_ok=True)
old_tga = os.path.join(out, "tiles.tga")             # 以前的版本写 TGA
if os.path.exists(old_tga):
    os.remove(old_tga)

# 封面
cover = opts.get("--cover")
if not cover and "--covers" in opts:
    cdir = opts["--covers"]
    index = os.path.join(cdir, "covers.json")
    if not os.path.exists(index):
        print("截图文件夹还没有 covers.json，现在对齐……")
        import subprocess
        subprocess.run([sys.executable, os.path.join(HERE, "nescovers.py"), os.path.dirname(os.path.abspath(src)), cdir],
                       check=True)
    import json
    hit = json.load(open(index, encoding="utf-8")).get(os.path.basename(src))
    if hit:
        cover = os.path.join(cdir, hit["img"] + "a.png")
    else:
        print("截图里没找到这个游戏，不带封面")
cover_tga = os.path.join(out, "cover.tga")
if cover:
    from PIL import Image
    im = Image.open(cover).convert("RGBA")
    if im.size != (256, 240):
        im = im.resize((256, 240), Image.NEAREST)
    canvas = Image.new("RGBA", (256, 256), (0, 0, 0, 255))
    canvas.paste(im, (0, 0))
    with open(cover_tga, "wb") as f:
        f.write(struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, 256, 256, 32, 0x08))
        f.write(canvas.transpose(Image.FLIP_TOP_BOTTOM).tobytes("raw", "BGRA"))
elif os.path.exists(cover_tga):
    os.remove(cover_tga)

sys.path.insert(0, HERE)
import numpy as np
from blp import write_dxt1_mask
write_dxt1_mask(os.path.join(out, "tiles.blp"), np.frombuffer(bytes(pix), dtype=np.uint8).reshape(H, W, 4)[:, :, 3])

size_kb = (len(prg) + len(chr_)) // 1024
kind = KINDS[mapper]
lua_name = name.replace("\\", "\\\\").replace('"', '\\"')
with open(os.path.join(out, "cart.lua"), "w", encoding="utf-8") as f:
    f.write("-- %s：由 NesLab\\tools\\nes2cart.py 从 %s 生成\n" % (name, os.path.basename(src)))
    f.write("NesLab.RegisterRom({\n")
    f.write('\tid = "%s", name = "%s", mapper = %d, mirror = "%s", battery = %s,\n'
            % (rid, lua_name, mapper, mirror, "true" if battery else "false"))
    f.write('\tatlasPath = "Interface\\\\AddOns\\\\%s\\\\tiles", atlasW = %d, atlasH = %d, slotsPerRow = %d,\n'
            % (folder, W, H, SLOTS_PER_ROW))
    f.write('\tatlasBlp = "Interface\\\\AddOns\\\\%s\\\\tiles.blp",\n' % folder)
    f.write('\tused = "%s",\n' % "".join(used))
    f.write('\tprg = "%s",\n' % prg.hex().upper())
    f.write('\tchr = "%s",\n' % chr_.hex().upper())
    f.write("})\n")
with open(os.path.join(out, folder + ".toc"), "w", encoding="utf-8") as f:
    f.write("## Interface: 16001\n")
    f.write("## Title: NesLab · %s\n" % name)
    f.write("## Title-zhCN: NES 卡带 · %s\n" % name)
    f.write("## Notes-zhCN: NesLab 的游戏卡带（%s，%d KB），在 /neslab 游戏库里打开\n" % (kind, size_kb))
    f.write("## LoadOnDemand: 1\n")
    f.write("## Dependencies: NesLab\n")
    f.write("## X-NesLab-Cart: 1\n")
    f.write("## X-NesLab-Id: %s\n" % rid)
    f.write("## X-NesLab-Name: %s\n" % name)
    f.write("## X-NesLab-Mapper: %s\n" % kind)
    f.write("## X-NesLab-Size: %d\n" % size_kb)
    if battery:
        f.write("## X-NesLab-Battery: 1\n")
    if cover:
        f.write("## X-NesLab-Cover: 1\n")
    f.write("\ncart.lua\n")
print("%s -> %s（%s，PRG %d KB + CHR %d KB，%s 镜像，贴图 %dx%d，%s）" % (os.path.basename(src), out, kind, len(prg) // 1024,
                                                           len(chr_) // 1024, mirror, W, H,
                                                           "封面 " + os.path.basename(cover) if cover else "无封面"))

# 共用音色库
sound = os.path.join(CORE, "sound")
have = len([n for n in os.listdir(sound) if n.endswith(".ogg")]) if os.path.isdir(sound) else 0
if have < 1116:
    print("音色库还没生成（%d / 1116），现在生成……" % have)
    import subprocess
    subprocess.run([sys.executable, os.path.join(HERE, "make_samples.py"), CORE], check=True)
else:
    print("音色库已就绪（%d 个采样）" % have)
print("完成。重启游戏后在 /neslab 游戏库里打开。")
