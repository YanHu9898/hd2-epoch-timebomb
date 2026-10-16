# Third-party notices

## HD2Runtime (required credit)

This project reuses **research findings** of [HD2Runtime](https://github.com/SkyeShade/HD2Runtime)
by **SkyeShade**: the native offsets/RVAs of the game structures it reads (players, game state,
entity map, inventory, units/pose chain, mission stats, the explosion queue), the instruction-byte
"pins" that prove a game build, and the `RequestExplosion` argument template.

HD2Runtime's license allows copying or adapting parts of its code or findings **only with clear,
visible credit** (section 2). That credit is given here, in the README, and in the mod's own
manifest and source headers:

    Uses code / research from HD2Runtime by SkyeShade
    https://github.com/SkyeShade/HD2Runtime

HD2Runtime itself is **not** redistributed here (section 3 prohibits that). To run
`tests/check_constants.py` (which compares this project's tables against the original research
files) download HD2Runtime's source yourself and point `HD2RUNTIME_SRC` at it.

HD2Runtime's license text is at <https://github.com/SkyeShade/HD2Runtime/blob/main/LICENSE>.
If you reuse this project's probe layer, keep the credit above in place — removing or hiding it
ends the permission granted by HD2Runtime's license.

## Others

- [Bingus Shared Loader](https://github.com/CowboyBingus) loads the addon in game; not bundled.
- Helldivers 2 is a trademark of Sony Interactive Entertainment; this is an unofficial fan project.
