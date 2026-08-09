---
name: claude-md-writer
description: Use when creating or refactoring CLAUDE.md files - enforces best practices for size, structure, and content organization
user_invocable: true
---

# CLAUDE.md Writer

Creates and refactors CLAUDE.md files following official Anthropic best practices.

**CLAUDE.md is context, not configuration.** It is delivered as a user message after the
system prompt — Claude reads it and tries to comply, but nothing enforces it. Anything that
MUST happen every time belongs in a hook, not here.

## Golden Rules

| Rule | Why |
|------|-----|
| **CLAUDE.md < 200 lines** | Loads on EVERY request, costs tokens |
| **Rules files < 500 lines each** | Rule of thumb, not an official limit — long files lose adherence |
| **Critical rules FIRST** | A bloated file gets half-ignored; buried rules are the ones lost |
| **Modular rules → `.claude/rules/`** | Conditional loading, organized |
| **Use `paths:` frontmatter** | Load rules only for matching files |
| **No linting rules** | Use ESLint/Prettier/Biome instead |
| **Pointers over copies** | Files change, references stay valid |
| **`@imports` do NOT save context** | Imported files load at launch too — only `paths:` rules cut tokens |

## Memory Hierarchy

Claude Code concatenates memory files rather than overriding them, in this load order —
broadest scope first, most specific last, so the most specific is read last:

| Order | Type | Location |
|-------|------|----------|
| 1 | Managed policy | macOS `/Library/Application Support/ClaudeCode/CLAUDE.md` · Linux/WSL `/etc/claude-code/CLAUDE.md` · Windows `C:\Program Files\ClaudeCode\CLAUDE.md` |
| 2 | User | `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md` |
| 3 | Project | `./CLAUDE.md` or `./.claude/CLAUDE.md`, `./.claude/rules/*.md` |
| 4 | Local | `./CLAUDE.local.md` |

Managed policy cannot be excluded by user settings. Rules without `paths:` carry the same
priority as the `CLAUDE.md` beside them; user rules load before project rules. Files in
directories *above* the working directory load at launch; those in subdirectories load on
demand when Claude reads a file there.

`/memory` lists and opens memory files. **`/context` shows what actually loaded** — that is
the one to check when a rule seems to be ignored.

## Auto Memory

A second, separate system: Claude writes its own notes to
`~/.claude/projects/<project>/memory/`, indexed by `MEMORY.md`. Only the first 200 lines (or
25 KB) of that index load each session; topic files beside it are read on demand. You write
CLAUDE.md; Claude writes auto memory. Disable per project with `"autoMemoryEnabled": false`.

## 3-Tier Documentation System

Community pattern (Claude Code Development Kit), mapped onto Claude Code's own loaders.
Useful for large projects; it is not an Anthropic recommendation:

| Tier | Location | Loads | Target |
|------|----------|-------|--------|
| **1. Foundation** | `CLAUDE.md` | Always | < 200 lines |
| **2. Component** | `.claude/rules/{component}/` | When working in component | < 500 lines |
| **3. Feature** | Co-located with code | When working on feature | As needed |

Example structure:
```
.claude/
├── CLAUDE.md                 # Tier 1: always loaded
└── rules/
    ├── database.md           # Tier 2: SQL, migrations
    ├── api.md                # Tier 2: API patterns
    └── frontend/             # Tier 2: subdirectory
        ├── components.md     # paths: src/**/*.tsx
        ├── layout.md         # paths: src/pages/**/*.tsx
        └── tokens.md         # paths: **/*.tsx
```

## Structure Template

```markdown
# Project Name

One-line description.

## Commands

- `npm run dev` - Development
- `npm run build` - Production
- `npm run test` - Tests

## Architecture

| Path | Purpose |
|------|---------|
| `lib/` | Core logic |
| `app/api/` | API routes |

## Key Patterns

**Pattern Name**: One-line explanation.

## Database (if applicable)

| Table | Key Fields |
|-------|------------|

## Modular Docs

See `.claude/rules/` for:
- `database.md` - queries, schema
- `deploy.md` - deployment

## Tech Stack

One line: Next.js 15, PostgreSQL, TypeScript
```

## Conditional Rules (Path-Specific)

Use YAML frontmatter for file-type-specific rules:

```markdown
---
paths: "src/api/**/*.ts"
---

# API Rules

- All endpoints must validate input
- Use standard error format
```

### Glob Patterns

| Pattern | Matches |
|---------|---------|
| `**/*.ts` | All .ts files anywhere |
| `src/**/*` | All files under src/ |
| `*.md` | Markdown in project root |
| `src/components/*.tsx` | Components in specific dir |

### Combining Patterns

```yaml
# Multiple extensions
paths: "src/**/*.{ts,tsx}"

# Multiple directories
paths: "{src,lib}/**/*.ts, tests/**/*.test.ts"
```

**Note:** Wrap patterns in quotes for YAML safety.

Rules with `paths:` only load when working with matching files → saves tokens. This is the
only mechanism that genuinely reduces startup context.

Behaviour worth knowing:

| Fact | Consequence |
|------|-------------|
| Matching triggers when Claude **reads** a matching file, not on every tool use | A rule can stay dormant for a whole session |
| Path-scoped rules are **not re-injected after `/compact`** | They reload the next time a matching file is read |
| Brace groups multiply: a rule's whole `paths:` list shares a budget of 1000 expanded patterns / 4 MiB | Over budget → the pattern is used unexpanded and its literal braces match nothing |
| `[` starts a bracket expression | `photos [2024/**` matches nothing; escape it as `photos \[2024/**` |
| `.claude/rules/` follows symlinks | `ln -s ~/shared-rules .claude/rules/shared` to share one set across projects |

Debug what loaded with the `InstructionsLoaded` hook — it logs which instruction files
loaded, when, and why.

## Workflow: New Project

1. Run `/init` for base CLAUDE.md
2. Review and trim generated content
3. Identify critical rules — what breaks if ignored?
4. Create `.claude/rules/` for domain-specific docs
5. Keep main file < 100 lines

## Workflow: Refactor Existing

1. **Count lines** — if > 300, must split
2. **Find task-specific content** — SQL, debugging, deploy → extract
3. **Create `.claude/rules/`**:
   - `database.md` - queries, schema, connection
   - `deploy.md` - deployment process
   - `messaging.md` - integrations (Telegram, etc.)
4. **Move it, don't import it** — `@file` imports still load at launch, so they organise but
   do not shrink context. Only `.claude/rules/` with `paths:` cuts what gets loaded.
5. **Keep in CLAUDE.md** — only what applies to EVERY task
6. **Run `/doctor`** — it proposes trims for a checked-in CLAUDE.md, cutting what Claude can
   derive from the codebase and keeping pitfalls and conventions (needs CC 2.1.206+)

## What Goes Where

| Content | Location |
|---------|----------|
| Project description | CLAUDE.md |
| Critical constraints | CLAUDE.md (top!) |
| Quick start (3 commands) | CLAUDE.md |
| Architecture overview | CLAUDE.md |
| Key patterns (1-liners) | CLAUDE.md |
| SQL queries/schema | `.claude/rules/database.md` |
| Deployment steps | `.claude/rules/deploy.md` |
| API documentation | `.claude/rules/api.md` |
| Git workflow | `.claude/rules/git.md` |
| Personal preferences | `CLAUDE.local.md` (gitignore it) |
| Code style rules | `.eslintrc` / `biome.json` (NOT docs) |

## Import Syntax

Reference files instead of duplicating:

```markdown
@README.md
@docs/architecture.md
@~/.claude/snippets/common.md
```

- Relative: `@docs/file.md` — resolves against the importing file, not the working directory
- Absolute: `@~/path/file.md`
- Max depth: 4 hops
- **Imports load at launch.** They organise content; they do not reduce context
- An import in a project file that resolves *outside* the working directory is external:
  Claude Code shows a one-time approval dialog. User-scope imports load without it
- Parsing skips code spans and fenced blocks — write `` `@README` `` to mention a path
  without importing it

### AGENTS.md

Claude Code reads `CLAUDE.md`, not `AGENTS.md`. If the repo already has one, import it
(`@AGENTS.md` on the first line, Claude-specific rules below) or symlink `CLAUDE.md` to it.

### Monorepos

`claudeMdExcludes` in `.claude/settings.local.json` skips other teams' files by glob:

```json
{ "claudeMdExcludes": ["**/monorepo/CLAUDE.md", "/path/to/other-team/.claude/rules/**"] }
```

## CLAUDE.local.md

Personal project settings — **add it to `.gitignore` yourself**; it is not automatic (the
exception: with `CLAUDE_CODE_NEW_INIT=1`, `/init`'s personal option does it for you):

```markdown
# My Local Settings

- Prefer verbose output
- Run tests after every change
- My worktree location: .trees/
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| 500+ lines | Split into `.claude/rules/` |
| SQL examples inline | → `rules/database.md` |
| "Run prettier" rules | Use tool config files |
| Full API docs | → `rules/api.md` |
| Deployment instructions | → `rules/deploy.md` |
| Code in CLAUDE.md | Cite the location in backticks: `` `src/api/auth.ts:42` `` |
| Negative rules only | Add alternatives: "Don't X; use Y instead" |
| `@imports` used to shrink the file | They load at launch — move content to `paths:` rules instead |
| A rule that MUST hold every time | CLAUDE.md is advisory; use a hook |
| Maintainer notes costing tokens | Block-level `<!-- HTML comments -->` are stripped before loading |

## Quality Checklist

Before finishing:

- [ ] CLAUDE.md < 200 lines?
- [ ] Each rules file < 500 lines?
- [ ] Critical rules at top?
- [ ] No task-specific content in main file?
- [ ] No code style rules (use ESLint/Prettier)?
- [ ] `.claude/rules/` for domain-specific docs?
- [ ] Subdirectories for components (frontend/, backend/)?
- [ ] `paths:` frontmatter for conditional loading?
- [ ] `@` references instead of duplication?
- [ ] CLAUDE.local.md for personal prefs, and listed in `.gitignore`?
- [ ] `/context` confirms the files actually loaded?

## Useful Commands

| Command | Purpose |
|---------|---------|
| `/init` | Generate initial CLAUDE.md |
| `/memory` | List and open memory files; toggle auto memory |
| `/context` | What actually loaded this session — the real check |
| `/doctor` | Proposes trims for a checked-in CLAUDE.md (CC 2.1.206+) |

## Sources

Official:
- code.claude.com/docs/en/memory (memory hierarchy, rules, `paths:` globs, auto memory)
- code.claude.com/docs/en/best-practices (was anthropic.com/engineering/claude-code-best-practices)
- claude.com/blog/using-claude-md-files (Nov 2025 — predates the "context, not system prompt" clarification)

Community:
- thedocumentation.org/claude-code-development-kit (3-Tier System)
- claudefa.st/blog/guide/mechanics/rules-directory
- humanlayer.dev/blog/writing-a-good-claude-md

Updated: Aug 2026 — checked against the docs above and Claude Code 2.1.226.

---

Vendored from [serejaris/personal-corp-os](https://github.com/serejaris/personal-corp-os/tree/main/skills/claude-md-writer)
(MIT), then corrected against the current docs. Changes: `user_invocable:` frontmatter;
import depth 4 not 5; `/context` (not `/memory`) shows what loaded; `CLAUDE.local.md` is not
auto-gitignored; memory hierarchy rebuilt in documented load order with the Linux and Windows
managed-policy paths; `@imports` no longer presented as a way to cut context; the 3-Tier
system and the 500-line rule relabelled as community/heuristic rather than official; stale
best-practices URL; plus auto memory, AGENTS.md, `claudeMdExcludes`, `/doctor`, glob budget
and compaction behaviour.
