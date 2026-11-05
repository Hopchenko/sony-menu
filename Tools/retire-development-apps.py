"""Move only this project's obsolete generated app bundles out of Spotlight."""
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parents[1]
register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
relocations = [
    ('build/Sony Headphone Control.app', 'build/Applications.noindex/Sony Headphone Control.app'),
    ('build/release/Sony Headphone Control.app', 'build/release.noindex/Sony Headphone Control.app'),
    ('build/Sony Menu.app', 'build/Retired.noindex/old-build-Sony Menu.app'),
    ('build/release/Sony Menu.app', 'build/Retired.noindex/old-release-Sony Menu.app'),
    ('build/IconProbe.app', 'build/Retired.noindex/IconProbe.app'),
]
for old, new in relocations:
    source, destination = root / old, root / new
    if not source.is_dir():
        continue
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'local.sonymenu.app':
        raise RuntimeError(f'Refusing to move an unrelated app: {source}')
    if destination.exists():
        destination = root / 'build/Retired.noindex' / ('old-location-' + source.name)
        number = 2
        while destination.exists():
            destination = destination.with_name(f'old-location-{number}-' + source.name)
            number += 1
    removed = subprocess.run([register, '-u', str(source)], capture_output=True, text=True)
    # Launch Services returns application-not-found for an unregistered build.
    if removed.returncode and '-10814' not in removed.stdout + removed.stderr:
        raise RuntimeError(removed.stdout + removed.stderr)
    destination.parent.mkdir(parents=True, exist_ok=True)
    source.rename(destination)
    print(f'Retired indexed development copy: {old}')
