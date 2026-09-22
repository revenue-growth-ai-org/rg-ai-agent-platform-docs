#!/usr/bin/env python3
"""Split scoped-deployment-policy.json into managed-policy-sized parts.

AWS caps a single customer-managed IAM policy at 6,144 bytes and a role's
combined inline policies at 10,240 bytes -- scoped-deployment-policy.json
exceeds both as one document, so it must be attached as multiple managed
policies instead. Re-run this after editing scoped-deployment-policy.json;
it packs statements greedily in their original order under a safety margin
so a small edit doesn't require re-checking sizes by hand.

Usage: python3 split-scoped-policy.py
Writes scoped-deployment-policy-part-N.json into this directory.
"""
import json
from pathlib import Path

HERE = Path(__file__).parent
SOURCE = HERE / "scoped-deployment-policy.json"
LIMIT = 5800  # margin under AWS's 6144-byte managed-policy limit


def size(statements):
    return len(json.dumps({"Version": "2012-10-17", "Statement": statements}, separators=(",", ":")))


def main():
    policy = json.loads(SOURCE.read_text())
    statements = policy["Statement"]

    groups, current = [], []
    for stmt in statements:
        trial = current + [stmt]
        if size(trial) > LIMIT and current:
            groups.append(current)
            current = [stmt]
        else:
            current = trial
    if current:
        groups.append(current)

    for old in HERE.glob("scoped-deployment-policy-part-*.json"):
        old.unlink()

    for i, group in enumerate(groups, 1):
        out = HERE / f"scoped-deployment-policy-part-{i}.json"
        doc = {"Version": "2012-10-17", "Statement": group}
        out.write_text(json.dumps(doc, indent=2) + "\n")
        print(f"wrote {out.name}: {len(group)} statements, {size(group)} bytes minified "
              f"({', '.join(s['Sid'] for s in group)})")

    print(f"\n{len(groups)} parts written. Attach each as a separate customer-managed policy.")


if __name__ == "__main__":
    main()
