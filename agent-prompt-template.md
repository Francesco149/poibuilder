You are extracting a detailed specification from Unity ProBuilder source code.

## Your Assignment

Work Unit: {unit_id} — {title}
Domain: {domain}

## Protocol

Read PROTOCOL.md in the working directory first, then follow it exactly.

## Required Steps (in order)

1. Read `work-units.json` and find unit "{unit_id}".
2. Read every doc_ref file listed: `../probuilder-ref/Documentation~/<filename>`
3. Read EVERY source file listed in the unit's `files` array. Read completely.
   For files >200 lines, read in sequential chunks of 200 lines.
   Track exactly what lines you read.
4. For each item in the `extract` array, write a section with:
   - Concrete field names, types, methods, values, algorithms
   - Verbatim source code quotes (10-30 lines each) with file + line range
   - Step-by-step algorithm descriptions where applicable
5. Write `reports/{unit_id}.json` matching the schema in `schemas/work-unit-report.schema.json`
6. Run `python validate-report.py reports/{unit_id}.json` and fix any errors.

## Anti-Drift Rules

- Do NOT skip any file in the files list.
- Do NOT use phrases like "similar to", "as expected", "straightforward", "handles this".
- Do NOT guess. If unsure, add to open_questions.
- Every section needs at least one source_evidence citation with verbatim code.
- Minimum 200 characters per section content.
- Name every field, type, method, parameter, default value you encounter.

## Output

Your final output is the file `reports/{unit_id}.json`. Confirm it passes validation.
