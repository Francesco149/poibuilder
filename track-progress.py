#!/usr/bin/env python3
"""
Progress tracker for ProBuilder specification extraction.
Shows which work units are done, pending, or failed.
"""

import json
import sys
import os
from pathlib import Path

def main():
    work_units = json.loads(Path("work-units.json").read_text())
    reports_dir = Path("reports")
    reports_dir.mkdir(exist_ok=True)

    done = []
    failed = []
    pending = []

    for wu in work_units:
        report_path = reports_dir / f"{wu['id']}.json"
        if report_path.exists():
            # Validate
            from validate_report import validate_report
            errors, warnings = validate_report(str(report_path))
            if errors:
                failed.append((wu, len(errors), len(warnings)))
            else:
                done.append((wu, len(warnings)))
        else:
            pending.append(wu)

    print("=" * 70)
    print("ProBuilder Specification Extraction Progress")
    print("=" * 70)
    print(f"\n  ✓ Done:    {len(done)}/{len(work_units)}")
    print(f"  ✗ Failed:  {len(failed)}/{len(work_units)}")
    print(f"  ○ Pending: {len(pending)}/{len(work_units)}")

    if done:
        print(f"\n{'─' * 70}")
        print("COMPLETED:")
        for wu, nw in done:
            warn = f" ({nw} warnings)" if nw else ""
            print(f"  ✓ {wu['id']}: {wu['title']}{warn}")

    if failed:
        print(f"\n{'─' * 70}")
        print("FAILED (need re-extraction):")
        for wu, ne, nw in failed:
            print(f"  ✗ {wu['id']}: {wu['title']} ({ne} errors, {nw} warnings)")

    if pending:
        print(f"\n{'─' * 70}")
        print("PENDING:")
        domains = {}
        for wu in pending:
            d = wu["domain"]
            if d not in domains:
                domains[d] = []
            domains[d].append(wu)
        for domain in sorted(domains):
            print(f"\n  [{domain}]")
            for wu in domains[domain]:
                print(f"    ○ {wu['id']}: {wu['title']} ({len(wu['files'])} files)")

    # Show next recommended work unit
    if pending:
        print(f"\n{'─' * 70}")
        print(f"NEXT: {pending[0]['id']} - {pending[0]['title']}")
        print(f"  Files: {', '.join(os.path.basename(f) for f in pending[0]['files'])}")

if __name__ == "__main__":
    main()
