#!/usr/bin/env python3
"""Grandfather-father-son retention for Minecraft world backups.

Understands both forms this repo can produce:
  * archives:  world-20261109T203000Z.tar.zst  (+ .sha256 sidecar)
  * snapshot dirs: 20261109T203000Z/           (legacy, still rotated)

Retention policy (all overridable):
  hourly  - every backup from the last 24 h
  daily   - the newest backup from each of the last 7 days
  weekly  - the newest backup from each of the last 4 ISO weeks
  anything older -> deleted

Usage: rotate-backups.py /mnt/backups/minecraft [--dry-run]
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import sys

TS_RE = re.compile(r"(\d{8}T\d{6}Z)")
FMT = "%Y%m%dT%H%M%SZ"


def _timestamp_of(name: str) -> dt.datetime | None:
    match = TS_RE.search(name)
    if not match:
        return None
    try:
        return dt.datetime.strptime(match.group(1), FMT).replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def collect(dest: str) -> list[tuple[dt.datetime, str]]:
    entries: list[tuple[dt.datetime, str]] = []
    for name in os.listdir(dest):
        if name.endswith(".sha256") or name.endswith(".part"):
            continue  # sidecars/files cleaned with their parent
        path = os.path.join(dest, name)
        if not (os.path.isdir(path) or os.path.isfile(path)):
            continue
        when = _timestamp_of(name)
        if when is None:
            continue
        entries.append((when, path))
    entries.sort(key=lambda item: item[0])
    return entries


def sidecars(path: str) -> list[str]:
    return [p for p in (path + ".sha256", path + ".part") if os.path.exists(p)]


def select_keep(
    entries: list[tuple[dt.datetime, str]],
    now: dt.datetime,
    keep_hours: int,
    keep_days: int,
    keep_weeks: int,
) -> set[str]:
    keep: set[str] = set()
    newest_by_day: dict[dt.date, tuple[dt.datetime, str]] = {}
    newest_by_week: dict[tuple[int, int], tuple[dt.datetime, str]] = {}
    day_cutoff = now - dt.timedelta(days=keep_days)
    week_cutoff = now - dt.timedelta(days=keep_weeks * 7)

    for when, path in entries:
        if now - when <= dt.timedelta(hours=keep_hours):
            keep.add(path)                                  # hourly tier
        elif when >= day_cutoff:
            newest_by_day[when.date()] = (when, path)        # daily tier
        elif when >= week_cutoff:
            iso = when.isocalendar()
            newest_by_week[(iso[0], iso[1])] = (when, path)  # weekly tier

    keep.update(path for _, path in newest_by_day.values())
    keep.update(path for _, path in newest_by_week.values())
    return keep


def main() -> int:
    ap = argparse.ArgumentParser(description="Rotate Minecraft world backups")
    ap.add_argument("dest")
    ap.add_argument("--keep-hours", type=int, default=24)
    ap.add_argument("--keep-days", type=int, default=7)
    ap.add_argument("--keep-weeks", type=int, default=4)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(args.dest):
        print(f"rotate-backups: {args.dest} is not a directory", file=sys.stderr)
        return 1

    now = dt.datetime.now(dt.timezone.utc)
    entries = collect(args.dest)
    keep = select_keep(entries, now, args.keep_hours, args.keep_days, args.keep_weeks)

    removed = 0
    for _when, path in entries:
        if path in keep:
            continue
        removed += 1
        if args.dry_run:
            print(f"would remove {os.path.basename(path)}")
            continue
        for extra in sidecars(path):
            os.remove(extra)
        if os.path.isdir(path):
            shutil.rmtree(path, ignore_errors=True)
        else:
            os.remove(path)

    total = 0
    for _when, path in entries:
        if not os.path.exists(path):
            continue
        if os.path.isdir(path):
            for root, _dirs, files in os.walk(path):
                for f in files:
                    try:
                        total += os.stat(os.path.join(root, f)).st_blocks * 512
                    except OSError:
                        pass
        else:
            total += os.stat(path).st_size

    print(
        f"rotate-backups: kept {len(keep)} of {len(entries)} backups, "
        f"removed {removed}, {total / 1e9:.1f} GB retained"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
