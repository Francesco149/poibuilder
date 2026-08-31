# ProBuilder → Godot Specification Extraction Protocol

## Goal

Extract a complete, precise specification of every feature, UX interaction,
algorithm, and configuration option in Unity 6 ProBuilder (v6.1.2) from its
source code. The specification must be detailed enough that a developer can
recreate the exact same tool in Godot without access to Unity.

## Source Code Location

All ProBuilder source: `../probuilder-ref/`

Key directories:
- `Runtime/Core/` — Data model, math, enums, mesh representation (80 files, 20k lines)
- `Runtime/MeshOperations/` — Algorithms: extrude, bevel, connect, etc. (20 files, 7.5k lines)
- `Runtime/Shapes/` — Shape primitive generators (14 files, 2.8k lines)
- `Editor/EditorCore/` — Editor tools, UI, scene view interaction (100 files, 29k lines)
- `Editor/MenuActions/` — Individual menu actions by category (68 files, 7k lines)
- `Editor/Overlays/` — Overlay panels (4 files, 1k lines)
- `Editor/StateMachines/` — Shape drawing state machine (4 files, 408 lines)
- `Content/Shader/` — Rendering shaders for overlays and picking (26 files, 3.4k lines)
- `Documentation~/` — Official docs (121 markdown files)

Total: ~442 C# files, ~88k lines of code.

## Work Units

The codebase is divided into **29 work units** defined in `work-units.json`.
Each unit specifies:
- `id` — e.g., "A01"
- `files` — exact file paths to read
- `extract` — specific information to extract (each becomes a report section)
- `doc_refs` — related documentation files in `Documentation~/`

## How to Process a Work Unit

### Step 1: Read the work unit definition
```
Read work-units.json, find your assigned unit by ID.
```

### Step 2: Read ALL documentation first
Read every doc_ref file listed for the unit. These provide intent and user-facing
descriptions. Path: `../probuilder-ref/Documentation~/<filename>`

### Step 3: Read EVERY assigned source file COMPLETELY
You MUST read every file listed in the unit's `files` array. For files over 200
lines, read in chunks (e.g., lines 1-200, then 201-400, etc.). Do NOT skip any
file. Do NOT skim.

Record what you read:
- File path
- Total lines in file
- Lines you actually read

### Step 4: Extract information for each item
For each item in the `extract` array, write a detailed section. Rules:

1. **Be concrete.** Name every field, type, method, enum value, constant, default.
2. **Quote source code.** Every claim must include a verbatim code quote (10-30 lines)
   with file path and line range.
3. **Describe algorithms step by step.** Not "it computes the extrusion" but the
   actual sequence of operations with variable names.
4. **Include all parameters** with types, defaults, and valid ranges.
5. **Describe UX flows** as step-by-step user interactions: what the user clicks/drags,
   what visual feedback appears, what state changes.

### Step 5: Write your report
Output a JSON file matching the schema in `schemas/work-unit-report.schema.json`.
Save to `reports/<unit_id>.json`.

### Step 6: Self-validate
Run: `python validate-report.py reports/<unit_id>.json`
Fix all errors before declaring done. Warnings are advisory but should be addressed.

## Quality Gates (the agent MUST NOT)

1. **Skip files.** Every file in the unit's `files` array must be read completely.
2. **Handwave.** Phrases like "similar to", "as expected", "straightforward",
   "handles this" are rejected. Say exactly what happens.
3. **Omit evidence.** Every section needs at least one source code citation.
4. **Invent behavior.** If you can't determine something from source, list it
   in `open_questions`. Never guess.
5. **Write thin sections.** Minimum 200 characters per section content.
6. **Skip extract items.** Every item in the `extract` array must have a
   corresponding section in your report.

## Report JSON Structure

```json
{
  "unit_id": "A01",
  "title": "ProBuilderMesh core data structures",
  "domain": "Data Model",
  "files_read": [
    {
      "path": "../probuilder-ref/Runtime/Core/ProBuilderMesh.cs",
      "lines_total": 1018,
      "lines_read": "FULL"
    }
  ],
  "sections": [
    {
      "heading": "FIELDS",
      "content": "Detailed description with field names, types, defaults...",
      "source_evidence": [
        {
          "file": "../probuilder-ref/Runtime/Core/ProBuilderMesh.cs",
          "line_range": "45-67",
          "quote": "exact code from source..."
        }
      ],
      "godot_notes": "Optional Godot-specific notes"
    }
  ],
  "cross_references": [
    { "unit_id": "A02", "relationship": "Face/Edge types referenced by mesh" }
  ],
  "open_questions": ["Could not determine X from source alone"]
}
```

## Domains and Work Unit Overview

| Domain | Units | Description |
|--------|-------|-------------|
| Data Model | A01-A04 | Core types, enums, math, mesh representation |
| Mesh Operations | B01-B04 | Extrude, connect, delete, transform algorithms |
| UV & Texturing | C01-C02 | UV editor, auto/manual UV, texture tools |
| Shape Creation | D01-D03 | Primitives, draw tool, poly/bezier shapes |
| Selection & Picking | E01-E03 | Color picking, rect select, loops/rings |
| Editor Tools | F01-F03 | Move/rotate/scale, cut tool, texture tools |
| Visual Rendering | G01-G02 | Wireframes, overlays, shaders |
| UI & Overlays | H01-H02 | Toolbar, settings, menus |
| Object Operations | I01-I02 | Merge, mirror, export, import, materials |
| Special Editors | J01 | Smoothing, vertex colors, positions |
| Interaction & Undo | K01 | Toggles, undo, drag-drop |
| Topology | L01 | WingedEdge, topology traversal |
| Boolean/CSG | M01 | CSG operations |

## Processing Order

Start with foundation (data model) and work outward:
1. A01 → A02 → A03 → A04 (data model — everything else depends on this)
2. L01 (topology — needed by many operations)
3. B01 → B02 → B03 → B04 (mesh operations)
4. E01 → E02 → E03 (selection)
5. F01 → F02 → F03 (tools)
6. G01 → G02 (rendering)
7. D01 → D02 → D03 (shapes)
8. C01 → C02 (UV)
9. H01 → H02 (UI)
10. I01 → I02 (object ops)
11. J01, K01, M01 (remaining)

## Agent Session Orientation

When starting a fresh session to process a work unit:

1. Read THIS file (`PROTOCOL.md`)
2. Read `work-units.json` to find your assigned unit
3. Check `reports/` to see what's already done
4. Read the schema: `schemas/work-unit-report.schema.json`
5. Begin processing your assigned unit following the steps above

## File Manifest

`probuilder-manifest.json` contains every source file organized by category
with line counts. Use this to plan your reading.
