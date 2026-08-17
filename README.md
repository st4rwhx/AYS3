# iOS RPCS3 build harness (research spike)

Experimental effort to cross-compile [RPCS3](https://github.com/RPCS3/rpcs3)
for `arm64-apple-ios` and measure how far it can be configured, built, and run
on iOS.

> **Status: research spike.** No playable build exists yet. This repo contains
> CI scaffolding whose only goal is to find out how far RPCS3 can be
> cross-compiled for iOS.

## Notes

- RPCS3 is **GPL-2.0-only**. This repo builds a distinct binary from RPCS3 and
  is licensed **GPL-2.0** (see [`LICENSE`](LICENSE)).
- Known constraints: host RAM expectations versus iOS jetsam limits;
  performance on passive mobile ARM; and runtime code execution (JIT), which
  requires debugger-based enablement on iOS.
- RPCS3 has had native ARM64 support since Dec 2024, so the CPU architecture
  itself is not the wall.

## CI

The Phase-1 workflow clones RPCS3, fetches an iOS CMake toolchain, and attempts
to configure and build RPCS3 for `arm64-apple-ios` on a macOS runner, uploading
the full logs.

## License

GPL-2.0-only, matching RPCS3. See [`LICENSE`](LICENSE).
