# Changelog

## Unreleased

- Automatic updates: the app checks GitHub Releases at launch and every 12 hours, shows the release notes and, on *Update now*, downloads the DMG, verifies its SHA-256 and code signature, replaces itself and relaunches. *Skip this version* and *Later* are available; *Check for Updates...* and an on/off toggle live in the app menu. If the app sits in a folder it cannot write to, the new DMG is opened instead.
- Fix: after a graceful stop of CrossOver, Wine processes such as `winedevice.exe` stayed behind without their `wineserver`, holding the bottle's files and blocking eject. Once the wineserver is gone, those orphans are now killed (they cannot run or save anything without it).
- "Force quit" is now always next to "Stop selected" (with a confirmation). Before, it appeared only 20 s after a failed stop and only while the row stayed selected, so it was easy to miss, and it was lost when the app was reopened.
- Fix: CrossOver (Wine) could not be stopped, even with "Force quit". Force quit killed only the macOS app and skipped the helper processes inside its bundle, and Wine ignores SIGTERM. Windows processes can even outlive `wineserver`. Force quit now SIGKILLs every remaining process of the app, `wineserver` first, including processes registered as apps (`forceTerminate()` alone did not stop Steam inside CrossOver).
- Fix: paths under `/private/var` and `/var` are treated as the same, so apps run from Downloads (App Translocation) are matched with their running application.

- Fix: processes supervised by launchd (`KeepAlive`, e.g. MySQL from `brew services`) were respawned right after being stopped, so their memory was never freed and the app reported "did not quit". The owning launchd job is now unloaded with `launchctl bootout` (until next login) instead of signalling the process.

## 1.0.0

First public release.

- RAM tab: memory summary, grouped processes with memory (MB and % of RAM), CPU and uptime, "Safe to quit / Be careful / System" verdicts with reasons, details popover, filter and sort.
- Disks tab: processes holding files on any volume, graceful stop, safe eject (never forced), "What holds the disk?" diagnostics, one-click Spotlight off per volume.
- Graceful stopping: apps quit like Cmd+Q (nested helpers first), SIGTERM for servers, fast shutdown for Postgres, `adb emu kill` for the Android emulator.
- English and Russian UI, follows the system language, manual override in the Language menu.
- Action log at `~/Library/Logs/MemoryAdvisor.log`.
- Universal binary (Apple Silicon + Intel), macOS 14+.
