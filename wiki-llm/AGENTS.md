# Wiki-LLM maintenance contract

This directory is the durable, model-oriented map of the router project.
Read `wiki/index.md` first, then follow links to the smallest relevant page.
The canonical implementation remains the parent codebase; the wiki explains it.

## Layout

- `raw/sources/` holds immutable imported source material, when any exists.
- `raw/assets/` holds immutable imported binary assets, when any exists.
- `wiki/` contains synthesized, maintained knowledge.
- `wiki/index.md` is the complete navigation entry point.
- `wiki/log.md` is append-only maintenance history.

## Editing rules

- Keep one topic per page and use kebab-case file names.
- Prefer pages between 20 and 80 lines.
- Link related pages with `[[relative/path]]` wiki links.
- Every wiki page must end with a `## Sources` section.
- Cite repository paths and commands that substantiate each page.
- Update `wiki/index.md` whenever a page is added, moved, or removed.
- Append to `wiki/log.md`; do not rewrite prior history.
- Treat `raw/` content as immutable after import.

## Security rules

- Never copy secret values, private keys, tokens, passwords, or cookies.
- Refer to `.env` and `config.json` by path and schema only.
- Do not include live public IP addresses unless operationally required.
- Sanitize diagnostic examples before adding them to the wiki.
- Treat router diagnostics and packet captures as potentially sensitive.

## Truth and freshness

- Mark historical proposals as historical; do not present them as active design.
- Distinguish verified live state from intended configuration.
- Prefer current scripts over `.claude/plan.md`, which is superseded.
- Record meaningful audits, deployments, and architecture changes in the log.
- If code and wiki disagree, repair the wiki in the same change.

## Sources

- The Wiki-LLM structure specification supplied as a session attachment.
- `../README.md` and `raw/sources/project-context-2026-10-25.md` define project intent.
