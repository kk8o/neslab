-- 一台 NES：地址分配（2 KB RAM 镜像、PPU 寄存器、OAM DMA、APU、手柄、卡带）和逐扫描线的帧时序。
-- 卡带：程序 4 个 8 KB 窗口（$8000 / $A000 / $C000 / $E000），图案 8 个 1 KB 窗口（ppu.chr1k），8 KB 存档内存
-- （$6000-$7FFF，带电池的游戏由 Player 存进 NesLabDB）。mapper：0 NROM、1 MMC1、2 UxROM、3 CNROM、4 MMC3、
-- 7 AxROM、34 BNROM、66 GxROM、140 Jaleco；图案可以写死在卡带里（CHR ROM），也可以是游戏运行时写的（CHR RAM，见 Ppu.lua）。MMC3 的扫描线计数：开着显示时每条可见线和预渲染线数一次，数到 0 拉起 IRQ。
-- 时序：先跑垂直空白（241 线置位、开了 NMI 就进中断）和预渲染线，再跑 0-239 可见线
-- （每线 341 / 3 个 CPU 周期，精灵 0 碰撞按线置位）；画面由 Screen 按这一帧的 PPU 状态画。窗口在 Player.lua。
local band, bor = bit.band, bit.bor

local CPL = 341 / 3
local A12_AT = 260 / 3                           -- 一行里 MMC3 数线的位置（CPU 周期）

NesLab.roms = NesLab.roms or {}
function NesLab.RegisterRom(rom)
	NesLab.roms[rom.id] = rom
end

-- 换页：返回 (写 $8000-$FFFF 时调的函数, 每条扫描线调的函数, 写 $6000-$7FFF 时调的函数——有它就不当存档内存,
-- 存 / 读内部寄存器的函数——即时存档用；只有 MMC1 / MMC3 有，别的一次写入就定下全部页，窗口状态由机器存)。
-- c 提供 SetPrg8(四个 8 KB 页号)、SetPrg16(两个 16 KB 页号)、SetChr1k(八个 1 KB 页号)、SetChr4k(两个 4 KB 页号)、
-- banks8 / banks16（程序有几页）、Irq(真假)
local function NewMapper(rom, ppu, c)
	local id = rom.mapper
	local banks16, banks8 = c.banks16, c.banks8
	if id == 2 then                                 -- UxROM：$8000 换 16 KB，$C000 固定最后一页
		c.SetPrg16(0, banks16 - 1)
		return function(_, v) c.SetPrg16(v % banks16, banks16 - 1) end
	elseif id == 3 then                             -- CNROM：换整 8 KB 图案
		return function(_, v)
			local b = (v % 4) * 2
			c.SetChr4k(b, b + 1)
		end
	elseif id == 7 then                             -- AxROM：换整 32 KB 程序，第 4 位选单屏图块表
		local function Write(_, v)
			c.SetPrg16((v % 8) * 2, (v % 8) * 2 + 1)
			ppu.SetMirror(band(v, 0x10) ~= 0 and "B" or "A")
		end
		Write(0, 0)
		return Write
	elseif id == 34 then                            -- BNROM：换整 32 KB 程序
		c.SetPrg16(0, 1)
		return function(_, v) c.SetPrg16((v % 64) * 2, (v % 64) * 2 + 1) end
	elseif id == 66 or id == 140 then               -- GxROM（$8000-$FFFF）/ Jaleco（$6000-$7FFF）：32 KB 程序 + 8 KB 图案
		local function Write(_, v)
			local p32 = math.floor(v / 16) % 4
			c.SetPrg16(p32 * 2, p32 * 2 + 1)
			local ch = (id == 66 and v % 4 or v % 16) * 2
			c.SetChr4k(ch, ch + 1)
		end
		Write(0, 0)
		if id == 66 then return Write end
		return nil, nil, Write
	elseif id == 1 then                             -- MMC1：5 次写入一位一位移进去，第 5 次按地址落到 4 个寄存器之一
		local shift, count = 0, 0
		local control, chr0, chr1, prg = 0x0C, 0, 0, 0
		local function Apply()
			local mir = control % 4
			ppu.SetMirror(mir == 0 and "A" or mir == 1 and "B" or mir == 2 and "V" or "H")
			local outer = banks16 > 16 and (math.floor(chr0 / 16) % 2) * 16 or 0   -- 512 KB 卡带：外层 256 KB
			local last = banks16 > 16 and outer + 15 or banks16 - 1
			local mode, b = math.floor(control / 4) % 4, outer + prg % 16
			if mode <= 1 then                          -- 整 32 KB 一起换
				local b2 = b - b % 2
				c.SetPrg16(b2, b2 + 1)
			elseif mode == 2 then                      -- $8000 固定第一页，换 $C000
				c.SetPrg16(outer, b)
			else                                       -- 换 $8000，$C000 固定最后一页
				c.SetPrg16(b, last)
			end
			if math.floor(control / 16) % 2 == 1 then
				c.SetChr4k(chr0, chr1)                 -- 两个 4 KB 分开换
			else
				local b8 = chr0 - chr0 % 2
				c.SetChr4k(b8, b8 + 1)                 -- 整 8 KB
			end
		end
		Apply()
		return function(a, v)
			if c.io.rmw then return end                -- 读改写的第二次写：MMC1 紧接着的写入不认
			if v >= 128 then
				shift, count, control = 0, 0, bor(control, 0x0C)
				return Apply()
			end
			shift = shift + (v % 2) * 2 ^ count
			count = count + 1
			if count < 5 then return end
			local reg = math.floor((a - 0x8000) / 0x2000)
			if reg == 0 then control = shift elseif reg == 1 then chr0 = shift elseif reg == 2 then chr1 = shift else prg = shift end
			shift, count = 0, 0
			Apply()
		end, nil, nil,
		function() return { shift, count, control, chr0, chr1, prg } end,
		function(t) shift, count, control, chr0, chr1, prg = t[1], t[2], t[3], t[4], t[5], t[6] end
	elseif id == 4 then                             -- MMC3
		local R = { [0] = 0, 2, 4, 5, 6, 7, 0, 1 }
		local sel, latch, counter, reload, enabled = 0, 0, 0, false, false
		local function Apply()
			local prgMode, chrInvert = band(sel, 0x40) ~= 0, band(sel, 0x80) ~= 0
			local r6, r7 = R[6] % banks8, R[7] % banks8
			if prgMode then
				c.SetPrg8(banks8 - 2, r7, r6, banks8 - 1)
			else
				c.SetPrg8(r6, r7, banks8 - 2, banks8 - 1)
			end
			-- R0 / R1 是 2 KB（低位忽略），R2-R5 是 1 KB；反转时两半对调
			local a0, a1 = R[0] - R[0] % 2, R[1] - R[1] % 2
			if chrInvert then
				c.SetChr1k(R[2], R[3], R[4], R[5], a0, a0 + 1, a1, a1 + 1)
			else
				c.SetChr1k(a0, a0 + 1, a1, a1 + 1, R[2], R[3], R[4], R[5])
			end
		end
		Apply()
		local function Write(a, v)
			local even = a % 2 == 0
			if a < 0xA000 then
				if even then sel = v else R[sel % 8] = v end
				Apply()
			elseif a < 0xC000 then
				if even then ppu.SetMirror(v % 2 == 0 and "V" or "H") end
			elseif a < 0xE000 then
				if even then latch = v else counter, reload = 0, true end
			else
				if even then
					enabled = false
					c.Irq(false)                          -- 关中断，也算应答
				else
					enabled = true
				end
			end
		end
		local function Scanline()
			if counter == 0 or reload then
				counter, reload = latch, false
			else
				counter = counter - 1
			end
			if counter == 0 and enabled then c.Irq(true) end
		end
		local function Save()
			local r = {}
			for i = 0, 7 do r[i + 1] = R[i] end
			return { r = r, sel = sel, latch = latch, counter = counter, reload = reload, enabled = enabled }
		end
		local function Load(t)
			for i = 0, 7 do R[i] = t.r[i + 1] end
			sel, latch, counter, reload, enabled = t.sel, t.latch, t.counter, t.reload, t.enabled
		end
		return Write, Scanline, nil, Save, Load
	end
	return nil                                     -- NROM：不换页
end

function NesLab.NewMachine(rom)
	local m = { rom = rom, nmiPending = false, irq = false }
	local PRG, prgSize = NesLab.Hex(rom.prg)
	local RAM, WRAM = {}, {}
	for i = 0, 2047 do RAM[i] = 0 end
	for i = 0, 8191 do WRAM[i] = 0 end
	m.wram = WRAM
	local ppu = NesLab.NewPpu(rom, m)
	m.ppu = ppu
	local apu = NesLab.NewApu()
	m.apu = apu
	local AWrite = apu.Write
	local pad = { buttons = 0, shift = 0, strobe = 0 }
	local pad2 = { buttons = 0, shift = 0 }          -- 2P：$4016 写入时一起锁存，从 $4017 读
	m.pad2 = pad2
	local io = { n = 0 }                              -- 写内存、读有副作用的端口就加 1（CPU 判断空转用）
	m.pad = pad
	local stall = 0
	local PRead, PWrite, Dma = ppu.Read, ppu.Write, ppu.OamDma

	-- 程序窗口：4 个 8 KB，p0-p3 是各窗口在 PRG 里的字节起点（16 KB 的卡带后半是前半的镜像）
	local banks8 = math.max(1, prgSize / 8192)
	local banks16 = math.max(1, prgSize / 16384)
	local p0, p1, p2, p3 = 0, 8192 % prgSize, 16384 % prgSize, 24576 % prgSize
	local chr1k, chrBanks1k = ppu.chr1k, rom.chrRam and 8 or math.max(1, #rom.chr / 2 / 1024)
	local c = { banks8 = banks8, banks16 = banks16, io = io }
	function c.SetPrg8(a, b, d, e)
		p0, p1, p2, p3 = (a % banks8) * 8192, (b % banks8) * 8192, (d % banks8) * 8192, (e % banks8) * 8192
	end
	function c.SetPrg16(a, b)
		c.SetPrg8((a % banks16) * 2, (a % banks16) * 2 + 1, (b % banks16) * 2, (b % banks16) * 2 + 1)
	end
	function c.SetChr1k(...)
		local changed = false
		for i = 0, 7 do
			local v = select(i + 1, ...) % chrBanks1k
			if chr1k[i] ~= v then
				chr1k[i] = v
				changed = true
			end
		end
		if changed then ppu.Split("c") end             -- 画面中途换页：从下一线开新横带
	end
	function c.SetChr4k(a, b)
		a, b = a * 4, b * 4
		c.SetChr1k(a, a + 1, a + 2, a + 3, b, b + 1, b + 2, b + 3)
	end
	function c.Irq(v) m.irq = v end
	local MapperWrite, Scanline, LowWrite, MapperSave, MapperLoad = NewMapper(rom, ppu, c)

	local rd
	rd = function(a)
		if a >= 0x8000 then
			if a < 0xA000 then return PRG[p0 + a - 0x8000] end
			if a < 0xC000 then return PRG[p1 + a - 0xA000] end
			if a < 0xE000 then return PRG[p2 + a - 0xC000] end
			return PRG[p3 + a - 0xE000] or rd(a % 0x10000)   -- 程序计数器跑过 $FFFF：真机回到 $0000（跑飞的游戏不至于报错）
		end
		if a < 0x2000 then return RAM[a % 2048] end
		if a >= 0x6000 then return WRAM[a - 0x6000] end
		if a < 0x4000 then
			local r = a % 8
			if r == 7 then io.n = io.n + 1 end       -- 读 $2007 会挪 VRAM 地址
			return PRead(r)
		end
		if a == 0x4016 then
			io.n = io.n + 1
			if pad.strobe == 1 then return 0x40 + pad.buttons % 2 end
			local b = pad.shift % 2
			pad.shift = (pad.shift - b) / 2 + 128
			return 0x40 + b
		end
		if a == 0x4015 then return apu.Status() end
		if a == 0x4017 then
			io.n = io.n + 1
			if pad.strobe == 1 then return 0x40 + pad2.buttons % 2 end
			local b = pad2.shift % 2
			pad2.shift = (pad2.shift - b) / 2 + 128
			return 0x40 + b
		end
		return 0
	end
	local function wr(a, v)
		io.n = io.n + 1
		if a < 0x2000 then
			RAM[a % 2048] = v
		elseif a < 0x4000 then
			PWrite(a % 8, v)
		elseif a == 0x4014 then
			for i = 0, 255 do Dma(rd(v * 256 + i)) end
			stall = stall + 513
		elseif a == 0x4016 then
			pad.strobe = v % 2
			pad.shift, pad2.shift = pad.buttons, pad2.buttons
		elseif a < 0x4018 then
			AWrite(a, v)
		elseif a >= 0x8000 then
			if MapperWrite then MapperWrite(a, v) end
		elseif a >= 0x6000 then
			if LowWrite then return LowWrite(a, v) end
			if WRAM[a - 0x6000] ~= v then
				WRAM[a - 0x6000] = v
				m.wramDirty, m.wramUsed = true, true
			end
		end
	end
	io.noIdle = NesLab.noIdle                       -- 关掉空转跳过（对比用）
	-- DMC 采样地址（$C000-$FFFF）→ 卡带程序里的字节号（按当前换页），Sound 拿它找还原好的采样
	function apu.PrgOffset(a)
		if a < 0xA000 then return p0 + a - 0x8000 end
		if a < 0xC000 then return p1 + a - 0xA000 end
		if a < 0xE000 then return p2 + a - 0xC000 end
		return p3 + a - 0xE000
	end
	local cpu = NesLab.NewCpu(rd, wr, io, not NesLab.slowCpu and RAM or nil)   -- NesLab.slowCpu：不走快路（对比用）
	m.cpu = cpu
	cpu.reset()

	-- 存档内存 ⇄ 十六进制文本（带电池的卡带由 Player 存进 NesLabDB）
	function m.SaveData()
		local t = {}
		for i = 0, 8191 do t[i + 1] = string.format("%02X", WRAM[i]) end
		return table.concat(t)
	end
	function m.LoadSave(hex)
		if type(hex) ~= "string" or #hex ~= 16384 then return end
		for i = 0, 8191 do WRAM[i] = tonumber(hex:sub(i * 2 + 1, i * 2 + 2), 16) or 0 end
	end

	local debt = 0
	local run, nmi, irq = cpu.run, cpu.nmi, cpu.irq

	-- 即时存档：整台机器在帧与帧之间的状态 → 一张表（内存类用十六进制文本，存进 SavedVariables 小一些）
	local function ToHex(t, n)
		local s = {}
		for i = 0, n - 1 do s[i + 1] = string.format("%02X", t[i]) end
		return table.concat(s)
	end
	local function FromHex(t, hex, n)
		for i = 0, n - 1 do t[i] = tonumber(hex:sub(i * 2 + 1, i * 2 + 2), 16) or 0 end
	end
	function m.SaveState()
		local chr = {}
		for i = 0, 7 do chr[i + 1] = chr1k[i] end
		return {
			v = 1, cpu = { cpu.state() }, prg = { p0, p1, p2, p3 }, chr = chr,
			ram = ToHex(RAM, 2048), wram = (rom.battery or m.wramUsed) and ToHex(WRAM, 8192) or nil,
			chrRam = rom.chrRam and ToHex(ppu.CHR, 8192) or nil,
			vram = ToHex(ppu.VRAM, ppu.fourScreen and 4096 or 2048), pal = ToHex(ppu.PAL, 32), oam = ToHex(ppu.OAM, 256),
			ppu = { ppu.ctrl, ppu.mask, ppu.status, ppu.oamAddr, ppu.v, ppu.t, ppu.x, ppu.w, ppu.buf, ppu.mirror },
			mapper = MapperSave and MapperSave() or nil, apu = apu.SaveState(),
			irq = m.irq, nmi = m.nmiPending, debt = debt, stall = stall,
		}
	end
	function m.LoadState(s)
		if type(s) ~= "table" or s.v ~= 1 then return false end
		cpu.setState(unpack(s.cpu))
		p0, p1, p2, p3 = s.prg[1], s.prg[2], s.prg[3], s.prg[4]
		for i = 0, 7 do chr1k[i] = s.chr[i + 1] end
		FromHex(RAM, s.ram, 2048)
		if s.wram then FromHex(WRAM, s.wram, 8192) else for i = 0, 8191 do WRAM[i] = 0 end end
		m.wramUsed = s.wram ~= nil                     -- 读回来的存档内存，下次存档也要带上
		FromHex(ppu.VRAM, s.vram, #s.vram / 2)
		if rom.chrRam and s.chrRam then
			FromHex(ppu.CHR, s.chrRam, 8192)
			ppu.ChrAllDirty()
		end
		FromHex(ppu.PAL, s.pal, 32)
		FromHex(ppu.OAM, s.oam, 256)
		local r = s.ppu
		ppu.ctrl, ppu.mask, ppu.status, ppu.oamAddr, ppu.v, ppu.t, ppu.x, ppu.w, ppu.buf = unpack(r, 1, 9)
		ppu.SetMirror(r[10])
		ppu.ntGen, ppu.bgPalGen = ppu.ntGen + 1, ppu.bgPalGen + 1   -- 画面全部重画
		for g = 0, 7 do ppu.pgen[g] = ppu.pgen[g] + 1 end
		if MapperLoad and s.mapper then MapperLoad(s.mapper) end
		if s.apu then apu.LoadState(s.apu) end
		m.irq, m.nmiPending, debt, stall = s.irq, s.nmi, s.debt, s.stall
		m.wramDirty = true
		return true
	end
	local function Line(counted)
		if counted and Scanline and band(ppu.mask, 0x18) ~= 0 then
			-- MMC3 在这一行第 260 个点（精灵取图、PPU 地址第 12 位升起）才数线：先跑到那里再数，
			-- 上一次打断的处理程序才来得及改好计数（有的游戏在打断里改下一次的行数）
			debt = debt + A12_AT
			if debt > 0 then debt = debt - run(debt) end
			Scanline()
			if m.irq then debt = debt - irq() end      -- 数到 0 拉起的打断马上进（真机也是这一行里就进）
			debt = debt + CPL - A12_AT
		else
			debt = debt + CPL
		end
		if debt > 0 then debt = debt - run(debt) end
		if stall > 0 then
			debt = debt - stall
			stall = 0
		end
		if m.nmiPending then
			m.nmiPending = false
			debt = debt - nmi()
		end
		if m.irq then debt = debt - irq() end        -- 电平触发：没应答就一直拉着（CPU 屏蔽时 irq 返回 0）
	end

	function m.Frame()
		ppu.line = 241
		if ppu.VblankStart() then
			-- 真机先把手上这条指令做完再进 NMI：主循环里「读 $2002 等垂直空白」的那条指令正好读到标志，
			-- NMI 处理程序再把它清掉。立刻进 NMI 的话标志先被清掉，这类游戏会永远等下去
			debt = debt - run(1)
			debt = debt - nmi()
		end
		for l = 241, 260 do
			ppu.line = l
			Line()
		end
		ppu.line = 261
		ppu.PreRender()
		Line(true)
		ppu.BeginVisible()
		local s0 = ppu.s0
		for l = 0, 239 do
			ppu.line = l
			if l == s0 then ppu.status = bor(ppu.status, 0x40) end
			Line(true)
		end
		ppu.line = 240
		Line()
		apu.EndFrame()
	end

	return m
end
