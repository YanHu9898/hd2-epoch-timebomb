-- game_probe.lua — Epoch Timebomb v3.0 game probe (standalone, Bingus Shared Loader only).
--
-- This probe reads the live game structures the Epoch Timebomb needs and requests the
-- game's own explosion through its native RequestExplosion. The offsets, the table
-- layouts, the instruction pins and the RequestExplosion argument template are research
-- and code adapted from HD2Runtime 0.40.0 for this exact build (game.dll sha256
-- 2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E,
-- helldivers2.exe sha256 F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06):
--
--   Uses code / research from HD2Runtime by SkyeShade
--   https://github.com/SkyeShade/HD2Runtime
--
-- Safety contract (project rules):
--   * no memory scanning, no writes to game memory: a fixed RVA table, proven by 442
--     reviewed instruction pins plus both module image sizes at open(), and the request
--     function's prologue bytes re-checked around every native call;
--   * every read goes through ReadProcessMemory(GetCurrentProcess); a failed read returns
--     nil and the caller stays passive;
--   * the only native call this probe can make is the guarded RequestExplosion;
--   * on any mismatch the probe refuses everything and reports which pin failed.
--
-- Offline tests drive this exact code through _G.EPOCH_V3_PROBE_TEST
-- ({ read = fun(address, size) -> string|nil, modules = fun(name) -> base|nil,
--    call = fun(kind, x, y, z, source, owner, peer_lo, peer_hi), now = fun() -> ms }).

local P = { revision = 'epoch-timebomb-probe/3.0.0' }

local ffi = require('ffi')
local TEST = rawget(_G, 'EPOCH_V3_PROBE_TEST')

-- ============================================================ constants
local K = {
    -- support_weapon/plas45_epoch/charge_2_expiry: the PLAS-45 Epoch's own big plasma
    -- blast (800 standard / 800 durable, radii 3/4/5 m — the same numbers as the shared
    -- overcharge row 321). Its assets live in the Epoch's own loadout package
    -- (packages/generated/loadout/plasma_blaster), which the game loads when the player
    -- carries the Epoch, so a carrier can always request it. The 321 row's assets live in
    -- the Meltagun's package (packages/generated/loadout/energy_weapon_shark) instead.
    blast_kind = 407,

    -- The PLAS-45 Epoch entity type ("E8D5F49AD7780E54").
    epoch_type_lo = 0xD7780E54,
    epoch_type_hi = 0xE8D5F49A,

    -- PE SizeOfImage of both modules of the reviewed build.
    game_image_size = 74727424,
    exe_image_size = 60719104,

    call_cooldown_ms = 400,
}

-- Native tables. Every entry is a game.dll (module 'g') or helldivers2.exe (module 'e')
-- relative virtual address, from the HD2Runtime 0.40.0 research for this build.
local N = {
    -- game state: pointer -> state object; +state = the mode value (4 = Mission);
    -- game mode object: count must be 1, descriptor flags bit 0 = the local peer is host.
    state = {
        game = 53633856, state = 705052, mission = 4,
        game_mode = 53634720, mode_count = 8, mode_descriptor = 56,
        mode_flags = 20, mode_type = 64,
    },
    -- player list: count, per-slot peer block (lo/hi u32 at +0/+4), per-slot descriptor
    -- pointer, local peer id (u64-halves at user + 45976).
    players = {
        global = 53634152, count = 132, peers = 712, peer_stride = 56,
        descriptors = 232, descriptor_entity = 8, max = 4,
        local_user = 55037680, local_peer = 45976,
    },
    -- network-id -> entity map (also the entity map entity_type() reads), plus the player
    -- list's lifecycle field (736, stride 56: 2 = waiting_for_respawn, 3 = spawned).
    avatars = {
        lifecycle = 736,
        avatar_id = 936, avatar_id_stride = 32, no_network_id = 32767,
        entities = 54968216, map_slots = 15871688,
        entity_base = 15937312, entity_stride = 24,
    },
    -- engine (helldivers2.exe): entity generation table and unit registry.
    engine = {
        entities = 28390840, generation_size = 128, generations = 136,
        units = 27328752, unit_count = 152, unit_generations = 160,
        unit_objects = 136, unit_id = 8,
        scene_graph_offset = 96, poses = 40, translation = 48,
    },
    -- the world-position accessor the unit chain must still be (lea rax,[rcx+0x60]; ret).
    scene_graph = { rva = 2873456, bytes = '488d4160c3' },
    -- the avatar's inventory record (primary +0, secondary +4, support +8, backpack +0xC).
    inventory = {
        global = 53634872, hash = 40, descriptors = 64, records = 80, stride = 48,
        support = 8,
    },
    -- entity -> descriptor map (the game's own entity map; the descriptor's unit is +12).
    wielder = {
        entities = 54968216, entity_map = 15838896, descriptors = 15937304,
        descriptor_stride = 24, descriptor_entity = 8, descriptor_unit = 12,
    },
    -- the local player's mission stats: index map, per-player record, main counter table
    -- (open-addressed, 20-byte entries) and up to 64 source blocks of 328 bytes.
    stats = {
        score = 53635808, index_slots = 228696, record_base = 228760, record_stride = 40,
        max_players = 4, table_entries = 0, table_capacity = 8, table_empty = 12,
        table_multiplier = 16, entry_stride = 20, entry_value = 4,
        sources = 24, source_blocks = 64, source_stride = 328,
        source_entries = 8, source_entry_count = 16,
        key_fired = 1448579290,
    },
    -- the game's own explosion request and its queue (queue pointer at +queue).
    request = {
        rva = 20712064,
        prologue = '40534883ec308b41204c8bda488bd93d000100000f8369020000',
    },
    queue = 54973784, queue_count = 32, queue_capacity = 256,
    settings_table = 58509600, type_bound = 423,
}

-- The reviewed instruction pins of the build (both modules), checked once at open().
local PINS = {
{m='e',rva=551575,hex='4889051acba801'},
{m='e',rva=645327,hex='488b351a289701'},
{m='e',rva=645356,hex='3b8698000000'},
{m='e',rva=645370,hex='488b86a0000000'},
{m='e',rva=645380,hex='381c01'},
{m='e',rva=645385,hex='488b8688000000'},
{m='e',rva=2927696,hex='488d4148'},
{m='e',rva=2927700,hex='c3'},
{m='e',rva=4225124,hex='ff92e8000000'},
{m='e',rva=4225137,hex='488b4828'},
{m='e',rva=4225141,hex='4883c130'},
{m='e',rva=6309542,hex='4c8db180000000'},
{m='e',rva=6309717,hex='488b8388000000'},
{m='e',rva=6309779,hex='81e2ffff3f00'},
{m='e',rva=6309794,hex='c1e816'},
{m='e',rva=6309839,hex='fe0418'},
{m='e',rva=7959294,hex='0f95c1'},
{m='e',rva=7970035,hex='8b4018'},
{m='e',rva=7970288,hex='8bea'},
{m='e',rva=7970389,hex='396818'},
{m='e',rva=7970402,hex='b8ffffffff'},
{m='g',rva=798697,hex='81faff1afdb3'},
{m='g',rva=799493,hex='ba7d000000'},
{m='g',rva=799507,hex='e8a8564000'},
{m='g',rva=2655101,hex='81faff1afdb3'},
{m='g',rva=2656279,hex='baf2000000'},
{m='g',rva=2656293,hex='e896012400'},
{m='g',rva=4867098,hex='4c8b156722e802'},
{m='g',rva=4867114,hex='458b8a38100000'},
{m='g',rva=4867129,hex='418b9a40100000'},
{m='g',rva=4867162,hex='498bba30100000'},
{m='g',rva=4867169,hex='418bb23c100000'},
{m='g',rva=4867242,hex='4869c1b8010000'},
{m='g',rva=4867249,hex='49038258100000'},
{m='g',rva=4867265,hex='418b4304'},
{m='g',rva=4879712,hex='488b1df1efe702'},
{m='g',rva=4879736,hex='448b8ba8480000'},
{m='g',rva=4879745,hex='448b93b0480000'},
{m='g',rva=4879770,hex='4c8b9ba0480000'},
{m='g',rva=4879777,hex='8bbbac480000'},
{m='g',rva=4879828,hex='b8ffffffff'},
{m='g',rva=4879838,hex='488b8bc8480000'},
{m='g',rva=4879868,hex='4969d084000000'},
{m='g',rva=4879875,hex='f20f110411'},
{m='g',rva=4879880,hex='89441108'},
{m='g',rva=5016173,hex='458bce'},
{m='g',rva=5400134,hex='488b1d03ffdf02'},
{m='g',rva=5400209,hex='ff430c'},
{m='g',rva=5400304,hex='4f8994c130400000'},
{m='g',rva=5400364,hex='448b430c'},
{m='g',rva=5400882,hex='c68488805f0c0000'},
{m='g',rva=5496245,hex='488b8648100000'},
{m='g',rva=5496265,hex='4c8934f8'},
{m='g',rva=5510146,hex='488b05374fde02'},
{m='g',rva=5510153,hex='83b81cc20a0004'},
{m='g',rva=5909699,hex='498b86b8480000'},
{m='g',rva=5924463,hex='8bb980480000'},
{m='g',rva=6327084,hex='486bc138'},
{m='g',rva=6327116,hex='42899c08e0020000'},
{m='g',rva=6342386,hex='c7842ba8030000ff7f0000'},
{m='g',rva=6473498,hex='488b0d479dcf02'},
{m='g',rva=6473508,hex='448b9184000000'},
{m='g',rva=6473520,hex='4c8d89c8020000'},
{m='g',rva=6473534,hex='4983c138'},
{m='g',rva=6473553,hex='488b8cc1e8000000'},
{m='g',rva=6473561,hex='8b5108'},
{m='g',rva=6473572,hex='458b8b607d0300'},
{m='g',rva=6473612,hex='498bbb587d0300'},
{m='g',rva=6475071,hex='488b359a9dcf02'},
{m='g',rva=6475120,hex='480557160000'},
{m='g',rva=6475133,hex='488d0480'},
{m='g',rva=6475137,hex='488d34c6'},
{m='g',rva=6475158,hex='8b7804'},
{m='g',rva=6475170,hex='4c8b4e18'},
{m='g',rva=6475231,hex='4883c114'},
{m='g',rva=6475235,hex='83fa10'},
{m='g',rva=6489002,hex='4981c548010000'},
{m='g',rva=6489009,hex='4183fc40'},
{m='g',rva=6664957,hex='3b151d89e202'},
{m='g',rva=6664963,hex='418bf0'},
{m='g',rva=6664966,hex='4c8b3d7bb3cc02'},
{m='g',rva=6664973,hex='8bda'},
{m='g',rva=6665120,hex='e8db662c00'},
{m='g',rva=6665140,hex='428b9431f0020000'},
{m='g',rva=6665148,hex='4289948df8000000'},
{m='g',rva=6665213,hex='492100'},
{m='g',rva=6665294,hex='e8bdaa2c00'},
{m='g',rva=6665360,hex='e84b415800'},
{m='g',rva=7888400,hex='448b4138'},
{m='g',rva=7888404,hex='448b5140'},
{m='g',rva=7888442,hex='4c8b5930'},
{m='g',rva=7888451,hex='448b713c'},
{m='g',rva=7888511,hex='458b7104'},
{m='g',rva=7888539,hex='488b4560'},
{m='g',rva=7888547,hex='4d69ced0010000'},
{m='g',rva=7888554,hex='49c1e204'},
{m='g',rva=7888570,hex='41893c02'},
{m='g',rva=8801990,hex='c744242800000000'},
{m='g',rva=8802002,hex='e899a2a300'},
{m='g',rva=8843931,hex='418944240c'},
{m='g',rva=8843936,hex='8b4708'},
{m='g',rva=8843943,hex='8944d13c'},
{m='g',rva=8848323,hex='8b4cc83c'},
{m='g',rva=8855706,hex='488b1d7f48ab02'},
{m='g',rva=8855716,hex='8b4318'},
{m='g',rva=8855755,hex='488b4348'},
{m='g',rva=8855762,hex='4b8d0cc0'},
{m='g',rva=8855802,hex='488b4340'},
{m='g',rva=8925963,hex='418984b630600000'},
{m='g',rva=8926498,hex='4c8b1d2730aa02'},
{m='g',rva=8926635,hex='498b84c330400000'},
{m='g',rva=8926667,hex='8b500c'},
{m='g',rva=8927277,hex='f6401401'},
{m='g',rva=8927295,hex='f6819000000001'},
{m='g',rva=8927308,hex='8b5008'},
{m='g',rva=9220479,hex='458b4e08'},
{m='g',rva=9220487,hex='458b4724'},
{m='g',rva=9220491,hex='488b0dc623ba02'},
{m='g',rva=9220561,hex='4b8b442c30'},
{m='g',rva=9220588,hex='438b442c2c'},
{m='g',rva=9555851,hex='41899c309c010000'},
{m='g',rva=9557549,hex='486be91c'},
{m='g',rva=9557574,hex='4803af60100000'},
{m='g',rva=9557652,hex='8b4514'},
{m='g',rva=9557662,hex='41894514'},
{m='g',rva=9562647,hex='41f644241401'},
{m='g',rva=9562684,hex='e80f860000'},
{m='g',rva=9562758,hex='0f4cc8'},
{m='g',rva=9575213,hex='480568020000'},
{m='g',rva=9575236,hex='b8ffffffff'},
{m='g',rva=9576268,hex='4a8b44c020'},
{m='g',rva=9576278,hex='3c02'},
{m='g',rva=9582156,hex='8b85200b0000'},
{m='g',rva=9583648,hex='49894738'},
{m='g',rva=9583668,hex='45897930'},
{m='g',rva=9583720,hex='488d87d0030000'},
{m='g',rva=9583747,hex='413bca'},
{m='g',rva=9584388,hex='8b8482f8000000'},
{m='g',rva=9584405,hex='4489ac8af8000000'},
{m='g',rva=9587992,hex='4489a8a4010000'},
{m='g',rva=9588542,hex='894844'},
{m='g',rva=9588552,hex='48894850'},
{m='g',rva=9588560,hex='897848'},
{m='g',rva=9590119,hex='498b5638'},
{m='g',rva=9597170,hex='83bc019c01000002'},
{m='g',rva=9603729,hex='448b8720100000'},
{m='g',rva=9603798,hex='f6411401'},
{m='g',rva=10136182,hex='448b4930'},
{m='g',rva=10136186,hex='448b5138'},
{m='g',rva=10136221,hex='4c8b5928'},
{m='g',rva=10136229,hex='8b7934'},
{m='g',rva=10136311,hex='48c1e104'},
{m='g',rva=10136330,hex='4d8b7d50'},
{m='g',rva=10136591,hex='41896f1c'},
{m='g',rva=10136649,hex='8b3a'},
{m='g',rva=10136653,hex='8b7a04'},
{m='g',rva=10137427,hex='488b0dc6b49702'},
{m='g',rva=10178950,hex='f3410f114500'},
{m='g',rva=10818074,hex='e83163a5ff'},
{m='g',rva=11100258,hex='488b0dcf068902'},
{m='g',rva=11218906,hex='4c8d34dd307f1402'},
{m='g',rva=11219100,hex='899f1cc20a00'},
{m='g',rva=11228591,hex='e83c1e9400'},
{m='g',rva=11231160,hex='498d8ef8dac901'},
{m='g',rva=11231167,hex='e8bc019100'},
{m='g',rva=11322981,hex='48c1e005'},
{m='g',rva=11322988,hex='428b9430a8030000'},
{m='g',rva=11323157,hex='488b05849f8502'},
{m='g',rva=11323171,hex='397808'},
{m='g',rva=11323176,hex='488b4838'},
{m='g',rva=11323185,hex='f6411401'},
{m='g',rva=11357257,hex='8b4840'},
{m='g',rva=12297966,hex='e8cd6e8200'},
{m='g',rva=16620452,hex='4c8b1ded234902'},
{m='g',rva=16620489,hex='458b93d02ef200'},
{m='g',rva=16620503,hex='418b9bd82ef200'},
{m='g',rva=16620537,hex='498bbbc82ef200'},
{m='g',rva=16620544,hex='418bb3d42ef200'},
{m='g',rva=16620617,hex='8b4004'},
{m='g',rva=16620624,hex='488d80e4651e00'},
{m='g',rva=16620880,hex='4c8b1541224902'},
{m='g',rva=16620904,hex='458b8ab8aef100'},
{m='g',rva=16620931,hex='498b9ab0aef100'},
{m='g',rva=16621019,hex='488d80e3651e00'},
{m='g',rva=17623767,hex='81fa08070000'},
{m='g',rva=17623798,hex='ba25010000'},
{m='g',rva=17623816,hex='e833e70d00'},
{m='g',rva=18474486,hex='48c744243000000000'},
{m='g',rva=18474514,hex='e839a92000'},
{m='g',rva=18535033,hex='448bf2'},
{m='g',rva=18535446,hex='458bc6'},
{m='g',rva=18535524,hex='e817362100'},
{m='g',rva=18538636,hex='488b157d821702'},
{m='g',rva=18538653,hex='488b4210'},
{m='g',rva=18538659,hex='ffd0'},
{m='g',rva=18538796,hex='f20f100574bc5e02'},
{m='g',rva=18538833,hex='f20f10053f050701'},
{m='g',rva=18538850,hex='f30f1005068c2101'},
{m='g',rva=18538870,hex='c784248800000000000000'},
{m='g',rva=18538881,hex='c784248000000009000000'},
{m='g',rva=18538892,hex='4489742478'},
{m='g',rva=18538915,hex='4533c0'},
{m='g',rva=18538952,hex='488b440138'},
{m='g',rva=18538957,hex='4889442440'},
{m='g',rva=18538970,hex='418d5006'},
{m='g',rva=18538974,hex='c644242801'},
{m='g',rva=18538987,hex='e820170f00'},
{m='g',rva=19526030,hex='488b35a3dd1d02'},
{m='g',rva=19526041,hex='488b0580740802'},
{m='g',rva=19526168,hex='8b8634112000'},
{m='g',rva=19526174,hex='3d00100000'},
{m='g',rva=19526232,hex='891f'},
{m='g',rva=19526234,hex='896f04'},
{m='g',rva=19526255,hex='f30f115f14'},
{m='g',rva=19526787,hex='e828a08eff'},
{m='g',rva=19526797,hex='e84ec994ff'},
{m='g',rva=19527985,hex='443b0de8421e02'},
{m='g',rva=19527995,hex='488b3df6d51d02'},
{m='g',rva=19528014,hex='488b05336d0802'},
{m='g',rva=19528126,hex='0f84f6020000'},
{m='g',rva=19528132,hex='8b8720112000'},
{m='g',rva=19528138,hex='3d00100000'},
{m='g',rva=19528143,hex='0f83e5020000'},
{m='g',rva=19528174,hex='486bf070'},
{m='g',rva=19528194,hex='448ba5af000000'},
{m='g',rva=19528236,hex='8b4557'},
{m='g',rva=19528254,hex='894593'},
{m='g',rva=19528374,hex='448964243c'},
{m='g',rva=19528384,hex='44897c2444'},
{m='g',rva=19528598,hex='4585f6'},
{m='g',rva=19558167,hex='8b8120112000'},
{m='g',rva=19558307,hex='e8980d0000'},
{m='g',rva=19561838,hex='8b4a0c'},
{m='g',rva=19561852,hex='488b05b5e50702'},
{m='g',rva=19561859,hex='488b5018'},
{m='g',rva=19561880,hex='488b5078'},
{m='g',rva=19561922,hex='413b06'},
{m='g',rva=19561944,hex='f6401401'},
{m='g',rva=19563139,hex='89442460'},
{m='g',rva=19563243,hex='e800b367ff'},
{m='g',rva=19564362,hex='488b059f471d02'},
{m='g',rva=19564369,hex='483b8898b30000'},
{m='g',rva=20615039,hex='4c8b25223f0d02'},
{m='g',rva=20615055,hex='41807c242800'},
{m='g',rva=20615067,hex='4883bd100a000000'},
{m='g',rva=20616981,hex='488d0d54df4102'},
{m='g',rva=20616988,hex='4a8b0cf9'},
{m='g',rva=20617068,hex='895da8'},
{m='g',rva=20617071,hex='895dac'},
{m='g',rva=20617110,hex='e895000000'},
{m='g',rva=20712070,hex='8b4120'},
{m='g',rva=20712079,hex='3d00010000'},
{m='g',rva=20712128,hex='4969fa98000000'},
{m='g',rva=20712145,hex='f20f11440f28'},
{m='g',rva=20712155,hex='4489440f34'},
{m='g',rva=20712207,hex='4889441f40'},
{m='g',rva=20712229,hex='44894c1f38'},
{m='g',rva=20712244,hex='894c1f3c'},
{m='g',rva=20712885,hex='3da7010000'},
{m='g',rva=20712896,hex='4c8bb4c120c97c03'},
{m='g',rva=20731021,hex='ba08000000'},
{m='g',rva=20731051,hex='8b4120'},
{m='g',rva=20731056,hex='0f42d0'},
{m='g',rva=20731069,hex='895124'},
{m='g',rva=20734389,hex='8b4924'},
{m='g',rva=20735533,hex='443bf1'},
{m='g',rva=20735943,hex='2bd9'},
{m='g',rva=20735977,hex='e80221cd00'},
{m='g',rva=20735988,hex='895e20'},
{m='g',rva=20736001,hex='44896624'},
{m='g',rva=20737400,hex='448bc6'},
{m='g',rva=20737508,hex='e8979cffff'},
{m='g',rva=20846141,hex='0f8dd6000000'},
{m='g',rva=20847460,hex='4c8b1dbdb90802'},
{m='g',rva=20847583,hex='488d0449'},
{m='g',rva=20847587,hex='410fb684837f5f0c00'},
{m='g',rva=20848695,hex='41884707'},
{m='g',rva=20848993,hex='8b9c96785f0c00'},
{m='g',rva=20936257,hex='488d8fd898c700'},
{m='g',rva=20936264,hex='e8d3ddfcff'},
{m='g',rva=20936322,hex='e9593afbff'},
{m='g',rva=20938078,hex='e88df1eaff'},
{m='g',rva=24320618,hex='448b4108'},
{m='g',rva=24320624,hex='448b5110'},
{m='g',rva=24320644,hex='4c8b19'},
{m='g',rva=24320647,hex='8b590c'},
{m='g',rva=24320665,hex='488d0c92'},
{m='g',rva=5251605,hex='488b057c9df602'},
{m='g',rva=5251615,hex='4c8b90002af100'},
{m='g',rva=5251622,hex='48b81b61b9a711967b1a'},
{m='g',rva=5251651,hex='6bc03a'},
{m='g',rva=5251667,hex='48c1e004'},
{m='g',rva=5251700,hex='83f839'},
{m='g',rva=5251707,hex='4183f93a'},
{m='g',rva=5251724,hex='4869c198000000'},
{m='g',rva=5251731,hex='4805a0030000'},
{m='g',rva=5252914,hex='4c8b1daf3ee202'},
{m='g',rva=5252939,hex='458b4b68'},
{m='g',rva=5252943,hex='418b5b70'},
{m='g',rva=5252964,hex='498b7b60'},
{m='g',rva=5252968,hex='418b736c'},
{m='g',rva=5253042,hex='4869c098000000'},
{m='g',rva=5253049,hex='490383a0000000'},
{m='g',rva=5253061,hex='498b0a'},
{m='g',rva=5253068,hex='e93ffaffff'},
{m='g',rva=7612994,hex='4c8b0dff3bbe02'},
{m='g',rva=7613003,hex='458b4128'},
{m='g',rva=7613007,hex='458b5130'},
{m='g',rva=7613024,hex='4d8b5920'},
{m='g',rva=7613028,hex='418b792c'},
{m='g',rva=7613103,hex='498b4150'},
{m='g',rva=7613107,hex='488d1449'},
{m='g',rva=7613111,hex='8b6c9004'},
{m='g',rva=7792474,hex='488b4d38'},
{m='g',rva=7792496,hex='8b9090000000'},
{m='g',rva=7792565,hex='488b4d50'},
{m='g',rva=7792569,hex='4b8d3476'},
{m='g',rva=7792604,hex='ba8b9164ec'},
{m='g',rva=7792609,hex='893cb0'},
{m='g',rva=8171400,hex='448b4120'},
{m='g',rva=8171404,hex='448b4928'},
{m='g',rva=8171423,hex='4c8b5618'},
{m='g',rva=8171427,hex='448b5e24'},
{m='g',rva=8171482,hex='488b6e38'},
{m='g',rva=8171498,hex='4969fee0000000'},
{m='g',rva=8171773,hex='891c2f'},
{m='g',rva=8171797,hex='c6442f1001'},
{m='g',rva=8171845,hex='e896589800'},
{m='g',rva=8911263,hex='448b5128'},
{m='g',rva=8911267,hex='448b5930'},
{m='g',rva=8911302,hex='4c8b4120'},
{m='g',rva=8911306,hex='448b492c'},
{m='g',rva=8911379,hex='498b4738'},
{m='g',rva=8911387,hex='f6411401'},
{m='g',rva=8911397,hex='498b4750'},
{m='g',rva=8911421,hex='428b0ce9'},
{m='g',rva=8913591,hex='41c706c3ec04f6'},
{m='g',rva=8913605,hex='e806d51200'},
{m='g',rva=8913616,hex='e84b121300'},
{m='g',rva=8913634,hex='e8e9d91200'},
{m='g',rva=8913643,hex='41c706909efef9'},
{m='g',rva=8913684,hex='41c7064aec8bf5'},
{m='g',rva=8916526,hex='4c8b0d0359aa02'},
{m='g',rva=8916683,hex='49037950'},
{m='g',rva=8916687,hex='3907'},
{m='g',rva=8916695,hex='8b17'},
{m='g',rva=8916700,hex='e88f70edff'},
{m='g',rva=8916886,hex='394704'},
{m='g',rva=8916895,hex='8b5704'},
{m='g',rva=8917054,hex='8b470c'},
{m='g',rva=8917165,hex='e83e170400'},
{m='g',rva=8917170,hex='83f817'},
{m='g',rva=8917175,hex='8b570c'},
{m='g',rva=8917181,hex='e8aeecffff'},
{m='g',rva=8917202,hex='394708'},
{m='g',rva=8917207,hex='8b5708'},
{m='g',rva=8917223,hex='e8c4c91200'},
{m='g',rva=9956872,hex='448b7020'},
{m='g',rva=9956959,hex='4c8b35ba7e9a02'},
{m='g',rva=9956975,hex='498d8ef8000000'},
{m='g',rva=9957006,hex='498dbe70e15300'},
{m='g',rva=9957013,hex='4869c838120000'},
{m='g',rva=9957026,hex='e859420c00'},
{m='g',rva=9957038,hex='e89d430c00'},
{m='g',rva=9957054,hex='e81d4a0c00'},
{m='g',rva=10132699,hex='4c8b1d56ca9702'},
{m='g',rva=10132708,hex='458b5330'},
{m='g',rva=10132715,hex='418b5b38'},
{m='g',rva=10132732,hex='498b7b28'},
{m='g',rva=10132736,hex='418b7334'},
{m='g',rva=10132830,hex='488d0c40'},
{m='g',rva=10132834,hex='498b4350'},
{m='g',rva=10132838,hex='4803c9'},
{m='g',rva=10132841,hex='8b4cc80c'},
{m='g',rva=10147812,hex='4c8b154d8f9702'},
{m='g',rva=10147939,hex='49035a50'},
{m='g',rva=10147949,hex='e82ea2daff'},
{m='g',rva=10147976,hex='e813a2daff'},
{m='g',rva=10148003,hex='e8f8a1daff'},
{m='g',rva=10148170,hex='83f817'},
{m='g',rva=10148197,hex='b001'},
{m='g',rva=10148543,hex='488b3d728c9702'},
{m='g',rva=10148678,hex='488b4740'},
{m='g',rva=10148686,hex='f6411401'},
{m='g',rva=10148709,hex='48036f50'},
{m='g',rva=10148713,hex='48837d2800'},
{m='g',rva=10148759,hex='e8f4f1b5ff'},
{m='g',rva=10148776,hex='488b5758'},
{m='g',rva=10148797,hex='448b24f2'},
{m='g',rva=10148989,hex='baf98220d9'},
{m='g',rva=10148994,hex='892cf0'},
{m='g',rva=10760475,hex='4c8b15fe3b8e02'},
{m='g',rva=10760491,hex='458b8a00010000'},
{m='g',rva=10760506,hex='418b9a08010000'},
{m='g',rva=10760539,hex='498bbaf8000000'},
{m='g',rva=10760546,hex='418bb204010000'},
{m='g',rva=10760618,hex='4869c138120000'},
{m='g',rva=10760625,hex='428b841088e85300'},
{m='g',rva=10760633,hex='48c1e815'},
{m='g',rva=10760637,hex='2401'},
{m='g',rva=10760672,hex='e81bffffff'},
{m='g',rva=10760684,hex='e85f000000'},
{m='g',rva=10760699,hex='e8e0060000'},
{m='g',rva=10760704,hex='b001'},
{m='g',rva=10760961,hex='48b900025b87f79a9d1f'},
{m='g',rva=10760971,hex='4a858c1888e85300'},
{m='g',rva=10760979,hex='4a8b941880e85300'},
{m='g',rva=10760987,hex='48b80000010001000000'},
{m='g',rva=10761010,hex='f6c202'},
{m='g',rva=10761577,hex='8b05ed06a402'},
{m='g',rva=10761583,hex='41394508'},
{m='g',rva=10761739,hex='e8b066f6ff'},
{m='g',rva=10762208,hex='e8abc9e3ff'},
{m='g',rva=10762323,hex='e8b8eeabff'},
{m='g',rva=10762330,hex='8b4824'},
{m='g',rva=10762333,hex='41894d04'},
{m='g',rva=10762340,hex='e877000000'},
{m='g',rva=10762636,hex='4c8bacd710010000'},
{m='g',rva=10763039,hex='4d85e4'},
{m='g',rva=10763044,hex='418b442404'},
{m='g',rva=10763049,hex='41894608'},
{m='g',rva=10763053,hex='418b442408'},
{m='g',rva=10763058,hex='4189460c'},
{m='g',rva=10763062,hex='458b0424'},
{m='g',rva=10763066,hex='45894604'},
{m='g',rva=10763120,hex='41b901000000'},
{m='g',rva=10763126,hex='418b5508'},
{m='g',rva=10763130,hex='488b0dbf2a8e02'},
{m='g',rva=10763143,hex='e8b473d8ff'},
{m='g',rva=10763362,hex='8b05f4ffa302'},
{m='g',rva=10763368,hex='41394608'},
{m='g',rva=17977987,hex='e8d8e50700'},
{m='g',rva=17977995,hex='e830ad0800'},
{m='g',rva=18156007,hex='ffca'},
{m='g',rva=18156009,hex='81fa320b0000'},
{m='g',rva=18156028,hex='418b949284c71501'},
{m='g',rva=18200482,hex='e8a999fcff'},
{m='g',rva=18200499,hex='e8589afcff'},
{m='g',rva=18215056,hex='9fb71501'},
{m='g',rva=18215060,hex='b0b71501'},
{m='g',rva=18496201,hex='e8a2be6dff'},
{m='g',rva=18547052,hex='e8af0c6dff'}
}

-- ============================================================ small helpers
local function mul32(a, c)
    local low, high = c % 65536, math.floor(c / 65536)
    return (a * low + ((a * high) % 65536) * 65536) % 4294967296
end
local function power_of_two(n)
    if n < 1 or n % 1 ~= 0 then return false end
    while n > 1 do
        if n % 2 ~= 0 then return false end
        n = n / 2
    end
    return true
end
local function hex_bytes(hex)
    local bytes = hex:gsub('%x%x', function(cc) return string.char(tonumber(cc, 16)) end)
    return bytes
end

local f32_bytes = ffi.new('uint8_t[4]')
local f32_value = ffi.cast('float *', f32_bytes)
local function f32(s, o)
    f32_bytes[0] = s:byte(o + 1)
    f32_bytes[1] = s:byte(o + 2)
    f32_bytes[2] = s:byte(o + 3)
    f32_bytes[3] = s:byte(o + 4)
    return tonumber(f32_value[0])
end
local function u32(s, o)
    if #s < o + 4 then return nil end
    return s:byte(o + 1) + s:byte(o + 2) * 256 + s:byte(o + 3) * 65536 + s:byte(o + 4) * 16777216
end
local function u64(s, o)
    local low = u32(s, o)
    local high = u32(s, o + 4)
    if not low or not high then return nil end
    return low + high * 4294967296
end
local function i32v(v)
    if v == nil then return nil end
    if v >= 2147483648 then return v - 4294967296 end
    return v
end

-- ============================================================ native bindings
local kernel, cdef_error
do
    local ok, err = pcall(function()
        ffi.cdef [[
            void *ehb3_GetCurrentProcess(void) __asm__("GetCurrentProcess");
            int ehb3_ReadProcessMemory(void *process, const void *address, void *buffer,
                size_t size, size_t *read) __asm__("ReadProcessMemory");
            void *ehb3_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
            uint64_t ehb3_GetTickCount64(void) __asm__("GetTickCount64");
        ]]
        kernel = ffi.load('kernel32')
    end)
    if not ok then
        cdef_error = tostring(err)
        kernel = nil
    end
end

local process
local function ensure_process()
    if not process and kernel then process = kernel.ehb3_GetCurrentProcess() end
    return process
end
local function now_ms()
    if TEST and TEST.now then return TEST.now() end
    if kernel then return tonumber(kernel.ehb3_GetTickCount64() % 2147483648) end
    return math.floor(os.clock() * 1000)
end

-- One resilient read. nil for any failure; callers treat nil as "unreadable, stay passive".
-- (TEST.read, when present, replaces the native read completely.)
local read_counter = 0
local function rd(address, size)
    read_counter = read_counter + 1
    if TEST and TEST.read then return TEST.read(address, size) end
    if type(address) ~= 'number' or address <= 0 or address > 9007199254740991 then return nil end
    if type(size) ~= 'number' or size <= 0 or size > 65536 then return nil end
    if not ensure_process() then return nil end
    local buffer = ffi.new('uint8_t[?]', size)
    local got = ffi.new('size_t[1]')
    local ok, result = pcall(function()
        return kernel.ehb3_ReadProcessMemory(process, ffi.cast('const void *', address), buffer, size, got)
    end)
    if not ok or result == 0 or tonumber(got[0]) ~= size then return nil end
    return ffi.string(buffer, size)
end
local function r32(address) local s = rd(address, 4); return s and u32(s, 0) end
local function r64(address) local s = rd(address, 8); return s and u64(s, 0) end
local function proves(address, hex)
    local s = rd(address, math.floor(#hex / 2))
    if not s then return false end
    return s == hex_bytes(hex)
end

-- ============================================================ module bases
local game, exe, opened = nil, nil, false
local image_override = nil
local last_call_ms = nil

local function module_base(name)
    if TEST and TEST.modules then return TEST.modules(name) end
    if not kernel then return nil end
    local handle = kernel.ehb3_GetModuleHandleA(name)
    if handle == nil then return nil end
    local address = tonumber(ffi.cast('uintptr_t', handle))
    if not address or address == 0 then return nil end
    return address
end
local function check_module(base, expected, label)
    local header = rd(base, 4096)
    if not header or header:sub(1, 2) ~= 'MZ' then return nil, label .. ': DOS header unreadable' end
    local pe = u32(header, 60)
    if not pe or pe < 64 or pe + 88 > #header or header:sub(pe + 1, pe + 4) ~= 'PE\0\0' then
        return nil, label .. ': PE header unreadable'
    end
    if u32(header, pe + 80) ~= expected then return nil, label .. ': image size changed' end
    return true
end

-- ============================================================ game state / players
local function game_state()
    local g = r64(game + N.state.game)
    if not g or g == 0 then return nil end
    local value = r32(g + N.state.state)
    if not value or value > 16 then return nil end
    local state = { mission = false }
    if value ~= N.state.mission then return state end
    local mode = r64(game + N.state.game_mode)
    if not mode or mode == 0 then return state end
    if r32(mode + N.state.mode_count) ~= 1 then return state end
    state.mission = true
    local descriptor = r64(mode + N.state.mode_descriptor)
    local flags = descriptor and r32(descriptor + N.state.mode_flags)
    state.host = flags ~= nil and flags % 2 == 1 or nil
    return state
end
local function local_peer()
    local user = r64(game + N.players.local_user)
    if not user or user == 0 then return nil end
    local s = rd(user + N.players.local_peer, 8)
    if not s then return nil end
    return u32(s, 0), u32(s, 4)
end
local function network_entity(nid)
    if not nid or nid == N.avatars.no_network_id then return nil end
    local manager = r64(game + N.avatars.entities)
    if not manager or manager == 0 then return nil end
    local header = rd(manager + N.avatars.map_slots, 20)
    if not header then return nil end
    local slots = u64(header, 0)
    local capacity, empty, multiplier = u32(header, 8), u32(header, 12), u32(header, 16)
    if not slots or not capacity or slots == 0 or capacity == 0 or capacity > 1048576 or capacity % 2 ~= 0 then
        return nil
    end
    local start = mul32(nid, multiplier)
    for probe = 0, math.min(capacity, 4096) - 1 do
        local bytes = rd(slots + ((start + probe) % capacity) * 8, 8)
        if not bytes then return nil end
        local key = u32(bytes, 0)
        if key == nid then
            local index = u32(bytes, 4)
            return r32(manager + N.avatars.entity_base + index * N.avatars.entity_stride)
        end
        if key == empty then return nil end
    end
    return nil
end
local function players(with_avatars)
    local manager = r64(game + N.players.global)
    if not manager or manager == 0 then return nil, 'the player list is unreadable' end
    local count = r32(manager + N.players.count)
    if not count or count > N.players.max then return nil, 'the player count is implausible' end
    local lo, hi = local_peer()
    local list = {}
    for slot = 0, count - 1 do
        local block = rd(manager + N.players.peers + slot * N.players.peer_stride, N.players.peer_stride)
        if block then
            local plo, phi = u32(block, 0), u32(block, 4)
            local descriptor = r64(manager + N.players.descriptors + slot * 8)
            local entry = {
                slot = slot, peer_lo = plo, peer_hi = phi,
                entity = descriptor and r32(descriptor + N.players.descriptor_entity) or nil,
                lifecycle = u32(block, N.avatars.lifecycle - N.players.peers),
                ["local"] = (lo ~= nil and plo == lo and phi == hi) or false,
            }
            if with_avatars then
                local nid = r32(manager + N.avatars.avatar_id + slot * N.avatars.avatar_id_stride)
                entry.avatar_network_id = nid
                entry.avatar = nid and network_entity(nid) or nil
            end
            list[#list + 1] = entry
        end
    end
    return list
end

-- ============================================================ engine identity
local function entity_exists(id)
    if type(id) ~= 'number' or id <= 0 or id >= 4294967296 then return false end
    local index, generation = id % 4194304, math.floor(id / 4194304) % 256
    local manager = r64(exe + N.engine.entities)
    if not manager or manager == 0 then return nil end
    local size = r32(manager + N.engine.generation_size)
    local bytes = r64(manager + N.engine.generations)
    if not size or not bytes or bytes == 0 then return nil end
    if index >= size then return false end
    local current = rd(bytes + index, 1)
    if not current then return nil end
    return current:byte(1) == generation
end
local function unit_position(unit)
    if type(unit) ~= 'number' or unit <= 0 or unit >= 4294967296 then return nil end
    local index, generation = unit % 4194304, math.floor(unit / 4194304) % 256
    local registry = r64(exe + N.engine.units)
    if not registry or registry == 0 then return nil end
    local count = r32(registry + N.engine.unit_count)
    local generations = r64(registry + N.engine.unit_generations)
    local objects = r64(registry + N.engine.unit_objects)
    if not count or not generations or not objects or generations == 0 or objects == 0 or index >= count then
        return nil
    end
    local current = rd(generations + index, 1)
    if not current or current:byte(1) ~= generation then return nil end
    local object = r64(objects + index * 8)
    if not object or object == 0 then return nil end
    if r32(object + N.engine.unit_id) ~= unit then return nil end
    local vtable = r64(object)
    if not vtable or vtable == 0 then return nil end
    local method = r64(vtable + 0xE8)
    if method ~= exe + N.scene_graph.rva then return nil end
    if not proves(method, N.scene_graph.bytes) then return nil end
    local poses = r64(object + N.engine.scene_graph_offset + N.engine.poses)
    if not poses or poses == 0 then return nil end
    local bytes = rd(poses + N.engine.translation, 12)
    if not bytes then return nil end
    local x, y, z = f32(bytes, 0), f32(bytes, 4), f32(bytes, 8)
    if x ~= x or y ~= y or z ~= z
        or math.abs(x) > 100000 or math.abs(y) > 100000 or math.abs(z) > 100000 then
        return nil
    end
    return x, y, z
end

-- ============================================================ local avatar
-- A value in one of the game's open-addressed u32 hashes ({buckets u64, capacity, empty key,
-- multiplier}); nil when absent or unreadable.
local function hash_value(address, key)
    if type(key) ~= 'number' or key <= 0 or key >= 4294967296 or key % 1 ~= 0 then return nil end
    local header = rd(address, 20)
    if not header then return nil end
    local buckets = u64(header, 0)
    local capacity, empty, multiplier = u32(header, 8), u32(header, 12), u32(header, 16)
    if not buckets or buckets == 0 or capacity > 1048576 or not power_of_two(capacity) then return nil end
    local start = mul32(key, multiplier)
    for probe = 0, math.min(capacity, 4096) - 1 do
        local bytes = rd(buckets + ((start + probe) % capacity) * 8, 8)
        if not bytes then return nil end
        local found = u32(bytes, 0)
        if found == key then
            local value = u32(bytes, 4)
            if value == 4294967295 then return nil end
            return value
        end
        if found == empty then return nil end
    end
    return nil
end
-- An entity's unit through the game's own entity map (the descriptor's unit field), the same
-- map entity_type() reads.
local function entity_unit(entity)
    local manager = r64(game + N.wielder.entities)
    if not manager or manager == 0 then return nil end
    local index = hash_value(manager + N.wielder.entity_map, entity)
    if not index or index >= 0x100000 then return nil end
    local descriptor = rd(manager + N.wielder.descriptors + index * N.wielder.descriptor_stride,
        N.wielder.descriptor_stride)
    if not descriptor or u32(descriptor, N.wielder.descriptor_entity) ~= entity then return nil end
    local unit = u32(descriptor, N.wielder.descriptor_unit)
    return unit and unit ~= 0 and unit or nil
end
-- The local player's current avatar: the player list decides (its lifecycle says spawned
-- vs waiting_for_respawn), and the avatar entity comes from the player's network id through
-- the game's own map. Not every field is re-read everywhere: this is a per-poll helper.
local function local_avatar()
    local list, why = players(true)
    if not list then return nil, why end
    local me
    for i = 1, #list do
        if list[i]["local"] then me = list[i] break end
    end
    if not me then return nil, 'the local player is not in the player list' end
    if me.lifecycle == 2 then return nil, 'the local player is waiting for respawn' end
    local avatar = me.avatar
    if not avatar and image_override then avatar = me.entity end
    if not avatar then return nil, 'the local player has no avatar now' end
    if entity_exists(avatar) ~= true then return nil, 'the avatar entity is stale' end
    return {
        id = avatar, player_entity = me.entity,
        unit = entity_unit(avatar), alive = true,
    }
end

-- ============================================================ entity type / inventory
local function entity_type(entity)
    local manager = r64(game + N.wielder.entities)
    if not manager or manager == 0 then return nil end
    local index = hash_value(manager + N.wielder.entity_map, entity)
    if not index or index >= 0x100000 then return nil end
    local descriptor = rd(manager + N.wielder.descriptors + index * N.wielder.descriptor_stride,
        N.wielder.descriptor_stride)
    if not descriptor or u32(descriptor, N.wielder.descriptor_entity) ~= entity then return nil end
    return u32(descriptor, 0), u32(descriptor, 4)
end
local function inventory_record(avatar)
    local manager = r64(game + N.inventory.global)
    if not manager or manager == 0 then return nil end
    local index = hash_value(manager + N.inventory.hash, avatar)
    if not index or index >= 0x10000 then return nil end
    local array = r64(manager + N.inventory.descriptors)
    if not array or array == 0 then return nil end
    local dpointer = r64(array + index * 8)
    if not dpointer or dpointer == 0 then return nil end
    local descriptor = rd(dpointer, 24)
    if not descriptor or u32(descriptor, N.wielder.descriptor_entity) ~= avatar then return nil end
    local records = r64(manager + N.inventory.records)
    if not records or records == 0 then return nil end
    return rd(records + index * N.inventory.stride, N.inventory.stride)
end

-- ============================================================ stats: the player's shots
local SOURCE_BYTES = N.stats.source_blocks * N.stats.source_stride
local source_buffer = ffi.new('uint8_t[?]', SOURCE_BYTES)
local function read_sources(address)
    read_counter = read_counter + 1
    if TEST and TEST.read then
        local data = TEST.read(address, SOURCE_BYTES)
        return data and { kind = 's', data = data } or nil
    end
    if not ensure_process() then return nil end
    local got = ffi.new('size_t[1]')
    local ok, result = pcall(function()
        return kernel.ehb3_ReadProcessMemory(process, ffi.cast('const void *', address), source_buffer,
            SOURCE_BYTES, got)
    end)
    if not ok or result == 0 or tonumber(got[0]) ~= SOURCE_BYTES then return nil end
    return { kind = 'b', buf = source_buffer }
end
local function blob_u32(blob, o)
    if blob.kind == 's' then return u32(blob.data, o) end
    local b = blob.buf
    return b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216
end
local function stat_lookup(slots, capacity, empty, multiplier, key, stride, value_offset)
    if not slots or slots == 0 or capacity == 0 or capacity > 65536 or capacity % 2 ~= 0 then return nil end
    local start = mul32(key, multiplier)
    for probe = 0, capacity - 1 do
        local at = slots + ((start + probe) % capacity) * stride
        local bytes = rd(at, 8)
        if not bytes then return nil end
        local found = u32(bytes, 0)
        if found == key then return u32(bytes, value_offset) end
        if found == empty then return false end
    end
    return false
end
-- The player's fired-projectile total this mission, as the game's own get_stat sums it: the
-- main counter table plus every source block, with the Epoch's own source block counted
-- explicitly so an attribution quirk cannot hide the very shots that must re-arm the fuse.
local function shots_total(player_entity)
    local score = r64(game + N.stats.score)
    if not score or score == 0 then return nil end
    local map = rd(score + N.stats.index_slots, 20)
    if not map then return nil end
    local index = stat_lookup(u64(map, 0), u32(map, 8), u32(map, 12), u32(map, 16),
        player_entity, 8, 4)
    if index == nil or index == false or index >= N.stats.max_players then return nil end
    local record = rd(score + N.stats.record_base + index * N.stats.record_stride, N.stats.record_stride)
    if not record then return nil end
    local main = stat_lookup(u64(record, N.stats.table_entries), u32(record, N.stats.table_capacity),
        u32(record, N.stats.table_empty), u32(record, N.stats.table_multiplier),
        N.stats.key_fired, N.stats.entry_stride, N.stats.entry_value)
    if main == nil then return nil end
    local total = 0
    if main ~= false then total = i32v(main) end
    local sources = u64(record, N.stats.sources)
    if sources and sources ~= 0 then
        local blob = read_sources(sources)
        if not blob then return nil end
        for block = 0, N.stats.source_blocks - 1 do
            local base = block * N.stats.source_stride
            local lo, hi = blob_u32(blob, base), blob_u32(blob, base + 4)
            if lo ~= 0 or hi ~= 0 then
                for entry = 0, N.stats.source_entry_count - 1 do
                    local at = base + N.stats.source_entries + entry * N.stats.entry_stride
                    local key = blob_u32(blob, at)
                    if key == 0 then break end
                    if key == N.stats.key_fired and lo == K.epoch_type_lo and hi == K.epoch_type_hi then
                        total = total + (i32v(blob_u32(blob, at + N.stats.entry_value)) or 0)
                    end
                end
            end
        end
    end
    return total
end

-- ============================================================ the guarded native request
local function request_function()
    local entry = game + N.request.rva
    if not proves(entry, N.request.prologue) then return nil, 'the request function changed' end
    return entry
end
local function explosion_settings(kind)
    if type(kind) ~= 'number' or kind <= 0 or kind >= N.type_bound or kind % 1 ~= 0 then return nil end
    local record = r64(game + N.settings_table + kind * 8)
    if not record or record == 0 then return nil end
    if r32(record) ~= kind then return nil end
    return record
end

-- ============================================================ public API
function P.open(opts)
    if cdef_error then return nil, 'kernel32 bindings failed: ' .. tostring(cdef_error) end
    if not kernel then return nil, 'kernel32 unavailable' end
    -- opts.base is for the offline tests only (one flat image serves as both modules); the
    -- game always resolves the real module bases and checks their image sizes.
    image_override = type(opts) == 'table' and type(opts.base) == 'number' and opts.base or nil
    if image_override then
        game, exe = image_override, image_override
    else
        game = module_base('game.dll')
        if not game then return nil, 'game.dll is not loaded' end
        exe = module_base(nil)
        if not exe then return nil, 'the main module is not loaded' end
        local ok, why = check_module(game, K.game_image_size, 'game.dll')
        if not ok then return nil, why end
        ok, why = check_module(exe, K.exe_image_size, 'helldivers2.exe')
        if not ok then return nil, why end
    end
    if not proves(exe + N.scene_graph.rva, N.scene_graph.bytes) then
        return nil, 'the world-position accessor changed'
    end
    if not proves(game + N.request.rva, N.request.prologue) then
        return nil, 'the RequestExplosion prologue changed'
    end
    for i = 1, #PINS do
        local pin = PINS[i]
        local base = pin.m == 'g' and game or exe
        if not proves(base + pin.rva, pin.hex) then
            return nil, string.format('build pins mismatch (%d/%d at %s+0x%X)',
                i, #PINS, pin.m == 'g' and 'game.dll' or 'helldivers2.exe', pin.rva)
        end
    end
    opened = true
    read_counter = 0
    return true
end

-- { in_mission, host, peer_lo, peer_hi, alive, avatar, player_entity, x, y, z } or nil when
-- the structures are unreadable this tick.
function P.state()
    if not opened then return nil end
    local state = game_state()
    if not state then return nil end
    if not state.mission then return { in_mission = false, host = state.host } end
    local lo, hi = local_peer()
    if lo == nil then return nil end
    local avatar, why = local_avatar()
    if not avatar then
        return { in_mission = true, host = state.host, peer_lo = lo, peer_hi = hi,
                 alive = false, reason = why }
    end
    local x, y, z
    if avatar.unit then x, y, z = unit_position(avatar.unit) end
    return { in_mission = true, host = state.host, peer_lo = lo, peer_hi = hi,
             alive = true, avatar = avatar.id, player_entity = avatar.player_entity,
             x = x, y = y, z = z }
end

-- true when the local player's support slot holds the PLAS-45 Epoch right now;
-- false when it does not (drop, another weapon, a dead player); nil when unreadable.
function P.carried_epoch()
    if not opened then return false end
    local avatar = local_avatar()
    if not avatar then return false end
    local record = inventory_record(avatar.id)
    if not record then return nil end
    local support = u32(record, N.inventory.support)
    if not support or support == 0 then return false end
    if entity_exists(support) ~= true then return false end
    local lo, hi = entity_type(support)
    if not lo then return nil end
    return lo == K.epoch_type_lo and hi == K.epoch_type_hi
end

-- The local player's fired-projectile total (monotonic within a mission); nil when unreadable.
function P.shots_epoch()
    if not opened then return nil end
    local list = players(false)
    if not list then return nil end
    local me
    for i = 1, #list do
        if list[i]["local"] then me = list[i] break end
    end
    if not me or not me.entity then return nil end
    return shots_total(me.entity)
end

-- Request one explosion through the game's own RequestExplosion, with the checks HD2Runtime
-- proved: mission, host, the reviewed prologue bytes, queue headroom, the type's settings
-- record, a living local avatar and its peer. Returns true, or false and the reason.
function P.explode_at(kind, x, y, z)
    if not opened then return false, 'PROBE_NOT_READY' end
    local now = now_ms()
    if last_call_ms and now - last_call_ms < K.call_cooldown_ms then return false, 'RATE_LIMITED' end
    if type(kind) ~= 'number' or kind <= 0 or kind >= N.type_bound or kind % 1 ~= 0 then
        return false, 'BAD_KIND'
    end
    local function finite(v)
        return type(v) == 'number' and v == v and math.abs(v) <= 100000
    end
    if not (finite(x) and finite(y) and finite(z)) then return false, 'INVALID_POSITION' end
    local state = game_state()
    if not (state and state.mission) then return false, 'NOT_IN_MISSION' end
    if state.host ~= true then return false, 'HOST_ONLY' end
    local entry, why = request_function()
    if not entry then return false, why end
    local queue = r64(game + N.queue)
    if not queue or queue == 0 then return false, 'the explosion queue is unreadable' end
    local count = r32(queue + N.queue_count)
    if count == nil then return false, 'the explosion queue is unreadable' end
    if count >= N.queue_capacity then return false, 'QUEUE_FULL' end
    if not explosion_settings(kind) then return false, 'no settings record for type ' .. tostring(kind) end
    local avatar = local_avatar()
    if not avatar then return false, 'NO_LOCAL_AVATAR' end
    if entity_exists(avatar.id) ~= true then return false, 'NO_LOCAL_AVATAR' end
    local lo, hi = local_peer()
    if lo == nil then return false, 'the local peer is unreadable' end
    last_call_ms = now
    if TEST and TEST.call then
        TEST.call(kind, x, y, z, avatar.id, avatar.id, lo, hi)
        return true
    end
    local request = ffi.cast('void (*)(void *, const float *, uint32_t, uint32_t, uint32_t, '
        .. 'uint64_t, uint32_t, const float *, uint8_t, uint32_t, const uint32_t *, '
        .. 'const float *, const float *, uint8_t, uint32_t)', entry)
    local position = ffi.new('float[3]', x, y, z)
    local peer = ffi.new('uint64_t', hi) * 4294967296 + lo
    local ok, err = pcall(function()
        -- The argument template the game's own callers pass (request, position, type, source,
        -- owner, creditor peer, then 0, null, 1, 0, null, null, null, 0, 0).
        request(ffi.cast('void *', queue), position, kind, avatar.id, avatar.id, peer,
            0, nil, 1, 0, nil, nil, nil, 0, 0)
    end)
    if not ok then return false, 'the request call failed: ' .. tostring(err) end
    return true
end

function P.close() end

-- Exposed for the offline tests and the constant cross-check.
P.pins = PINS
P.blast_kind = K.blast_kind
P.constants = { K = K, N = N }
P.mul32 = mul32
P.read_count = function() return read_counter end

return P
