"""Validate the explicit live diagnostic run; never operates the headphones."""
import json
import sys
from pathlib import Path

path = Path(sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/sony-menu-diagnostics.json")
result = json.loads(path.read_text())
expected = {
    "connection": "ready",
    "externalVolumeWriteSucceeded": True,
    "coreAudioVolumeEventReceived": True,
    "externalVolumeSyncedToPanel": True,
    "panelWriteSyncedToMac": True,
    "controlChangeConfirmed": True,
    "originalModeRestored": True,
    "volumeChangeConfirmed": True,
    "originalVolumeRestored": True,
    "sleepHandlerDisconnectedHeadphones": True,
    "reconnectedAfterSleepTest": True,
    "idleConnectionChecks": 0,
    "idleBluetoothQueries": 0,
}
failures = [f"{key}: expected {value!r}, got {result.get(key)!r}" for key, value in expected.items() if result.get(key) != value]
if failures:
    raise SystemExit("Live checks failed or were not requested:\n" + "\n".join(failures))
print(f"Passed {len(expected)} live diagnostic assertions.")
