-- HD2-Addon: mods/hexua/epoch_timebomb_standalone
-- Epoch Timebomb, STANDALONE v3.0 (Bingus Shared Loader only; NO HD2Runtime).
--
-- Gameplay (what the player asked for):
--   * While the local player carries the PLAS-45 Epoch (its support slot), a 7 s fuse runs with one
--     beep per second (pitch rises as the fuse runs out). At zero the Epoch's own big plasma blast
--     (type 407) is requested at the player's position.
--   * Firing the Epoch re-arms the 7 s fuse. That is the only way to cancel it.
--   * 35 s of uninterrupted carry is a hard blast: shots cannot delay it. Dropping the weapon,
--     dying, or leaving the mission resets the whole cycle; dropping also cancels the 7 s fuse.
--
-- How it works without HD2Runtime:
--   * Game data is read from fixed RVAs in game.dll that are proven by prologue bytes (the same
--     positions HD2Runtime 0.40.0 documents for this build, F5FEE03DCFDB / 6AB382E4 stamps).
--     Reads go through ReadProcessMemory(GetCurrentProcess) - a handful of 4-byte reads at 10 Hz.
--     After load there is no scanning of memory whatsoever.
--   * The blast calls the game's own RequestExplosion (game.dll+RVA 20712064) with the argument
--     template the game's own callers pass (0, null, 1, 0, null, null, null, 0, 0), only after the
--     same checks HD2Runtime does: settings record carries the type, queue headroom, finite
--     coordinates, the player entity exists.
--   * Beeps are Windows PlaySoundA (winmm) with synthesised wave buffers: asynchronous, never
--     blocks a frame, independent of the game's SFX slider.
--
-- Safety (project rules):
--   * The update hook CHAINS the previous global update; it never cuts the chain (v2.3 lesson).
--   * If the build does not match the pins, or a read is inconsistent: log once, stay passive.
--     The only write this addon ever performs is the validated RequestExplosion call.
--   * Host scope only, exactly like the proven Runtime version: the timers run while the local
--     player is the authority over the game mode (solo, or hosting a lobby).

local REVISION = 'epoch-timebomb-standalone/3.0.0'
local existing = rawget(_G, 'EpochTimebombStandalone')
if type(existing) == 'table' and existing.revision then return existing end

local ffi = require('ffi')

local EPOCH_NAME = 'PLAS-45 Epoch'
-- Blast type: the probe's reviewed choice (407 = support_weapon/plas45_epoch/charge_2_expiry,
-- the Epoch's own charged-shot blast, 800/800 in 3/4/5 m; its assets ship in the Epoch's own
-- loadout package, so a carrier always has them loaded). Fallback 227 (the Epoch's impact
-- blast) only if a future probe does not name one.
local BLAST_KIND = (type(PROBE) == 'table' and type(PROBE.blast_kind) == 'number'
    and PROBE.blast_kind) or 227

local CONFIG = {
    fuse_seconds = 7.0,
    carry_limit_seconds = 35.0,
    poll_seconds = 0.10,
    beep = true,
}

local STATE = {
    revision = REVISION,
    phase = 'starting',
    frames = 0,
    logs = {},
    probe_ready = false,
    probe_reason = nil,
    in_game = false,
    carrying = false,
    carry_started_ms = nil,
    fuse_armed_ms = nil,
    last_beep_step = nil,
    last_shots = nil,
    limit_blasted = false,
    blast_count = 0,
    next_poll_ms = 0,
    idle_logged = false,
}
rawset(_G, 'EpochTimebombStandalone', STATE)
-- Sandbox hook only: the offline tests inject _G.EPOCH_TIMEBOMB_TEST before loading the addon
-- (a simulated clock, beep capture, no real audio). nil in the game.
local TEST = rawget(_G, 'EPOCH_TIMEBOMB_TEST')

-- ============================================================ logging
local log_file
local function make_log_directory()
    local base = os.getenv('LOCALAPPDATA')
    if not base then return nil end
    local ok, kernel = pcall(ffi.load, 'kernel32')
    if not ok or kernel == nil then return nil end
    ffi.cdef[[ int CreateDirectoryA(const char *path, void *security); uint32_t GetLastError(void); ]]
    local path = base
    for _, part in ipairs({ 'CowboyBingus', 'Helldivers2', 'Logs', 'EpochTimebombStandalone' }) do
        path = path .. '/' .. part
        if kernel.CreateDirectoryA(path, nil) == 0 and kernel.GetLastError() ~= 183 then return nil end
    end
    return path
end
do
    local loader = rawget(_G, 'CowboyBingusModLoader')
    if type(loader) == 'table' and type(loader.open_log) == 'function' then
        local ok, handle = pcall(loader.open_log, 'EpochTimebombStandalone.log')
        if ok and handle then log_file = handle end
    end
    if not log_file then
        local dir = make_log_directory()
        if dir then
            local f = io.open(dir .. '/EpochTimebombStandalone.log', 'a')
            if f then log_file = f end
        end
    end
end
local function emit(line)
    local text = '[' .. REVISION .. '] ' .. tostring(line)
    -- Ring-buffer the in-memory log so a long session cannot grow the Lua state
    -- (the file on disk is the full record; this list is only for tests/overlays).
    local logs = STATE.logs
    logs[#logs + 1] = text
    if #logs > 400 then table.remove(logs, 1) end
    if log_file then
        pcall(function()
            log_file:write(text .. '\n')
            log_file:flush()
        end)
    end
    pcall(print, '[EpochTimebomb] ' .. tostring(line))
end

-- ============================================================ winmm beeper
local function make_beeper()
    ffi.cdef[[
        int __stdcall epoch_timebomb_v3_PlaySoundA(const char *sound, void *module,
            unsigned long flags) __asm__("PlaySoundA");
    ]]
    local winmm = ffi.load('winmm')
    local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
    local function le32(n) return le16(n % 65536) .. le16(math.floor(n / 65536)) end
    local rate, count, amplitude = 22050, 1764, 6500
    local buffers = {}
    for step = 1, math.floor(CONFIG.fuse_seconds) do
        -- step = seconds REMAINING (7 = lowest tone), rising as the fuse runs out.
        local frequency = 700 + (math.floor(CONFIG.fuse_seconds) - step) * 160
        local samples = {}
        for i = 0, count - 1 do
            local envelope = math.min(1, i / 176, (count - 1 - i) / 176)
            local value = math.floor(amplitude * envelope * math.sin(2 * math.pi * frequency * i / rate))
            samples[#samples + 1] = le16(value % 65536)
        end
        local data = table.concat(samples)
        local wave = 'RIFF' .. le32(36 + #data) .. 'WAVEfmt ' .. le32(16) ..
            le16(1) .. le16(1) .. le32(rate) .. le32(rate * 2) .. le16(2) .. le16(16) ..
            'data' .. le32(#data) .. data
        local buffer = ffi.new('char[?]', #wave)
        ffi.copy(buffer, wave, #wave)
        buffers[step] = buffer
    end
    return {
        buffers = buffers,
        library = winmm,
        play = function(self, step)
            step = math.max(1, math.min(math.floor(CONFIG.fuse_seconds), math.floor(step or 1)))
            -- SND_ASYNC | SND_MEMORY | SND_NODEFAULT | SND_NOSTOP = 0x17
            return self.library.epoch_timebomb_v3_PlaySoundA(self.buffers[step], nil, 0x17) ~= 0
        end,
    }
end
local sound_ok, beeper = pcall(make_beeper)
if not sound_ok then beeper = nil end
local audio_warned = false
local function play_beep(step)
    if TEST and type(TEST.on_beep) == 'function' then TEST.on_beep(step) end
    if TEST and TEST.beep == false then return true end
    if not CONFIG.beep or beeper == nil then
        if not audio_warned then
            audio_warned = true
            emit('BEEP unavailable (no winmm); countdown continues silently')
        end
        return false
    end
    local ok, played = pcall(function() return beeper:play(step) end)
    return ok and played
end

-- ============================================================ timing
local kernel
do
    local ok = pcall(function()
        ffi.cdef[[ uint64_t GetTickCount64(void); ]]
    end)
    if ok then kernel = ffi.load('kernel32') end
end
local function now_ms()
    if TEST and type(TEST.now) == 'function' then return TEST.now() end
    if kernel then return tonumber(kernel.GetTickCount64() % 2147483648) end
    return math.floor(os.clock() * 1000)
end

-- ============================================================ cycle helpers
local function reset_cycle(reason, force_log)
    local was_active = STATE.carrying or STATE.fuse_armed_ms ~= nil or STATE.limit_blasted
    STATE.carrying = false
    STATE.carry_started_ms = nil
    STATE.fuse_armed_ms = nil
    STATE.last_beep_step = nil
    STATE.limit_blasted = false
    if was_active or force_log then emit('cycle reset: ' .. tostring(reason)) end
end
local function arm_fuse(now, reason)
    STATE.fuse_armed_ms = now
    STATE.last_beep_step = math.floor(CONFIG.fuse_seconds)
    play_beep(STATE.last_beep_step)
    emit(string.format('FUSE_7S armed (%s); beep %d', tostring(reason), STATE.last_beep_step))
end

-- blast: returns true when an explosion was actually requested.
local function request_blast(x, y, z, reason)
    local ok, why = PROBE.explode_at(BLAST_KIND, x, y, z)
    if ok then
        STATE.blast_count = STATE.blast_count + 1
        emit(string.format('OVERCHARGE_REQUESTED (%s) at %.1f %.1f %.1f; total=%d',
            tostring(reason), x, y, z, STATE.blast_count))
        return true
    end
    emit('EXPLOSION_REFUSED: ' .. tostring(why))
    return false
end

-- ============================================================ the 10 Hz poll
local function poll(now)
    local st = PROBE.state()
    if not st then
        if not STATE.idle_logged then
            STATE.idle_logged = true
            emit('probe unreadable this tick; waiting')
        end
        return
    end
    STATE.in_game = st.in_mission == true
    if not STATE.in_game or not st.host then
        -- not the scenario this mod runs in (ship, or a lobby we are not authoritative in)
        if STATE.carrying or STATE.fuse_armed_ms or STATE.limit_blasted then
            reset_cycle(st.in_mission and 'not host' or 'left mission')
        end
        return
    end
    if st.alive ~= true then
        if STATE.carrying or STATE.fuse_armed_ms or STATE.limit_blasted then
            reset_cycle('local player not alive')
        end
        return
    end
    local carried = PROBE.carried_epoch()
    if carried == nil then return end
    if not carried then
        if STATE.carrying or STATE.fuse_armed_ms or STATE.limit_blasted then
            reset_cycle('Epoch dropped / not carried')
        end
        return
    end
    if not STATE.carrying then
        STATE.carrying = true
        STATE.carry_started_ms = now
        STATE.limit_blasted = false
        emit('CARRY_STARTED: Epoch is on the diver; 7 s fuse and 35 s hard limit running')
    end
    -- shots: cumulative projectiles_fired credited to the Epoch
    local shots = PROBE.shots_epoch()
    if shots ~= nil then
        if STATE.last_shots ~= nil and shots > STATE.last_shots then
            if not STATE.limit_blasted then
                arm_fuse(now, 'RESET_BY_EPOCH_SHOT')
            end
        end
        STATE.last_shots = shots
    end
    -- carry limit: hard blast, shots cannot delay it
    if not STATE.limit_blasted and now - STATE.carry_started_ms >= CONFIG.carry_limit_seconds * 1000 then
        STATE.limit_blasted = true
        STATE.fuse_armed_ms = nil
        STATE.last_beep_step = nil
        emit('CARRY_LIMIT_REACHED after 35 s uninterrupted carry; shots can no longer save it; drop to reset')
        if st.x then request_blast(st.x, st.y, st.z, 'CARRY_LIMIT_REACHED') end
        return
    end
    if STATE.limit_blasted then return end
    if STATE.fuse_armed_ms == nil then
        arm_fuse(now, 'carrying Epoch')
    end
    local remaining = CONFIG.fuse_seconds - (now - STATE.fuse_armed_ms) / 1000
    if remaining <= 0 then
        -- 7 s fuse expired
        STATE.fuse_armed_ms = nil
        STATE.last_beep_step = nil
        local blasted = st.x and request_blast(st.x, st.y, st.z, 'FUSE_7S') or false
        if not blasted then
            arm_fuse(now, 'RETRY_AFTER_REFUSAL')
        end
        return
    end
    local step = math.ceil(remaining - 0.000001)
    if STATE.last_beep_step and step < STATE.last_beep_step and step >= 1 then
        STATE.last_beep_step = step
        play_beep(step)
        emit(string.format('BEEP %d (%.1f s to blast)', step, remaining))
    end
end

-- ============================================================ update hook (chained!)
-- v2.3 lesson: read the previous hook BEFORE defining ours, or the reference inside the
-- closure would resolve to a global and the chain would be cut again.
local original_update = rawget(_G, 'update')

local function update_hook(dt, ...)
    STATE.frames = STATE.frames + 1
    local now = now_ms()
    if STATE.probe_ready and now >= STATE.next_poll_ms then
        STATE.next_poll_ms = now + CONFIG.poll_seconds * 1000
        pcall(poll, now)
    end
    if type(original_update) == 'function' then return original_update(dt, ...) end
end

rawset(_G, 'update', update_hook)
STATE.frame_hook = type(original_update) == 'function' and 'chained' or 'installed'

-- ============================================================ bring-up
do
    local ready, reason = false, nil
    if type(PROBE) == 'table' and type(PROBE.open) == 'function' then
        local ok, r, why = pcall(PROBE.open, {})
        if ok then
            ready, reason = r == true, why
        else
            reason = tostring(r)
        end
    else
        reason = 'game_probe module missing'
    end
    STATE.probe_ready = ready == true
    STATE.probe_reason = reason
    if STATE.probe_ready then
        emit('PROBE_READY: build pins verified; 10 Hz reads, RequestExplosion template armed. '
            .. 'Update hook: ' .. STATE.frame_hook .. '.')
        emit(string.format(
            'loaded: standalone Epoch Timebomb v3.0 (no HD2Runtime): %g s shot-resettable fuse, '
            .. '%g s carry hard limit, per-second beeps, native blast #%d.',
            CONFIG.fuse_seconds, CONFIG.carry_limit_seconds, BLAST_KIND))
    else
        emit('PROBE_NOT_READY: ' .. tostring(reason)
            .. ' -- staying passive (no reads, no writes). Game build changed? update the RVA table.')
    end
end

return STATE
