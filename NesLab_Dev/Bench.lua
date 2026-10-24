-- 测速：
--   NesLab.BenchCpu(frames, mapped)：跑一段游戏式的 6502 代码，每帧 29780 周期（NTSC），量每帧耗时、每秒指令数。
--     mapped = true 时读写走 NES 的地址分配（RAM 镜像、PPU 寄存器、卡带 ROM），否则是平坦的 64 KB。
--   NesLab.ShowTiles() / BenchTiles(n)：32 × 30 个 8 像素图块、每块三层（NES 一个图块 4 色 = 底色 + 三种颜色），
--     一次改 n 个图块（贴图坐标 + 颜色），量耗时。
--   NesLab.Live(seconds, tilesPerFrame)：每个游戏帧跑一个 NES 帧的 CPU + 改若干图块，看游戏帧率。
local _, ns = ...

local CYCLES_PER_FRAME = 29780

-- 测试程序（$8000）：变址读写、累加、异或、子程序里用 ($20),Y 间接读，和游戏主循环里的活差不多
local PROGRAM = {
	0xA2, 0x00,             -- 8000 LDX #0
	0xBD, 0x00, 0x02,       -- 8002 LDA $0200,X
	0x18,                   -- 8005 CLC
	0x69, 0x03,             -- 8006 ADC #3
	0x9D, 0x00, 0x03,       -- 8008 STA $0300,X
	0xA5, 0x10,             -- 800B LDA $10
	0x49, 0x5A,             -- 800D EOR #$5A
	0x85, 0x10,             -- 800F STA $10
	0x20, 0x1D, 0x80,       -- 8011 JSR $801D
	0xE8,                   -- 8014 INX
	0xD0, 0xEB,             -- 8015 BNE $8002
	0xE6, 0x11,             -- 8017 INC $11
	0x4C, 0x00, 0x80,       -- 8019 JMP $8000
	0xEA,                   -- 801C NOP
	0xA4, 0x10,             -- 801D LDY $10
	0x88,                   -- 801F DEY
	0x84, 0x12,             -- 8020 STY $12
	0xB1, 0x20,             -- 8022 LDA ($20),Y
	0x29, 0x0F,             -- 8024 AND #$0F
	0x60,                   -- 8026 RTS
}

local function FlatMemory()
	local M = {}
	for i = 0, 65535 do M[i] = 0 end
	for i, b in ipairs(PROGRAM) do M[0x8000 + i - 1] = b end
	M[0xFFFC], M[0xFFFD] = 0x00, 0x80
	M[0x20], M[0x21] = 0x00, 0x04
	return function(a) return M[a] end, function(a, v) M[a] = v end
end

-- NES 的地址分配：$0000-$1FFF 2 KB RAM 镜像，$2000-$3FFF PPU 寄存器（每 8 个镜像），$4000-$401F APU / 手柄，
-- $8000-$FFFF 卡带 32 KB
local function MappedMemory()
	local RAM, PRG, ppuReads, ppuWrites = {}, {}, 0, 0
	for i = 0, 2047 do RAM[i] = 0 end
	for i = 0, 32767 do PRG[i] = 0 end
	for i, b in ipairs(PROGRAM) do PRG[i - 1] = b end
	PRG[0x7FFC], PRG[0x7FFD] = 0x00, 0x80
	RAM[0x20], RAM[0x21] = 0x00, 0x04
	local function rd(a)
		if a >= 0x8000 then return PRG[a - 0x8000] end
		if a < 0x2000 then return RAM[a % 2048] end
		ppuReads = ppuReads + 1
		return 0
	end
	local function wr(a, v)
		if a < 0x2000 then
			RAM[a % 2048] = v
		elseif a < 0x4020 then
			ppuWrites = ppuWrites + 1
		end
	end
	return rd, wr
end

function NesLab.BenchCpu(frames, mapped)
	frames = frames or 30
	local rd, wr = (mapped and MappedMemory or FlatMemory)()
	local t0 = debugprofilestop()
	local cpu = NesLab.NewCpu(rd, wr)
	local build = debugprofilestop() - t0
	cpu.reset()
	cpu.run(CYCLES_PER_FRAME)               -- 预热
	local worst, total, instr = 0, 0, 0
	for _ = 1, frames do
		local t = debugprofilestop()
		local _, n = cpu.run(CYCLES_PER_FRAME)
		local dt = debugprofilestop() - t
		total, instr = total + dt, instr + n
		if dt > worst then worst = dt end
	end
	local A, X, Y, P, S, PC = cpu.state()
	return {
		ops = NesLab.opcodeCount, build = build,
		msPerFrame = total / frames, worst = worst,
		instrPerFrame = instr / frames, mips = instr / (total / 1000) / 1e6,
		fps = 1000 / (total / frames),
		state = string.format("A=%02X X=%02X Y=%02X P=%02X S=%02X PC=%04X", A, X, Y, P, S, PC),
	}
end

------------------------------------------------------------------------------------------------------------------------
-- 图块画面

local COLS, ROWS, LAYERS, TILE = 32, 30, 3, 2 * 8
local ATLAS = "Interface\\Icons\\INV_Misc_Token_Darkmoon_01"   -- 测速用的替身图（真做时换成从卡带烘出来的图块图）

function NesLab.ShowTiles()
	if NesLab.screen then
		NesLab.screen:Show()
		return NesLab.screen
	end
	local f = CreateFrame("Frame", "NesLabScreen", UIParent)
	f:SetSize(COLS * TILE, ROWS * TILE)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetClipsChildren(true)
	local bg = f:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	local layer = CreateFrame("Frame", nil, f)        -- 卷屏时整体挪这一层
	layer:SetSize(COLS * TILE, ROWS * TILE)
	layer:SetPoint("TOPLEFT")
	f.layer = layer
	f.tex = {}
	for y = 0, ROWS - 1 do
		for x = 0, COLS - 1 do
			for l = 1, LAYERS do
				local t = layer:CreateTexture(nil, "ARTWORK", nil, l)
				t:SetTexture(ATLAS)
				t:SetSize(TILE, TILE)
				t:SetPoint("TOPLEFT", x * TILE, -y * TILE)
				f.tex[#f.tex + 1] = t
			end
		end
	end
	NesLab.screen = f
	return f
end

local random = math.random

-- 改 n 个图块（每块三层：贴图坐标 + 颜色）
local function Paint(f, n)
	local tex, count = f.tex, #f.tex / LAYERS
	for _ = 1, n do
		local k = random(count) - 1
		local u, v = random(0, 15) / 16, random(0, 15) / 16
		for l = 1, LAYERS do
			local t = tex[k * LAYERS + l]
			t:SetTexCoord(u, u + 1 / 16, v, v + 1 / 16)
			t:SetVertexColor(random(), random(), random(), l == 1 and 1 or 0.6)
		end
	end
end

function NesLab.BenchTiles(n, rounds)
	local f = NesLab.ShowTiles()
	rounds = rounds or 10
	local total, worst = 0, 0
	for _ = 1, rounds do
		local t = debugprofilestop()
		Paint(f, n)
		local dt = debugprofilestop() - t
		total = total + dt
		if dt > worst then worst = dt end
	end
	return { textures = #f.tex, tiles = n, ms = total / rounds, worst = worst }
end

-- 实跑：每个游戏帧跑一个 NES 帧的 CPU、改若干图块、卷屏 1 像素；记游戏帧率
function NesLab.Live(seconds, tilesPerFrame, mapped)
	local f = NesLab.ShowTiles()
	local rd, wr = (mapped ~= false and MappedMemory or FlatMemory)()
	local cpu = NesLab.NewCpu(rd, wr)
	cpu.reset()
	local driver = NesLab.driver or CreateFrame("Frame")
	NesLab.driver = driver
	local stats = { frames = 0, cpuMs = 0, gfxMs = 0, fps = {}, startFps = GetFramerate() }
	NesLab.live = stats
	local start, scroll = GetTime(), 0
	driver:SetScript("OnUpdate", function()
		local t = debugprofilestop()
		cpu.run(CYCLES_PER_FRAME)
		local t2 = debugprofilestop()
		Paint(f, tilesPerFrame or 60)
		scroll = (scroll + 1) % TILE
		f.layer:SetPoint("TOPLEFT", -scroll, 0)
		local t3 = debugprofilestop()
		stats.frames = stats.frames + 1
		stats.cpuMs = stats.cpuMs + (t2 - t)
		stats.gfxMs = stats.gfxMs + (t3 - t2)
		if stats.frames % 30 == 0 then stats.fps[#stats.fps + 1] = math.floor(GetFramerate()) end
		if GetTime() - start > (seconds or 5) then
			driver:SetScript("OnUpdate", nil)
			stats.done = true
			stats.cpuMs, stats.gfxMs = stats.cpuMs / stats.frames, stats.gfxMs / stats.frames
			stats.gameFps = stats.frames / (GetTime() - start)
		end
	end)
	return stats
end

function NesLab.Hide()
	if NesLab.screen then NesLab.screen:Hide() end
	if NesLab.driver then NesLab.driver:SetScript("OnUpdate", nil) end
end
