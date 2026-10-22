#!/usr/bin/env python3
"""Runs SwiftLint and fails on any violation not already in
.swiftlint-baseline.json, or one that got worse.

SwiftLint's own --baseline matches a size violation by its message, which
carries the size: a grandfathered 600-line type then fails as soon as it
changes length in either direction, and the only way on is to regenerate
the baseline, which also lets growth in. Here a grandfathered file, type,
function or line may shrink but not grow, so the old code can only get
better and new code meets the rules in full.

Regenerate the baseline (only when a rule changes) with
`swiftlint lint --write-baseline .swiftlint-baseline.json`.
"""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, ".swiftlint-baseline.json")
SIZE = re.compile(r"currently (?:spans |contains |it has |complexity is |has )?(\d+)")


def size(reason):
    match = SIZE.search(reason)
    return int(match.group(1)) if match else None


def key(rule, file, text):
    return (rule, file, "" if rule == "file_length" else text.strip())


def main():
    with open(BASELINE) as f:
        allowed = defaultdict(list)
        for entry in json.load(f):
            violation = entry["violation"]
            k = key(violation["ruleIdentifier"], violation["location"]["file"], entry["text"])
            allowed[k].append(size(violation["reason"]))

    result = subprocess.run(
        ["swiftlint", "lint", "--strict", "--quiet", "--reporter", "json"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode not in (0, 2):
        sys.stderr.write(result.stderr)
        return result.returncode
    violations = json.loads(result.stdout or "[]")

    failures = []
    for v in violations:
        file = os.path.relpath(v["file"], ROOT)
        with open(v["file"], encoding="utf-8") as f:
            lines = f.read().split("\n")
        text = lines[v["line"] - 1] if v["line"] and v["line"] <= len(lines) else ""
        sizes = allowed[key(v["rule_id"], file, text)]
        now = size(v["reason"])
        fits = [s for s in sizes if s is None or now is None or now <= s]
        if fits:
            sizes.remove(min(fits, key=lambda s: -1 if s is None else s))
            continue
        failures.append(f"{file}:{v['line']}:{v['character'] or 1}: {v['reason']} ({v['rule_id']})")

    for line in failures:
        print(line)
    if failures:
        print(f"{len(failures)} SwiftLint violation(s). Grandfathered code may shrink, but not grow.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
