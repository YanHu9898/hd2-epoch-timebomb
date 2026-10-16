-- Offline stub of game_probe.lua for the state-machine tests. Driven through _G.SIM.
local P = { revision = 'probe-stub/1.0', blast_kind = 407 }
local CALLS = { open = 0, state = 0, carried = 0, shots = 0, explode = {} }
_G.SIM_CALLS = CALLS
function P.open(opts)
    CALLS.open = CALLS.open + 1
    return _G.SIM.open_ready ~= false, _G.SIM.open_reason
end
function P.state()
    CALLS.state = CALLS.state + 1
    if _G.SIM.state then return _G.SIM.state(_G.SIM.now) end
    return nil
end
function P.carried_epoch()
    CALLS.carried = CALLS.carried + 1
    if _G.SIM.carried then return _G.SIM.carried(_G.SIM.now) end
    return false
end
function P.shots_epoch()
    CALLS.shots = CALLS.shots + 1
    if _G.SIM.shots then return _G.SIM.shots(_G.SIM.now) end
    return 0
end
function P.explode_at(kind, x, y, z)
    CALLS.explode[#CALLS.explode + 1] = { kind = kind, x = x, y = y, z = z, at = _G.SIM.now }
    if _G.SIM.explode_ok == false then return false, 'stub refusal' end
    return true
end
function P.close() end
return P
