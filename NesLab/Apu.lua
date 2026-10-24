-- APU（2A03 的声音部分）：不生成波形，只跟踪四个声道的状态，每帧换算成「音符」事件，像 MIDI 一样交给
-- 采样播放（Sound.lua）或导出。声道：1、2 方波（占空比 12.5 / 25 / 50 / 75%），3 三角波，4 噪声；DMC 不做。
-- 帧序列器按 4 步模式、每帧末尾一次补齐：4 次四分之一帧（包络、三角波线性计数）、2 次半帧（音长、扫频）。
-- 事件：{ 帧号, 声道, 音符号（MIDI；噪声 = 周期档 + 16 × 模式）, 音量档 1-4（0 = 关）, 占空比 }
local _, ns = ...
local band, rshift = bit.band, bit.rshift

local CPU_HZ = 1789773
local LENGTH = { [0] = 10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
	12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30 }

local function Note(freq)
	if freq <= 0 then return nil end
	return math.floor(69 + 12 * math.log(freq / 440) / math.log(2) + 0.5)
end

local function VolBucket(v)
	if v <= 0 then return 0 end
	return math.floor((v - 1) / 4) + 1             -- 1-4 → 1，5-8 → 2，9-12 → 3，13-15 → 4
end

local function NewPulse(id)
	return { id = id, duty = 0, halt = false, const = false, vol = 0, timer = 0, length = 0,
		envStart = false, envDiv = 0, decay = 0, swEn = false, swPeriod = 0, swNeg = false, swShift = 0,
		swReload = false, swDiv = 0, keyon = false }
end

function NesLab.NewApu()
	local a = { frame = 0, enabled = 0, events = nil }
	local p1, p2 = NewPulse(1), NewPulse(2)
	local tri = { halt = false, linReload = 0, linear = 0, linFlag = false, timer = 0, length = 0, keyon = false }
	local noise = { halt = false, const = false, vol = 0, period = 0, mode = 0, length = 0,
		envStart = false, envDiv = 0, decay = 0, keyon = false }
	-- DMC：放卡带里的一段 1 位增量采样（鼓点、人声）。这里不合成，只在开始 / 停止时发事件（a.onDmc），
	-- 由 Sound 播放事先从卡带里还原好的 ogg（tools/dmc2ogg.py）；left = 这段还剩多少 CPU 周期
	local dmc = { rate = 0, loop = false, addr = 0xC000, len = 1, level = 0, left = 0 }
	a.p1, a.p2, a.tri, a.noise, a.dmc = p1, p2, tri, noise, dmc
	local last = { {}, {}, {}, {} }

	local function Enabled(bitn) return band(a.enabled, bitn) ~= 0 end

	-- 即时存档：四个声道的寄存器状态（数字和真假，浅拷贝）；读回后忘掉「上次放的音」，好重新发事件
	local CH = { p1 = p1, p2 = p2, tri = tri, noise = noise, dmc = dmc }
	function a.SaveState()
		local t = { enabled = a.enabled }
		for k, ch in pairs(CH) do
			local c = {}
			for f, v in pairs(ch) do c[f] = v end
			t[k] = c
		end
		return t
	end
	function a.LoadState(t)
		a.enabled = t.enabled or 0
		for k, ch in pairs(CH) do
			for f, v in pairs(t[k] or {}) do ch[f] = v end
		end
		dmc.left = 0                                   -- 读档时声音全停了：DMC 当作放完，下次写 $4015 就重新起
		for ch = 1, 4 do last[ch] = {} end
	end

	local DMC_PERIOD = { [0] = 428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54 }
	local function DmcStart()
		dmc.left = dmc.len * 8 * DMC_PERIOD[dmc.rate]
		if a.onDmc then a.onDmc(dmc.addr, dmc.len, dmc.rate) end
	end
	-- $4015 读：各声道还在不在响（长度计数没到 0、DMC 没放完）
	function a.Status()
		return (p1.length > 0 and 1 or 0) + (p2.length > 0 and 2 or 0) + (tri.length > 0 and 4 or 0)
			+ (noise.length > 0 and 8 or 0) + (dmc.left > 0 and 16 or 0)
	end

	function a.Write(addr, v)
		if addr <= 0x4007 then
			local p = addr < 0x4004 and p1 or p2
			local r = addr % 4
			if r == 0 then
				p.duty = rshift(v, 6)
				p.halt = band(v, 0x20) ~= 0
				p.const = band(v, 0x10) ~= 0
				p.vol = band(v, 0x0F)
			elseif r == 1 then
				p.swEn = band(v, 0x80) ~= 0
				p.swPeriod = band(rshift(v, 4), 7)
				p.swNeg = band(v, 0x08) ~= 0
				p.swShift = band(v, 7)
				p.swReload = true
			elseif r == 2 then
				p.timer = band(p.timer, 0x700) + v
			else
				p.timer = band(p.timer, 0xFF) + band(v, 7) * 256
				if Enabled(p.id) then p.length = LENGTH[rshift(v, 3)] end
				p.envStart, p.keyon = true, true
			end
		elseif addr == 0x4008 then
			tri.halt = band(v, 0x80) ~= 0
			tri.linReload = band(v, 0x7F)
		elseif addr == 0x400A then
			tri.timer = band(tri.timer, 0x700) + v
		elseif addr == 0x400B then
			tri.timer = band(tri.timer, 0xFF) + band(v, 7) * 256
			if Enabled(4) then tri.length = LENGTH[rshift(v, 3)] end
			tri.linFlag, tri.keyon = true, true
		elseif addr == 0x400C then
			noise.halt = band(v, 0x20) ~= 0
			noise.const = band(v, 0x10) ~= 0
			noise.vol = band(v, 0x0F)
		elseif addr == 0x400E then
			noise.mode = rshift(v, 7)
			noise.period = band(v, 0x0F)
		elseif addr == 0x400F then
			if Enabled(8) then noise.length = LENGTH[rshift(v, 3)] end
			noise.envStart, noise.keyon = true, true
		elseif addr == 0x4010 then
			dmc.rate, dmc.loop = v % 16, band(v, 0x40) ~= 0
		elseif addr == 0x4011 then
			dmc.level = v % 128
		elseif addr == 0x4012 then
			dmc.addr = 0xC000 + v * 64
		elseif addr == 0x4013 then
			dmc.len = v * 16 + 1
		elseif addr == 0x4015 then
			a.enabled = v
			if not Enabled(1) then p1.length = 0 end
			if not Enabled(2) then p2.length = 0 end
			if not Enabled(4) then tri.length = 0 end
			if not Enabled(8) then noise.length = 0 end
			if Enabled(16) then
				if dmc.left <= 0 then DmcStart() end           -- 正在放的不重开（和真机一样）
			elseif dmc.left > 0 then
				dmc.left = 0
				if a.onDmc then a.onDmc(nil) end
			end
		end
	end

	local function Envelope(c)
		if c.envStart then
			c.envStart, c.decay, c.envDiv = false, 15, c.vol
		elseif c.envDiv == 0 then
			c.envDiv = c.vol
			if c.decay > 0 then c.decay = c.decay - 1 elseif c.halt then c.decay = 15 end
		else
			c.envDiv = c.envDiv - 1
		end
	end

	local function SweepTarget(p)
		local change = rshift(p.timer, p.swShift)
		if p.swNeg then return p.timer - change - (p.id == 1 and 1 or 0) end
		return p.timer + change
	end

	local function Sweep(p)
		local target = SweepTarget(p)
		if p.swDiv == 0 and p.swEn and p.swShift > 0 and p.timer >= 8 and target <= 0x7FF then p.timer = target end
		if p.swDiv == 0 or p.swReload then
			p.swDiv, p.swReload = p.swPeriod, false
		else
			p.swDiv = p.swDiv - 1
		end
	end

	local function Quarter()
		Envelope(p1) Envelope(p2) Envelope(noise)
		if tri.linFlag then
			tri.linear = tri.linReload
		elseif tri.linear > 0 then
			tri.linear = tri.linear - 1
		end
		if not tri.halt then tri.linFlag = false end
	end

	local CH4 = { p1, p2, tri, noise }
	local function Half()
		for _, c in ipairs(CH4) do
			if not c.halt and c.length > 0 then c.length = c.length - 1 end
		end
		Sweep(p1) Sweep(p2)
	end

	-- 这一帧各声道在发什么：音符号、音量档、占空比（不发声返回 nil）
	local function PulseState(p)
		if not Enabled(p.id) or p.length == 0 or p.timer < 8 or SweepTarget(p) > 0x7FF then return nil end
		local vb = VolBucket(p.const and p.vol or p.decay)
		if vb == 0 then return nil end
		return Note(CPU_HZ / (16 * (p.timer + 1))), vb, p.duty
	end

	local function TriState()
		if not Enabled(4) or tri.length == 0 or tri.linear == 0 or tri.timer < 2 then return nil end
		return Note(CPU_HZ / (32 * (tri.timer + 1))), 3, 0
	end

	local function NoiseState()
		if not Enabled(8) or noise.length == 0 then return nil end
		local vb = VolBucket(noise.const and noise.vol or noise.decay)
		if vb == 0 then return nil end
		return noise.period + 16 * noise.mode, vb, 0
	end

	-- 一个声道这一帧的状态和上一帧比，有变化就发事件
	local function Report(ch, keyon, note, vb, duty)
		local l = last[ch]
		if note then
			if keyon or note ~= l.note or vb ~= l.vb or duty ~= l.duty then
				l.note, l.vb, l.duty = note, vb, duty
				if a.onEvent then a.onEvent(ch, note, vb, duty) end
				if a.events then a.events[#a.events + 1] = { a.frame, ch, note, vb, duty } end
			end
		elseif l.note then
			l.note = nil
			if a.onEvent then a.onEvent(ch, nil) end
			if a.events then a.events[#a.events + 1] = { a.frame, ch, 0, 0, 0 } end
		end
	end

	-- 每帧末尾：补齐帧序列器，比较各声道，有变化就记事件（交给 a.onEvent，录音时也存进 a.events）
	function a.EndFrame()
		a.frame = a.frame + 1
		Quarter() Half() Quarter() Quarter() Half() Quarter()
		if dmc.left > 0 then                             -- DMC 按时长走完；循环的重新起一遍
			dmc.left = dmc.left - 29781
			if dmc.left <= 0 then
				if dmc.loop and Enabled(16) then DmcStart() else dmc.left = 0 end
			end
		end
		Report(1, p1.keyon, PulseState(p1))
		Report(2, p2.keyon, PulseState(p2))
		Report(3, tri.keyon, TriState())
		Report(4, noise.keyon, NoiseState())
		p1.keyon, p2.keyon, tri.keyon, noise.keyon = false, false, false, false
	end

	return a
end
