# TouchBar Spectrum — KITT 红色声波频谱

在 MacBook Pro 的 **Touch Bar** 上实时显示系统播放音频的频谱可视化，视觉模仿《霹雳游侠》KITT 的红色声波扫描灯：从中心向两侧对称扩散的红色脉动条，带辉光、峰值缓慢回落、来回扫描律动，60fps 刷新。

原生 macOS 菜单栏后台应用（无 Dock 图标），Swift + AppKit + Core Graphics。

> 目标机型：2019 16" Intel MacBook Pro，macOS 15.7.2（24G325）。整套代码已在该环境上完成编译 + 链接 + 签名验证。

---

## 工作原理一图流

```
系统音频输出混音
   │  Core Audio Process Tap（macOS 14.2+，抓全系统混音，不影响你听声音）
   ▼                              ┌─ 降级：BlackHole 虚拟设备 (AVAudioEngine)
AudioTapManager ──── mono Float32 ─┤
   │                              └────────────┐
   ▼                                           ▼
RingBuffer(无锁 SPSC) ──► SpectrumAnalyzer(vDSP FFT/对数分箱/快攻慢落/峰值衰减)
                                   │ 64 段 0..1
                                   ▼
            VisualizerEngine(60fps) ──► TouchBarSpectrumView(KITT 渲染)
                                           ├─ 控制条常驻小号迷你扫描条（失焦也在）
                                           └─ 轻点展开 685pt 全宽大声波条
```

---

## 系统要求

- **带 Touch Bar 的 Mac**（2016–2019 的 13"/15"/16" MacBook Pro）。
- **macOS 15.0+**（开发目标 15.7.2）。Core Audio Process Tap 本身需 14.2+；本项目用了 `Synchronization.Atomic` 等 API，故下限设 15.0。
- 构建需要 **完整 Xcode**（推荐）**或** 仅 Command Line Tools + 本仓库的 `build.sh`（见下）。

---

## 两种构建方式

### 方式 A：用 `build.sh`（仅需 Command Line Tools，无需完整 Xcode）

你当前这台机器若只装了 Command Line Tools，直接：

```bash
./build.sh
open TouchBarSpectrum.app
# 想看日志就直接跑可执行文件：
# ./TouchBarSpectrum.app/Contents/MacOS/TouchBarSpectrum
```

`build.sh` 会用 `swiftc` 编译全部源码（带 bridging header）、组装 `.app`、解析 Info.plist 变量、用 entitlements 做 ad-hoc 签名。产物即 `./TouchBarSpectrum.app`。

### 方式 B：用 Xcode（推荐，可断点调试）

```bash
open TouchBarSpectrum.xcodeproj
```

选中 **TouchBarSpectrum** scheme → ⌘R 运行。工程已配置好 Info.plist、entitlements、bridging header、ad-hoc 签名、部署目标。

> 修改了文件结构 / 构建设置后，可由 `project.yml` 重新生成工程（需 `brew install xcodegen`）：
> ```bash
> xcodegen generate
> ```

---

## 首次运行：授予权限

1. 启动后 App 出现在菜单栏（一个 `waveform` 小图标），并开始捕获。
2. 首次捕获会触发系统的**音频捕获授权**弹窗（来自 `NSAudioCaptureUsageDescription`），点**允许**。
3. 若误拒或没弹：菜单 → **Open Privacy Settings…**，或手动到「系统设置 → 隐私与安全性」找到音频/录音相关项勾选本 App，然后菜单选 **Restart Capture**。

---

## 在 Touch Bar 上使用

- 启动后，**控制条**右侧常驻一个**小号红色 KITT 迷你扫描条**——即使你切到别的 App、本 App 失焦，它依然显示并随音乐跳动。
- **轻点它** → 展开成**铺满整条 Touch Bar** 的完整 KITT 大声波条（系统模态 `placement 1`，会盖过正在播放的媒体控制区）。再点小图标、或点大条 → 收起回小图标。
- 槽位的点击由一个 `NSButton` 承载（control strip 只把点击投递给 NSControl，不会投给裸 `NSView`）。
- 常驻是**每次启动重新注册**的（系统不持久化），所以 App 重启后会自动恢复。

> ⚠️ 平台硬约束：控制条常驻槽位只有 ~64pt 一个小位置，**无法**把 685pt 宽视图永久塞进去——全宽视图只能在「点击展开」时存在（与 Pock / MTMR 同款机制）。所以这里是「常驻迷你条 + 点击展开全宽」的设计。

---

## 音频源与 BlackHole 降级

菜单里可切换两种音频源：

- **Core Audio Tap (system mix)**（默认）：用官方 Process Tap 抓整个系统输出混音，**无需任何虚拟声卡**，也**不影响你正常听声音**。
- **BlackHole (fallback)**：当 Tap 异常时的降级路径。

### 何时会自动降级
内置「全零样本看门狗」：捕获启动后约 6 秒仍只收到全零样本 → 自动重建一次 tap；再约 6 秒仍全零 → **自动切换到 BlackHole** 并在菜单更新选中态。（已知 Process Tap 在长时会话偶发"持续输出全零"的 bug，见下文。）

### 配置 BlackHole（降级用）
1. 安装：`brew install blackhole-2ch`（或到 [existential.audio/blackhole](https://existential.audio/blackhole/) 下载）。
2. 打开「音频 MIDI 设置」→ 左下 `+` → **创建多输出设备** → 勾选你的**扬声器/耳机** + **BlackHole 2ch**。
3. 把系统输出设为这个**多输出设备**（这样你照常听到声音，同时音频被复制进 BlackHole 供捕获）。
4. 本 App 菜单选 **BlackHole (fallback)**。

---

## Intel + macOS 15.7.2 兼容性 / 已知风险

- **匹配度**：目标机型与本项目开发/验证环境完全一致（x86_64 / 15.7.2 / 24G325）。
- **Process Tap 在 Intel 上的把握：中等**。它是 macOS 14.2+ 的纯软件特性，Apple 文档未限制 CPU 架构，Intel 上**预期可用**，但缺少官方在 Intel 实机的明确背书。
- **缓解措施（已内置）**：
  - 全零样本看门狗 + 自动切 BlackHole（见上）。
  - 菜单 **Restart Capture** 一键重建。
  - 随包提供完整 BlackHole 降级路径。
- **建议**：首次在实机可先观察——若开始播放音乐后频谱毫无反应（持续静止），等几秒看是否自动切到 BlackHole；或手动切 BlackHole。

---

## 实机验证清单（首次上机，按序）

这些点只能在带 Touch Bar 的实机上确认，代码已尽量加固，但行为依赖系统私有组件：

1. **Tap 是否拿到声音**：先 `swift Tools/TapSmokeTest.swift`，播放音乐，看是否出现 `✓ audio`。`PASS` 即主路径可用。
2. **控制条小图标出现**：启动 App 后看控制条右侧是否有红色迷你扫描条。没有 → `pkill ControlStrip`。
3. **点击展开**：轻点小图标 → 应展开 685pt 全宽条。已用 `NSPressGestureRecognizer`（不依赖 `mouseDown`）实现；万一无反应，是 Touch Bar 手势分发的实机差异，可在 `slotTapped()` 加日志排查。
4. **收起**：关闭框、再点小图标、或点大条任一方式都能收起。若偶发"需点两次"（系统主动收起导致状态不同步），已做防御，再点一次即可。
5. **自动降级**：若播放中频谱持续静止，约 6–12 秒内看门狗会自动重建 tap、再不行自动切 BlackHole（菜单选中态会变）。

## 调参（视觉 / 分析）

- **视觉**：`TouchBarSpectrum/Support/KITTPalette.swift` 里的 `KITTPalette.kitt`——
  - 4 段红色亮度色阶：`ember`→`crimson`→`signalRed`→`hotCore`，以及光晕 `bloom`；
  - 扫描眼：来回次数 / 停顿 / 快慢的**随机范围**在 `VisualizerEngine.ScannerModel`（`min/maxCrossings`、`min/maxPause`、`min/maxCrossDuration`）；眼核宽 `eyeSigmaFrac`、拖尾 `trailLambdaFrac`/`trailWeight` 在 palette；
  - 段形：段数 `segmentsWide`、段宽占比 `barWidthFrac`、圆角 `cornerRadius`、待机厚度 `minBarFraction`；
  - 音频联动：`audioGamma`（响应曲线）、`audioRelease`（柱子回落速度）。频谱亮度/高度的权重在 `TouchBarSpectrumView.draw` 的 `brightness`/`halfH` 两行。
- **分析**：`TouchBarSpectrum/DSP/SpectrumAnalyzer.swift`——`fftSize`(2048)、`bandCount`(64)、**自适应归一化** `dynamicRangeDb`/`headroomDb`/`ceilingDecay`/`minCeilingDb`（自动跟踪响度，柱子静时压低、随拍冲高，不会一直撑满）、`attack`/`release`（快攻慢落）、`peakFall`、`trebleTiltDb`（高频提亮）。
- **布局**：低频在中心、向两侧镜像扩散（KITT 声纹盒），由 `TouchBarSpectrumView.draw` 里"按到中心距离取频段"实现。
- **调试**：启动前设环境变量 `TBS_DEBUG=1`（如 `TBS_DEBUG=1 ./TouchBarSpectrum.app/Contents/MacOS/TouchBarSpectrum`）会每秒打印 `frameMaxDb/ceiling/floor/maxBand`，便于校准归一化。

---

## 项目结构

```
TouchBarSpectrum/
├── main.swift                         # 程序入口（.accessory agent）
├── AppDelegate.swift                  # 状态栏菜单 + 管线装配 + 源切换
├── Audio/
│   ├── AudioSource.swift              # 统一音频源协议
│   ├── AudioTapManager.swift          # Core Audio Process Tap 主方案 + 看门狗
│   └── BlackHoleSource.swift          # AVAudioEngine BlackHole 降级
├── DSP/
│   ├── RingBuffer.swift               # 无锁 SPSC 环形缓冲
│   └── SpectrumAnalyzer.swift         # vDSP FFT / 对数分箱 / 平滑 / 峰值
├── TouchBar/
│   ├── TouchBarSpectrumView.swift     # KITT 渲染（尺寸自适应，小/大通用）
│   ├── VisualizerEngine.swift         # 60fps 中央驱动
│   └── TouchBarController.swift       # 常驻槽位 + 点击展开全宽
├── Support/
│   ├── TouchBarSpectrum-Bridging-Header.h  # AppKit 私有 SPI（ObjC category）
│   ├── DFRBridge.swift                # dlopen 包装 DFRFoundation C 函数
│   └── KITTPalette.swift              # 视觉调色板/调参
├── Info.plist
└── TouchBarSpectrum.entitlements      # 沙盒关闭
project.yml                            # XcodeGen 工程定义
build.sh                               # 无 Xcode 构建脚本
```

---

## 签名与分发说明

- 本应用使用了**私有 API**（`DFRFoundation` + AppKit Touch Bar SPI），因此**不能上架 App Store、不能公证（notarize）**。仅供本地 / Developer-ID / ad-hoc 使用。
- **App Sandbox 关闭**（私有 Touch Bar SPI + Process Tap 不在沙盒支持组合内）。沙盒关闭后无需额外的音频输入 entitlement，也无需关闭库验证（DFRFoundation 由 Apple 签名）。

---

## 故障排查

| 现象 | 处理 |
|---|---|
| 控制条没出现小图标 / 显示陈旧 | 终端执行 `pkill ControlStrip`（系统会自动重启并刷新） |
| 频谱不动、持续静止 | 等几秒看是否自动切 BlackHole；或菜单手动切 BlackHole；或 Restart Capture |
| 没弹授权 / 误拒了 | 菜单 → Open Privacy Settings…，勾选后 Restart Capture |
| `build.sh` 报找不到 SDK | 确认已装 Command Line Tools：`xcode-select --install` |
| Xcode 打开后签名报错 | 目标已设 ad-hoc（`CODE_SIGN_IDENTITY = "-"`）；如仍报错，可在 Signing & Capabilities 选你的个人账号 |
| 听不到声音了（用了 BlackHole） | 把系统输出设回「多输出设备」而非纯 BlackHole |
