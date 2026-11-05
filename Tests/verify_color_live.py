"""Validate explicit color/icon diagnostics; does not change app or headphones."""
import json
from pathlib import Path
import sys

result = json.loads(Path(sys.argv[1] if len(sys.argv) > 1 else '/private/tmp/sony-menu-diagnostics.json').read_text())
checks = [
    ('connected', result.get('connection') == 'ready'),
    ('reported color', result.get('reportedHeadphoneColor') in ['black', 'silver']),
    ('restored choice', result.get('colorChoiceRestored') is True),
    ('Bluetooth authorization', result.get('bluetoothAuthorizationAfterIconChanges') == 3),
]
if result.get('headphoneColorChoice') == 'automatic':
    checks.append(('Auto matches report', result.get('resolvedHeadphoneColor') == result.get('reportedHeadphoneColor')))
for color in ['black', 'silver']:
    value = result.get('colorIconChecks', {}).get(color, {})
    checks.append((f'{color} resolved', value.get('resolvedColor') == color))
    for key in ['applicationIconMatches', 'finderIconMatches', 'finderIconUpdated']:
        checks.append((f'{color} {key}', value.get(key) is True))
if len(sys.argv) > 2:
    relaunch = json.loads(Path(sys.argv[2]).read_text())
    checks.extend([
        ('relaunch ready', relaunch.get('connection') == 'ready'),
        ('relaunch initially authorized', relaunch.get('initialBluetoothAuthorization') == 3),
        ('relaunch authorized', relaunch.get('bluetoothAuthorization') == 3),
    ])
failures = [name for name, passed in checks if not passed]
if failures:
    raise SystemExit('Color/icon checks failed or were not requested: ' + ', '.join(failures))
print(f'Passed {len(checks)} live color/icon assertions.')
