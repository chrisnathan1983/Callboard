"""Build the installable Callboard ZIP for a GitHub Actions run."""

import argparse
from datetime import datetime, timezone
from pathlib import Path
import re
import subprocess
from zipfile import ZIP_DEFLATED, ZipFile


ADDON = "addons/callboard"
PLUGIN_CONFIG = f"{ADDON}/plugin.cfg"
VERSION_LINE = re.compile(r'^version="[^"\r\n]*"$', re.MULTILINE)


def parse_timestamp(value: str) -> datetime:
    try:
        timestamp = datetime.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("Expected an ISO 8601 timestamp") from exc
    if timestamp.utcoffset() is None:
        raise argparse.ArgumentTypeError("The timestamp must include a timezone")
    return timestamp.astimezone(timezone.utc)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("created_at", type=parse_timestamp, help="Workflow creation timestamp")
    parser.add_argument("--pr", type=int)
    args = parser.parse_args()

    config = Path(PLUGIN_CONFIG).read_text(encoding="utf-8")
    if VERSION_LINE.search(config) is None:
        parser.error(f"Missing version field in {PLUGIN_CONFIG}")
    timestamp = args.created_at
    version = f"0.{timestamp.month}.{timestamp.day}.{timestamp:%H%M%S}"
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
