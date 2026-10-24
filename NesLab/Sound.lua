-- 声音：APU 每出一个音符事件，就停掉这个声道上一个声音、放对应的采样（tools/make_samples.py 生成的 sound/*.ogg）。
-- 像 MIDI 一样：音高按半音取整，音量 4 档；颤音、包络变化会变成重新起音。走「主音量」声道。
-- DMC（卡带里的采样）：放卡带文件夹 dmc\<程序字节号>_<字节数>_<速率>.ogg（tools/dmc2ogg.py 从卡带还原）；
-- 还没还原的先用噪声顶一下，并记进 NesLabDB.dmcWanted[卡带 id]，退出游戏后跑 dmc2ogg.py 就会生成。
local _, ns = ...

local DIR = "Interface\\AddOns\\NesLab\\sound\\"
local FADE = 15                                -- 停音淡出（毫秒）

local function Clamp(v, lo, hi)
	return v < lo and lo or v > hi and hi or v
end

function NesLab.NewSound()
	local s = { handles = {}, enabled = true, played = 0, failed = 0 }

	function s.Event(ch, note, vb, duty)
		local h = s.handles[ch]
		if h then
			StopSound(h, FADE)
			s.handles[ch] = nil
		end
		if not note or not s.enabled then return end
		local file
		if ch <= 2 then
			file = string.format("p%d_%d_%d", duty == 3 and 1 or duty, Clamp(note, 33, 108), vb)
		elseif ch == 3 then
			file = "t_" .. Clamp(note, 21, 96)
		else
			file = string.format("n%d%d_%d", math.floor(note / 16), note % 16, vb)
		end
		local ok, handle = PlaySoundFile(DIR .. file .. ".ogg", "Master")
		if ok then
			s.handles[ch] = handle
			s.played = s.played + 1
		else
			s.failed = s.failed + 1
		end
	end

	-- s.cartId、s.dmcDir、s.PrgOffset 由 Player 开游戏时设好
	function s.Dmc(addr, len, rate)
		local h = s.handles[5]
		if h then
			StopSound(h, FADE)
			s.handles[5] = nil
		end
		if not addr or not s.enabled or not s.dmcDir then return end
		local key = string.format("%x_%d_%d", s.PrgOffset(addr), len, rate)
		local ok, handle = PlaySoundFile(s.dmcDir .. key .. ".ogg", "Master")
		if not ok then
			NesLabDB.dmcWanted = NesLabDB.dmcWanted or {}
			local w = NesLabDB.dmcWanted[s.cartId] or {}
			NesLabDB.dmcWanted[s.cartId] = w
			w[key] = true
			ok, handle = PlaySoundFile(DIR .. "n0" .. Clamp(15 - rate, 0, 15) .. "_3.ogg", "Master")   -- 先用噪声顶着
		end
		if ok then s.handles[5] = handle end
	end

	function s.StopAll()
		for _, h in pairs(s.handles) do StopSound(h, FADE) end
		wipe(s.handles)
	end

	return s
end
