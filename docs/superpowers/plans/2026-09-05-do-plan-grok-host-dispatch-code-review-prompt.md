## TASK

Review the implementation on branch feat/do-plan-grok-host-dispatch through `/claude-mesh:mesh-review`.
Do not continue the work.

## DO NOT

- Do not implement the plan, and do not fix what the review finds — the review skill owns
  its own fix phases.
- Do not push, do not open a PR/MR, do not call gh/glab.
- Take no action beyond reading the documents and running the preflight block below until
  the user explicitly says to start.

## DOCUMENTS

- Git range: `b24e4671898578612ceffaf546b9806dcad68e6a..151d1603e0ad2656dbeb6ca154ce48202981aeec` on branch `feat/do-plan-grok-host-dispatch`, against base `master`
  (HEAD at generation: `151d1603e0ad2656dbeb6ca154ce48202981aeec`). If HEAD has moved since, review through the current
  HEAD and say so. Pass that base on when starting the review (see the invocation below):
  without it every review skill auto-detects its own — `origin/HEAD`, else `master` — which
  is a different range whenever this base is not the repository default.
- Commits:
  151d160 fix: drop PreToolUse from the context hook
  4314d93 fix: /do-plan on Grok inherits host models and polls signals.json for STOP
- Note: uncommitted changes existed at generation — the review covers commits only.

## ENVIRONMENT

This session probably runs in a sandbox. git remote, gh and glab may be unreachable. The set
of configured agents and models HERE differs from the session that wrote this prompt — assume
no reviewer exists until the preflight below says so. Local commits are normal and expected:
mesh-review commits its own auto-fixes and decisions.

## PREFLIGHT — run this before anything else

```bash
PF="./skills/shared/preflight-env.sh"
[ -f "$PF" ] || [ -z "${GROK_SESSION_ID:-}" ] || PF="$(find "$HOME"/.grok/installed-plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$PF" ] || PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$PF" ] || PF="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$PF" ] || { echo "preflight-env.sh not found — older claude-mesh here; expected degradation, NOT a broken environment"; exit 0; }
bash "$PF"
```

Print the table verbatim. Do not soften a verdict into "probably fine". `OK` on the codex /
gemini rows is a heuristic — binary present, section valid, endpoint answered; NOT an auth
check, and it does not prove the CLI points at that endpoint. `OK` on grok is stronger: the
probe runs the CLI itself, which answers only when a login is live. `OK` on gh / glab means
presence on PATH only. If the script is not found, say so and ask the user whether to update
the plugin in this sandbox first or proceed on the built-in `claude` reviewer alone — and
before offering that, check a `config.yaml` exists in the plugin data dir: claude needs no
config section, but the review skills refuse to start without a usable config.yaml at all.

## CONTEXT

Implemented without a written design or plan (bounded in-chat design). Goal: `/do-plan` works on Grok without changing the Claude Code path.

Dispatch: on Grok, `runtime.dispatch_model` is passed to `spawn_subagent` only if it is a live `grok models` slug (`list-host-models.sh`, `grep -Fxq`). Miss / empty catalog / no `timeout(1)` → clear `DISPATCH_MODEL`, omit `model:` so the child inherits the session. `spawn_subagent` has no effort field; inherit is what keeps session effort (e.g. xhigh). Claude Code still passes the configured alias (opus) as before.

Session bind: `SID="${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}"`. Both empty still abort.

STOP on Grok is not the hook. Grok ignores `PostToolUse` stdout and does not inject status-line / `/session-info` counts into the model. Step 1 echoes `CONTEXT_SIGNALS=`; after each task checkpoint the controller reads `contextTokensUsed` and pauses at the threshold. Auto-compact (~85% of the Grok window) is not the `/do-plan` threshold.

Hook: still `PostToolUse` only — `hooks.json` matches master (no `PreToolUse`, no extra timeout). The script also parses Grok camelCase, `signals.json`, `$GROK_PLUGIN_DATA`, and skips `subagentType`. That path is unused for STOP on Grok; do not treat a missing hook reminder as a defect.

Deviation: a `PreToolUse` registration was added, then removed in 151d160, so Claude Code hook wiring stayed identical.

Unfinished / not live-verified: a real Grok `/do-plan` run that crosses the threshold; Grok plugin reinstall (copy, not live mount). Known pre-existing data-dir mismatch under `--plugin-dir` is out of scope.

Weak spots: `CONTEXT_SIGNALS` glob `sessions/*/$SID/signals.json`; missing file → WARN and continue (no invented count); catalog probe fail-closed to inherit; Go-yq flavour test failures on this machine are pre-existing and not in this diff.

## THEN STOP

1. Summarise what was built, in 5–10 lines.
2. Print the preflight table verbatim.
3. One line: which reviewers are actually available here.
4. Wait. Do not start the review on your own.

## WHEN THE USER SAYS GO

Invoke `/claude-mesh:mesh-review BASE_BRANCH=master` and select only reviewers the
preflight marked available. The argument is what makes the reviewers look at the range named
under DOCUMENTS; drop it and each skill re-detects a base of its own.
The two halves of the table answer different questions, so read both: **`SUMMARY available`
decides eligibility** — a reviewer absent from that line cannot be selected whatever its own row
says, because a row reports whether that endpoint answered, not whether the orchestrator starts.
With a rejected `claude:` section, `provider:*` rows can read `OK` next to `SUMMARY available: —`,
and both orchestrators exit on the catalog read before offering anything. **The ROWS carry the
caveats** the summary has no room for: `OK` on codex / gemini is a heuristic — binary present,
section valid, endpoint answered — and says nothing about auth, while `OK` on grok also means
a live login: its probe runs the CLI itself.

Whether the `default` argument is safe here is a membership check between two SUMMARY lines.
Split both on `, ` and compare WHOLE entries — never substrings: a bare `claude` is a substring
of `claude:<model>`, and `<provider>/<model>` of `<provider>/<model>-<variant>`, so a substring
test reports a match where the orchestrator would find none.

- `SUMMARY available: —` → `default` is never safe, however the defaults line reads. Nothing is
  selectable in that environment, and membership against an empty list is vacuously true — the
  one case where the mechanical check would say yes precisely when the answer is no. With no
  usable config both lines print `—`; with a rejected `claude:` section the defaults line prints
  a real list next to an empty available line.
- `SUMMARY defaults code_review: —` or `— (preset empty)` → also never safe, for the same
  reason read the other way: there is no preset to run, and `default` mode stops instead of
  starting.
- Otherwise `default` is safe only when every entry of the defaults line is also an entry of the
  available line — with one exception: a bare `claude` on the defaults line is satisfied by any
  `claude:<model>` entry on the available line. That spelling means the preset carries no
  `claude_models`, and the orchestrator then runs exactly one reviewer named literally `claude`
  on the session's dispatch model, which asks the catalog for nothing.

Anything short of that → select interactively.
