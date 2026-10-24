# NesLab 自检卡带（NROM）：砖块 / 棋盘背景（两张图块表横向相连）、文字、三个精灵（精灵 0 是状态栏底边的碰撞标记，
# 一个在背景前、可用方向键移动，一个在背景后、自动横移），按住 A 横向卷屏，状态栏靠精灵 0 碰撞分屏不动。
# 用到调色板、图块表、属性表、OAM DMA、手柄、卷屏、NMI、精灵 0。输出 16 KB PRG + 8 KB CHR、竖向镜像。
# 用法：python make_demo.py out.nes
import sys
from nesasm import Program, PALETTE, letter, bg_bank, sprite_bank, ines

P = Program(0xC000)
L, I, DB = P.L, P.I, P.DB

L("reset")
I("SEI"); I("CLD"); I("LDX", "imm", 0x40); I("STX", "abs", 0x4017); I("LDX", "imm", 0xFF); I("TXS"); I("INX")
I("STX", "abs", 0x2000); I("STX", "abs", 0x2001); I("STX", "abs", 0x4010)
L("vw1"); I("BIT", "abs", 0x2002); I("BPL", "rel", "vw1")
I("LDX", "imm", 0)
L("clr")
I("LDA", "imm", 0)
for page in (0x0000, 0x0100, 0x0300, 0x0400, 0x0500, 0x0600, 0x0700):
    I("STA", "absx", page)
I("LDA", "imm", 0xFF); I("STA", "absx", 0x0200)          # 精灵页全填 FF = 都藏在屏幕外
I("INX"); I("BNE", "rel", "clr")
L("vw2"); I("BIT", "abs", 0x2002); I("BPL", "rel", "vw2")
# 调色板
I("LDA", "imm", 0x3F); I("STA", "abs", 0x2006); I("LDA", "imm", 0x00); I("STA", "abs", 0x2006); I("LDX", "imm", 0)
L("pal"); I("LDA", "absx", "palette"); I("STA", "abs", 0x2007); I("INX"); I("CPX", "imm", 32); I("BNE", "rel", "pal")
# 两张图块表（$2000-$27FF）填图块 1..4 轮换
I("LDA", "imm", 0x20); I("STA", "abs", 0x2006); I("LDA", "imm", 0x00); I("STA", "abs", 0x2006)
I("LDY", "imm", 8); I("LDX", "imm", 0)
L("fill"); I("TXA"); I("AND", "imm", 0x03); I("CLC"); I("ADC", "imm", 1); I("STA", "abs", 0x2007)
I("INX"); I("BNE", "rel", "fill"); I("DEY"); I("BNE", "rel", "fill")
# 属性表：第一张按序号铺开（各种调色板组合），第二张统一
I("LDA", "imm", 0x23); I("STA", "abs", 0x2006); I("LDA", "imm", 0xC0); I("STA", "abs", 0x2006); I("LDX", "imm", 0)
L("att0"); I("TXA"); I("STA", "abs", 0x2007); I("INX"); I("CPX", "imm", 64); I("BNE", "rel", "att0")
I("LDA", "imm", 0x27); I("STA", "abs", 0x2006); I("LDA", "imm", 0xC0); I("STA", "abs", 0x2006); I("LDX", "imm", 0)
I("LDA", "imm", 0xE4)
L("att1"); I("STA", "abs", 0x2007); I("INX"); I("CPX", "imm", 64); I("BNE", "rel", "att1")
# 文字（第一张表第 2 行第 4 列）
I("LDA", "imm", 0x20); I("STA", "abs", 0x2006); I("LDA", "imm", 0x44); I("STA", "abs", 0x2006); I("LDX", "imm", 0)
L("txt"); I("LDA", "absx", "text"); I("CMP", "imm", 0xFF); I("BEQ", "rel", "txtdone"); I("STA", "abs", 0x2007); I("INX"); I("JMP", "abs", "txt")
L("txtdone")
I("LDA", "imm", 120); I("STA", "zp", 0x02); I("LDA", "imm", 100); I("STA", "zp", 0x03)
I("LDA", "imm", 0); I("STA", "abs", 0x2005); I("STA", "abs", 0x2005)
I("LDA", "imm", 0x88); I("STA", "abs", 0x2000)            # 开 NMI，精灵用第二张图案表
I("LDA", "imm", 0x1E); I("STA", "abs", 0x2001)            # 显示背景和精灵
# 主循环：等精灵 0 碰撞（状态栏底边），之后才写卷屏 = 状态栏不动、下面卷动
L("main")
L("s0clr"); I("BIT", "abs", 0x2002); I("BVS", "rel", "s0clr")
L("s0set"); I("BIT", "abs", 0x2002); I("BVC", "rel", "s0set")
I("LDA", "zp", 0x04); I("STA", "abs", 0x2005); I("LDA", "imm", 0); I("STA", "abs", 0x2005)
I("JMP", "abs", "main")

L("nmi")
I("PHA"); I("TXA"); I("PHA"); I("TYA"); I("PHA")
# 精灵 0：固定在状态栏底边的标记（碰撞用）；精灵 1：笑脸，跟方向键走；精灵 2：调色板 2、在背景后面，自动横移
SPRITES = (  # 每个精灵 (y, 图块, 属性, x)；("zp", 地址) = 取零页变量（$02 x、$03 y、$00 帧计数）
    (("imm", 24), ("imm", 1), ("imm", 0x01), ("imm", 16)),
    (("zp", 0x03), ("imm", 1), ("imm", 0x00), ("zp", 0x02)),
    (("imm", 60), ("imm", 1), ("imm", 0x22), ("zp", 0x00)),
)
for i, fields in enumerate(SPRITES):
    for j, (mode, v) in enumerate(fields):
        I("LDA", mode, v)
        I("STA", "abs", 0x0200 + i * 4 + j)
I("LDA", "imm", 0); I("STA", "abs", 0x2003); I("LDA", "imm", 2); I("STA", "abs", 0x4014)
# 手柄：读 8 位进 $01（第 7 位 A … 第 0 位 右）
I("LDA", "imm", 1); I("STA", "abs", 0x4016); I("LDA", "imm", 0); I("STA", "abs", 0x4016); I("LDX", "imm", 8)
L("rj"); I("LDA", "abs", 0x4016); I("LSRA"); I("ROL", "zp", 0x01); I("DEX"); I("BNE", "rel", "rj")
for mask, op, var, nxt in ((0x08, "DEC", 0x03, "nu"), (0x04, "INC", 0x03, "nd"), (0x02, "DEC", 0x02, "nl"),
                           (0x01, "INC", 0x02, "nr"), (0x80, "INC", 0x04, "na")):
    I("LDA", "zp", 0x01); I("AND", "imm", mask); I("BEQ", "rel", nxt); I(op, "zp", var); L(nxt)
I("LDA", "imm", 0); I("STA", "abs", 0x2005); I("STA", "abs", 0x2005)   # 状态栏：不卷
I("LDA", "imm", 0x88); I("STA", "abs", 0x2000)
I("INC", "zp", 0x00)
I("PLA"); I("TAY"); I("PLA"); I("TAX"); I("PLA"); I("RTI")
L("irq"); I("RTI")

L("palette")
DB(*PALETTE)
L("text")
DB(*[letter(ch) for ch in "NESLAB OK"], 0xFF)

code, labels = P.assemble()
prg = bytearray(16384)
prg[:len(code)] = code
for addr, name in ((0xFFFA, "nmi"), (0xFFFC, "reset"), (0xFFFE, "irq")):
    prg[addr - 0xC000] = labels[name] & 0xFF
    prg[addr - 0xC000 + 1] = labels[name] >> 8
open(sys.argv[1], "wb").write(ines(prg, bg_bank() + sprite_bank(), mapper=0))
print("code", len(code), "bytes")
