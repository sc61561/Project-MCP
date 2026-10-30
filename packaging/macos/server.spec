# Build from the repository root with the isolated build interpreter.
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, collect_data_files, copy_metadata

root = Path(SPECPATH).resolve().parents[1]
datas, binaries, hiddenimports = [], [], []
for package in ('fastmcp', 'mcp', 'burner_redis'):
    package_datas, package_binaries, package_imports = collect_all(package)
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_imports
datas += copy_metadata('fastmcp', recursive=True)
datas += collect_data_files('docket')
a = Analysis([str(root / 'server.py')], pathex=[str(root)], binaries=binaries,
             datas=datas, hiddenimports=hiddenimports, excludes=['pytest', 'tkinter'],
             noarchive=False)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='project-mcp-server',
          debug=False, strip=False, upx=False, console=True, target_arch='arm64')
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name='server')
