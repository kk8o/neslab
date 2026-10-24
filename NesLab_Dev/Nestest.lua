-- nestest 自检：从 $C000 开始（自动模式，不需要画面），每条指令执行前把寄存器和累计周期
-- 跟标准执行记录逐行比，返回第一处不一致。NesLab.Nestest(行数上限)
local _, ns = ...

local function Hex(s, i, n) return tonumber(s:sub(i, i + n - 1), 16) end

function NesLab.Nestest(limit)
	local prgHex, log = NesLab.NESTEST_PRG, NesLab.NESTEST_LOG
	local PRG = {}
	for i = 0, #prgHex / 2 - 1 do PRG[i] = Hex(prgHex, i * 2 + 1, 2) end
	local size = #prgHex / 2                       -- 16 KB：$8000 和 $C000 是同一块
	local RAM = {}
	for i = 0, 2047 do RAM[i] = 0 end
	local function rd(a)
		if a < 0x2000 then return RAM[a % 2048] end
		if a >= 0x8000 then return PRG[(a - 0x8000) % size] end
		if a >= 0x4000 and a < 0x4020 then return 0xFF end   -- APU / 手柄：记录里读出来是 FF
		return 0
	end
	local function wr(a, v)
		if a < 0x2000 then RAM[a % 2048] = v end
	end
	local cpu = NesLab.NewCpu(rd, wr, nil, RAM)        -- 带上内存表：零页 / 栈走 CPU 快路，正好一起测
	cpu.setPC(0xC000)
	cpu.setP(0x24)
	local total = 7
	local lines = #log / 21
	limit = math.min(limit or lines, lines)
	local t0 = debugprofilestop()
	for n = 1, limit do
		local o = (n - 1) * 21 + 1
		local ePC, eA, eX, eY, eP, eS = Hex(log, o, 4), Hex(log, o + 4, 2), Hex(log, o + 6, 2), Hex(log, o + 8, 2),
			Hex(log, o + 10, 2), Hex(log, o + 12, 2)
		local eCyc = Hex(log, o + 14, 6)
		local A, X, Y, P, S, PC = cpu.state()
		if PC ~= ePC or A ~= eA or X ~= eX or Y ~= eY or P ~= eP or S ~= eS or total ~= eCyc then
			local prev = n > 1 and log:sub(o - 21, o - 1) or ""
			return {
				ok = false, line = n, unofficial = log:sub(o + 20, o + 20) == "*",
				want = string.format("PC=%04X A=%02X X=%02X Y=%02X P=%02X S=%02X CYC=%d", ePC, eA, eX, eY, eP, eS, eCyc),
				got = string.format("PC=%04X A=%02X X=%02X Y=%02X P=%02X S=%02X CYC=%d", PC, A, X, Y, P, S, total),
				prevLine = prev, op = string.format("%02X", rd(PC)),
			}
		end
		total = total + cpu.run(1)
	end
	-- 测试 ROM 把结果写在 $02（官方指令）和 $03（非官方指令），0 = 全部通过
	return { ok = true, lines = limit, ms = debugprofilestop() - t0,
		result02 = string.format("%02X", RAM[2]), result03 = string.format("%02X", RAM[3]) }
end
