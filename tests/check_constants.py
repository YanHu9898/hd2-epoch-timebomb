"""Cross-check game_probe.lua's native constants against HD2Runtime 0.40.0 domain files.

The offline fixture tests would pass even if the probe and the fixture shared one transcribed
number, so this check compares the probe's tables with the generated research files directly
(brace-matched subtables, no Lua execution).
"""
import io
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(os.environ.get('HD2RUNTIME_SRC',
    r'C:\Users\hexua\AppData\Local\Temp\hd2runtime-src-040\src\HD2Runtime-0.40.0'))
PROBE = pathlib.Path(__file__).resolve().parent.parent / 'src' / 'game_probe.lua'
if not (ROOT / 'domains' / 'event_natives.lua').exists():
    sys.exit('HD2Runtime source not found at %s\nSet HD2RUNTIME_SRC to your HD2Runtime 0.40.0 source '
             'folder. Those research files stay under HD2Runtime\'s own license (credit required) and '
             'are not redistributed in this repository.' % ROOT)


def sub(text, opener):
    if text is None:
        return None
    i = text.find(opener)
    if i < 0:
        return None
    j = i + len(opener)
    depth = 1
    while depth > 0 and j < len(text):
        c = text[j]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        j += 1
    return text[i:j]


def rnum(text, key):
    if text is None:
        return None
    m = re.search(r'\["%s"\]\s*=\s*(-?\d+)' % re.escape(key), text)
    return int(m.group(1)) if m else None


def rstr(text, key):
    if text is None:
        return None
    m = re.search(r'\["%s"\]\s*=\s*"([^"]*)"' % re.escape(key), text)
    return m.group(1) if m else None


def pnum(text, key):
    if text is None:
        return None
    m = re.search(r'\b%s\s*=\s*(0x[0-9a-fA-F]+|-?\d+)' % re.escape(key), text)
    return int(m.group(1), 0) if m else None


def pstr(text, key):
    if text is None:
        return None
    m = re.search(r"\b%s\s*=\s*['\"]([^'\"]*)['\"]" % re.escape(key), text)
    return m.group(1) if m else None


def main():
    events = io.open(ROOT / 'domains' / 'event_natives.lua', encoding='utf-8').read()
    equipment = io.open(ROOT / 'domains' / 'player_equipment.lua', encoding='utf-8').read()
    catalogue = io.open(ROOT / 'domains' / 'explosion_catalogue.lua', encoding='utf-8').read()
    probe_src = PROBE.read_text(encoding='utf-8')

    def ptable(name):
        return sub(probe_src, '%s = {' % name)

    failures = []

    def check(label, got, expected):
        if got != expected:
            failures.append('%s: probe=%r research=%r' % (label, got, expected))

    def block(probe_table, research_text, pairs):
        for pk, rk in pairs:
            check(probe_table + '.' + pk, pnum(ptable(probe_table), pk), rnum(research_text, rk))

    players = sub(events, '["players"]={')
    block('players', players, [('global', 'global'), ('count', 'count'), ('peers', 'peers'),
                               ('peer_stride', 'peerStride'), ('descriptors', 'descriptors'),
                               ('descriptor_entity', 'descriptorEntity'), ('max', 'maxPlayers'),
                               ('local_user', 'localUser'), ('local_peer', 'localPeer')])

    avatars = sub(events, '["playerAvatars"]={')
    block('avatars', avatars, [('lifecycle', 'lifecycle'), ('avatar_id', 'avatarId'),
                               ('avatar_id_stride', 'avatarIdStride'),
                               ('no_network_id', 'noNetworkId'), ('entities', 'entities'),
                               ('map_slots', 'mapSlots'), ('entity_base', 'entityBase'),
                               ('entity_stride', 'entityStride')])

    state = sub(events, '["state"]={')
    block('state', state, [('game', 'game'), ('state', 'state'), ('mission', 'mission'),
                           ('game_mode', 'gameMode'), ('mode_count', 'gameModeCount'),
                           ('mode_descriptor', 'gameModeDescriptor'),
                           ('mode_flags', 'descriptorFlags'), ('mode_type', 'gameModeType')])

    engine = sub(events, '["engine"]={')
    block('engine', engine, [('entities', 'entities'), ('generation_size', 'generationSize'),
                             ('generations', 'generations'), ('units', 'units'),
                             ('unit_count', 'unitCount'), ('unit_generations', 'unitGenerations'),
                             ('unit_objects', 'unitObjects'), ('unit_id', 'unitId'),
                             ('scene_graph_offset', 'sceneGraphOffset'), ('poses', 'poses'),
                             ('translation', 'translation')])
    check('scene_graph.rva', pnum(ptable('scene_graph'), 'rva'), rnum(engine, 'sceneGraphMethod'))
    check('scene_graph.bytes', pstr(ptable('scene_graph'), 'bytes'),
          rstr(engine, 'sceneGraphMethodBytes'))

    stats = sub(events, '["stats"]={')
    block('stats', stats, [('score', 'score'), ('index_slots', 'indexSlots'),
                           ('record_base', 'recordBase'), ('record_stride', 'recordStride'),
                           ('max_players', 'maxPlayers'), ('table_entries', 'tableEntries'),
                           ('table_capacity', 'tableCapacity'), ('table_empty', 'tableEmpty'),
                           ('table_multiplier', 'tableMultiplier'), ('entry_stride', 'entryStride'),
                           ('entry_value', 'entryValue'), ('sources', 'sources'),
                           ('source_blocks', 'sourceBlocks'), ('source_stride', 'sourceStride'),
                           ('source_entries', 'sourceEntries'),
                           ('source_entry_count', 'sourceEntryCount')])
    key_fired = re.search(r'\["projectiles_fired"\]\s*=\s*(\d+)', stats)
    check('stats.key_fired', pnum(ptable('stats'), 'key_fired'),
          int(key_fired.group(1)) if key_fired else None)

    wielder = sub(events, '["wielder"]={')
    block('wielder', wielder, [('entities', 'entities'), ('entity_map', 'entityMap'),
                               ('descriptors', 'descriptors'),
                               ('descriptor_stride', 'descriptorStride'),
                               ('descriptor_entity', 'descriptorEntity')])
    equipment_descriptor = sub(sub(events, '["health"]={'), '["descriptor"]={')
    check('wielder.descriptor_unit', pnum(ptable('wielder'), 'descriptor_unit'),
          rnum(equipment_descriptor, 'unit'))

    explosion = sub(events, '["explosion"]={')
    check('request.rva', pnum(ptable('request'), 'rva'), rnum(explosion, 'rva'))
    check('request.prologue', pstr(ptable('request'), 'prologue'), rstr(explosion, 'prologue'))
    n_table = sub(probe_src, 'local N = {')
    check('queue', pnum(n_table, 'queue'), rnum(explosion, 'queue'))
    check('queue_count', pnum(n_table, 'queue_count'), rnum(explosion, 'count'))
    check('queue_capacity', pnum(n_table, 'queue_capacity'), rnum(explosion, 'capacity'))
    check('settings_table', pnum(n_table, 'settings_table'), rnum(explosion, 'settingsTable'))
    check('type_bound', pnum(n_table, 'type_bound'), rnum(explosion, 'typeBound'))

    inventory = sub(equipment, '["inventory"]={')
    block('inventory', inventory, [('global', 'global'), ('hash', 'hash'),
                                   ('descriptors', 'descriptors'), ('records', 'records'),
                                   ('stride', 'stride')])
    check('inventory.support', pnum(ptable('inventory'), 'support'),
          rnum(sub(inventory, '["slots"]={'), 'support'))

    entry = sub(catalogue, '["support_weapon/plas45_epoch/charge_2_expiry"]={')
    entry_type = re.search(r'\["type"\]\s*=\s*(\d+),\s*\["values"\]', entry) if entry else None
    check('catalogue charge_2_expiry type', int(entry_type.group(1)) if entry_type else None, 407)
    k_table = sub(probe_src, 'local K = {')
    check('K.blast_kind', pnum(k_table, 'blast_kind'), 407)
    check('K.epoch_type_lo', pnum(k_table, 'epoch_type_lo'), 0xD7780E54)
    check('K.epoch_type_hi', pnum(k_table, 'epoch_type_hi'), 0xE8D5F49A)
    check('K.game_image_size', pnum(k_table, 'game_image_size'), rnum(sub(events, '["source"]={'), 'imageSize'))
    check('K.exe_image_size', pnum(k_table, 'exe_image_size'), rnum(sub(events, '["source"]={'), 'exeImageSize'))

    probe_pins = set()
    for m in re.finditer(r"\{m='(g|e)',rva=(\d+),hex='([0-9a-f]+)'\}", probe_src):
        probe_pins.add((m.group(1), int(m.group(2)), m.group(3)))
    research_pins = set()
    for text in (events, equipment):
        for m in re.finditer(
                r'\{\["module"\]="(\w+)",\["rva"\]=(\d+),\["hex"\]="([0-9a-fA-F]+)",\["label"\]="(?:[^"\\]|\\.)*"\}',
                text):
            research_pins.add(('g' if m.group(1) == 'game' else 'e', int(m.group(2)),
                               m.group(3).lower()))
        for m in re.finditer(
                r'\{\["label"\]="(?:[^"\\]|\\.)*",\["rva"\]=(\d+),\["hex"\]="([0-9a-fA-F]+)",\["module"\]="(\w+)"\}',
                text):
            research_pins.add(('g' if m.group(3) == 'game' else 'e', int(m.group(1)),
                               m.group(2).lower()))
    if probe_pins != research_pins:
        missing = sorted(research_pins - probe_pins)[:5]
        extra = sorted(probe_pins - research_pins)[:5]
        failures.append('pins differ: %d missing %r, %d extra %r'
                        % (len(research_pins - probe_pins), missing,
                           len(probe_pins - research_pins), extra))

    if failures:
        print('CONSTANTS FAILED')
        for failure in failures:
            print('  ' + failure)
        return 1
    print('CONSTANTS OK: every table and all %d pins match the research files' % len(probe_pins))
    return 0


if __name__ == '__main__':
    sys.exit(main())
