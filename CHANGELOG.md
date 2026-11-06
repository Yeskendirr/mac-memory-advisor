# Changelog

## 1.0.0

First public release.

- RAM tab: memory summary, grouped processes with memory (MB and % of RAM), CPU and uptime, "Safe to quit / Be careful / System" verdicts with reasons, details popover, filter and sort.
- Disks tab: processes holding files on any volume, graceful stop, safe eject (never forced), "What holds the disk?" diagnostics, one-click Spotlight off per volume.
- Graceful stopping: apps quit like Cmd+Q (nested helpers first), SIGTERM for servers, fast shutdown for Postgres, `adb emu kill` for the Android emulator.
- English and Russian UI, follows the system language, manual override in the Language menu.
- Action log at `~/Library/Logs/MemoryAdvisor.log`.
- Universal binary (Apple Silicon + Intel), macOS 14+.
