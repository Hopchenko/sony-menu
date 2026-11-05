# WH-1000XM3 call sidetone investigation

Tested on the connected WH-1000XM3, firmware 4.5.2, on 5 November 2026.

The reported symptom was hearing the user's voice and surrounding sounds when
Google Meet used the Sony microphone. The user confirmed that selecting
**MacBook Pro Microphone inside Meet’s own Settings → Audio** resolved it.
The app’s microphone selector changes the macOS default; it cannot override
an application's explicit microphone choice.

## Read-only device findings

The device returned MDR V1 protocol `0x4010`. A `CONNECT_GET_SUPPORT_FUNCTION`
inquiry (`06 00`) returned 19 advertised function IDs:

```text
11 C1 12 13 14 30 71 62 81 42 41 51 A1 E1 E2 D1 D2 F4 39
```

General-setting capability inquiries (`D0 <slot> 01`, English) returned:

| Slot | Returned subject | Type |
| --- | --- | --- |
| D1 | ASSIGNABLE_KEY_SETTING | List: NC/AMB, Google Assistant, Amazon Alexa |
| D2 | TOUCH_PANEL_SETTING | Boolean |
| D3 | No capability value returned | Not advertised |

The documented newer call-settings capability/parameter read requests
(`F0 08`, `F6 08`) were acknowledged but returned no corresponding values.
No returned capability identified `SIDETONE_SETTING` or the newer call controls.
All inquiries were read-only; no general-setting, call-setting, DSP, or firmware
writes were performed.

## What this establishes

There is no verified sidetone-disable control available through the tested
XM3 control interface. Noise cancellation and Ambient Sound settings are
separate from call sidetone; receiving an ACK alone would not establish that
a hypothetical off command worked.

This does **not** prove the electronics could never be modified. Deeper DSP
or firmware research would be a separate project. The app does not expose
a nonfunctional “disable sidetone” switch or send speculative write commands.

## References

- [Sony’s explanation of call sidetone and model-specific controls](https://www.sony.ee/electronics/support/wireless-headphones-bluetooth-headphones/wh-1000xm3/articles/00273844)
- [SonyHeadphonesClient V1 protocol definitions](https://github.com/mos9527/SonyHeadphonesClient/blob/v1-compat/libmdr/include/mdr/ProtocolV1T1.hpp)
- [SonyHeadphonesClient V2 protocol definitions](https://github.com/mos9527/SonyHeadphonesClient/blob/v1-compat/libmdr/include/mdr/ProtocolV2T1.hpp)
- [Independent XM3 firmware 4.5.2 capability report](https://github.com/mos9527/SonyHeadphonesClient/blob/v1-compat/docs/device-support/WH-1000XM3.md)
