# 纪元定时炸弹 · 独立版（Epoch Timebomb Standalone）

《绝地潜兵 2》模组：把 **PLAS-45「纪元」** 变成一颗你能听见倒计时的定时炸弹。
只用 **Bingus Shared Loader v19**（LuaJIT + FFI），**不依赖 HD2Runtime**，**不扫内存**。

Turn the PLAS-45 Epoch into a beeping time bomb. Loader-only (Bingus Shared Loader),
no HD2Runtime, no memory scanning.

---

## 玩法（中文）

- 支援武器槽里带着「纪元」→ **7 秒引信**开始走；每秒一声"滴"，音调逐秒升高。
- 7 秒到点 → **在手里引爆**（游戏本体的纪元大爆炸：800/800、3/4/5 米）。
- **7 秒内用纪元开火 → 引信重置**（唯一解除方式）。
- **连续携带满 35 秒 → 强制引爆**（开枪无法推迟）；**扔掉武器解除一切**（同时清掉 7 秒引信）。
- 死亡 / 任务结束 / 离开任务 → 自动复位；重新捡起从零开始。
- 只在你是**房主**（单人 / 自己开的房）时生效。

## Gameplay (English)

- Carry the Epoch → a **7 s fuse** starts; one beep per second with rising pitch.
- At zero the Epoch **detonates in your hands** (the game's own big plasma blast, 800/800, 3/4/5 m).
- **Firing the Epoch re-arms the fuse** — that is the only way to cancel it.
- **35 s of uninterrupted carry is a hard blast** that shots cannot delay; **dropping the weapon
  cancels everything** (fuse included).
- Death / mission end resets the cycle. Host/solo scope only.

## 安装 / Install

1. Install Bingus Shared Loader v19+ (or a mod manager that drives it, e.g. Echelon / Arsenal).
2. Import `release/纪元定时炸弹-独立版v3.0-BSL版.zip`, enable and deploy it.
3. Restart the game. Log: `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\EpochTimebombStandalone.log`
   (success keywords: `PROBE_READY`, `FUSE_7S armed`, `OVERCHARGE_REQUESTED`).

中文安装/排错详解见 [docs/安装说明-中文.txt](docs/安装说明-中文.txt)。

## 它是怎么做到的（以及为什么不会卡）/ How it works

- **零内存扫描**：不遍历内存区域、不搜内容。所有数据来自 `game.dll` / `helldivers2.exe` 里
  **固定的 RVA**：玩家实体、装备槽、任务统计、单位坐标、爆炸队列。每 100 ms 读几十个 4 字节
  （≈每秒几 KB），一个复用缓冲，没有每帧分配、没有常驻大缓冲。
- **引爆** = 调用游戏自己的 `RequestExplosion`（与 HD2Runtime 相同的参数模板和前置校验）。
- **防游戏更新**：启动时逐条校验 **442 条指令字节 + 两个模块的 PE 大小**；每次引爆前再校验一次
  爆炸函数序言字节。任何一条不匹配 → 只写日志、完全不读不写（休眠），不会乱写内存。
- **提示音** = Windows 异步 `PlaySound`（启动时合成 7 个小波形），不占帧、不进游戏音频总线。
- 唯一"写/调用"就是那一次爆炸请求；其余全部只读。

## 目录 / Layout

| 路径 | 内容 |
| --- | --- |
| `src/game_probe.lua` | 固定地址读取层 + 引爆调用（移植自 HD2Runtime 的研究，见 THIRD_PARTY.md） |
| `src/addon.lua` | 状态机：7 秒引信 / 每秒提示音 / 35 秒硬炸 / 链式 update 钩子 |
| `tools/build.py` | 打包成 BSL 模组 zip（LuaJIT 编译校验 + 逐字节复验，可复现） |
| `tests/` | 离线测试：状态机 9 场景、442 条常量核对、模块冒烟；结果在 `tests/results/` |
| `release/` | 构建好的模组 zip |
| `docs/` | 中文安装说明 |

## 构建与测试 / Build & test

Windows + Python 3（需本机装有游戏以使用它的 `bin\lua51.dll`；可用环境变量 `HD2_LUA51` 覆盖）：

```bash
python tools/build.py            # 打包（可复现：与 release/ 里的 zip 逐字节一致）
python tests/run_tests.py        # 状态机 9/9
python tests/smoke_probe.py      # 模块加载/安全拒绝
set HD2RUNTIME_SRC=<你的 HD2Runtime 0.40.0 源码目录>
python tests/check_constants.py  # 442 条 pin 与研究文件逐条核对
```

`check_constants.py` 需要你自行下载 HD2Runtime 的源码（其研究文件按其自身许可，不在本仓库分发）。

## 版本绑定 / Version pinning

- 适配游戏 build `F5FEE03DCFDB`（`helldivers2.exe` 戳 `6AB382E4`，`game.dll` 戳 `6AB3B43F`；
  game.dll sha256 以 `2E2C3B7C…51E` 开头）。
- 游戏更新后所有 pin 会不匹配 → 模组自动休眠（只写日志）。按 `src/game_probe.lua` 顶部的注释
  更新偏移表即可恢复。

## 署名 / Credit（必需）

本模组的偏移/指令指纹/爆炸调用模板来自 **HD2Runtime by SkyeShade** 的研究成果，按其许可证
第 2 条使用并署名 / The offsets, instruction pins and the `RequestExplosion` template are
research findings reused from HD2Runtime under its license (section 2, credit required):

    Uses code / research from HD2Runtime by SkyeShade
    https://github.com/SkyeShade/HD2Runtime

不包含、也不再分发 HD2Runtime 本身。详见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 许可 / License

本仓库代码：MIT（见 [LICENSE](LICENSE)）。第三方研究数据的署名要求见上。

## 免责声明 / Disclaimer

非官方粉丝作品，与 Arrowhead Game Studios / Sony Interactive Entertainment 无关。
仅供单机/与朋友自用；使用风险自负。请勿用于破坏他人游戏体验的用途。
