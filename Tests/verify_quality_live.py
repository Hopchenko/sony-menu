"""Validate the explicit sound-quality diagnostic; never operates headphones."""
import json
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1] if len(sys.argv) > 1 else '/private/tmp/sony-menu-diagnostics.json').read_text())
assert result.get('connection') == 'ready', result.get('connection')
assert result.get('soundQualityChangeConfirmed') is True, 'Mode change was not confirmed by the headphones'
assert result.get('originalSoundQualityRestored') is True, 'Original mode was not restored'
assert result.get('soundQualityAfterRestore') == result.get('soundQualityMode'), 'Restored mode differs'
print('Passed 4 live sound-quality assertions.')
