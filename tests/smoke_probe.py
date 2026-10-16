"""Smoke test: the real game_probe.lua must load, execute and refuse safely outside the game.

This process has no game.dll, so open() must refuse with a reason, every public call must
return its documented "not ready" value, and the module must not raise. It also checks the
reviewed choice (blast kind 407) and the size of the pin set.
"""
import ctypes
import os
import pathlib
import sys
import tempfile

WORK = pathlib.Path(__file__).resolve().parent.parent
PROBE = WORK / 'src' / 'game_probe.lua'
REPORT = WORK / 'tests' / 'results' / 'probe-smoke-results.txt'
DLL = pathlib.Path(os.environ.get('HD2_LUA51', r'D:\SteamLibrary\steamapps\common\Helldivers 2\bin\lua51.dll'))

SCRIPT = """
local ok, why = PROBE.open()
local out = {}
out[#out + 1] = 'OPEN=' .. tostring(ok) .. '/' .. tostring(why)
out[#out + 1] = 'BLAST_KIND=' .. tostring(PROBE.blast_kind)
out[#out + 1] = 'PINS=' .. tostring(PROBE.pins and #PROBE.pins)
out[#out + 1] = 'STATE=' .. tostring(PROBE.state())
out[#out + 1] = 'CARRIED=' .. tostring(PROBE.carried_epoch())
out[#out + 1] = 'SHOTS=' .. tostring(PROBE.shots_epoch())
local ok2, why2 = PROBE.explode_at(407, 0, 0, 0)
out[#out + 1] = 'EXPLODE=' .. tostring(ok2) .. '/' .. tostring(why2)
return table.concat(out, '\\n')
"""


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


def main():
    os.environ.setdefault('LOCALAPPDATA', tempfile.mkdtemp(prefix='epoch_v3_smoke_'))
    lib = load_lib()
    state = lib.luaL_newstate()
    if not state:
        raise SystemExit('luaL_newstate failed')
    try:
        lib.luaL_openlibs(state)
        payload = ('local PROBE = (function()\n' + PROBE.read_bytes().decode('utf-8')
                   + '\nend)()\n_G.PROBE = PROBE\n')
        status, text = run_chunk(lib, state, payload.encode('utf-8'), b'@probe')
        if status != 0:
            print('SMOKE FAILED: module did not load:\n' + text)
            return 1
        status, text = run_chunk(lib, state, SCRIPT.encode('utf-8'), b'@smoke')
        if status != 0:
            print('SMOKE FAILED: calls raised:\n' + text)
            return 1
    finally:
        lib.lua_close(state)
    print(text)
    fields = dict(line.split('=', 1) for line in text.splitlines() if '=' in line)
    problems = []
    if fields.get('OPEN', '').startswith('true'):
        problems.append('open() unexpectedly succeeded outside the game')
    if fields.get('BLAST_KIND') != '407':
        problems.append('blast kind is not 407: ' + str(fields.get('BLAST_KIND')))
    if fields.get('PINS') != '442':
        problems.append('pin count is not 442: ' + str(fields.get('PINS')))
    if fields.get('STATE') != 'nil':
        problems.append('state() should be nil before open: ' + str(fields.get('STATE')))
    if fields.get('CARRIED') != 'false':
        problems.append('carried_epoch() should be false before open: ' + str(fields.get('CARRIED')))
    if fields.get('SHOTS') != 'nil':
        problems.append('shots_epoch() should be nil before open: ' + str(fields.get('SHOTS')))
    if not (fields.get('EXPLODE') or '').startswith('false'):
        problems.append('explode_at() should refuse before open: ' + str(fields.get('EXPLODE')))
    summary = 'SMOKE ' + ('PASS' if not problems else 'FAILED')
    print(summary)
    for problem in problems:
        print('FAIL: ' + problem)
    REPORT.write_text(text + '\n' + summary + '\n' + ''.join('FAIL: ' + p + '\n' for p in problems),
                      encoding='utf-8')
    return 1 if problems else 0


if __name__ == '__main__':
    raise SystemExit(main())
