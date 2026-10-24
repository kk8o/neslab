# NesLab 的 MMC1 自检卡带：64 KB PRG（4 页，代码在固定的最后一页）+ 16 KB CHR（4 个 4 KB 页）+ 带电池的 8 KB 存档内存。
# 屏幕上（状态栏，第 1 行）：
#   程序换页：依次把 $8000 换成第 0、1、2 页，读出每页开头的字节写到屏幕上 —— 换页对了显示「NES」
#   存档内存：往 $6000 写 $5A 再读回来 —— 读得回显示「OK」，读不回显示「BB」
# 操作：B 键 = 状态栏以下换成另一套背景图案（第 2 页，画面中途换图案页）；Select = 镜像在竖向 / 单屏之间切换
# （按住 A 横向卷动时看得出来）；方向键移动笑脸。状态栏始终用第 0 页图案、不卷动（精灵 0 碰撞后才改）。
# 用法：python make_demo_mmc1.py out.nes
import sys
from nesasm import Program, PALETTE, letter, bg_bank, sprite_bank, ines, BG

P = Program(0xC000)
L, I, DB = P.L, P.I, P.DB
FRAME, BUTTONS, X, Y, SCROLL, PREV, BGBANK, CONTROL, PRESSED = range(9)   # 零页变量
CTRL_V, CTRL_FLIP = 0x1E, 0x02          # 控制寄存器：竖向镜像 + PRG 模式 3 + 4 KB 图案；^2 = 单屏

L("reset")
I("SEI"); I("CLD"); I("LDX", "imm", 0x40); I("STX", "abs", 0x4017); I("LDX", "imm", 0xFF); I("TXS"); I("INX")
I("STX", "abs", 0x2000); I("STX", "abs", 0x2001); I("STX", "abs", 0x4010)
I("LDA", "imm", 0x80); I("STA", "abs", 0x8000)            # MMC1 复位
I("LDA", "imm", CTRL_V); I("JSR", "abs", "mmc_ctrl")      # （零页变量要等清完内存再设）
I("LDA", "imm", 0); I("JSR", "abs", "mmc_chr0")            # 背景 = 第 0 页
I("LDA", "imm", 1); I("JSR", "abs", "mmc_chr1")            # 精灵 = 第 1 页
I("LDA", "imm", 0); I("JSR", "abs", "mmc_prg")
L("vw1"); I("BIT", "abs", 0x2002); I("BPL", "rel", "vw1")
I("LDX", "imm", 0)
L("clr")
I("LDA", "imm", 0)
for page in (0x0000, 0x0100, 0x0300, 0x0400, 0x0500, 0x0600, 0x0700):
    I("STA", "absx", page)
I("LDA", "imm", 0xFF); I("STA", "absx", 0x0200)
I("INX"); I("BNE", "rel", "clr")
L("vw2"); I("BIT", "abs", 0x2002); I("BPL", "rel", "vw2")
I("LDA", "imm", CTRL_V); I("STA", "zp", CONTROL)
I("LDA", "imm", 0x3F); I("STA", "abs", 0x2006); I("LDA", "imm", 0x00); I("STA", "abs", 0x2006); I("LDX", "imm", 0)
L("pal"); I("LDA", "absx", "palette"); I("STA", "abs", 0x2007); I("INX"); I("CPX", "imm", 32); I("BNE", "rel", "pal")
I("LDA", "imm", 0x20); I("STA", "abs", 0x2006); I("LDA", "imm", 0x00); I("STA", "abs", 0x2006)
I("LDY", "imm", 8); I("LDX", "imm", 0)
L("fill"); I("TXA"); I("AND", "imm", 0x03); I("CLC"); I("ADC", "imm", 1); I("STA", "abs", 0x2007)
I("INX"); I("BNE", "rel", "fill"); I("DEY"); I("BNE", "rel", "fill")
I("LDA", "imm", 0x23); I("STA", "abs", 0x2006); I("LDA", "imm", 0xC0); I("STA", "abs", 0x2006); I("LDX", "imm", 0)
L("att0"); I("TXA"); I("STA", "abs", 0x2007); I("INX"); I("CPX", "imm", 64); I("BNE", "rel", "att0")
I("LDA", "imm", 0x27); I("STA", "abs", 0x2006); I("LDA", "imm", 0xC0); I("STA", "abs", 0x2006); I("LDX", "imm", 0)
I("LDA", "imm", 0xE4)
L("att1"); I("STA", "abs", 0x2007); I("INX"); I("CPX", "imm", 64); I("BNE", "rel", "att1")
# 第 1 行第 4 列起：程序换页测试 + 存档内存测试
I("LDA", "imm", 0x20); I("STA", "abs", 0x2006); I("LDA", "imm", 0x24); I("STA", "abs", 0x2006)
for b in range(3):
    I("LDA", "imm", b); I("JSR", "abs", "mmc_prg"); I("LDA", "abs", 0x8000); I("STA", "abs", 0x2007)
I("LDA", "imm", 0); I("JSR", "abs", "mmc_prg")
I("LDA", "imm", 0); I("STA", "abs", 0x2007)                 # 空一格
I("LDA", "imm", 0x5A); I("STA", "abs", 0x6000); I("LDA", "imm", 0); I("LDA", "abs", 0x6000)
I("CMP", "imm", 0x5A); I("BNE", "rel", "ramfail")
I("LDA", "imm", letter("O")); I("STA", "abs", 0x2007); I("LDA", "imm", letter("K")); I("STA", "abs", 0x2007)
I("JMP", "abs", "ramdone")
L("ramfail"); I("LDA", "imm", letter("B")); I("STA", "abs", 0x2007); I("STA", "abs", 0x2007)
L("ramdone")
# 第 2 行第 4 列：标题
I("LDA", "imm", 0x20); I("STA", "abs", 0x2006); I("LDA", "imm", 0x44); I("STA", "abs", 0x2006); I("LDX", "imm", 0)
L("txt"); I("LDA", "absx", "text"); I("CMP", "imm", 0xFF); I("BEQ", "rel", "txtdone"); I("STA", "abs", 0x2007); I("INX"); I("JMP", "abs", "txt")
L("txtdone")
I("LDA", "imm", 120); I("STA", "zp", X); I("LDA", "imm", 100); I("STA", "zp", Y)
I("LDA", "imm", 0); I("STA", "zp", BGBANK); I("STA", "abs", 0x2005); I("STA", "abs", 0x2005)
I("LDA", "imm", 0x88); I("STA", "abs", 0x2000)
I("LDA", "imm", 0x1E); I("STA", "abs", 0x2001)
# 主循环：精灵 0 碰撞后（状态栏底边）卷屏 + 把背景换成 BGBANK 页 —— 画面中途换图案页
L("main")
L("s0clr"); I("BIT", "abs", 0x2002); I("BVS", "rel", "s0clr")
L("s0set"); I("BIT", "abs", 0x2002); I("BVC", "rel", "s0set")
I("LDA", "zp", SCROLL); I("STA", "abs", 0x2005); I("LDA", "imm", 0); I("STA", "abs", 0x2005)
I("LDA", "zp", BGBANK); I("JSR", "abs", "mmc_chr0")
I("JMP", "abs", "main")

L("nmi")
I("PHA"); I("TXA"); I("PHA"); I("TYA"); I("PHA")
SPRITES = (
    (("imm", 24), ("imm", 1), ("imm", 0x01), ("imm", 16)),
    (("zp", Y), ("imm", 1), ("imm", 0x00), ("zp", X)),
    (("imm", 60), ("imm", 1), ("imm", 0x22), ("zp", FRAME)),
)
for i, fields in enumerate(SPRITES):
    for j, (mode, v) in enumerate(fields):
        I("LDA", mode, v); I("STA", "abs", 0x0200 + i * 4 + j)
I("LDA", "imm", 0); I("STA", "abs", 0x2003); I("LDA", "imm", 2); I("STA", "abs", 0x4014)
I("LDA", "imm", 1); I("STA", "abs", 0x4016); I("LDA", "imm", 0); I("STA", "abs", 0x4016); I("LDX", "imm", 8)
L("rj"); I("LDA", "abs", 0x4016); I("LSRA"); I("ROL", "zp", BUTTONS); I("DEX"); I("BNE", "rel", "rj")
# 刚按下的键 = 这次按着 & 上次没按
I("LDA", "zp", PREV); I("EOR", "imm", 0xFF); I("AND", "zp", BUTTONS); I("STA", "zp", PRESSED)
I("LDA", "zp", BUTTONS); I("STA", "zp", PREV)
for mask, op, var, nxt in ((0x08, "DEC", Y, "nu"), (0x04, "INC", Y, "nd"), (0x02, "DEC", X, "nl"),
                           (0x01, "INC", X, "nr"), (0x80, "INC", SCROLL, "na")):
    I("LDA", "zp", BUTTONS); I("AND", "imm", mask); I("BEQ", "rel", nxt); I(op, "zp", var); L(nxt)
I("LDA", "zp", PRESSED); I("AND", "imm", 0x40); I("BEQ", "rel", "nb")      # B：背景页 0 ⇄ 2
I("LDA", "zp", BGBANK); I("EOR", "imm", 0x02); I("STA", "zp", BGBANK); L("nb")
I("LDA", "zp", PRESSED); I("AND", "imm", 0x20); I("BEQ", "rel", "ns")      # Select：竖向 ⇄ 单屏
I("LDA", "zp", CONTROL); I("EOR", "imm", CTRL_FLIP); I("STA", "zp", CONTROL); L("ns")
I("LDA", "zp", CONTROL); I("JSR", "abs", "mmc_ctrl")
I("LDA", "imm", 0); I("JSR", "abs", "mmc_chr0")             # 状态栏用第 0 页
I("LDA", "imm", 0); I("STA", "abs", 0x2005); I("STA", "abs", 0x2005)
I("LDA", "imm", 0x88); I("STA", "abs", 0x2000)
I("INC", "zp", FRAME)
I("PLA"); I("TAY"); I("PLA"); I("TAX"); I("PLA"); I("RTI")
L("irq"); I("RTI")

# MMC1 写寄存器：A 的低 5 位从低到高一位一位写进去
for name, addr in (("mmc_ctrl", 0x8000), ("mmc_chr0", 0xA000), ("mmc_chr1", 0xC000), ("mmc_prg", 0xE000)):
    L(name)
    for k in range(5):
        I("STA", "abs", addr)
        if k < 4: I("LSRA")
    I("RTS")

L("palette")
DB(*PALETTE)
L("text")
DB(*[letter(ch) for ch in "NESLAB OK"], 0xFF)

code, labels = P.assemble()
prg = bytearray(4 * 16384)
for b, ch in enumerate("NES"):                                 # 第 0-2 页开头的标记字节
    prg[b * 16384] = letter(ch)
base = 3 * 16384                                               # 代码在第 3 页（固定在 $C000）
prg[base:base + len(code)] = code
for addr, name in ((0xFFFA, "nmi"), (0xFFFC, "reset"), (0xFFFE, "irq")):
    prg[base + addr - 0xC000] = labels[name] & 0xFF
    prg[base + addr - 0xC000 + 1] = labels[name] >> 8
alt = dict(BG)                                                 # 第 2 页：背景图块换个样子（砖 ⇄ 棋盘、叉 ⇄ 点）
alt[1], alt[2], alt[3], alt[4] = BG[2], BG[1], BG[4], BG[3]
chr_ = bg_bank() + sprite_bank() + bg_bank(alt) + bytearray(4096)
open(sys.argv[1], "wb").write(ines(prg, chr_, mapper=1, flags6_low=0x03))   # 竖向 + 电池
print("code", len(code), "bytes")
