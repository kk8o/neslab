-- PPU（2C02），按「图块」这一层模拟：寄存器 $2000-$2007、内部的 v / t / x / w、读缓冲、调色板镜像、OAM。
-- 不逐点算像素：每帧结束交给 Screen 按图块表 / 属性表 / 调色板 / OAM 画。
-- 画面中途改卷屏（写 $2005 / $2006 / $2000）记成「横带」：从下一条扫描线起换新的卷屏位置，Screen 分带画，
-- 状态栏这类分屏能显示对。精灵 0 碰撞按扫描线近似：精灵 0 第一行不透明像素所在的线置位。
-- 图案在卡带内存里（CHR RAM，rom.chrRam）的游戏：图案是游戏运行时写进去的，贴图没法按地址预先烘。
-- tools/chrram.py 先在电脑上把游戏跑一阵，收集它写过的所有图块，按内容烘进贴图（rom.tiles 是这些图块的十六进制）；
-- 这里每个 16 字节的图块按内容查到贴图里的号（p.SLOT），Screen 按它画。查不到的交给 p.onUnknownTile 记下，以后补烘。
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

local MAX_BANDS = 240                         -- 一行一段也够（伪 3D 赛车这类游戏每行都改卷屏）

local function Hex(s)
	local t = {}
	for i = 0, #s / 2 - 1 do t[i] = tonumber(s:sub(i * 2 + 1, i * 2 + 2), 16) end
	return t, #s / 2
end
NesLab.Hex = Hex

local function ScrollX(t, x) return band(rshift(t, 10), 1) * 256 + band(t, 31) * 8 + x end
local function ScrollY(t) return band(rshift(t, 11), 1) * 240 + band(rshift(t, 5), 31) * 8 + band(rshift(t, 12), 7) end

function NesLab.NewPpu(rom, machine)
	local p = {
		ctrl = 0, mask = 0, status = 0, oamAddr = 0, OAM = {}, VRAM = {}, PAL = {},
		v = 0, t = 0, x = 0, w = 0, buf = 0, line = 0, bands = {}, nbands = 0,
		ntGen = 0, bgPalGen = 0,                     -- 图块表 / 背景调色板的版本号：变了 Screen 才重画
		pgen = {},                                   -- 8 组调色板（背景 0-3、精灵 4-7）各自的版本号
		chr1k = { [0] = 0, 1, 2, 3, 4, 5, 6, 7 },   -- 8 个 1 KB 图案窗口当前映射到第几个 1 KB（mapper 改）
	}
	-- 版本号从全局递增的起点开始：同一个画面换新机器（重置、换卡带）时不会和旧版本号撞上
	NesLab.genSeq = (NesLab.genSeq or 0) + 1000000
	p.ntGen, p.bgPalGen = NesLab.genSeq, NesLab.genSeq
	for g = 0, 7 do p.pgen[g] = NesLab.genSeq end
	for i = 0, 255 do p.OAM[i] = 0xFF end
	for i = 0, 4095 do p.VRAM[i] = 0 end            -- 一般卡带只用前 2 KB；四屏卡带（卡带自带 2 KB 显存）用满 4 KB
	for i = 0, 31 do p.PAL[i] = 0x0F end
	local CHR, chrSize
	if rom.chrRam then
		CHR, chrSize = {}, 8192
		for i = 0, 8191 do CHR[i] = 0 end
	else
		CHR, chrSize = Hex(rom.chr)
	end
	p.CHR = CHR
	local VRAM, PAL, OAM = p.VRAM, p.PAL, p.OAM

	-- 图块表镜像：V 竖向（左右两张不同）、H 横向（上下两张不同）、A / B 单屏（只用第一 / 第二张）；
	-- off = 地址 - $2000（0..4095）。MMC1 运行中会换
	local MIRROR = {
		V = function(off) return off % 2048 end,
		H = function(off) return (off >= 2048 and 1024 or 0) + off % 1024 end,
		A = function(off) return off % 1024 end,
		B = function(off) return 1024 + off % 1024 end,
		["4"] = function(off) return off % 4096 end,   -- 四屏：四张图块表各自独立
	}
	p.fourScreen = rom.mirror == "4"
	local NTI
	function p.SetMirror(mode)
		if p.fourScreen then mode = "4" end            -- 四屏卡带：游戏写的镜像设置不起作用
		if mode == p.mirror and NTI then return end    -- MMC1 / MMC3 每次换页都会写一遍镜像：没变就不算
		NTI = MIRROR[mode] or MIRROR.H
		p.NTI, p.mirror = NTI, mode
		p.ntGen = p.ntGen + 1
	end
	p.SetMirror(rom.mirror)

	-- 图案地址（$0000-$1FFF）→ CHR 里的字节号
	local chr1k = p.chr1k
	local function ChrIndex(a)
		return (chr1k[math.floor(a / 1024)] * 1024 + a % 1024) % chrSize
	end
	p.ChrIndex = ChrIndex

	-- 横带记下背景那张图案表的 4 个 1 KB 窗口（图块号 t 在贴图里 = m[t / 64] × 64 + t % 64），
	-- 还有这时的 8 个图案窗口、显示开关（mask）、精灵设置（ctrl）：有的游戏画到状态栏时关精灵、换图案页，
	-- 精灵按它所在那条横带的设置画
	local function SnapBg(b)
		local w = band(p.ctrl, 0x10) ~= 0 and 4 or 0
		b.m0, b.m1, b.m2, b.m3 = chr1k[w], chr1k[w + 1], chr1k[w + 2], chr1k[w + 3]
		local spr = band(p.ctrl, 0x28)
		local changed = b.c == nil or b.spr ~= spr
		local c = b.c or {}
		for i = 0, 7 do
			if c[i] ~= chr1k[i] then
				c[i] = chr1k[i]
				changed = true
			end
		end
		b.c, b.mask, b.spr = c, band(p.mask, 0x18), spr   -- mask 只记显示开关（灰度、强调、左 8 裁剪不画）
		if changed then b.key = spr .. ":" .. table.concat(c, ",", 0, 7) end   -- 精灵按它判断要不要重画
	end
	local function SameBg(a, b)
		if a.m0 ~= b.m0 or a.m1 ~= b.m1 or a.m2 ~= b.m2 or a.m3 ~= b.m3 or a.mask ~= b.mask or a.spr ~= b.spr then
			return false
		end
		for i = 0, 7 do
			if a.c[i] ~= b.c[i] then return false end
		end
		return true
	end

	local function PalIndex(a)
		a = a % 32
		if a >= 16 and a % 4 == 0 then a = a - 16 end   -- $3F10/14/18/1C 是 $3F00/04/08/0C 的镜像
		return a
	end

	local function VramRead(a)
		a = a % 0x4000
		if a < 0x2000 then return CHR[ChrIndex(a)] end
		if a < 0x3F00 then return VRAM[NTI((a - 0x2000) % 4096)] end
		return PAL[PalIndex(a)]
	end

	-- CHR RAM：图块内容 → 贴图里的号
	local SLOT, dirty, index
	if rom.chrRam then
		index = rom.tileIndex
		if not index then                               -- 同一张卡带只建一次（重置、读档不用再建）
			index = {}
			local hex = rom.tiles or ""
			for s = 0, #hex / 32 - 1 do
				local key = hex:sub(s * 32 + 1, s * 32 + 32):gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
				index[key] = index[key] or s
			end
			rom.tileIndex = index
		end
		SLOT, dirty = {}, {}
		for t = 0, 511 do SLOT[t], dirty[t] = 0, true end
		p.SLOT, p.chrGen, p.chrDirty = SLOT, NesLab.genSeq, true
	end
	local blank = string.rep("\0", 16)
	-- 写过的图块按内容重新查号（Screen 画之前调；没画的帧不用查）
	function p.ResolveChr()
		if not p.chrDirty then return end
		p.chrDirty = false
		local changed = false
		for t in pairs(dirty) do
			local key = string.char(unpack(CHR, t * 16, t * 16 + 15))
			local s = index[key]
			if not s then
				s = 0                                      -- 没烘到的图块先空着（0 号是全空的图块）
				if key ~= blank and p.onUnknownTile then p.onUnknownTile(key) end
			end
			if SLOT[t] ~= s then
				SLOT[t] = s
				changed = true
			end
		end
		wipe(dirty)
		if changed then p.chrGen = p.chrGen + 1 end
	end
	function p.ChrAllDirty()                          -- 读档后整张重查
		if not dirty then return end
		for t = 0, 511 do dirty[t] = true end
		p.chrDirty = true
	end

	local function VramWrite(a, val)
		a = a % 0x4000
		if a < 0x2000 then                               -- CHR ROM 只读；CHR RAM 记下哪个图块变了
			if dirty then
				local i = ChrIndex(a)
				if CHR[i] ~= val then
					CHR[i] = val
					dirty[(i - i % 16) / 16] = true
					p.chrDirty = true
				end
			end
			return
		end
		if a < 0x3F00 then
			local i = NTI((a - 0x2000) % 4096)
			if VRAM[i] ~= val then
				VRAM[i] = val
				p.ntGen = p.ntGen + 1
			end
		else
			local i = PalIndex(a)
			if PAL[i] ~= val then
				PAL[i] = val
				if i % 4 ~= 0 then                       -- 各组的颜色 1-3（颜色 0 是通用背景色，Screen 单独画）
					local g = (i - i % 4) / 4
					p.pgen[g] = p.pgen[g] + 1
					if g < 4 then p.bgPalGen = p.bgPalGen + 1 end
				end
			end
		end
	end

	-- 画面中途改了卷屏：从下一条线开一条新横带
	local function Split(kind)
		local line = p.line
		if line < 0 or line >= 239 or p.nbands == 0 then return end
		local start = line + 1
		local bands, n = p.bands, p.nbands
		local prev = bands[n]
		local b = prev.line == start and prev or nil
		if not b then
			if n >= MAX_BANDS then return end
			n = n + 1
			p.nbands = n
			b = bands[n] or {}
			bands[n] = b
			b.line = start
			b.sy = prev.sy + (start - prev.line)    -- 只改横向时，纵向接着走
		end
		b.sx = ScrollX(p.t, p.x)
		SnapBg(b)                                       -- 换了图案页也开新带
		if kind == "v" then b.sy = ScrollY(p.v) end
		-- 写了寄存器但卷屏、图案页其实没变：并回上一条（少一道接缝）。b 总是最后一条
		local before = bands[p.nbands - 1]
		if before and b.sx == before.sx and SameBg(b, before) and b.sy == before.sy + (b.line - before.line) then
			p.nbands = p.nbands - 1
		end
	end

	p.Split = Split                                  -- mapper 画面中途换图案页时也调

	function p.Read(reg)
		if reg == 2 then
			local r = bor(band(p.status, 0xE0), band(p.buf, 0x1F))
			p.status = band(p.status, 0x7F)
			p.w = 0
			return r
		elseif reg == 4 then
			return OAM[p.oamAddr]
		elseif reg == 7 then
			local a = p.v % 0x4000
			local r
			if a >= 0x3F00 then
				r = PAL[PalIndex(a)]
				p.buf = VRAM[NTI((a - 0x2000) % 4096)]
			else
				r = p.buf
				p.buf = VramRead(a)
			end
			p.v = (p.v + (band(p.ctrl, 4) ~= 0 and 32 or 1)) % 0x8000
			return r
		end
		return 0
	end

	function p.Write(reg, val)
		if reg == 0 then
			local was = p.ctrl
			p.ctrl = val
			p.t = bor(band(p.t, 0xF3FF), lshift(band(val, 3), 10))
			if band(val, 0x80) ~= 0 and band(was, 0x80) == 0 and band(p.status, 0x80) ~= 0 then
				machine.nmiPending = true                  -- 垂直空白里才打开 NMI：马上触发
			end
			Split("x")
		elseif reg == 1 then
			local was = band(p.mask, 0x18)
			p.mask = val
			if band(val, 0x18) ~= was then Split("m") end   -- 只有开关背景 / 精灵才分带
		elseif reg == 3 then
			p.oamAddr = val
		elseif reg == 4 then
			OAM[p.oamAddr] = val
			p.oamAddr = (p.oamAddr + 1) % 256
		elseif reg == 5 then
			if p.w == 0 then
				p.x = band(val, 7)
				p.t = bor(band(p.t, 0xFFE0), rshift(val, 3))
				p.w = 1
				Split("x")                                 -- 横向卷动下一行就生效（每行只写一次 $2005 的赛车游戏靠它画弯道）
			else
				p.t = bor(band(p.t, 0x8C1F), lshift(band(val, 7), 12), lshift(rshift(val, 3), 5))
				p.w = 0
				Split("x")
			end
		elseif reg == 6 then
			if p.w == 0 then
				p.t = bor(band(p.t, 0x00FF), lshift(band(val, 0x3F), 8))
				p.w = 1
			else
				p.t = bor(band(p.t, 0xFF00), val)
				p.v = p.t
				p.w = 0
				Split("v")
			end
		elseif reg == 7 then
			VramWrite(p.v, val)
			p.v = (p.v + (band(p.ctrl, 4) ~= 0 and 32 or 1)) % 0x8000
		end
	end

	function p.OamDma(byte)
		OAM[p.oamAddr] = byte
		p.oamAddr = (p.oamAddr + 1) % 256
	end

	-- 精灵 0 第一条有不透明像素的扫描线（背景、精灵都开着才算）
	local function Sprite0Line()
		if band(p.mask, 0x18) ~= 0x18 then return nil end
		local y = OAM[0]
		if y >= 239 then return nil end
		local tall = band(p.ctrl, 0x20) ~= 0
		local tile, base = OAM[1], 0
		if tall then
			base = band(tile, 1) * 4096
			tile = band(tile, 0xFE)
		else
			base = band(p.ctrl, 8) ~= 0 and 4096 or 0
		end
		local flipV = band(OAM[2], 0x80) ~= 0
		local h = tall and 16 or 8
		for r = 0, h - 1 do
			local row = flipV and (h - 1 - r) or r
			local tt = tile + (row >= 8 and 1 or 0)
			local a = base + tt * 16 + row % 8
			if CHR[ChrIndex(a)] ~= 0 or CHR[ChrIndex(a + 8)] ~= 0 then return y + 1 + r end
		end
		return nil
	end

	-- 帧的三个时点（Machine 调）
	function p.VblankStart()
		p.status = bor(p.status, 0x80)
		return band(p.ctrl, 0x80) ~= 0
	end

	function p.PreRender()
		p.status = band(p.status, 0x1F)             -- 清垂直空白、精灵 0、溢出
		if band(p.mask, 0x18) ~= 0 then p.v = p.t end   -- 只有开着显示才从 t 拷（关着显示时程序在往 VRAM 写，不能打断）
	end

	function p.BeginVisible()
		local b = p.bands[1] or {}
		p.bands[1] = b
		b.line, b.sx, b.sy = 0, ScrollX(p.t, p.x), ScrollY(p.t)
		SnapBg(b)
		p.nbands = 1
		p.s0 = Sprite0Line()
	end

	return p
end
