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
- All 64 simulated-device, preferences, lifecycle, protocol and UI tests passed.
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
setting. Microphone controls now live in Settings → Call audio.

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
