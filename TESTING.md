# Testing

## Automated suite

```sh
zsh test.sh
```

The suite currently contains 75 named tests. It compiles the production source
with LLVM instrumentation, runs against isolated preferences and simulated
Bluetooth/macOS services, and renders native SwiftUI panels in Light, Dark,
and Auto appearance. It never changes your real headphone or login settings.

Outputs:

- `build/coverage.txt`: per-file line and function coverage.
- `build/tests.profdata`: merged LLVM coverage data.
- `build/test-previews/`: native panel screenshots for visual review.

`python3 Tools/verify-app.py` checks the distributable's bundle identifier,
Bluetooth usage description, executable, multi-resolution icon, third-party
notices, and code signature. CI runs this packaging check as well as the suite.
For a locally certificate-signed bundle, run it in the normal user session
where the user keychain's trust settings are available.

| Area | Automated checks |
| --- | --- |
| Appearance and preferences | Default/fallback values, persistence, native theme mapping, an open popover updating native appearance and rendered pixels, clearing overrides in Auto mode |
| Protocol framing | Known wire fixture, every-byte payload, every split boundary, combined frames, checksum/length validation, illegal escapes, bounded parser and recovery |
| Bluetooth client | Handshake, unsupported versions, replies/notifications, ACK sequencing, retries, timeouts, write failure, command coalescing, readback, cancellation |
| Controls | Noise modes, ambient level and voice focus, value clamping, debounce, latest-command behavior, macOS volume reads/writes and external change notifications |
| Sound quality | Initial/refresh reads, both SET payloads plus GET readback, rejected writes, phone notifications, invalid values, unknown/missing support, rapid reversal, no-op/disconnected/shutdown guards, reconnect state reset |
| Microphone | Current input without auto-switching, selection in either direction, external routing updates, vanished devices, write/readback failures, shutdown cleanup |
| Sleep and connection | Manual disconnect intent, optional reconnect, repeated background wake, unlock-before-wake, disabled sleep disconnect, pairing errors, bounded retries |
| Lifecycle and efficiency | No idle polling or keepalive requests, cancelled work on sleep, subscriptions removed on shutdown, diagnostics disabled normally |
| Interface | Light/Dark/Auto panels, connected/disconnected/connecting/error/ambient layouts, scrollable Settings and size constraints |
| Panel positioning | Fixed screen-space anchor while the source window moves; repeated open, fresh reopen, anchor cleanup, unattached views and captured viewport height |
| Accessibility | Primary and secondary app text at least 4.5:1 on all custom surfaces in both themes; native segment descriptions/tooltips, selection bindings and keyboard-focus acceptance |

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

`--verify-microphone` briefly switches to another available Mac input, checks
that the native input-change notification reaches the selector, and restores
the original input. It needs two available microphones and does not change
the selected output device or record audio.

`--inspect-sidetone` sends only read-only supported-function, general-setting,
and call-setting inquiries. It does not send any setting writes and never
runs during normal operation. See [the XM3 investigation](docs/xm3-sidetone.md).

## Manual checks

- Close the lid for a sustained period, use the headphones with another device,
  then reopen/unlock. Repeat with optional reconnection on and off.
- Change volume with the headphone gestures and macOS controls while the panel
  is open; check that the slider follows and no feedback loop occurs.
- Toggle Auto appearance and change macOS appearance while the panel is open.
- Verify Open at login after a real logout/login.
- Check the first-launch Bluetooth prompt and downloaded-app approval flow on
  another Mac.

These OS and physical-device scenarios cannot be fully validated by fakes.

## Accessibility validation (1.2)

The automated contrast check uses sRGB relative luminance and tests both text
colors on the panel, card and selected-mode surfaces. Native macOS controls
keep their system styling; this calculation does not measure their internal
colors, disabled labels, headphone photo or the full composited screen.

Live checks of the installed interface confirmed named theme radio buttons,
switch descriptions, microphone picker, percentage volume value and More menu.
Light and Dark changed while the panel remained open. Arrow keys and Space
activated the theme segments, with a visible native focus ring. Tab traversal
across all controls and spoken VoiceOver output still need a manual check.

For an Inspector-friendly window containing the same production panel, quit
Sony Menu and run:

```sh
open '/Applications/Sony Menu.app' --args --accessibility-audit
```

Quit and relaunch normally to return to menu-bar-only operation. The audit flag
adds no observers, polling or background work to normal operation.

Apple Accessibility Inspector was invoked with Element Description, Hit Region,
Contrast, Element Detection, Parent/Child and Action enabled. It returned an
empty report even when pointed at a separate negative-control app with an
intentionally unnamed button. That result is **inconclusive**, not a successful
full audit. The report is not used as evidence that the app is fully accessible.
The automated checks and live inspection above are the validated results.

The positioning regression moves the source window (to a second display when available), checks that the open popover and its independent anchor keep their frames, and verifies that a fresh opening uses the new position. Live scrolling confirmed the scrollbar remains in its own gutter outside the settings cards. Physical focus changes between displays remain a manual check.

## Sound quality live check

With the XM3 connected to the Mac, quit the app and run:

```sh
open -W '/Applications/Sony Menu.app' --args --diagnose --verify-sound-quality
python3 Tests/verify_quality_live.py
```

This explicitly switches to the other sound-quality mode, checks the headset
readback, restores the original mode, and reconnects if the headset interrupts
the link. Audio may pause. Normal operation only queries this setting at
connection, explicit refresh and after a setting write; it does not poll.

The UI renders also write `design-light-0/1/2.png` and `design-dark-0/1/2.png` for Noise Cancelling, Ambient Sound and Off. These variants support visual review of equal-width tiles, two-line labels, selection badges, ambient controls, card/section spacing and footer alignment. Sound quality is in Settings → Audio.

Native field tests cover fixed width with long device names, full-name tooltips, confirmed selection after a rejected write, and matching main/Settings card edges measured from rendered Light/Dark images. The scrollbar rail occupies the outer margin so it does not narrow the Settings cards.
