-- 6502 核心（NES 用的 2A03：没有十进制模式）。151 条官方指令 + 常用的非官方指令（多字节 NOP、LAX、SAX、
-- DCP、ISB、SLO、RLA、SRE、RRA、EB 版 SBC）；其余非官方指令当 2 周期 NOP。
-- 为了快：每条指令按「寻址方式 + 操作」拼成一段源码，加载时用 loadstring 一次编译成 256 个函数，
-- 寄存器都是同一个代码块里的局部变量（函数之间共享为上值）。Z / N 标志不单独存：zv 为 0 即 Z，nv ≥ 128 即 N。
-- 用法：local cpu = NesLab.NewCpu(rd, wr, io, RAM)；cpu.reset()；cpu.run(周期数) → 实际跑的周期数、指令数。
-- 给了 RAM（2 KB 内存表）就走快路：零页、栈、间接寻址的指针直接读写 RAM，不经过 rd / wr 的地址分发
-- （这些地址一定落在内存里；直写的次数记在 WN，空转判断把它和 io.n 一起看）。
-- 空转跳过：往回跳（分支、JMP）时，若跳到的地址、寄存器、标志和上次往回跳到这里时完全一样，
-- 且这期间 io.n 没变（机器每次写内存、读有副作用的端口都加 1），这段循环在这次 run 里只会原样一圈圈转下去。
-- 这条跳转指令就在返回的周期数上加 BIG 报信；run 收到后照常跑一圈量出一圈多少周期，再整圈跳过，
-- 只留最后不满两圈照常执行——停下的指令和周期与不跳完全一样。平常的指令循环不多做任何事。io 可省（自检时不跳）。

-- 寻址方式：算出地址 a（立即数直接给值 v）；带 * 的读操作跨页多 1 周期
local MODE = {
	zp = "local a = rd(PC) PC = PC + 1",
	zpx = "local a = (rd(PC) + X) % 256 PC = PC + 1",
	zpy = "local a = (rd(PC) + Y) % 256 PC = PC + 1",
	abs = "local a = rd(PC) + rd(PC + 1) * 256 PC = PC + 2",
	absx = "local b = rd(PC) + rd(PC + 1) * 256 PC = PC + 2 local a = (b + X) % 65536",
	absy = "local b = rd(PC) + rd(PC + 1) * 256 PC = PC + 2 local a = (b + Y) % 65536",
	indx = "local z = (rd(PC) + X) % 256 PC = PC + 1 local a = rd(z) + rd((z + 1) % 256) * 256",
	indy = "local z = rd(PC) PC = PC + 1 local b = rd(z) + rd((z + 1) % 256) * 256 local a = (b + Y) % 65536",
}
local PENALTY = {
	absx = "if b % 256 + X > 255 then cy = cy + 1 end",
	absy = "if b % 256 + Y > 255 then cy = cy + 1 end",
	indy = "if b % 256 + Y > 255 then cy = cy + 1 end",
}

local function NZ(r) return " zv = " .. r .. " nv = " .. r end
local ADC = "local s = A + v + C V = band(bxor(A, s), bxor(v, s), 128) ~= 0 and 1 or 0 C = s > 255 and 1 or 0 A = s % 256" .. NZ("A")

-- 读类操作（用值 v）
local READ = {
	LDA = "A = v" .. NZ("v"), LDX = "X = v" .. NZ("v"), LDY = "Y = v" .. NZ("v"),
	ADC = ADC, SBC = "v = 255 - v " .. ADC,
	AND = "A = band(A, v)" .. NZ("A"), ORA = "A = bor(A, v)" .. NZ("A"), EOR = "A = bxor(A, v)" .. NZ("A"),
	CMP = "local r = A - v C = r >= 0 and 1 or 0 r = r % 256" .. NZ("r"),
	CPX = "local r = X - v C = r >= 0 and 1 or 0 r = r % 256" .. NZ("r"),
	CPY = "local r = Y - v C = r >= 0 and 1 or 0 r = r % 256" .. NZ("r"),
	BIT = "zv = band(A, v) nv = v V = v % 128 >= 64 and 1 or 0",
	NOP = "", LAX = "A = v X = v" .. NZ("v"),       -- 非官方
	ANC = "A = band(A, v)" .. NZ("A") .. " C = A >= 128 and 1 or 0",
	ALR = "A = band(A, v) C = A % 2 A = (A - C) / 2" .. NZ("A"),
	ARR = "A = band(A, v) A = (A - A % 2) / 2 + C * 128" .. NZ("A") .. " C = A % 128 >= 64 and 1 or 0 V = bxor(C, A % 64 >= 32 and 1 or 0)",
	AXS = "local r = band(A, X) - v C = r >= 0 and 1 or 0 X = r % 256" .. NZ("X"),
	XAA = "A = band(X, v)" .. NZ("A"), LXA = "A = v X = v" .. NZ("v"),
	LAS = "local r = band(v, S) A = r X = r S = r" .. NZ("r"),
}
-- 写类、读改写类（用地址 a）
local WRITE = {
	STA = "wr(a, A)", STX = "wr(a, X)", STY = "wr(a, Y)",
	INC = "local o = rd(a) local v = (o + 1) % 256 wr2(a, o, v)" .. NZ("v"),
	DEC = "local o = rd(a) local v = (o + 255) % 256 wr2(a, o, v)" .. NZ("v"),
	ASL = "local o = rd(a) local v = o * 2 C = v > 255 and 1 or 0 v = v % 256 wr2(a, o, v)" .. NZ("v"),
	LSR = "local o = rd(a) C = o % 2 local v = (o - C) / 2 wr2(a, o, v)" .. NZ("v"),
	ROL = "local o = rd(a) local v = o * 2 + C C = v > 255 and 1 or 0 v = v % 256 wr2(a, o, v)" .. NZ("v"),
	ROR = "local o = rd(a) local c = o % 2 local v = (o - c) / 2 + C * 128 C = c wr2(a, o, v)" .. NZ("v"),
	-- 非官方：存 A & X；读改写之后再做一次运算
	SAX = "wr(a, band(A, X))",
	DCP = "local o = rd(a) local v = (o + 255) % 256 wr2(a, o, v) local r = A - v C = r >= 0 and 1 or 0 r = r % 256" .. NZ("r"),
	ISB = "local o = rd(a) local v = (o + 1) % 256 wr2(a, o, v) v = 255 - v " .. ADC,
	SLO = "local o = rd(a) local v = o * 2 C = v > 255 and 1 or 0 v = v % 256 wr2(a, o, v) A = bor(A, v)" .. NZ("A"),
	RLA = "local o = rd(a) local v = o * 2 + C C = v > 255 and 1 or 0 v = v % 256 wr2(a, o, v) A = band(A, v)" .. NZ("A"),
	SRE = "local o = rd(a) C = o % 2 local v = (o - C) / 2 wr2(a, o, v) A = bxor(A, v)" .. NZ("A"),
	RRA = "local o = rd(a) local c = o % 2 local v = (o - c) / 2 + C * 128 C = c wr2(a, o, v) " .. ADC,
}
-- 隐含 / 累加器 / 跳转等单独写
local IMPLIED = {
	ASL_A = "A = A * 2 C = A > 255 and 1 or 0 A = A % 256" .. NZ("A"),
	LSR_A = "C = A % 2 A = (A - C) / 2" .. NZ("A"),
	ROL_A = "A = A * 2 + C C = A > 255 and 1 or 0 A = A % 256" .. NZ("A"),
	ROR_A = "local c = A % 2 A = (A - c) / 2 + C * 128 C = c" .. NZ("A"),
	CLC = "C = 0", SEC = "C = 1", CLI = "I = 0", SEI = "I = 1", CLV = "V = 0", CLD = "D = 0", SED = "D = 1",
	TAX = "X = A" .. NZ("X"), TAY = "Y = A" .. NZ("Y"), TXA = "A = X" .. NZ("A"), TYA = "A = Y" .. NZ("A"),
	TSX = "X = S" .. NZ("X"), TXS = "S = X",
	INX = "X = (X + 1) % 256" .. NZ("X"), INY = "Y = (Y + 1) % 256" .. NZ("Y"),
	DEX = "X = (X + 255) % 256" .. NZ("X"), DEY = "Y = (Y + 255) % 256" .. NZ("Y"),
	PHA = "push(A)", PLA = "A = pull()" .. NZ("A"), PHP = "push(getP(16))", PLP = "setP(pull())",
	NOP = "",
	JMP = "local t = rd(PC) + rd(PC + 1) * 256 if t < PC and Idle(t) then PC = t return cy + BIG end PC = t",
	JMPI = "local p = rd(PC) + rd(PC + 1) * 256 PC = rd(p) + rd(p - p % 256 + (p + 1) % 256) * 256",
	JSR = "local t = rd(PC) + rd(PC + 1) * 256 local r = PC + 1 push((r - r % 256) / 256) push(r % 256) PC = t",
	RTS = "local lo = pull() PC = (pull() * 256 + lo + 1) % 65536",
	RTI = "setP(pull()) local lo = pull() PC = pull() * 256 + lo",
	BRK = "local r = PC + 1 push((r - r % 256) / 256) push(r % 256) push(getP(16)) I = 1 PC = rd(0xFFFE) + rd(0xFFFF) * 256",
}
local BRANCH = { BPL = "nv < 128", BMI = "nv >= 128", BVC = "V == 0", BVS = "V == 1",
	BCC = "C == 0", BCS = "C == 1", BNE = "zv ~= 0", BEQ = "zv == 0" }

-- 指令表：{ 操作码, 名字, 寻址方式, 周期, 跨页加 1 }
local LIST = {}
local function Add(op, name, mode, cy, pen) LIST[#LIST + 1] = { op, name, mode, cy, pen } end
local function Group(name, codes)                 -- 标准读类：imm zp zpx abs absx* absy* indx indy*
	local modes = { "imm", "zp", "zpx", "abs", "absx", "absy", "indx", "indy" }
	local cys = { 2, 3, 4, 4, 4, 4, 6, 5 }
	for i, c in ipairs(codes) do
		if c then Add(c, name, modes[i], cys[i], modes[i] == "absx" or modes[i] == "absy" or modes[i] == "indy") end
	end
end
Group("ADC", { 0x69, 0x65, 0x75, 0x6D, 0x7D, 0x79, 0x61, 0x71 })
Group("AND", { 0x29, 0x25, 0x35, 0x2D, 0x3D, 0x39, 0x21, 0x31 })
Group("CMP", { 0xC9, 0xC5, 0xD5, 0xCD, 0xDD, 0xD9, 0xC1, 0xD1 })
Group("EOR", { 0x49, 0x45, 0x55, 0x4D, 0x5D, 0x59, 0x41, 0x51 })
Group("LDA", { 0xA9, 0xA5, 0xB5, 0xAD, 0xBD, 0xB9, 0xA1, 0xB1 })
Group("ORA", { 0x09, 0x05, 0x15, 0x0D, 0x1D, 0x19, 0x01, 0x11 })
Group("SBC", { 0xE9, 0xE5, 0xF5, 0xED, 0xFD, 0xF9, 0xE1, 0xF1 })
Add(0xA2, "LDX", "imm", 2) Add(0xA6, "LDX", "zp", 3) Add(0xB6, "LDX", "zpy", 4) Add(0xAE, "LDX", "abs", 4) Add(0xBE, "LDX", "absy", 4, true)
Add(0xA0, "LDY", "imm", 2) Add(0xA4, "LDY", "zp", 3) Add(0xB4, "LDY", "zpx", 4) Add(0xAC, "LDY", "abs", 4) Add(0xBC, "LDY", "absx", 4, true)
Add(0xE0, "CPX", "imm", 2) Add(0xE4, "CPX", "zp", 3) Add(0xEC, "CPX", "abs", 4)
Add(0xC0, "CPY", "imm", 2) Add(0xC4, "CPY", "zp", 3) Add(0xCC, "CPY", "abs", 4)
Add(0x24, "BIT", "zp", 3) Add(0x2C, "BIT", "abs", 4)
Add(0x85, "STA", "zp", 3) Add(0x95, "STA", "zpx", 4) Add(0x8D, "STA", "abs", 4) Add(0x9D, "STA", "absx", 5)
Add(0x99, "STA", "absy", 5) Add(0x81, "STA", "indx", 6) Add(0x91, "STA", "indy", 6)
Add(0x86, "STX", "zp", 3) Add(0x96, "STX", "zpy", 4) Add(0x8E, "STX", "abs", 4)
Add(0x84, "STY", "zp", 3) Add(0x94, "STY", "zpx", 4) Add(0x8C, "STY", "abs", 4)
for name, codes in pairs({ INC = { 0xE6, 0xF6, 0xEE, 0xFE }, DEC = { 0xC6, 0xD6, 0xCE, 0xDE },
	ASL = { 0x06, 0x16, 0x0E, 0x1E }, LSR = { 0x46, 0x56, 0x4E, 0x5E },
	ROL = { 0x26, 0x36, 0x2E, 0x3E }, ROR = { 0x66, 0x76, 0x6E, 0x7E } }) do
	Add(codes[1], name, "zp", 5) Add(codes[2], name, "zpx", 6) Add(codes[3], name, "abs", 6) Add(codes[4], name, "absx", 7)
end
for name, c in pairs({ ASL_A = 0x0A, LSR_A = 0x4A, ROL_A = 0x2A, ROR_A = 0x6A, CLC = 0x18, SEC = 0x38, CLI = 0x58,
	SEI = 0x78, CLV = 0xB8, CLD = 0xD8, SED = 0xF8, TAX = 0xAA, TAY = 0xA8, TXA = 0x8A, TYA = 0x98, TSX = 0xBA,
	TXS = 0x9A, INX = 0xE8, INY = 0xC8, DEX = 0xCA, DEY = 0x88, NOP = 0xEA }) do
	Add(c, name, "impl", 2)
end
Add(0x48, "PHA", "impl", 3) Add(0x08, "PHP", "impl", 3) Add(0x68, "PLA", "impl", 4) Add(0x28, "PLP", "impl", 4)
Add(0x4C, "JMP", "impl", 3) Add(0x6C, "JMPI", "impl", 5) Add(0x20, "JSR", "impl", 6)
Add(0x60, "RTS", "impl", 6) Add(0x40, "RTI", "impl", 6) Add(0x00, "BRK", "impl", 7)
for name, c in pairs({ BPL = 0x10, BMI = 0x30, BVC = 0x50, BVS = 0x70, BCC = 0x90, BCS = 0xB0, BNE = 0xD0, BEQ = 0xF0 }) do
	Add(c, name, "rel", 2)
end
NesLab = NesLab or {}

-- 非官方指令（有些游戏用到；nestest 后半段专门测）
for _, c in ipairs({ 0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA }) do Add(c, "NOP", "impl", 2) end
for _, c in ipairs({ 0x80, 0x82, 0x89, 0xC2, 0xE2 }) do Add(c, "NOP", "imm", 2) end
for _, c in ipairs({ 0x04, 0x44, 0x64 }) do Add(c, "NOP", "zp", 3) end
for _, c in ipairs({ 0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4 }) do Add(c, "NOP", "zpx", 4) end
Add(0x0C, "NOP", "abs", 4)
for _, c in ipairs({ 0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC }) do Add(c, "NOP", "absx", 4, true) end
Add(0xA7, "LAX", "zp", 3) Add(0xB7, "LAX", "zpy", 4) Add(0xAF, "LAX", "abs", 4) Add(0xBF, "LAX", "absy", 4, true)
Add(0xA3, "LAX", "indx", 6) Add(0xB3, "LAX", "indy", 5, true)
Add(0x87, "SAX", "zp", 3) Add(0x97, "SAX", "zpy", 4) Add(0x8F, "SAX", "abs", 4) Add(0x83, "SAX", "indx", 6)
Add(0xEB, "SBC", "imm", 2)
-- 其余非官方：立即数运算按定义做；SHA / SHX / SHY / TAS 很少用，只保证长度对（不写），LAS 照做
for name, c in pairs({ ANC = 0x0B, ALR = 0x4B, ARR = 0x6B, AXS = 0xCB, XAA = 0x8B, LXA = 0xAB }) do Add(c, name, "imm", 2) end
Add(0x2B, "ANC", "imm", 2)
Add(0x93, "NOP", "indy", 6) Add(0x9B, "NOP", "absy", 5) Add(0x9F, "NOP", "absy", 5)
Add(0x9C, "NOP", "absx", 5) Add(0x9E, "NOP", "absy", 5) Add(0xBB, "LAS", "absy", 4, true)
for name, codes in pairs({ DCP = { 0xC7, 0xD7, 0xCF, 0xDF, 0xDB, 0xC3, 0xD3 }, ISB = { 0xE7, 0xF7, 0xEF, 0xFF, 0xFB, 0xE3, 0xF3 },
	SLO = { 0x07, 0x17, 0x0F, 0x1F, 0x1B, 0x03, 0x13 }, RLA = { 0x27, 0x37, 0x2F, 0x3F, 0x3B, 0x23, 0x33 },
	SRE = { 0x47, 0x57, 0x4F, 0x5F, 0x5B, 0x43, 0x53 }, RRA = { 0x67, 0x77, 0x6F, 0x7F, 0x7B, 0x63, 0x73 } }) do
	local modes, cys = { "zp", "zpx", "abs", "absx", "absy", "indx", "indy" }, { 5, 6, 6, 7, 7, 8, 8 }
	for i, c in ipairs(codes) do Add(c, name, modes[i], cys[i]) end
end

local ZP = { zp = true, zpx = true, zpy = true }
local FAST_MODE = {                              -- 快路：间接寻址的两字节指针在零页，直接读 RAM
	indx = "local z = (rd(PC) + X) % 256 PC = PC + 1 local a = RAM[z] + RAM[(z + 1) % 256] * 256",
	indy = "local z = rd(PC) PC = PC + 1 local b = RAM[z] + RAM[(z + 1) % 256] * 256 local a = (b + Y) % 65536",
}

local function Body(e, fast)
	local name, mode, cy, pen = e[2], e[3], e[4], e[5]
	if fast and ZP[mode] then                    -- 快路：零页的读写直接走 RAM
		local body = Body(e, false)
		body = body:gsub("wr2%(a, o, v%)", "zw(a, v)"):gsub("rd%(a%)", "RAM[a]"):gsub("wr%(a, ", "zw(a, ")
		return body
	end
	if fast and FAST_MODE[mode] then
		return (Body(e, false):gsub(MODE[mode]:gsub("%p", "%%%0"), (FAST_MODE[mode]:gsub("%%", "%%%%"))))
	end
	local parts = { "local cy = " .. cy }
	if mode == "rel" then
		parts[#parts + 1] = "local o = rd(PC) PC = PC + 1 if " .. BRANCH[name] .. " then local t = (PC + (o < 128 and o or o - 256)) % 65536"
			.. " cy = cy + 1 if t - t % 256 ~= PC - PC % 256 then cy = cy + 1 end"
			.. " if t < PC and Idle(t) then PC = t return cy + BIG end PC = t end"
	elseif mode == "impl" then
		parts[#parts + 1] = IMPLIED[name]
	elseif mode == "imm" then
		parts[#parts + 1] = "local v = rd(PC) PC = PC + 1 " .. READ[name]
	else
		parts[#parts + 1] = MODE[mode]
		if READ[name] then
			if pen then parts[#parts + 1] = PENALTY[mode] end
			parts[#parts + 1] = "local v = rd(a) " .. READ[name]
		else
			parts[#parts + 1] = WRITE[name]
		end
	end
	parts[#parts + 1] = "return cy"
	return table.concat(parts, " ")
end

local function Source(fast)
	local src = { [[
local rd, wr, io, RAM = ...
local WN = 0                                     -- 快路直写内存的次数（空转判断用）
local function zw(a, v) RAM[a] = v WN = WN + 1 end
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local A, X, Y, S, PC, C, V, I, D, zv, nv = 0, 0, 0, 0xFD, 0, 0, 0, 1, 0, 1, 0
local BIG = 1048576                             -- 空转报信：跳转指令返回的周期数加上它
local LT, LIO, LA, LX, LY, LS, LC, LV, LZ, LN, HIT = -1
local function Idle(t)                          -- 往回跳到 t：是不是原样空转（同一目标、没写内存、寄存器标志全同）
	if not io or io.noIdle then return false end
	local n = io.n + WN
	if t ~= LT or n ~= LIO then                  -- 绝大多数往回跳走这里：记下就走
		LT, LIO, LA = t, n, nil
		return false
	end
	if A == LA and X == LX and Y == LY and S == LS and C == LC and V == LV and zv == LZ and nv == LN then
		HIT = t
		return true
	end
	LA, LX, LY, LS, LC, LV, LZ, LN = A, X, Y, S, C, V, zv, nv
	return false
end
local OPS = {}
local function push(v) wr(0x100 + S, v) S = (S + 255) % 256 end
local function wr2(a, o, v)                     -- 读改写的两次写：卡带区先写原值，第二次标 io.rmw（MMC1 不认）
	if a >= 0x8000 and io then
		wr(a, o)
		io.rmw = true
		wr(a, v)
		io.rmw = false
	else
		wr(a, v)
	end
end
local function pull() S = (S + 1) % 256 return rd(0x100 + S) end
local function getP(b) return (nv >= 128 and 128 or 0) + V * 64 + 32 + b + D * 8 + I * 4 + (zv == 0 and 2 or 0) + C end
local function setP(p)
	C = p % 2 zv = p % 4 >= 2 and 0 or 1 I = p % 8 >= 4 and 1 or 0 D = p % 16 >= 8 and 1 or 0
	V = p % 128 >= 64 and 1 or 0 nv = p >= 128 and 128 or 0
end
for i = 0, 255 do OPS[i] = function() return 2 end end
]] }
	if fast then                                 -- 快路：栈在 $0100-$01FF，直接读写 RAM
		src[#src + 1] = "push = function(v) RAM[0x100 + S] = v WN = WN + 1 S = (S + 255) % 256 end"
			.. " pull = function() S = (S + 1) % 256 return RAM[0x100 + S] end"
	end
	for _, e in ipairs(LIST) do
		src[#src + 1] = string.format("OPS[%d] = function() %s end", e[1], Body(e, fast))
	end
	src[#src + 1] = [[
local cpu = {}
function cpu.run(budget)
	local done, n = 0, 0
	while true do
		while done < budget do
			local op = rd(PC)
			PC = PC + 1
			done = done + OPS[op]()
			n = n + 1
		end
		if done < BIG then break end
		done = done - BIG                       -- 空转：照常跑一圈，量出一圈多少周期
		local start, lap, t0 = done, nil, HIT
		while done < budget do
			local op = rd(PC)
			PC = PC + 1
			local c = OPS[op]()
			n = n + 1
			if c >= BIG then
				done = done + c - BIG
				if HIT == t0 then lap = done - start end   -- 同一个循环又报了一次才算量准
				break
			end
			done = done + c
		end
		if lap and lap > 0 then                  -- 整圈跳过，留不满两圈照常跑完
			local k = math.floor((budget - done) / lap) - 1
			if k > 0 then done = done + k * lap end
		end
	end
	return done, n
end
function cpu.reset() PC = rd(0xFFFC) + rd(0xFFFD) * 256 S = 0xFD I = 1 end
function cpu.nmi()
	push((PC - PC % 256) / 256) push(PC % 256) push(getP(0)) I = 1
	PC = rd(0xFFFA) + rd(0xFFFB) * 256
	return 7
end
function cpu.irq()                          -- 可屏蔽中断（MMC3 扫描线计数）：I 标志置着就不进，返回 0
	if I == 1 then return 0 end
	push((PC - PC % 256) / 256) push(PC % 256) push(getP(0)) I = 1
	PC = rd(0xFFFE) + rd(0xFFFF) * 256
	return 7
end
function cpu.setPC(p) PC = p end
function cpu.setP(p) setP(p) end
function cpu.state() return A, X, Y, getP(0), S, PC end
function cpu.setState(a, x, y, p, s, pc) A, X, Y, S, PC = a, x, y, s, pc setP(p) end   -- 读即时存档
return cpu
]]
	return table.concat(src, "\n")
end

NesLab.opcodeCount = #LIST
local compiled = {}                              -- 源码只拼一次（快路 / 普通各一份）
function NesLab.NewCpu(rd, wr, io, RAM)
	local fast = RAM ~= nil
	local src = compiled[fast] or Source(fast)
	compiled[fast] = src
	local chunk, err = loadstring(src, "=NesCpu")
	if not chunk then error(err) end
	return chunk(rd, wr, io, RAM)
end
