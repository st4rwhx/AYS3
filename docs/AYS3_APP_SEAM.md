# AYS3 app seam — the RPCS3 symbols the app layer must provide

**Status: Phase 1/2 toolchain de-risk is DONE.** RPCS3's PS3 core cross-compiles
and links into a valid `arm64-apple-ios` Mach-O (`platform IOS`, `minos 16.3`).
The link probe uses `-undefined dynamic_lookup` so it links despite the
frontend symbols being absent; on a real device those must be **implemented**,
because a missing dynamic-lookup symbol crashes at launch.

## What the seam is

RPCS3 keeps its Qt desktop frontend (`rpcs3_lib`) behind `if (NOT ANDROID)`. Our
iOS build compiles the **Emu core only** (like Android), so the core's calls
into that frontend are unresolved. These are the **Emu↔app seam**: the interface
the AYS3 app (our Swift / Obj-C++ layer) must implement — exactly the role the
Android app fills with its own code.

The authoritative list comes from the strict `-force_load` probe (which pulled
every core object, surfacing the complete seam). Grouped by concern:

### 1. Pad / input (the bulk — all null-able on a headless boot)
- `pad_thread::AddLddPad()`
- `pad_thread::UnregisterLddPad(u32)`
- `pad_thread::SetIntercepted(bool)`
- `pad_thread::SetRumble(u32, u8, u8)`
- `pad::g_pad_thread`  (global)
- `pad::g_pad_mutex`   (global)
- `input::get_products_by_class(int)`
- `sdl_instance::get_instance()`
- `sdl_instance::initialize()`
- `sdl_instance::pump_events()`
- `cfg_ps_moves::load()`
- `g_cfg_move`          (global)
- `ps_move_tracker<false>::ps_move_tracker()` / `~ps_move_tracker()`
- `ps_move_tracker<false>::process_image()`
- `ps_move_tracker<false>::set_image_data(const void*, u64, u32, u32, int)`
- `ps_move_tracker<false>::set_active(u32, bool)`
- `ps_move_tracker<false>::set_hue(u32, u16)`
- `ps_move_tracker<false>::set_hue_threshold(u32, u16)`
- `ps_move_tracker<false>::set_saturation_threshold(u32, u16)`
- `ps_move_tracker<false>::hsv_to_rgb(u16, float, float)`
- `ps_move_tracker<false>::rgb_to_hsv(float, float, float)`

### 2. App identity
- `rpcs3::get_verbose_version()`   → return a fixed AYS3 version string
- `rpcs3::get_version_and_branch()` → return a fixed AYS3 version string

### 3. App lifecycle glue
- `report_fatal_error(std::string_view, bool, bool)` → log + `std::abort()`
- `qt_events_aware_op(int, std::function<bool()>)`   → just run the op once
  (no Qt event loop on iOS)

Everything else that appeared "undefined" under `dynamic_lookup`
(`std::…`, `VTT for std::…`, `__cxa_*`, `memcpy`, `__tlv_*`, …) is provided at
runtime by the iOS SDK's **libc++ / libc++abi / libSystem** — NOT the app. Those
are noise in the probe's `nm -u`; they resolve automatically in a normal link.

## Why this is encouraging

The seam is **small and almost entirely input/pad** — and a headless boot needs
no real controllers. So the glue is mostly *null* implementations: an empty
`pad_thread`, a no-op `sdl_instance`, a stub `ps_move_tracker`, two version
strings, a fatal-error handler, and a trivial `qt_events_aware_op`. No emulator
internals to reimplement.

## Next phase (Phase 2 proper) — headless boot + RAM

1. Write `ays3_seam.mm/.cpp`: minimal real implementations of the symbols above
   (correct signatures from RPCS3 headers: `Input/pad_thread.h`,
   `Input/sdl_instance.h`, `Input/ps_move_tracker.h`, `Input/product_info.h`,
   `util/version.hpp`, the `report_fatal_error` / `qt_events_aware_op` decls).
2. Drop `-undefined dynamic_lookup`; link the probe against `ays3_seam` so it
   links with a **runtime-safe** symbol set (std:: from libc++, seam from us).
3. Add an Obj-C++ bridge that calls `Emu.Init(...)` then `Emu.BootGame(...)`
   (from `Emu/System.h`) on a user-supplied PS3 firmware/title.
4. Measure resident memory at boot — the real **jetsam go/no-go**: RPCS3 targets
   8–16 GB; iOS kills apps at ~2–4 GB. This is the fundamental wall the whole
   feasibility hinges on.

On-device verification stays with the user via sideload, as with AYS2.
