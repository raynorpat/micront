#!/usr/bin/env python3
"""Stamp NTVERP.H with a fresh build identity.

Run as part of CI before the MSVC build kicks off:

    python src/tools/stamp-version.py              # auto-detect from git
    python src/tools/stamp-version.py --channel rc
    python src/tools/stamp-version.py --date 20260415 --sha abc1234 --channel dev
    python src/tools/stamp-version.py --show       # print current stamp, no write

Idempotent — re-running with the same inputs produces no diff.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import libversion as lv


def _parse_date(s: str) -> dt.date:
    return dt.datetime.strptime(s, "%Y%m%d").date()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--channel", choices=(*lv.CHANNELS, "auto"), default="auto")
    ap.add_argument("--date", type=_parse_date, metavar="YYYYMMDD",
                    help="override build date (default: today UTC)")
    ap.add_argument("--sha", help="override 7-char git short sha")
    ap.add_argument("--show", action="store_true",
                    help="print current on-disk stamp and exit")
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if writing would change the file")
    args = ap.parse_args()

    if args.show:
        try:
            s = lv.parse_ntverp()
        except RuntimeError as e:
            print(f"unstamped: {e}", file=sys.stderr)
            return 1
        print(f"NT {s.version_str}  {s.current_build_number}  "
              f"channel={s.channel}  sha={s.sha}  "
              f"tuple={s.version_tuple}  beta={s.beta_str!r}")
        return 0

    auto = lv.detect_from_git()
    stamp = lv.BuildStamp(
        date=args.date or auto.date,
        sha=args.sha or auto.sha,
        channel=auto.channel if args.channel == "auto" else args.channel,
    )

    if args.check:
        # Parse current, compare — no write.
        try:
            current = lv.parse_ntverp()
        except RuntimeError:
            print("NTVERP.H not yet stamped", file=sys.stderr)
            return 2
        if current == stamp:
            return 0
        print(f"stamp differs: on-disk={current} desired={stamp}", file=sys.stderr)
        return 2

    changed = lv.write_ntverp(stamp)
    action = "updated" if changed else "unchanged"
    print(f"{lv.NTVERP_PATH}: {action}  "
          f"NT {stamp.version_str}  {stamp.current_build_number}  "
          f"{stamp.channel}  {stamp.sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
