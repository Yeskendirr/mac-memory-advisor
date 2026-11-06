# Changelog

## Unreleased

- Fix: processes supervised by launchd (`KeepAlive`, e.g. MySQL from `brew services`) were respawned right after being stopped, so their memory was never freed and the app reported "did not quit". The owning launchd job is now unloaded with `launchctl bootout` (until next login) instead of signalling the process.

## 1.0.0

First public release.

- RAM tab: memory summary, grouped processes with memory (MB and % of RAM), CPU and uptime, "Safe to quit / Be careful / System" verdicts with reasons, details popover, filter and sort.
- Disks tab: processes holding files on any volume, graceful stop, safe eject (never forced), "What holds the disk?" diagnostics, one-click Spotlight off per volume.
- Graceful stopping: apps quit like Cmd+Q (nested helpers first), SIGTERM for servers, fast shutdown for Postgres, `adb emu kill` for the Android emulator.
- English and Russian UI, follows the system language, manual override in the Language menu.
- Action log at `~/Library/Logs/MemoryAdvisor.log`.
- Universal binary (Apple Silicon + Intel), macOS 14+.
