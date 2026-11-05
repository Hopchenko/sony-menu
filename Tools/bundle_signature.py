"""Verify signed code strictly, allowing only macOS's external Finder icon metadata.

NSWorkspace.setIcon adds FinderInfo and a zero-data Icon\r resource-fork file.
These preserve normal code validity and its designated requirement, but strict
packaging hygiene rejects them. Verify a temporary copy without those two
metadata items; never alter the installed app or remove sealed resources.
"""
from pathlib import Path
import subprocess
import tempfile


def _check(app: Path, strict: bool = True) -> subprocess.CompletedProcess:
    command = ['/usr/bin/codesign', '--verify', '--deep']
    if strict:
        command.append('--strict')
    return subprocess.run(command + [str(app)], capture_output=True, text=True)


def verify_bundle_signature(app: Path) -> str:
    strict = _check(app)
    if strict.returncode == 0:
        return 'strict signature'
    icon = app / 'Icon\r'
    if not icon.is_file() or icon.is_symlink() or icon.stat().st_size != 0:
        raise RuntimeError(strict.stderr.strip())
    finder = subprocess.run(['/usr/bin/xattr', '-px', 'com.apple.FinderInfo', str(app)], capture_output=True, text=True)
    try:
        info = bytes.fromhex(finder.stdout)
    except ValueError:
        info = b''
    if finder.returncode or len(info) != 32 or not int.from_bytes(info[8:10], 'big') & 0x0400:
        raise RuntimeError(strict.stderr.strip())
    normal = _check(app, strict=False)
    if normal.returncode:
        raise RuntimeError(normal.stderr.strip())
    with tempfile.TemporaryDirectory(prefix='sony-menu-signature-') as temporary:
        clean = Path(temporary) / app.name
        subprocess.run(['/usr/bin/ditto', str(app), str(clean)], check=True)
        subprocess.run(['/usr/bin/xattr', '-d', 'com.apple.FinderInfo', str(clean)], check=True)
        (clean / 'Icon\r').unlink()
        cleaned = _check(clean)
        if cleaned.returncode:
            raise RuntimeError(cleaned.stderr.strip())
    return 'strict signature on a copy without Finder icon metadata; original code validity confirmed'
