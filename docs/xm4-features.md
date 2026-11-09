# WH-1000XM4 feature settings

Investigated on the owner's connected blue WH-1000XM4 on 9 November 2026.
All operations use the existing Sony MDR V1 control service. Packet layouts
below are payload bytes, after framing/escaping has been removed.

## Observed reads and capability replies

| Setting | Capability request | Observed capability | Parameter request | Observed parameter |
| --- | --- | --- | --- | --- |
| Wear pause/resume | F0 03 | F1 03 00 | F6 03 | F7 03 00 01 |
| Wear power-off | F0 04 | F1 04 02 10 11 | F6 04 | F7 04 01 10 00 |
| Speak-to-Chat | F0 05 | F1 05 00 01 00 00 00 00 0F 1E 3C 00 | F6 05 | F7 05 00 01 |
| Conversation details | As above | As above | FA 05 | FB 05 00 00 00 01 |
| DSEE Extreme | E0 02 | E1 02 02 00 | E6 02 | E7 02 00 00 |
| Multipoint | D0 D2 01 | MULTIPOINT_SETTING / MULTIPOINT_SETTING_SUMMARY, boolean | D6 D2 | D7 D2 01 01 |

The general-setting subject must be matched exactly. D2 is touch-panel control
on XM3 but multipoint on this XM4; never reuse an XM3 slot-based write on XM4.
Malformed capabilities, unknown booleans, unknown enum values, and truncated
replies are ignored. A model name alone never enables a feature setter.

## Confirmed write/readback layouts

- Speak-to-Chat: F8 05 01 <enabled>. Readback F7/F9 uses setting type 00 or 01.
- Conversation: FC 05 00 <sensitivity> <voice-focus> <timeout>.
  Sensitivity Auto/High/Low = 00/01/02. Timeout Short/Standard/Long/Manual =
  00/01/02/03. Both option edits preserve the other confirmed fields.
- Wear pause/resume: F8 03 00 <enabled>.
- Wear power-off: F8 04 01 <10 when enabled, 11 when disabled> <existing timer>.
  The returned timer byte is preserved; the XM4's removed-headset power-off
  feature is described separately from Mac sleep disconnection.
- DSEE: E8 02 00 <enabled>; true means Auto, not a forced active DSP indicator.
- Multipoint: D8 <discovered-slot> 01 <enabled>. This requires the additional
  confirmation exchange below. An ACK plus an unchanged D9/D7 is not success.

Boolean values above are 00 Off / 01 On. Re-read each setting after writing;
notifications also update the UI. Startup and refresh only inquire about
settings and never restore feature preferences automatically.

## Multipoint confirmation and reconnection

Before the user's requested multipoint change, subscribe with 94 01 00. The
headset emits fixed-message notification 99 01 07 01 for Off or 99 01 06 01 for
On. Respond with 98 01 <same-message> 01 only when the same session has that
exact pending user request. Ignore unrelated, unsolicited, malformed, expired,
or already-confirmed alerts. Cancel the pending request on disconnect/reset.

The headset then closes its Bluetooth control session. Verification holds the
selected headset identity, opens the native Bluetooth baseband link before
RFCOMM when necessary, and waits for capability and state readback. Reconnection
attempts are bounded and restricted to this operation, with no idle polling.
If readback is unavailable, Settings reports the failure and asks the user to
reconnect in macOS Bluetooth settings. The UI never reports success based only
on the positive confirmation or a closed channel. During hardware research,
repeated RFCOMM timeouts after changing multipoint required a manual reconnect
and headset restart before further control-channel verification.

## Validation

108 app tests cover discovery, readback, no optimistic ACK updates, preservation
of conversation fields, malformed input, XM3 isolation, unrelated confirmation
rejection, session cleanup, reconnect handling, and native scrolling previews.
The existing five signature-integrity tests also passed on the built bundle.
Live Speak-to-Chat, conversation settings, wear pause/resume, wear power-off,
and DSEE change/restore checks passed. Multipoint Off and final restored On readback are recorded in VALIDATION.md
and the exported hardware validation report, including the manual reconnect
needed after disabling it.
Physical pause/resume timing and acoustic DSP behavior were not measured.

## References

- [Public V1 schema](https://github.com/mos9527/SonyHeadphonesClient/blob/v1-compat/libmdr/include/mdr/Generated/ProtocolV1T1.hpp)
- [V1 alert subscription flow](https://github.com/mos9527/SonyHeadphonesClient/blob/v1-compat/libmdr/src/HeadphonesV1.cpp)
- [Sony Speak-to-Chat guide](https://helpguide.sony.net/mdr/wh1000xm4/v1/en/contents/TP0002754732.html)
- [Sony wearing-detection guide](https://helpguide.sony.net/mdr/wh1000xm4/v1/en/contents/TP0002928786.html)
- [Sony multipoint guide](https://helpguide.sony.net/mdr/wh1000xm4/v1/en/contents/TP0002935899.html)
