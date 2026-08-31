#!/usr/bin/env python3
"""
Generates a concrete agent prompt for a specific work unit.
Usage: python gen-prompt.py A01
"""

import json
import sys
from pathlib import Path

def main():
    if len(sys.argv) < 2:
        print("Usage: python gen-prompt.py <unit_id>")
        sys.exit(1)

    unit_id = sys.argv[1].upper()
    work_units = json.loads(Path("work-units.json").read_text())
    template = Path("agent-prompt-template.md").read_text()

    matching = [wu for wu in work_units if wu["id"] == unit_id]
    if not matching:
        print(f"Unknown unit: {unit_id}")
        print("Available:", ", ".join(wu["id"] for wu in work_units))
        sys.exit(1)

    wu = matching[0]
    prompt = template.format(
        unit_id=wu["id"],
        title=wu["title"],
        domain=wu["domain"],
    )

    # Add the specific file list and extract items for clarity
    prompt += "\n## Files to Read\n\n"
    for f in wu["files"]:
        prompt += f"- `{f}`\n"

    if wu.get("doc_refs"):
        prompt += "\n## Documentation to Read First\n\n"
        for d in wu["doc_refs"]:
            prompt += f"- `../probuilder-ref/Documentation~/{d}`\n"

    prompt += "\n## Information to Extract\n\n"
    for item in wu["extract"]:
        prompt += f"- {item}\n"

    print(prompt)

if __name__ == "__main__":
    main()
