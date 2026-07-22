# AYS3 — PS3 emulation on iOS (RPCS3): feasibility & staged plan

> **Status: research spike.** This document states verified facts and a staged
> de-risk plan so that each failure arrives **early and cheap**. It does not
> claim a playable iOS PS3 emulator exists today.

## Starting decision

Goal: PS3 emulation on iOS via **RPCS3** (github.com/RPCS3/rpcs3), reusing
AYS2's know-how (iOS JIT via a debugger handshake, library/cover UX) — as a
**separate "AYS3" application**, not merged into AYS2.

## Why AYS3 must be a SEPARATE app (license constraint)

- **RPCS3** is **GPL-2.0-only**.
- **AYS2** (PCSX2 base) is **GPL-3.0-or-later**.
- GPL-2.0-only and GPL-3.0 are **mutually incompatible**: the two cannot be
  linked into one binary. "Put the PS3 core inside AYS2" = one binary = license
  violation. So AYS3 is a **distinct binary** built from RPCS3, licensed
  **GPL-2.0**; any shared UI ideas are **re-implemented**, never imported from
  the GPLv3 PS2 codebase.

## Verified facts (research)

- **ARM64 native** in RPCS3 since December 2024 (Linux/macOS/Windows ARM, Apple
  Silicon). The LLVM PPU/SPU JIT recompilers target arm64 — CPU arch is **not**
  the wall.
- Rendering via **Vulkan → MoltenVK** on Apple, or OpenGL 4.3.
- **RAM: 8 GB minimum, 16 GB recommended** on the host — the main iOS wall.
- The RPCS3 team **officially declines** iOS/Android and bans the topic; only a
  very recent **experimental Android alpha** exists, **nothing for iOS**, and no
  iOS toolchain in their build.
- Build: a large CMake project with many submodules (LLVM, Vulkan headers,
  FFmpeg, etc.). This is a second full emulator, not a swappable "core".

### The iOS wall (independent of license)

1. **Memory.** iOS jetsam kills apps around **2–4 GB** even on 8 GB devices;
   RPCS3 targets 8–16 GB → OOM on nearly all devices. Only high-RAM M-series
   iPads have any chance, still under the per-app jetsam limit.
2. **Performance.** PS3 emulation already saturates **fan-cooled** M-series
   Macs; passive mobile ARM would be far slower — most titles unplayable.
3. **JIT.** RPCS3 maps large executable (W^X) regions for the PPU/SPU
   recompilers. The debugger-based JIT gives RWX, but RPCS3's executable-memory
   appetite far exceeds PCSX2's, compounding the RAM wall.

**Honest feasibility conclusion:** a *playable* AYS3 on mainstream iPhone/iPad
is not reachable today. The work has value as **research** (prove what
builds/boots; document the walls), not as a finished product. Hence phases with
a hard stop at each.

## Staged plan (each phase = a go/no-go stop)

### Phase 0 — this document + repo skeleton (done)
Facts + architecture + plan. No emulator code.

### Phase 1 — de-risk the TOOLCHAIN (current)
Prove RPCS3 (or just its core) can be **configured/cross-compiled for
arm64-apple-ios** in CI, isolated.
- Clone RPCS3 (pinned) in CI; fetch an iOS CMake toolchain.
- Attempt a **configure** for `arm64-apple-ios` on a macOS runner; upload logs.
- Success criterion: how far configuration gets and **what the first real wall
  is**. No boot, no UI.
- If it fails hard here → stop, minimal cost lost.

### Phase 2 — headless boot + RAM measurement
Get the RPCS3 VM to **initialize** on a device (user supplies PS3 firmware,
like the PS2 BIOS), no rendering, measuring RAM. Go/no-go on the real jetsam
limit.

### Phase 3 — MoltenVK rendering + a first homebrew
Wire Vulkan→MoltenVK; try a light PS3 **homebrew** (not a AAA title). Measure
real performance.

### Phase 4 — AYS3 shell (re-written SwiftUI UI) + PS3 library/covers
Only if 1–3 pass: re-implement an AYS2-style UI (independent, not imported), a
PS3 game library, and PS3 cover downloading.

## Next concrete action

Run **Phase 1 only**: CI attempts the iOS configure and reports the first wall.
Stop and review before Phase 2.

## Verification

- Phase 1: the CI log is the deliverable — it names the first blocker.
- No on-device verification is possible in this environment (no Mac, no test
  device); final confirmation stays with the user via sideload, as with AYS2.
