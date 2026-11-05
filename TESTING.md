# Testing

## Automated suite

```sh
zsh test.sh
```

The suite currently contains 49 named tests. It compiles the production source
with LLVM instrumentation, runs against isolated preferences and simulated
Bluetooth/macOS services, and renders native SwiftUI panels in Light, Dark,
and Device appearance. It never changes your real headphone or login settings.

Outputs:

- `build/coverage.txt`: per-file line and function coverage.
- `build/tests.profdata`: merged LLVM coverage data.
- `build/test-previews/`: native panel screenshots for visual review.

| Area | Automated checks |
| --- | --- |
| Appearance and preferences | Default/fallback values, persistence, native theme mapping, an existing panel updating its appearance |
| Protocol framing | Known wire fixture, every-byte payload, every split boundary, combined frames, checksum/length validation, illegal escapes, bounded parser and recovery |
| Bluetooth client | Handshake, unsupported versions, replies/notifications, ACK sequencing, retries, timeouts, write failure, command coalescing, readback, cancellation |
| Controls | Noise modes, ambient level and voice focus, value clamping, debounce, latest-command behavior, macOS volume reads/writes and external change notifications |
| Sleep and connection | Manual disconnect intent, optional reconnect, repeated background wake, unlock-before-wake, disabled sleep disconnect, pairing errors, bounded retries |
| Lifecycle and efficiency | No idle polling or keepalive requests, cancelled work on sleep, subscriptions removed on shutdown, diagnostics disabled normally |
| Interface | Light/Dark/Device panels, connected/disconnected/connecting/error/ambient layouts and size constraints |

This is broad regression coverage, not 100% line coverage. Hardware-specific
IOBluetooth and Core Audio code is mostly exercised by the live checks below,
not by the simulated suite. Rendering tests do not replace hands-on UI testing.

## Live hardware checks

Quit any running Sony Menu instance first. These options temporarily change
noise mode and volume, disconnect the headphones, then restore the original
settings and reconnect. They do not put the Mac to sleep.

```sh
open 'build/Sony Menu.app' --args --diagnose --verify-idle --verify-volume-sync --verify-control --verify-sleep
```

After the diagnostic app exits, inspect `/private/tmp/sony-menu-diagnostics.json`.
Use `python3 Tests/verify_live.py` to assert all expected results. The idle check
observes five seconds with no app-initiated connection checks or status queries;
it is not a measurement of power draw or a battery-life benchmark.

Read-only diagnostics use `--diagnose` alone. Adding `--capture-preview` writes
native Light and Dark screenshots under `/private/tmp`. Logs stay in memory
during normal operation only when diagnostic mode is explicitly enabled; the
JSON file is written only by a diagnostic run.

## Manual checks

- Close the lid for a sustained period, use the headphones with another device,
  then reopen/unlock. Repeat with optional reconnection on and off.
- Change volume with the headphone gestures and macOS controls while the panel
  is open; check that the slider follows and no feedback loop occurs.
- Toggle Device appearance and change macOS appearance while the panel is open.
- Verify Open at login after a real logout/login.
- Check the first-launch Bluetooth prompt and downloaded-app approval flow on
  another Mac.

These OS and physical-device scenarios cannot be fully validated by fakes.
