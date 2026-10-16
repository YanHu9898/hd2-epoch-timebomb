"""Offline state-machine tests for the v3.0 Epoch Timebomb addon.

Loads the real addon.lua with a scripted game_probe stub inside the game's own lua51.dll,
with a simulated clock (_G.EPOCH_TIMEBOMB_TEST), and checks the full gameplay contract:
7 s shot-resettable fuse, one beep per second, 35 s hard carry blast, drop/death/mission resets,
chained update hook, probe-not-ready passivity.
"""
import ctypes
import os
import pathlib
import re
import sys
import tempfile

WORK = pathlib.Path(__file__).resolve().parent.parent
ADDON = WORK / 'src' / 'addon.lua'
STUB = WORK / 'tests' / 'probe_stub.lua'
DLL = pathlib.Path(os.environ.get('HD2_LUA51', r'D:\SteamLibrary\steamapps\common\Helldivers 2\bin\lua51.dll'))

PREAMBLE = r"""
_G.SIM = { now = 0, beeps = {} }
_G.EPOCH_TIMEBOMB_TEST = {
    beep = false,
    now = function() return _G.SIM.now end,
    on_beep = function(step) _G.SIM.beeps[#_G.SIM.beeps + 1] = { step = step, at = _G.SIM.now } end,
}
"""

DRIVER = r"""
local SIM = _G.SIM
local CALLS = _G.SIM_CALLS
for t = 0, SIM.total_ms, 100 do
    SIM.now = t
    if SIM.on_step then SIM.on_step(t) end
    local u = rawget(_G, 'update')
    if type(u) == 'function' then u(0.1) end
end
local beeps = {}
for _, b in ipairs(SIM.beeps) do beeps[#beeps + 1] = b.step .. '@' .. b.at end
local blasts = {}
for _, e in ipairs(CALLS.explode) do
    blasts[#blasts + 1] = e.kind .. '@' .. e.at .. '@' .. ((e.x or 0) .. '') .. ',' .. ((e.y or 0) .. '') .. ',' .. ((e.z or 0) .. '')
end
local logs = {}
for _, l in ipairs(MOD.logs or {}) do logs[#logs + 1] = l end
return 'BEEPS=' .. table.concat(beeps, ' ') .. '\n'
    .. 'BLASTS=' .. table.concat(blasts, ' ') .. '\n'
    .. 'FRAMES=' .. tostring(SIM.loader_frames or -1) .. '\n'
    .. 'HOOK=' .. tostring(MOD.frame_hook) .. '\n'
    .. 'PROBE_READY=' .. tostring(MOD.probe_ready) .. '\n'
    .. 'CALLS=open' .. CALLS.open .. ',state' .. CALLS.state .. ',carried' .. CALLS.carried .. ',shots' .. CALLS.shots .. '\n'
    .. 'LOGS=\n' .. table.concat(logs, '\n')
"""

COMMON_STATE = """
SIM.state = function(t)
    return {in_mission = SIM.in_mission ~= false, host = SIM.host ~= false, peer_lo = 1, peer_hi = 0,
        player_entity = 42, alive = SIM.alive ~= false,
        x = SIM.alive ~= false and 1.0 or nil, y = 2.0, z = 3.0}
end
"""

SCENARIOS = {
    'CARRY_FUSE': dict(
        setup=COMMON_STATE + """
SIM.carried = function(t) return t >= 1000 end
SIM.shots = function(t) return 0 end
""",
        total=12000,
        # after the blast the cycle re-arms (the fuse keeps ticking while the weapon is carried)
        expect_beeps=[(7, 1000), (6, 2000), (5, 3000), (4, 4000), (3, 5000), (2, 6000), (1, 7000),
                      (7, 8100), (6, 9100), (5, 10100), (4, 11100)],
        expect_blasts=[(407, 8000)],
        expect_logs=['FUSE_7S armed', 'OVERCHARGE_REQUESTED (FUSE_7S)'],
    ),
    'SHOT_RESET': dict(
        setup=COMMON_STATE + """
SIM.carried = function(t) return true end
SIM.shots = function(t) return t >= 3000 and 1 or 0 end
""",
        total=12000,
        expect_beeps=[(7, 0), (6, 1000), (5, 2000), (7, 3000), (6, 4000), (5, 5000), (4, 6000),
                      (3, 7000), (2, 8000), (1, 9000), (7, 10100), (6, 11100)],
        expect_blasts=[(407, 10000)],
        expect_logs=['RESET_BY_EPOCH_SHOT', 'OVERCHARGE_REQUESTED (FUSE_7S)'],
    ),
    'CARRY_LIMIT': dict(
        setup=COMMON_STATE + """
SIM.carried = function(t) return true end
SIM.shots = function(t) return math.floor(t / 2000) end
""",
        total=45000,
        # a shot every 2 s re-arms the fuse, so the tones alternate 7,6,7,6 ... until the 35 s hard blast
        expect_beeps=[(7, 0), (6, 1000), (7, 2000), (6, 3000), (7, 4000), (6, 5000), (7, 6000),
                      (6, 7000), (7, 8000), (6, 9000), (7, 10000), (6, 11000), (7, 12000), (6, 13000),
                      (7, 14000), (6, 15000), (7, 16000), (6, 17000), (7, 18000), (6, 19000),
                      (7, 20000), (6, 21000), (7, 22000), (6, 23000), (7, 24000), (6, 25000),
                      (7, 26000), (6, 27000), (7, 28000), (6, 29000), (7, 30000), (6, 31000),
                      (7, 32000), (6, 33000), (7, 34000)],
        expect_blasts=[(407, 35000)],
        expect_logs=['CARRY_LIMIT_REACHED', 'OVERCHARGE_REQUESTED (CARRY_LIMIT_REACHED)'],
    ),
    'DROP_RESETS': dict(
        setup=COMMON_STATE + """
SIM.carried = function(t) return t < 5000 end
SIM.shots = function(t) return 0 end
""",
        total=15000,
        expect_beeps=[(7, 0), (6, 1000), (5, 2000), (4, 3000), (3, 4000)],
        expect_blasts=[],
        expect_logs=['cycle reset: Epoch dropped / not carried'],
    ),
    'NOT_HOST_IDLE': dict(
        setup=COMMON_STATE + """
SIM.host = false
SIM.carried = function(t) return true end
SIM.shots = function(t) return 0 end
""",
        total=10000,
        expect_beeps=[],
        expect_blasts=[],
        expect_logs=[],
    ),
    'DEATH_RESETS': dict(
        setup=COMMON_STATE + """
SIM.carried = function(t) return true end
SIM.shots = function(t) return 0 end
SIM.alive = true
SIM.on_step = function(t) if t >= 6000 then SIM.alive = false end end
""",
        total=15000,
        expect_beeps=[(7, 0), (6, 1000), (5, 2000), (4, 3000), (3, 4000), (2, 5000)],
        expect_blasts=[],
        expect_logs=['cycle reset: local player not alive'],
    ),
    'MISSION_END': dict(
        setup=COMMON_STATE + """
SIM.carried = function(t) return true end
SIM.shots = function(t) return 0 end
SIM.on_step = function(t) if t >= 4000 then SIM.in_mission = false end end
""",
        total=12000,
        expect_beeps=[(7, 0), (6, 1000), (5, 2000), (4, 3000)],
        expect_blasts=[],
        expect_logs=['cycle reset: left mission'],
    ),
    'CHAIN': dict(
        setup=COMMON_STATE + """
_G.update = function() SIM.loader_frames = (SIM.loader_frames or 0) + 1 end
SIM.loader_frames = 0
SIM.carried = function(t) return false end
SIM.shots = function(t) return 0 end
""",
        total=2000,
        expect_beeps=[],
        expect_blasts=[],
        expect_logs=[],
        expect_frames=21,
        expect_hook='chained',
    ),
    'PROBE_NOT_READY': dict(
        setup=COMMON_STATE + """
SIM.open_ready = false
SIM.open_reason = 'build pins mismatch (test)'
SIM.carried = function(t) return true end
SIM.shots = function(t) return 0 end
""",
        total=5000,
        expect_beeps=[],
        expect_blasts=[],
        expect_logs=['PROBE_NOT_READY', 'build pins mismatch'],
        expect_calls='open1,state0,carried0,shots0',
        expect_probe_ready='false',
    ),
}


def load_lib():
    lib = ctypes.CDLL(str(DLL))
    lib.luaL_newstate.restype = ctypes.c_void_p
    lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lib.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
    lib.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    lib.lua_tolstring.restype = ctypes.c_void_p
    lib.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.lua_close.argtypes = [ctypes.c_void_p]
    return lib


def run_chunk(lib, state, code, name):
    status = lib.luaL_loadbuffer(state, code, len(code), name)
    if status == 0:
        status = lib.lua_pcall(state, 0, 1, 0)
    length = ctypes.c_size_t()
    pointer = lib.lua_tolstring(state, -1, ctypes.byref(length))
    text = ctypes.string_at(pointer, length.value).decode('utf-8', 'replace') if pointer else ''
    lib.lua_settop(state, 0)
    return status, text


def run_scenario(name, spec):
    payload = ('local MOD = (function()\n'
               'local PROBE = (function()\n'
               + STUB.read_bytes().decode('utf-8') + '\nend)()\n'
               + ADDON.read_bytes().decode('utf-8')
               + '\nend)()\n_G.MOD = MOD\n')
    setup = PREAMBLE + spec['setup'] + '\nSIM.total_ms = %d\n' % spec['total']
    driver = DRIVER
    lib = load_lib()
    state = lib.luaL_newstate()
    if not state:
        raise SystemExit('luaL_newstate failed')
    try:
        lib.luaL_openlibs(state)
        status, text = run_chunk(lib, state, setup.encode('utf-8'), b'@setup')
        if status != 0:
            return None, 'setup chunk failed:\n' + text
        status, text = run_chunk(lib, state, payload.encode('utf-8'), b'@payload')
        if status != 0:
            return None, 'payload chunk failed:\n' + text
        status, text = run_chunk(lib, state, driver.encode('utf-8'), b'@driver')
        if status != 0:
            return None, 'driver chunk failed:\n' + text
        result = {}
        logs = []
        in_logs = False
        for line in text.splitlines():
            if in_logs:
                logs.append(line)
                continue
            if line.startswith('LOGS='):
                in_logs = True
                continue
            if '=' in line:
                key, value = line.split('=', 1)
                result[key] = value
        result['LOGS'] = logs
        return result, None
    finally:
        lib.lua_close(state)


def parse_beeps(text):
    out = []
    for token in (text or '').split():
        m = re.match(r'(\d+)@(\d+)$', token)
        if m:
            out.append((int(m.group(1)), int(m.group(2))))
    return out


def parse_blasts(text):
    out = []
    for token in (text or '').split():
        parts = token.split('@')
        if len(parts) >= 2:
            out.append((int(parts[0]), int(parts[1])))
    return out


def check(name, spec, result):
    problems = []
    beeps = parse_beeps(result.get('BEEPS'))
    blasts = parse_blasts(result.get('BLASTS'))
    logs = '\n'.join(result.get('LOGS') or [])
    if beeps != spec['expect_beeps']:
        problems.append('beeps %r, expected %r' % (beeps, spec['expect_beeps']))
    if blasts != spec['expect_blasts']:
        problems.append('blasts %r, expected %r' % (blasts, spec['expect_blasts']))
    for want in spec.get('expect_logs', []):
        if want not in logs and not any(want in line for line in result.get('LOGS') or []):
            problems.append('log missing: ' + want)
    if 'expect_frames' in spec and result.get('FRAMES') != str(spec['expect_frames']):
        problems.append('chained frames %s, expected %s' % (result.get('FRAMES'), spec['expect_frames']))
    if 'expect_hook' in spec and result.get('HOOK') != spec['expect_hook']:
        problems.append('hook %s, expected %s' % (result.get('HOOK'), spec['expect_hook']))
    if 'expect_calls' in spec and result.get('CALLS') != spec['expect_calls']:
        problems.append('calls %s, expected %s' % (result.get('CALLS'), spec['expect_calls']))
    if 'expect_probe_ready' in spec and result.get('PROBE_READY') != spec['expect_probe_ready']:
        problems.append('probe_ready %s, expected %s' % (result.get('PROBE_READY'), spec['expect_probe_ready']))
    if 'PROBE_READY' not in result:
        problems.append('scenario produced no result footer')
    return problems


def main():
    os.environ.setdefault('LOCALAPPDATA', tempfile.mkdtemp(prefix='epoch_v3_test_'))
    names = sys.argv[1:] or list(SCENARIOS)
    failures = 0
    for name in names:
        spec = SCENARIOS[name]
        result, error = run_scenario(name, spec)
        print('===== %s =====' % name)
        if error:
            print(error)
            print('FAIL')
            failures += 1
            continue
        print('BEEPS=' + result.get('BEEPS', ''))
        print('BLASTS=' + result.get('BLASTS', ''))
        print('CALLS=' + result.get('CALLS', ''))
        for line in result.get('LOGS') or []:
            print('LOG ' + line)
        problems = check(name, spec, result)
        for problem in problems:
            print('FAIL: ' + problem)
        print('PASS' if not problems else 'FAILED')
        failures += 1 if problems else 0
    print('===== state machine summary: %d/%d passed =====' % (len(names) - failures, len(names)))
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
