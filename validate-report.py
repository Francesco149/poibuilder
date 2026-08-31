#!/usr/bin/env python3
"""
Validates a work unit extraction report against:
1. JSON schema compliance
2. Source evidence requirements (every section needs citations)
3. File coverage (did the agent actually read the assigned files?)
4. Content depth (rejects thin/handwavy descriptions)
5. Cross-checks extract items from work-units.json
6. Citation density (requires proportional evidence)
7. Source verification (optional: checks quotes against actual files)
"""

import json
import sys
import re
from pathlib import Path

def load_json(path):
    with open(path) as f:
        return json.load(f)

def validate_report(report_path, work_units_path="work-units.json"):
    report = load_json(report_path)
    work_units = load_json(work_units_path)

    errors = []
    warnings = []

    # Find the matching work unit
    unit_id = report.get("unit_id", "")
    matching_unit = None
    for wu in work_units:
        if wu["id"] == unit_id:
            matching_unit = wu
            break

    if not matching_unit:
        errors.append(f"FATAL: unit_id '{unit_id}' not found in work-units.json")
        return errors, warnings

    # 1. Check all required fields exist
    for field in ["unit_id", "title", "domain", "files_read", "sections"]:
        if field not in report:
            errors.append(f"MISSING FIELD: '{field}' is required")

    # 2. Check file coverage
    assigned_files = set(matching_unit["files"])
    read_files = set(fr["path"] for fr in report.get("files_read", []))

    unread = assigned_files - read_files
    if unread:
        for f in sorted(unread):
            errors.append(f"UNREAD FILE: '{f}' was assigned but not read")

    # Check that files were actually read (not just listed)
    for fr in report.get("files_read", []):
        if fr.get("lines_read", "") in ("", "0", "NONE"):
            errors.append(f"FILE NOT ACTUALLY READ: '{fr['path']}' has lines_read='{fr.get('lines_read')}'")

    # 3. Check extract item coverage
    extract_items = matching_unit.get("extract", [])
    section_headings = [s.get("heading", "").upper() for s in report.get("sections", [])]

    for item in extract_items:
        # Extract the heading keyword (before the colon)
        heading_key = item.split(":")[0].strip().upper()
        # Check if any section heading contains this key
        found = any(heading_key in sh for sh in section_headings)
        if not found:
            errors.append(f"MISSING EXTRACT: No section found for extract item '{heading_key}'")

    # 4. Check section quality
    for section in report.get("sections", []):
        heading = section.get("heading", "UNKNOWN")
        content = section.get("content", "")
        evidence = section.get("source_evidence", [])

        # Content depth check
        if len(content) < 200:
            errors.append(f"THIN CONTENT: Section '{heading}' has only {len(content)} chars. Minimum 200 required.")

        # Citation density check: at least 1 citation per 1500 chars of content
        min_citations = max(1, len(content) // 1500)
        if len(evidence) < min_citations:
            warnings.append(
                f"LOW CITATION DENSITY: Section '{heading}' has {len(content)} chars "
                f"but only {len(evidence)} citation(s). Recommend at least {min_citations}."
            )

        # Handwave detection
        handwave_phrases = [
            "similar to", "probably", "likely", "should be", "presumably",
            "standard approach", "typical", "as expected", "straightforward",
            "self-explanatory", "obvious", "trivial", "simple", "basic",
            "etc.", "and so on", "and more", "various", "multiple things",
            "handles this", "takes care of", "manages this",
        ]
        for phrase in handwave_phrases:
            if phrase.lower() in content.lower():
                warnings.append(f"HANDWAVE: Section '{heading}' contains vague phrase '{phrase}'. Be specific.")

        # Evidence check
        if not evidence:
            errors.append(f"NO EVIDENCE: Section '{heading}' has no source_evidence citations")
        else:
            cited_files = set()
            for ev in evidence:
                quote = ev.get("quote", "")
                if len(quote) < 20:
                    errors.append(f"THIN QUOTE: Section '{heading}' has quote under 20 chars: '{quote[:50]}'")
                if not ev.get("file"):
                    errors.append(f"NO FILE: Evidence in '{heading}' missing file path")
                else:
                    cited_files.add(ev["file"])
                if not ev.get("line_range"):
                    errors.append(f"NO LINE RANGE: Evidence in '{heading}' missing line_range")

        # Must contain concrete identifiers (field names, method names, etc.)
        has_code_refs = bool(re.search(r'[A-Z][a-z]+[A-Z]|[a-z]+_[a-z]+|\b[A-Z]{2,}\b|`[^`]+`', content))
        if not has_code_refs:
            warnings.append(f"NO CODE REFS: Section '{heading}' doesn't reference any identifiers. Should mention actual field/method/type names.")

        # Check for backtick-wrapped identifier density (proxy for specificity)
        backtick_ids = re.findall(r'`[^`]+`', content)
        if len(backtick_ids) < 3:
            warnings.append(f"LOW SPECIFICITY: Section '{heading}' has only {len(backtick_ids)} backtick-wrapped identifiers. Should reference concrete code elements.")

    # 5. Check cross-references exist
    if not report.get("cross_references"):
        warnings.append("NO CROSS-REFS: Report has no cross_references to related work units")

    # 6. Optional: verify quotes against actual source files
    verify = "--verify" in sys.argv
    if verify:
        for section in report.get("sections", []):
            heading = section.get("heading", "UNKNOWN")
            for ev in section.get("source_evidence", []):
                fpath = ev.get("file", "")
                # Resolve relative path
                resolved = Path(report_path).parent.parent / fpath
                if not resolved.exists():
                    # Try from cwd
                    resolved = Path(fpath)
                if not resolved.exists():
                    resolved = Path(fpath.replace("../probuilder-ref/", "/opt/src/probuilder-ref/"))

                if not resolved.exists():
                    warnings.append(f"UNVERIFIABLE: {fpath} not found on disk")
                    continue

                lr = ev.get("line_range", "")
                if "-" not in lr:
                    continue
                try:
                    start, end = lr.split("-")
                    start, end = int(start), int(end)
                except ValueError:
                    warnings.append(f"BAD LINE RANGE: '{lr}' in {heading}")
                    continue

                try:
                    actual_lines = resolved.read_text().splitlines()[start-1:end]
                    actual = "\n".join(actual_lines).strip()
                except Exception as e:
                    warnings.append(f"READ ERROR: {fpath}:{lr} — {e}")
                    continue

                quoted = ev.get("quote", "").strip()
                # Normalize for comparison (collapse whitespace)
                actual_norm = re.sub(r'\s+', ' ', actual)[:500]
                quoted_norm = re.sub(r'\s+', ' ', quoted)[:500]

                if len(actual_norm) == 0 or len(quoted_norm) == 0:
                    warnings.append(f"EMPTY COMPARISON: {heading} → {fpath}:{lr}")
                    continue

                # Character-level similarity
                matches = sum(a == b for a, b in zip(actual_norm, quoted_norm))
                similarity = matches / max(len(actual_norm), len(quoted_norm))

                if similarity < 0.7:
                    errors.append(f"FABRICATED QUOTE: Section '{heading}' quote from {fpath}:{lr} only {similarity:.0%} similar to actual source")
                elif similarity < 0.9:
                    warnings.append(f"DEGRADED QUOTE: Section '{heading}' quote from {fpath}:{lr} is {similarity:.0%} similar (encoding issues?)")

    return errors, warnings

def main():
    if len(sys.argv) < 2:
        print("Usage: python validate-report.py <report.json> [work-units.json] [--verify]")
        print("  --verify  Check quotes against actual source files on disk")
        sys.exit(1)

    report_path = sys.argv[1]
    wu_path = "work-units.json"
    for arg in sys.argv[2:]:
        if arg != "--verify" and not arg.startswith("-"):
            wu_path = arg

    errors, warnings = validate_report(report_path, wu_path)

    if warnings:
        print(f"\n⚠ {len(warnings)} WARNINGS:")
        for w in warnings:
            print(f"  ⚠ {w}")

    if errors:
        print(f"\n✗ {len(errors)} ERRORS (report REJECTED):")
        for e in errors:
            print(f"  ✗ {e}")
        sys.exit(1)
    else:
        print(f"\n✓ Report VALID ({len(warnings)} warnings)")
        sys.exit(0)

if __name__ == "__main__":
    main()
