"""Build the installable Callboard ZIP for a GitHub Actions run."""

import argparse
from pathlib import Path
import re
import subprocess
from zipfile import ZIP_DEFLATED, ZipFile


ADDON = "addons/callboard"
PLUGIN_CONFIG = f"{ADDON}/plugin.cfg"
VERSION_LINE = re.compile(r'^version="(\d+)\.(\d+)\.(\d+)"$', re.MULTILINE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("run_number", type=int)
    parser.add_argument("--pr", type=int)
    args = parser.parse_args()

    config = Path(PLUGIN_CONFIG).read_text(encoding="utf-8")
    base_version = VERSION_LINE.search(config)
    if base_version is None:
        parser.error(f"Expected a major.minor.patch version in {PLUGIN_CONFIG}")
    major, minor, patch = map(int, base_version.groups())
    version = f"{major}.{minor}.{patch + args.run_number}"
    if args.pr is not None:
        version += f"-pr.{args.pr}"

    tracked = subprocess.check_output(["git", "ls-files", "-z", "--", ADDON, "LICENSE"])
    files = [name for name in tracked.decode("utf-8").split("\0")
             if name and not name.startswith(f"{ADDON}/tests/")]
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / f"callboard-{version}.zip"
    with ZipFile(archive, "w", compression=ZIP_DEFLATED) as package:
        for name in files:
            if name == PLUGIN_CONFIG:
                package.writestr(name, VERSION_LINE.sub(f'version="{version}"', config, count=1))
            else:
                package.write(name, name)
    print(version)


if __name__ == "__main__":
    main()
