# Validation on the connected WH-1000XM3

Checked locally on 5 November 2026 with the user's paired Sony WH-1000XM3,
firmware 4.5.2.

- Native application built successfully and ad-hoc signature verified.
- Protocol fixture, stream parser and sleep/reconnect policy checks passed.
- Live Sony MDR handshake and battery/noise/volume reads succeeded.
- Noise-mode change confirmed by readback; original ambient mode restored.
- macOS Core Audio volume decrease confirmed by readback; original volume restored.
- The app's sleep handler disconnected the actual Bluetooth link.
- The app reconnected and completed the Sony handshake after that test.
- Native control and Settings views rendered and visually inspected.
- Live Core Audio volume-change notifications reached the panel within a
  250 ms verification window after a write outside the app's state store.
- An app volume write was read back from macOS; the original volume was restored.
- All 87 simulated-device, preferences, lifecycle, protocol and UI tests passed.
- Light, Dark and Device appearances were rendered; live appearance changes
  on an existing panel and preference persistence were tested.
- The updated event-driven build passed all 13 live diagnostic assertions,
  including actual Bluetooth disconnection and subsequent reconnection.
- A five-second idle observation recorded zero connection checks and zero
  app-initiated Bluetooth queries. This is not a battery-life measurement.

Version 1.1 adds microphone input selection with seven new simulated routing
tests. Live native enumeration, input switching, notification synchronization,
and restoration of the original microphone all passed on the connected Mac.
Meet's own per-call input selection still requires a manual check.

The user subsequently confirmed that selecting MacBook Pro Microphone inside
Google Meet (rather than changing only the Mac default) resolved the call
sidetone problem. Read-only XM3 capability checks found no exposed sidetone
setting. Microphone controls now live in Settings → Audio.

Version 1.1.1 installs at `/Applications/Sony Menu.app` with an icon built from
the same user-provided headphone picture shown in the panel. A dedicated local
certificate was created in the user keychain with code-signing-only trust.
Two rebuilds produced the same certificate-bound designated requirement,
without a changing executable hash in that requirement. The installed bundle's
signature, icon representations, executable and metadata passed verification.
The first launch under the new certificate required Bluetooth approval and
then completed the Sony handshake with authorized access.
On the next launch, Bluetooth authorization was already `allowedAlways`
(raw value 3) before initialization and the headphone connection became ready.

The volume notification check simulates an external macOS volume change;
physical headphone touch gestures still need a hands-on check. Device-list
notifications rebind volume listeners after a reconnect.

The sleep-handler test did not put the Mac to sleep. Actual closed-lid sleep,
long backpack periods, unlock-triggered reconnection, and launch at login
have not been tested. The sleep feature only targets this headset and cannot
guarantee that macOS will reject all incoming connections while the app is
suspended. See README.md for the behavior and limitations.

Live diagnostic output is generated at `/private/tmp/sony-menu-diagnostics.json`;
that temporary file is overwritten by the next diagnostic run.

Version 1.2 fixes live popover appearance overrides and adds the compact native
Auto/sun/moon control. An open-popover regression checks the rendered background
pixels as well as AppKit appearance, including clearing all overrides for Auto.
Primary and secondary custom text colors pass 4.5:1 contrast on every custom
surface in Light and Dark. Helper text is at least 12 pt, noise-mode labels wrap
instead of shrinking, and selection has a checkmark in addition to color.

Live accessibility inspection confirmed theme names/selection, volume percentage,
microphone and switch descriptions. Theme arrow/Space navigation and visible
focus were checked on the installed app. Settings scroll within the available
screen height. Apple's Inspector audit was inconclusive after an empty result
also occurred on a deliberately unnamed-button fixture; no full-audit pass is
claimed. See TESTING.md for scope and remaining manual checks.

Panel positioning now snapshots the status item’s screen coordinates into a temporary transparent, non-interactive anchor window. Source-window motion and repeated opening leave the existing panel frame unchanged in native regression tests. Closing releases the anchor, and the next opening uses the newly clicked location. Settings height is captured on opening rather than following `NSScreen.main`. A live scroll check confirmed the scrollbar sits outside the cards and switches.

The connected XM3 confirmed changing from Prioritize Sound Quality to Prioritize Stable Connection and restoring Prioritize Sound Quality. All four live quality assertions passed. The mode uses GET `E6 01` and SET `E8 01 00 <mode>` (`00` quality, `01` stability), followed by setting and codec readback. Valid notifications also update the panel. Unsupported/unreported settings stay disabled; ACK alone never changes the selected state.

The final visual pass checks Light and Dark controls, all three selectable noise modes, the expanded ambient section and Settings. Mode tiles use equal widths, explicit two-line labels, retained mode icons and a separate selection badge. Cards share 14 pt insets, 12 pt gaps and 12 pt corner radii; Settings groups use 16 pt gaps. Voice focus switches align at the trailing edge, the More menu has one icon, and the footer separator respects the panel inset. Sound quality and microphone controls live together in Settings → Audio. Notices inside Settings scroll with the content rather than increasing the fixed viewport.

Native popup fields now fill the same content width, and label icons use a fixed 16 pt column with an 8 pt label gap. Appearance segments fill their allocated width. Rendered pixel checks confirm matching main/Settings card edges in both themes; the scroll rail occupies the outer margin rather than reducing the Settings card width. Native field tests retain the confirmed selection after a rejected write and keep long device names within the fixed field width while exposing full tooltips.

Version 1.3 queried the connected XM3's series/color field and received Black.
Both Silver and Black application and Finder icons matched their respective
bundled images after normalization. Auto was restored. All 16 live color/icon
assertions passed, including a second ready launch with Bluetooth already
authorized (raw value 3). The installed signed code passed verification with
its custom Finder icon preserved. The Swift suite has 87 tests, and all five
signature-integrity tests passed locally. Color-selection photo tiles were
rendered in both themes and inspected in the installed app.

The app was renamed to Sony Headphone Control in version 1.3. The installer
renamed the previous installation in place, keeping `local.sonymenu.app`, the
existing signing identity, and preferences. The migrated app connected, kept
Auto/Black color detection, retained enabled launch-at-login registration, and
started with Bluetooth authorization already allowed (raw value 3).

Version 1.3.1 relocates generated app copies into `.noindex` directories and
unregisters their old paths. Spotlight and Launch Services both reported only
`/Applications/Sony Headphone Control.app` after cleanup. The installed metadata
is a normal Utilities app, while the running application reports accessory
activation policy 1. This preserves menu-bar-only operation. The native launcher
UI was unavailable for visual inspection; no global index reset was performed.


## WH-1000XM4 support — 2026-11-09

A connected WH-1000XM4 exposes Sony Serial HPC service
96CC203E-5068-46AD-B32D-E316F5E069BA (channel 9 on this device; discovered by UUID).
The unchanged V1 stack successfully reads model, battery 40%, AAC, noise
cancellation and protocol volume 22/30. Init reply is 01 00 70 00; series/color
reply is 05 03 30 05. Color 0x05 maps to Blue for XM4, physically confirmed by the owner; XM3 mappings are unchanged.
No factory settings or pairing changes are part of this support.

Automated tests cover connected-device preference, same-model device identity,
explicit disconnected selection, model/artwork retention, scoped preferences,
old ambient-write cancellation across sessions, XM4 V1 reply fixtures, and
native Light/Dark renders of all three supplied XM4 artwork variants.
Hardware command validation is recorded below for the local installation.
Firmware version and simultaneous XM3/XM4 hardware behavior remain unverified.

### Installed 1.4.0 hardware result

The installed app selected the connected XM4 automatically while the paired XM3
was disconnected. Auto resolved the owner-confirmed Blue report to
HeadphonesXM4Blue, with battery 40%, AAC and noise cancellation.

The live diagnostic passed: noise mode change and restoration; ambient level 7
with voice focus; ambient maximum 20 without voice focus; original noise state
restoration; selected Core Audio volume write/readback; external volume listener
notification and panel sync; original volume restoration. System volume was
restored to 0.75. A five-second idle observation produced zero connection checks
and zero outgoing Bluetooth queries. Bluetooth authorization remained allowed
before and after installation. The existing local signing identity was retained.

96 app tests and five bundle signature-integrity tests passed. Native Light/Dark
panels were rendered for Black, Silver and Blue. No physical sleep or simultaneous
XM3/XM4 test was performed; those behaviors have automated regression coverage.


## 1.4.1 sleep defaults — 2026-11-09

Disconnect on sleep now defaults to Off for XM4 and On for XM3. Explicit saved
preferences take precedence. The owner's current XM4 setting was changed to Off
as requested. All 97 native tests pass, including XM4 sleep without a Bluetooth
audio disconnect and retention of an explicit user preference.


## 1.5.0 XM4 feature controls — 2026-11-09

Added capability-driven Speak-to-Chat (toggle, sensitivity, conversation timeout
and voice focus), multipoint, wear pause/resume, removed-headset power-off and
DSEE Extreme Off/Auto. Settings contains a description for every control.

Live device write/readback and restoration passed for every feature and for the
conversation detail tuple. Initial values restored: Speak-to-Chat On, sensitivity
Auto, conversation voice focus Off, timeout 30 seconds, multipoint On, wear
pause/resume On, removed-headset power-off On, DSEE Off. Mac sleep disconnection
remains Off. Acoustic enhancement and physical wear timing were not measured.

Multipoint required registering fixed-message notifications (94 01 00), then
confirming only the explicitly requested matching 99 message with 98. Without
that registration, the headset ACKed the write but retained its setting. After
a confirmed Off request it disconnected the Mac, and several immediate RFCOMM
reconnection attempts timed out. The user reconnected the headset; the running
app then read multipoint Off. A later On request, matching confirmation, native
Bluetooth reconnection and final D7 D2 01 01 readback restored multipoint On.
The UI reports success only after readback and allows a bounded reconnect
window; manual reconnection may still be needed.

106 native app tests and five signature-integrity tests pass. Native Light/Dark
settings renders cover scrolling through conversation, multipoint, wearing and
DSEE descriptions. The installed app is version 1.5.0, signed with the existing
local identity. See docs/xm4-features.md for packet details and known limits.


## Idle-efficiency recheck — 2026-11-09

The installed 1.5.0 app stayed connected to XM4 and running normally during two
separate 30-second background samples. Measured app CPU time was 0.000004 s and
0.000000 s; both samples reported zero interrupt/package-idle wakeups and zero
disk I/O. Physical footprint was stable within each sample (91.72 MiB and
91.74 MiB). No idle-drain regression was observed; this is a process idle check,
not a whole-Mac battery-life or Bluetooth-radio energy benchmark.

Two new XM4 regressions verify no packets, connection checks, retries or volume
writes after discovery, and no extra queries/retries after a completed setting
change. All 108 app tests pass. See docs/performance.md for details and the
optional Tools/measure-idle.c sampler for reproduction.


## 1.5.1 delayed control-service discovery — 2026-11-09

The owner reported both XM3 and XM4 briefly showing Controls unavailable /
No supported Sony MDR control service was found, followed by successful control
when the panel was reopened. Model selection itself was already correct.

A fresh SDP discovery now retries missing records or transient SDP errors after
1, 2 and 4 seconds within the existing overall connection deadline. It stops
on success, disconnect, generation change or shutdown. Connected-headset
retries remain bounded. UI status stays Connecting with a native spinner while
recovery is pending; only exhausted recovery shows a terminal error.

Added regressions cover late service availability, finite failures, cancelled
and stale callbacks, transient query-start failure, recovery without a panel
refresh, retry exhaustion, manual cancellation, and the native loading layout.
All 115 tests pass. No periodic idle scan was introduced.

When both headsets stay connected, Automatic intentionally retains its current
connected control target. A new panel notice and Settings description explain
that the Mac's audio output can independently use the other headset.
