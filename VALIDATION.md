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
