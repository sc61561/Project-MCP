"""Collect build-environment license texts into the generated app, not source code."""
import importlib.metadata
import json
import shutil
import sys
from pathlib import Path

destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
packages = []
for distribution in importlib.metadata.distributions():
    name = distribution.metadata['Name']
    if name.lower() in {'pytest', 'pyinstaller', 'pyinstaller-hooks-contrib', 'altgraph', 'macholib'}:
        continue
    packages.append({'name': name, 'version': distribution.version,
                     'license': distribution.metadata.get('License-Expression') or distribution.metadata.get('License', 'See bundled license texts')})
    for item in distribution.files or []:
        if any(part.lower().startswith(('license', 'copying', 'notice', 'copyright')) for part in item.parts):
            source = Path(distribution.locate_file(item))
            if source.is_file():
                target = destination / name / item
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
(destination / 'python-packages.json').write_text(json.dumps(packages, indent=2), encoding='utf-8')
