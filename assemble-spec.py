#!/usr/bin/env python3
"""
Assembles all validated reports into a single ProBuilder specification document.
Only includes reports that pass validation.
"""

import json
from pathlib import Path

def main():
    work_units = json.loads(Path("work-units.json").read_text())
    reports_dir = Path("reports")

    # Group by domain
    domains = {}
    for wu in work_units:
        d = wu["domain"]
        if d not in domains:
            domains[d] = []
        domains[d].append(wu)

    output = []
    output.append("# ProBuilder Complete Specification")
    output.append("")
    output.append("Extracted from Unity ProBuilder v6.1.2 source code.")
    output.append("Target: Godot reimplementation with identical UX.")
    output.append("")

    # Table of contents
    output.append("## Table of Contents")
    output.append("")
    for domain in domains:
        output.append(f"### {domain}")
        for wu in domains[domain]:
            status = "✓" if (reports_dir / f"{wu['id']}.json").exists() else "○"
            output.append(f"- [{status}] {wu['id']}: {wu['title']}")
        output.append("")

    # Content
    total_sections = 0
    total_evidence = 0
    open_questions_all = []

    for domain in domains:
        output.append(f"---")
        output.append(f"# {domain}")
        output.append("")

        for wu in domains[domain]:
            report_path = reports_dir / f"{wu['id']}.json"
            if not report_path.exists():
                output.append(f"## {wu['id']}: {wu['title']}")
                output.append("")
                output.append("*Not yet extracted.*")
                output.append("")
                continue

            report = json.loads(report_path.read_text())
            output.append(f"## {wu['id']}: {report['title']}")
            output.append("")

            for section in report.get("sections", []):
                total_sections += 1
                output.append(f"### {section['heading']}")
                output.append("")
                output.append(section["content"])
                output.append("")

                # Source evidence
                evidence = section.get("source_evidence", [])
                total_evidence += len(evidence)
                if evidence:
                    output.append("<details><summary>Source Evidence</summary>")
                    output.append("")
                    for ev in evidence:
                        output.append(f"**{ev['file']}:{ev['line_range']}**")
                        output.append("```csharp")
                        output.append(ev["quote"])
                        output.append("```")
                        output.append("")
                    output.append("</details>")
                    output.append("")

                if section.get("godot_notes"):
                    output.append(f"> **Godot Note:** {section['godot_notes']}")
                    output.append("")

            # Cross references
            xrefs = report.get("cross_references", [])
            if xrefs:
                output.append("**Cross References:**")
                for xr in xrefs:
                    output.append(f"- {xr['unit_id']}: {xr['relationship']}")
                output.append("")

            # Open questions
            oqs = report.get("open_questions", [])
            if oqs:
                output.append("**Open Questions:**")
                for q in oqs:
                    output.append(f"- {q}")
                    open_questions_all.append(f"[{wu['id']}] {q}")
                output.append("")

    # Summary
    output.append("---")
    output.append("# Summary")
    output.append("")
    output.append(f"- Total sections: {total_sections}")
    output.append(f"- Total source citations: {total_evidence}")
    output.append(f"- Open questions: {len(open_questions_all)}")
    output.append("")

    if open_questions_all:
        output.append("## All Open Questions")
        output.append("")
        for q in open_questions_all:
            output.append(f"- {q}")

    spec_text = "\n".join(output)
    Path("SPECIFICATION.md").write_text(spec_text)
    print(f"Written SPECIFICATION.md ({len(spec_text)} bytes)")
    print(f"  {total_sections} sections, {total_evidence} citations, {len(open_questions_all)} open questions")

if __name__ == "__main__":
    main()
