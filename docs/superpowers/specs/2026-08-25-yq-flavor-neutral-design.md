# Flavor-neutral yq — design

**Date:** 2026-08-25
**Topic:** `yq-flavor-neutral`
**Status:** design approved in brainstorming; implementation plan pending

## Problem

`config-loader.sh` refuses to run when the `yq` on PATH is Go-yq (`mikefarah/yq`) rather than
Python-yq (`kislyuk/yq`). `require_yq()` (:60-72) reads `yq --version` and `die`s on a Go-yq
banner. `apt install yq`, `brew install yq` and recent `snap install yq` all deliver Go-yq, so
on an ordinary machine the loader dies before it opens `config.yaml`.

`preflight-env.sh` reports that as `config UNKNOWN` (cause: toolchain) and, critically,
`SUMMARY available: —`: no reviewer is selectable, not even the built-in `claude`, whose row
reads "config state could not be evaluated". `/mesh-review` and `/mesh-design-review` cannot
start at all. The sandboxes that run this plugin's own fresh-session prompts hit exactly this.

The rationale in the code is aimed one step off target. The comment at :64-66 says Go-yq "will
silently misparse" the jq-style expressions. Those expressions run under `jq`, not under `yq`.
The plugin uses `yq` for exactly one operation — a single YAML→JSON transcode at :133,
`yq '.' "$CONFIG_FILE" > "$CONFIG_JSON"` — after which every read is a `jq` call against the
snapshot. The design note at :116-132 states this outright, and a grep confirms there is no
other functional `yq` invocation in the repository. The real and only incompatibility is the
invocation itself: under Go-yq `yq '.'` emits YAML, so `jq` on the "snapshot" fails. Go-yq's
JSON form is `yq -o=json '.'`.

## Decisions taken

| Question | Decision | Rationale |
|---|---|---|
| Scope | Either flavor works; `yq` stays a hard dependency | Making `yq` optional needs a python3 fallback, and PyYAML — the only realistic one — is YAML 1.1 (measured: `off` → `false`), which would silently change what a config means |
| How the flavor is established | It is not: run the invocation, verify the output is JSON | An identity check is open-ended; "did this produce JSON" is closed, and unlike a banner it cannot be faked |
| The YAML-1.1 risk | Detected in the snapshot, then confirmed against the installed binary | Scalar resolution of `off/on/yes/no` is the only property that accepting a second flavor can break, and it is visible in the output. A version gate would instead rest on claims about Go-yq v3 that this design could not verify |
| What triggers the scalar probe | The presence of a boolean in the snapshot — never which invocation succeeded | Gating on the winning form is an identity inference: a flavor whose default output is JSON skips the check. A prototype caught exactly that |
| Version gate | None | Any `yq` that cannot emit JSON is refused by one and the same path, whatever it calls itself. An old v4 without `-o=json` needs no special case |
| Docs stance | Flavor-neutral; the distro→flavor matrix is deleted, not inverted | That matrix already rotted once. Measured here: `/usr/bin/yq` came from a third-party repository (`4.53.6-2~ops2deb`), not from Ubuntu main |
| Preflight rows | `yq` and `jq` gain OK rows | Which `yq` is installed is now a real variable affecting behaviour and speed, and the probe exists to answer "what can actually be used here" |
| Hint text | One line covering all three `yq` failures | Absent and incapable share a fix; the YAML-1.1 case is unobserved; and the `config` row already carries the loader's exact sentence |

## Architecture: capability, not identity

The loader stops asking *which* `yq` is installed and starts asking *which invocation of it
produces JSON*. That is the only property the snapshot needs, and it is the one an identity
check can merely guess at.

Two forms are tried in order — the Python-yq form first, so the historically recommended
flavor pays nothing for the fallback:

1. `yq '.' FILE` — Python-yq is a `jq` wrapper whose default output is already JSON;
2. `yq -o=json '.' FILE` — Go-yq v4 prints YAML unless told otherwise.

Each is accepted only if `jq` can parse what it wrote.

Scalar semantics are then checked the same way — against the artifact, never against the
binary's identity. A YAML-1.1 resolver differs from a YAML-1.2-core one by turning
`off/on/yes/no` into booleans, so the divergence, when it happens, is visible as a boolean in
the snapshot. If the snapshot holds none, no divergence was possible on that document and
nothing more is asked. If it holds some, a probe settles whether this `yq` can be trusted.

## Measured evidence

Ubuntu 26.04; Python-yq 4.1.2 (`~/.local/bin/yq`) and Go-yq v4.53.6 (`/usr/bin/yq`); 10
iterations per figure.

| operation | Python-yq | Go-yq v4 |
|---|---|---|
| `yq --version` (the current flavor check) | 94 ms | 7 ms |
| `yq '.' cfg` / `yq -o=json '.' cfg` | 115 ms | 13 ms |
| `jq . snapshot` | 4 ms | 4 ms |
| `config-loader.sh list-models`, end to end | 480 ms | — |

`require_yq` is reached from `load_or_die`, and `load_or_die` from every subcommand except
`data-dir` (11 call sites), so that 94 ms is paid on every loader invocation today. Deleting
the flavor check makes the Python-yq path *faster* than it is now. On a real config — which
holds no booleans, so the scalar probe never runs — the work is 115 (transcode) + 4 (`jq`
validity) + 4 (boolean scan) = 123 ms, against today's 94 + 115 = 209 ms. The Go-yq path costs
13 + 4 for the rejected first form, 13 + 4 for the second and 4 for the scan: about 38 ms. A
config that does contain booleans adds one probe — 87 ms under Python-yq, which puts it back at
roughly today's figure, and 13 ms under Go-yq.

Type resolution is identical across flavors. For `a: off`, `b: yes`, `c: true`, `d: 3` both
produce `"string","string","boolean","number"` — exactly the semantics `validate_codex`
(:288), `validate_defaults` (:522) and Test 45 depend on. Normalised with `jq -S .`, both
flavors transcode real configs byte-for-byte identically: `config.example.yaml` 3310 bytes and
the installed `config.yaml` 3851 bytes, empty diff in each case.

Neither real config contains a boolean at all: `[paths(type=="boolean")] | length` returns 0
for `config.example.yaml` and 0 for the installed `config.yaml`. That is what makes the gate
above free in practice rather than merely cheap.

A YAML-1.1 resolver also does not corrupt anything silently — it produces a misleading refusal.
Running today's loader against a double that transcodes with PyYAML, a config carrying
`reasoning_level: off` comes back as:

```
config-loader: codex.reasoning_level: must be a string (got boolean) — quote it, e.g. reasoning_level: "ultra"
```

The user is told to quote a value that is already correct, and the real culprit is never named.
That is the same misattribution this design exists to remove, one layer deeper than the Go-yq
refusal itself.

Two behaviours that shape the code:

- **The validity gate must be `jq .`, not `jq -e .`.** On an empty snapshot `jq -e .` returns
  rc=4 while `jq .` returns rc=0. Python-yq transcodes an empty or comment-only `config.yaml`
  to **0 bytes** — the case the comment at :148 already describes. With `-e` the loader would
  read that as "the first form failed", fall through, and end in a "check yaml syntax" die
  instead of today's honest "providers: section is empty or missing".
- **The degenerate document converges on its own.** Go-yq also emits nothing for an empty file,
  so `jq .` accepts it and the first form "wins" on a Go-yq. Nothing is lost: on a document
  where YAML and JSON coincide the snapshot is correct either way, and there are no `off/yes`
  scalars to mis-resolve. On any non-empty config Go-yq emits block YAML, which `jq .` rejects
  with rc=5 (verified on `config.example.yaml` and on a one-line `a: off`).

This algorithm was prototyped end to end against all six scenarios — real Python-yq, real
Go-yq, and the three doubles below, over good, malformed, empty and comment-only configs —
before it was written down. The prototype is what produced the boolean gate: an earlier draft
gated the probe on which invocation had won, and the YAML-1.1 double walked straight through it
because its default output is JSON.

The current detector is also weaker than it looks. Running its own `case` statement over test
strings: `yq (https://github.com/mikefarah/yq/) version v4.53.6` is rejected, while `yq 4.1.2`,
`yq version 3.4.1`, `yq 3.2.3` and `yq version 4.9.8` all pass. Only the `mikefarah` URL or the
literal `version v` is recognised; anything else sails through the check and then dies at the
transcode with `(check yaml syntax)` — blaming a `config.yaml` nothing has read.

## The loader

`require_yq` keeps the presence check and loses the flavor police. The substring `yq not found`
is preserved verbatim: `preflight-env.sh:239` already matches on it.

```bash
require_yq() {
    command -v yq >/dev/null 2>&1 || die "yq not found. claude-mesh accepts either flavor: \
Python-yq (kislyuk/yq — 'pipx install yq') or Go-yq v4+ (mikefarah/yq — 'apt install yq', \
'brew install yq'). Install either one."
}
```

`yq_to_json` replaces the bare call at :133. Which form won is deliberately not recorded: nothing downstream may branch on it (see the gate below).

```bash
# Python-yq (kislyuk/yq) is a jq wrapper: its DEFAULT output is already JSON. Go-yq (mikefarah)
# v4 prints YAML unless told -o=json. We do not ask which one is installed — the only property
# the snapshot needs is "this invocation returned JSON", and that is checked rather than
# guessed. The order is not arbitrary: the python-yq form goes first so the historically
# recommended flavor pays nothing for the fallback.
yq_to_json() {                       # $1 = source YAML, $2 = destination JSON
    yq '.'         "$1" > "$2" 2>/dev/null && jq . "$2" >/dev/null 2>&1 && return 0
    yq -o=json '.' "$1" > "$2" 2>/dev/null && jq . "$2" >/dev/null 2>&1 && return 0
    return 1
}
```

`yq_probe` answers three questions with one invocation: can this `yq` emit JSON at all, and if
so does it resolve scalars correctly. It reports through a global rather than through stdout,
and that is deliberate — see the note in the code.

```bash
YQ_SCALARS_1_2='"string","string","boolean","number"'
# The one property that accepting a second flavor can break: off/on/yes/no must stay STRINGS
# (YAML 1.2 core). A YAML-1.1 resolver turns them into booleans, and validate_codex,
# validate_defaults and Test 45 then read that as a type error or a failed membership test — a
# config that silently changed meaning. Checked against the binary that is actually installed,
# not inferred from a version number.
# SETS YQ_PROBE_TYPES; does NOT print. A `die` inside a $(...) substitution would exit only the
# SUBSHELL, and the caller would carry on reading an empty result as "this yq cannot emit JSON"
# — a tmpfile failure reported as a toolchain verdict. An empty YQ_PROBE_TYPES must mean one
# thing only.
yq_probe() {
    YQ_PROBE_TYPES=""
    local d
    d=$(mktemp -d -t claude-mesh-yqprobe-XXXXXX) || die "mktemp failed for the yq probe"
    printf 'a: off\nb: yes\nc: true\nd: 3\n' > "$d/probe.yaml"
    yq_to_json "$d/probe.yaml" "$d/probe.json" \
        && YQ_PROBE_TYPES=$(jq -r '[.a,.b,.c,.d|type]|@csv' "$d/probe.json" 2>/dev/null)
    rm -rf "$d"
}
```

And the call site inside `load_or_die`:

```bash
if yq_to_json "$CONFIG_FILE" "$CONFIG_JSON"; then
    # A YAML-1.1 resolver differs from YAML-1.2-core by ONE thing that reaches this schema: it
    # turns off/on/yes/no into booleans. Such a divergence therefore always shows up AS A
    # BOOLEAN IN THE SNAPSHOT. No booleans means no divergence was possible on this document,
    # whichever binary produced it — a property of the artifact, not an inference about who ran.
    # Gating on "which form won" instead would be an identity check smuggled back in: a flavor
    # whose DEFAULT output is JSON would win with the first form and skip this entirely.
    # Measured 2026-08-25: config.example.yaml and the installed config.yaml both hold ZERO
    # booleans, so on a real config the probe below never runs.
    # ${bools:-0} guards the same case as $count at :151 — an empty snapshot makes jq print nothing.
    local bools
    bools=$(jq '[paths(type=="boolean")] | length' "$CONFIG_JSON" 2>/dev/null)
    if [ "${bools:-0}" -gt 0 ]; then
        yq_probe
        if [ "$YQ_PROBE_TYPES" != "$YQ_SCALARS_1_2" ]; then
            rm -f "$CONFIG_JSON"
            die "yq mis-resolves YAML scalars: off/on/yes/no must stay strings (YAML 1.2 core), \
but this yq turned them into booleans. claude-mesh needs Python-yq (kislyuk/yq) or Go-yq v4+ \
(mikefarah/yq). Got: $(yq --version 2>&1 | head -1)"
        fi
    fi
else
    rm -f "$CONFIG_JSON"
    # The transcode failed: is that the yq's fault or the yaml's? The probe runs a document
    # that is known to be good, so it separates the two.
    yq_probe
    if [ -n "$YQ_PROBE_TYPES" ]; then
        die "config snapshot: yaml→json conversion failed for $CONFIG_FILE (check yaml syntax)"
    else
        die "yq cannot produce JSON: neither 'yq .' nor 'yq -o=json .' returned JSON for a \
known-good document. claude-mesh accepts Python-yq (kislyuk/yq — 'pipx install yq') or Go-yq \
v4+ (mikefarah/yq — 'apt install yq', 'brew install yq'). Got: $(yq --version 2>&1 | head -1)"
    fi
fi
```

`yq --version` survives only inside the two new `die` messages, on paths that end in `exit 1`.

Net effect on the loader's toolchain messages: `yq flavor mismatch` disappears; `yq not found`
keeps its wording; `yq cannot produce JSON` and `yq mis-resolves YAML scalars` are new; and
`config snapshot: ... (check yaml syntax)` stays and now means only what it says.

## Preflight

1. **Signature match (~239).** `*"yq not found"*|*"yq cannot produce JSON"*|*"yq mis-resolves"*`.
   Every toolchain `die` must appear here or it falls through to `*)` → `config INVALID` and
   accuses an unread `config.yaml` — the impersonation this routing exists to prevent.
2. **Hint (~693).** One flavor-neutral line: install a `yq` that emits JSON, `pipx install yq`
   (Python-yq) or `apt install yq` / `brew install yq` (Go-yq v4+). Deliberately not three
   lines: "absent" and "incapable" share a fix, the YAML-1.1 state is unobserved and, as far as this
   design can tell, hard to reach at all (a flavor that emits JSON by neither form lands in
   "incapable" instead), and the `config`
   row already prints the loader's own first stderr line verbatim. The honest cost is that for
   a YAML-1.1 flavor the bottom-line advice can be a no-op while the diagnosis sits one row
   above.
3. **Comments.** Three blocks become false and must be rewritten, not left standing: ~231-236
   ("a Go-yq binary ... is present under the name the loader looks for, and passes it"),
   ~689-693 ("Go-yq is a DIFFERENT program that config-loader.sh rejects on sight
   (config-loader.sh:71)" — the cited line will not exist), and ~649-651.
4. **OK rows.** `toolchain_row` currently prints nothing on success, so the table says nothing
   about which `yq` is in play. It gains an OK row carrying the `--version` banner, for `yq` and
   `jq` alike (one shared helper, no special case). The row does not name the working *form*:
   deriving that would duplicate loader logic, and this file's own doctrine forbids
   re-deriving a verdict made elsewhere. The banner comes from `$YQ_BIN`, matching
   `toolchain_row`'s stated contract that the override governs what this script checks.

## Tests

**The existing Go-yq stub stops being usable, and that is the design working.** The stub at
`test-preflight-env.sh:222-227` answers `--version` with a mikefarah banner and `exit 0` to
everything else. Run against the new loader it produces 0 bytes, `jq .` accepts that (rc=0), the
first form "succeeds" with an empty snapshot, the probe never runs, and the validators land on
`config INVALID` — the test would assert the wrong thing entirely. Identity can be faked with a
banner; capability cannot. A double must now really transcode.

Three doubles, all built from what is already installed:

| double | construction | what it covers |
|---|---|---|
| `mkyq_go` | `--version` → mikefarah banner; `-o=json '.'` → `python-yq '.'`; bare `'.'` → `python-yq -y '.'` | the second form, happy path |
| `mkyq_nojson` | both forms → `python-yq -y '.'` | `yq cannot produce JSON` routed to toolchain, not to "check yaml syntax" |
| `mkyq_yaml11` | `python3 -c 'json.dump(yaml.safe_load(...))'` | `yq mis-resolves YAML scalars`, and the accept half of the per-document rule |

Python-yq's `-y` flag emits YAML (`a: 'off'`) which `jq .` rejects with rc=5, so a faithful
Go-yq impersonation needs nothing beyond python-yq. The third double is the same PyYAML
YAML-1.1 behaviour that disqualified python3 as an *implementation*, reused as the ideal
negative fixture for the failure the probe guards against; it needs `import yaml` and skips
loudly when that is unavailable.

`test-config-loader.sh` gains: a sibling to Test 45 running `reasoning_level: off` under
`mkyq_go` and expecting `gpt-5.5|off`; the two new toolchain dies, the `nojson` one asserting
`assert_no_match` on "check yaml syntax"; `mkyq_yaml11` against a config with no
boolean-producing scalars, which must be **accepted** — the other half of the per-document rule,
and the assertion that stops a future refactor from turning the gate back into a blanket probe;
a malformed-yaml case under a healthy `yq` that must still say "check yaml syntax"; and empty / comment-only configs still reporting "providers:
section is empty or missing" under **both** forms — the degenerate case where `jq .` cannot
tell the flavors apart, which is why it is locked by a test rather than by an argument.

`test-preflight-env.sh`: the `~215-232` scenario is rewritten on `mkyq_go` and flips to
`config OK`, losing its `flavor mismatch` and `pipx install yq` assertions; two new scenarios
take over the UNKNOWN role; `:654` and `:669` move to the new hint wording, with `:669` still
proving that toolchain advice does not leak into the TMPDIR case; the new OK rows get an
assertion on the happy path.

**Real binary, opportunistically and loudly.** Doubles prove the plumbing, not that a real
Go-yq behaves. `type -a yq` finds `/usr/bin/yq` and `/bin/yq` as mikefarah v4.53.6 on this
machine even though `command -v yq` resolves to python-yq, so a helper that walks every `yq` in
PATH and reads its banner will find a real one when there is one. The tests here deliberately
do the identity check that production no longer does — production asks "can this one do the
job", a test asks "is the implementation I need to exercise present"; different questions. When
no real Go-yq is found the suite prints `SKIP: no real Go-yq found — the mikefarah path was
exercised only against a stub`. Never zero coverage, never a silent gap; and never a hard
requirement for both binaries, because there is no CI and the suites are run by hand.

**PATH hygiene.** Overrides go on the individual invocation (`PATH="$WORK/goyq:$PATH" "$LOADER"
...`), never exported across the suite: `test-config-loader.sh:638` calls raw `yq -r
'.models[].id'` in its own harness and a global export would send that through a double.

## File-by-file changes

Line numbers as of `a7dd2f5`.

- `skills/shared/config-loader.sh` — `require_yq()` (:60-72) loses the flavor `case`; new
  `yq_to_json` and `yq_probe`; the transcode at :133 becomes the branch above; the notes at
  :116-132 and the flavor remarks at :288 and :522 are updated to say "either flavor".
- `skills/shared/preflight-env.sh` — signature match :239; hint :693; comments ~231-236,
  ~649-651, ~689-693; `toolchain_row` gains its OK row.
- `skills/shared/tests/test-config-loader.sh` — the doubles, the new scenarios, the Test 45
  sibling.
- `skills/shared/tests/test-preflight-env.sh` — :215-232 rewritten; :232, :654, :669 reworded;
  two new scenarios; OK-row assertions.
- `README.md` — :128 dependency row; :136-137 install commands (`yq` moves to its own line with
  no distro claims); :139 "Important" paragraph deleted; :180-181 troubleshooting rows.
- `skills/ext-claude-exec/SKILL.md:415` — the same troubleshooting row.
- `CHANGELOG.md` — `### Requirements` for the dependency contract, `### Fixed` for the refusal
  and for the misrouted transcode failure.

## Out of scope

- Making `yq` optional or removing it; vendoring a transcoder.
- Auto-selecting between two installed `yq` binaries — PATH order stands.
- The version bump and `chore(release):` commit. In this repository releasing is its own step
  after the PR merges; the recommendation is **0.11.0**, not 0.10.1, because the dependency
  contract, the `die` texts and the preflight table all change.
- `commands/mesh-review.md:58` and `skills/mesh-design-review/SKILL.md:20,229`, which say "read
  config through the loader, never raw `yq`" — still true, untouched.

## Verification (manual)

1. Both suites under Python-yq.
2. Both suites again with PATH pointed at Go-yq — the strongest available check, and it needs
   no new machinery, only time (182 s → roughly 364 s for the pair).
3. `preflight-env.sh` by hand under each flavor: `config OK`, `SUMMARY available:` non-empty,
   and the new `yq`/`jq` rows naming the binary in use.
4. Sanity on the timing claim: `config-loader.sh list-models` under Python-yq should drop from
   roughly 480 ms.

## Risks

- **Go-yq v3 was never verified** — it is not installable here, and no claim in this design
  rests on it. Whatever it does, it reaches the loader through the same two forms and is
  refused by the same path if neither yields JSON. Residual: the message it gets says "cannot
  produce JSON" rather than "too old".
- **The scalar check is per-document, and that is deliberate.** A `yq` that resolves YAML 1.1 is
  accepted for a config that yields no booleans — correctly, because on that document it emitted
  exactly what a YAML-1.2-core resolver would, and the snapshot is all anything downstream reads.
  It is refused the moment a boolean appears. Both halves are pinned by tests.
- **`YQ_PROBE_TYPES` is a global, and that is load-bearing.** The probe reports through it rather
  than through stdout so that a `die` inside the probe is not swallowed by a command
  substitution — which would turn a tmpfile failure into a toolchain verdict.
- **No CI.** The real-Go-yq scenarios depend on the machine having one. The suite announces the
  gap instead of hiding it.
