"""Build the release zip for Epoch Timebomb Standalone (v3.0) from src/.

Produces a Bingus Shared Loader addon patch (the same container the game's loader extracts),
packs it with a manifest.json into release/纪元定时炸弹-独立版v3.0-BSL版.zip, and verifies:
the payload compiles under the game's own lua51.dll (LuaJIT), the container rebuilds byte-for-byte,
and the resource hash matches the addon id.
"""
import ctypes
import json
import os
import struct
import sys
import zipfile
from io import BytesIO
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_PROBE = ROOT / 'src' / 'game_probe.lua'
SRC_ADDON = ROOT / 'src' / 'addon.lua'
OUT = ROOT / 'release' / '纪元定时炸弹-独立版v3.0-BSL版.zip'
LUA_DLL = Path(os.environ.get('HD2_LUA51',
    r'D:\SteamLibrary\steamapps\common\Helldivers 2\bin\lua51.dll'))

M64 = (1 << 64) - 1
MIX = 0xC6A4A7935BD1E995
LUA_TYPE = 0xA14E8DFA2CD117E2
NAME = 'mods/hexua/epoch_timebomb_standalone'

MANIFEST = {
    "Version": 1,
    "Guid": "e1de5a10-2e70-56f4-bfd2-57e59c62c45a",
    "Name": "纪元定时炸弹 独立版 v3.0（BSL 版·无需 Runtime）",
    "Description": (
        "Bingus Shared Loader only, no HD2Runtime. Carry the PLAS-45 Epoch and a 7 s fuse runs with one "
        "beep per second (rising pitch); firing the Epoch re-arms it, dropping the weapon cancels it. "
        "35 s of uninterrupted carry is a hard blast that shots cannot delay. The blast is the Epoch's own "
        "big plasma explosion (type 407, assets in the Epoch's own loadout package), requested through the "
        "game's native RequestExplosion; every game read is a fixed RVA in game.dll / helldivers2.exe "
        "verified by 442 instruction pins, a handful of 4-byte reads at 10 Hz, no scanning. Build pins must "
        "match or the mod stays passive. Host scope only. Uses code / research from HD2Runtime by SkyeShade "
        "(https://github.com/SkyeShade/HD2Runtime)."
    ),
    "Options": [
        {
            "Name": "纪元定时炸弹 独立版 v3.0（表头定位·零内容扫描）",
            "Description": (
                "Bingus Shared Loader only, no HD2Runtime. Carry the PLAS-45 Epoch and a 7 s fuse runs with one "
                "beep per second (rising pitch); firing the Epoch re-arms it, dropping the weapon cancels it. "
                "35 s of uninterrupted carry is a hard blast that shots cannot delay. The blast is the Epoch's own "
                "big plasma explosion (type 407, assets in the Epoch's own loadout package), requested through the "
                "game's native RequestExplosion; every game read is a fixed RVA in game.dll / helldivers2.exe "
                "verified by 442 instruction pins, a handful of 4-byte reads at 10 Hz, no scanning. Build pins must "
                "match or the mod stays passive. Host scope only. Uses code / research from HD2Runtime by SkyeShade "
                "(https://github.com/SkyeShade/HD2Runtime)."
            ),
            "Include": ["Addon"],
        }
    ],
}


def resource_hash(name: str) -> int:
    data = name.encode('utf-8')
    n = len(data)
    result = (n * MIX) & M64
    complete = n // 8 * 8
    for at in range(0, complete, 8):
        word = int.from_bytes(data[at:at + 8], 'little')
        word = (word * MIX) & M64
        word ^= word >> 47
        result = ((result ^ ((word * MIX) & M64)) * MIX) & M64
    if complete != n:
        tail = 0
        for i in range(complete, n):
            tail |= data[i] << ((i - complete) * 8)
        result = ((result ^ tail) * MIX) & M64
    result ^= result >> 47
    result = (result * MIX) & M64
    return result ^ (result >> 47)


def container(name: str, body: bytes) -> bytes:
    data_offset = 192
    resource_length = len(body) + 8
    padding = (16 - (resource_length % 16)) % 16
    out = bytearray()
    out += struct.pack('<III', 0xF0000011, 1, 1)
    out += b'\x00' * 20
    out += struct.pack('<Q', data_offset + resource_length + padding)
    out += struct.pack('<Q', 0)
    out += b'\x00' * 24
    out += struct.pack('<II', 0, 0)
    out += struct.pack('<Q', LUA_TYPE)
    out += struct.pack('<IIII', 1, 0, 16, 16)
    out += struct.pack('<Q', resource_hash(name))
    out += struct.pack('<Q', LUA_TYPE)
    out += struct.pack('<Q', data_offset)
    out += struct.pack('<QQQQ', 0, 0, 0, 0)
    out += struct.pack('<III', resource_length, 0, 0)
    out += struct.pack('<III', 16, 16, 0)
    out += b'\x00' * (data_offset - len(out))
    out += struct.pack('<II', len(body), 2)
    out += body
    out += b'\x00' * padding
    return bytes(out)


def compile_check(payload: bytes) -> None:
    if not LUA_DLL.exists():
        print('lua51.dll not found at %s -- skipping LuaJIT compile check '
              '(set HD2_LUA51 to your game bin\\lua51.dll)' % LUA_DLL)
        return
    dll = ctypes.CDLL(str(LUA_DLL))
    dll.luaL_newstate.restype = ctypes.c_void_p
    dll.luaL_openlibs.argtypes = [ctypes.c_void_p]
    dll.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
    dll.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    dll.lua_tolstring.restype = ctypes.c_void_p
    state = dll.luaL_newstate()
    dll.luaL_openlibs(ctypes.c_void_p(state))
    status = dll.luaL_loadbuffer(ctypes.c_void_p(state), payload, len(payload), b'@payload')
    if status != 0:
        length = ctypes.c_size_t()
        pointer = dll.lua_tolstring(ctypes.c_void_p(state), -1, ctypes.byref(length))
        message = ctypes.string_at(pointer, length.value).decode('utf-8', 'replace') if pointer else '?'
        raise SystemExit('LuaJIT compile check failed: ' + message)
    print('LuaJIT compile check (game lua51.dll): OK')


def main() -> int:
    probe = SRC_PROBE.read_bytes().replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    addon = SRC_ADDON.read_bytes().replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    # The loader discovers addons by scanning the first bytes for the "-- HD2-Addon:" declaration,
    # so it must be the very first line of the payload, before the probe wrapper.
    declaration = b'-- HD2-Addon: mods/hexua/epoch_timebomb_standalone\n'
    body = declaration + b'local PROBE = (function()\n' + probe + b'\nend)()\n' + addon
    compile_check(body)
    patch = container(NAME, body)
    manifest_bytes = json.dumps(MANIFEST, ensure_ascii=False, indent=2).encode('utf-8')
    entries = [('Addon/9ba626afa44a3aa3.patch_0', patch),
               ('Addon/9ba626afa44a3aa3.patch_0.gpu_resources', b''),
               ('Addon/9ba626afa44a3aa3.patch_0.stream', b''),
               ('manifest.json', manifest_bytes)]
    # Pinned timestamps keep the zip byte-identical between rebuilds (and with the release that
    # has been published/tested); see the sha256 in README.md.
    zip_time = (2026, 10, 15, 23, 45, 0)
    buf = BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=zip_time)
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)
    data = buf.getvalue()
    with zipfile.ZipFile(BytesIO(data)) as z:
        got = z.read('Addon/9ba626afa44a3aa3.patch_0')
        assert got == patch, 'patch bytes differ'
        assert struct.unpack_from('<I', got, 192)[0] == len(body), 'length field wrong'
        assert got[200:200 + len(body)] == body, 'payload differs'
        assert struct.pack('<Q', resource_hash(NAME)) == got[104:112], 'resource hash wrong'
    OUT.write_bytes(data)
    print('wrote %s (%d bytes, payload %d bytes)' % (OUT, len(data), len(body)))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
