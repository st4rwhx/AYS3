# AYS3 — PlayStation 3 emulation on iOS (research spike)

AYS3 is an **experimental** effort to run PlayStation 3 games on iOS by
building [RPCS3](https://github.com/RPCS3/rpcs3) for `arm64-apple-ios`, reusing
the JIT-enablement and UX know-how from the PS2 project (AYS2) — but as a
**separate application and binary**.

> **Status: research spike.** No playable build exists yet. This repo currently
> contains the Phase‑1 scaffolding whose only goal is to find out how far
> RPCS3 can be cross‑compiled for iOS in CI. See
> [`docs/AYS3_PS3_FEASIBILITY.md`](docs/AYS3_PS3_FEASIBILITY.md) for the full,
> honest assessment and the staged plan.

## Why a separate app (not part of AYS2)

- **RPCS3 is GPL‑2.0‑only.**
- **AYS2 (PCSX2 base) is GPL‑3.0‑or‑later.**
- These two licenses are **mutually incompatible** — RPCS3 and PCSX2 code
  **cannot** be linked into one binary. AYS3 is therefore a distinct binary
  built from RPCS3, licensed **GPL‑2.0** (see [`LICENSE`](LICENSE)). Any UI or
  helper ideas borrowed from AYS2 are **re‑implemented here**, never imported.

## The known walls (be honest up front)

1. **RAM.** RPCS3 wants 8–16 GB host RAM; iOS kills apps (jetsam) around
   2–4 GB. This is the primary blocker on most devices.
2. **Performance.** PS3 emulation strains even fan‑cooled Apple‑Silicon Macs;
   passive mobile ARM will be far slower.
3. **JIT.** RPCS3 maps large W^X executable regions for its PPU/SPU
   recompilers; that must ride on the same debugger‑based JIT enablement used
   by the PS2 app.

The good news: RPCS3 has **native ARM64** since Dec 2024, so the CPU
architecture itself is not the wall.

## Phase 1 — de‑risk the toolchain (current)

The [Phase 1 spike workflow](.github/workflows/phase1-ios-spike.yml) clones
RPCS3, fetches an iOS CMake toolchain, and attempts to **configure** RPCS3 for
`arm64‑apple‑ios` on a macOS runner, uploading the full logs. Success criterion
for Phase 1 is narrow and binary: *how far does configuration get, and what is
the first real wall?* No boot, no rendering, no UI yet.

## License

GPL‑2.0‑only, matching RPCS3. See [`LICENSE`](LICENSE).
