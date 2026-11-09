# Mac idle-efficiency audit

9 November 2026 · installed Sony Headphone Control 1.5.0 · Apple Silicon · macOS 27.2.
The XM4 was connected, no feature change was pending, and the menu panel was
closed. The normal app stayed running; this audit did not change headset settings.

## Measured process counters

Two separate 30-second background samples used macOS `proc_pid_rusage` counters.
The sampler itself runs in a separate process and does not inject into the app.

| Counter | First sample | Second sample |
| --- | ---: | ---: |
| Elapsed | 30.005 s | 30.002 s |
| App user + system CPU time | 0.000004 s | 0.000000 s |
| Average CPU, one-core basis | <0.001% | <0.001% |
| Interrupt wakeups | 0 | 0 |
| Package-idle wakeups | 0 | 0 |
| Physical footprint, start → end | 91.72 → 91.72 MiB | 91.74 → 91.74 MiB |
| Disk bytes read / written | 0 / 0 | 0 / 0 |

No idle-drain regression was observed in these samples. They do not measure
whole-Mac battery life, radio energy attributed to macOS's Bluetooth services,
or long-term battery consumption. Keeping an XM4 connected during Mac sleep
is optional and may have a system-level Bluetooth cost outside this process.

## Code review

- There are no repeating idle timers, periodic Bluetooth status requests,
  keepalive packets, continuous device scans, or background battery sampling.
- Bluetooth, Core Audio volume, and microphone changes use removable observers.
- XM4 capability discovery runs at connection time. Status is queried again
  only for explicit refreshes, opening the panel, or command verification.
- Icon updates are cached by model and color; unchanged images do not rewrite
  Finder icons or application resources, even when other state updates arrive.
- Ordinary operation keeps packet diagnostics disabled; bounded in-memory logs
  and disk exports are enabled only for explicit developer diagnostics.
- Connection retries have a finite budget. A command retries at most once.
- Feature readback checks sleep between in-memory comparisons only while a user
  change is active: at most 10 seconds normally, or 45 seconds for multipoint
  reconnection. They cancel on completion, target change, manual disconnect,
  sleep, or shutdown. These are not an idle background loop.
- Sleep closes the control session; XM4 keeps the Bluetooth audio link by
  default, while XM3 defaults to disconnecting it. Each headset can override this.

## Regression checks

`Tests/XM4FeatureChecks.swift` asserts that after XM4 discovery settles there
are no new packets, connection attempts, connection checks or volume writes
while idle. A second check verifies a completed XM4 settings change returns
to idle without further reads or retries. The existing XM3 idle check remains.
All 108 app tests passed, including cancellation and lifecycle coverage.

## Reproduce on macOS

Build the optional read-only sampler using Xcode command-line tools:

```sh
xcrun clang -Wall -Wextra Tools/measure-idle.c -o /private/tmp/sony-menu-idle
pgrep -fl SonyMenu
/private/tmp/sony-menu-idle <installed-app-pid> 30
```

Choose the PID for the executable inside the installed app, close the menu
panel, allow connection/startup work to finish, and avoid changing settings
during the sample. The JSON reports deltas for CPU, wakeups, footprint and disk
I/O; CPU percentages are relative to one fully occupied core. The tool exits
if it cannot read that process or if the process exits during sampling.

The existing `--diagnose --verify-idle` mode additionally measures five seconds
with no application-initiated queries or connection checks, then quits. It is
a developer diagnostic, so close the regular instance first and reopen it
normally afterward. Do not use control/multipoint-changing diagnostics for a
read-only battery-efficiency check.
