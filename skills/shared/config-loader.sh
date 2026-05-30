#!/usr/bin/env bash
# config-loader.sh — parses, validates, and exports claude-mesh config.
#
# Usage:
#   config-loader.sh validate           # validate only, exit 0/1
#   config-loader.sh data-dir           # print resolved plugin data dir (no validation; works pre-config)
#   config-loader.sh export <model-id>  # validate + print `export KEY=val` lines
#
# Data dir resolved by resolve_plugin_data(): $CLAUDE_PLUGIN_DATA if set (hook context),
# else the ~/.claude/plugins/data/claude-mesh-* dir with config.yaml, else claude-mesh-zinin.
# (Task 2.5, CC 2.1.156: $CLAUDE_PLUGIN_DATA is EMPTY in skill Bash-tool calls.)
# Config: $PLUGIN_DATA/config.yaml

set -u

# Bash 4+ required. macOS ships system bash 3.2 — instruct user to `brew install bash`.
# Fast-fail here so users get a clear message instead of `declare: -A: invalid option`
# from validate_models (or any other 4+ feature) deep in the call stack.
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
    echo "config-loader: bash 4+ required (got ${BASH_VERSION:-unknown}). Install: brew install bash" >&2
    exit 1
}

resolve_plugin_data() {
    # CLAUDE_PLUGIN_DATA is set in HOOK contexts but EMPTY in skill Bash-tool calls
    # (Task 2.5, CC 2.1.156). Resolve robustly.
    if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then printf '%s\n' "$CLAUDE_PLUGIN_DATA"; return; fi
    local d cand=""
    for d in "$HOME"/.claude/plugins/data/claude-mesh-*; do
        [ -d "$d" ] || continue
        if [ -f "$d/config.yaml" ]; then printf '%s\n' "$d"; return; fi
        [ -z "$cand" ] && cand="$d"
    done
    [ -n "$cand" ] && { printf '%s\n' "$cand"; return; }
    printf '%s\n' "$HOME/.claude/plugins/data/claude-mesh-zinin"
}
PLUGIN_DATA="$(resolve_plugin_data)"
CONFIG_FILE="$PLUGIN_DATA/config.yaml"

die() {
    echo "config-loader: $*" >&2
    exit 1
}

require_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        die "yq not found. claude-mesh requires Python-yq (kislyuk/yq). Install: 'pipx install yq' or 'pip install --user yq'. Do NOT install via 'brew install yq' or recent 'snap install yq' — those provide Go-yq with an incompatible DSL."
    fi
    # Detect flavor: Python-yq (kislyuk/yq, jq-wrapper) prints e.g. "yq 3.x.y" and is a Python script;
    # Go-yq (mikefarah/yq) prints "yq (https://github.com/mikefarah/yq/) version v4.x.y".
    # The plan's expressions (raw jq with escaped quotes) are Python-yq syntax — Go-yq will silently misparse them.
    local yq_ver
    yq_ver=$(yq --version 2>&1 | head -1)
    case "$yq_ver" in
        *mikefarah*|*"version v"*)
            die "yq flavor mismatch: detected Go-yq (mikefarah/yq) but claude-mesh requires Python-yq (kislyuk/yq). Install via: 'pipx install yq'. Remove or shadow the Go-yq binary in PATH. Got: $yq_ver"
            ;;
    esac
}

require_gnu_coreutils() {
    # claude-mesh uses GNU-only utilities: `timeout`, `stdbuf`, `setsid`, `stat -c`, `find`.
    # On macOS these are absent by default (BSD find lacks `-printf`; BSD stat uses `-f`; no `timeout`
    # without coreutils; no `setsid` without util-linux). Users must install GNU coreutils + util-linux
    # + findutils via Homebrew and put gnubin first in PATH. Fast-fail with concrete instructions.
    case "$(uname -s)" in
        Darwin)
            local missing=""
            # `find` is also required (some skills shell out to `find ... -mtime ...`). We check
            # that `find` exists; the supervised-mode loop was rewritten to use `ls -t` so we no
            # longer depend on GNU `find -printf` specifically.
            for tool in timeout stdbuf stat setsid find; do
                if ! command -v "$tool" >/dev/null 2>&1; then
                    missing="$missing $tool"
                fi
            done
            # GNU `stat -c` test catches BSD-vs-GNU divergence even if `stat` itself is present.
            if command -v stat >/dev/null 2>&1 && ! stat -c %Y "$0" >/dev/null 2>&1; then
                missing="$missing stat(GNU)"
            fi
            if [ -n "$missing" ]; then
                die "macOS detected but GNU coreutils/util-linux/findutils not first in PATH (missing:$missing). Install: 'brew install bash coreutils util-linux findutils' then prepend gnubin to PATH: 'export PATH=\"\$(brew --prefix)/opt/coreutils/libexec/gnubin:\$(brew --prefix)/opt/util-linux/sbin:\$(brew --prefix)/opt/util-linux/bin:\$(brew --prefix)/opt/findutils/libexec/gnubin:\$PATH\"' (add to your shell rc)."
            fi
            ;;
    esac
}

load_or_die() {
    # iter-2 CONCERN-11: "config not found" gets a DISTINCT exit code (2) so
    # user-invoked commands like /do-plan can tolerate the genuinely-tolerable
    # "no config yet" case during first-run, while every other class of error
    # (yaml malformed, env binaries missing, validator die) still fast-fails
    # via the canonical `die` (rc=1). See `commands/do-plan.md` Step 1 for the
    # consumer side. Do NOT fold this into `die` — it must stay distinguishable.
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "config.yaml not found at $CONFIG_FILE. Copy config.example.yaml from the plugin install dir." >&2
        exit 2
    fi
    require_yq
    require_gnu_coreutils
    command -v jq >/dev/null 2>&1 || die "jq not found. Install: 'apt install jq' or 'brew install jq' (jq is universal — same on Linux and macOS)."

    # CONCERN-3 + CONCERN-12: snapshot the yaml to a JSON tmpfile and read everything
    # downstream through jq on the snapshot. This (a) eliminates mid-edit race
    # (the loader sees one consistent version for the duration of one call) and
    # (b) replaces ~30+ yq invocations with one yq + N jq calls (jq is much faster
    # and ships everywhere). Expressions are identical because Python-yq is a jq
    # wrapper — yq's jq-style expressions transfer to jq one-for-one.
    CONFIG_JSON=$(mktemp -t claude-mesh-cfg-XXXXXX.json) || die "mktemp failed for config snapshot"
    chmod 600 "$CONFIG_JSON"
    # NOTE (Task 5): the plan text shows `yq -o=json '.'`, but `-o`/`--output` is GO-yq
    # (mikefarah) syntax. claude-mesh targets PYTHON-yq (kislyuk/yq) — see require_yq above —
    # whose DEFAULT behavior already transcodes YAML→JSON (the `-y` flag is what switches it
    # to YAML output). With Python-yq, `-o=json` is forwarded verbatim to jq, which rejects it
    # ("jq: Unknown option -o=json", exit 2), so the snapshot would ALWAYS fail. The correct,
    # flavor-consistent invocation is therefore the bare `yq '.'`. This still satisfies the
    # JSON-snapshot invariant (one yq → $CONFIG_JSON, then all reads via jq on the snapshot).
    if ! yq '.' "$CONFIG_FILE" > "$CONFIG_JSON" 2>/dev/null; then
        rm -f "$CONFIG_JSON"
        die "config snapshot: yaml→json conversion failed for $CONFIG_FILE (check yaml syntax)"
    fi
    # Cleanup runs even on `die` because die exits non-zero and the EXIT trap fires.
    # NOTE: bash EXIT traps do NOT stack — if a caller later sets its own `trap … EXIT`
    # it REPLACES this one. That is why cmd_export (Task 8) must manage its own
    # $CONFIG_JSON / $ENV_FILE cleanup explicitly rather than relying on this trap.
    trap 'rm -f "$CONFIG_JSON"' EXIT
}

validate_providers() {
    local count
    # CONCERN-12: null-coalesce so `providers: null` (or `providers: ~`) doesn't yield
    # "integer expression expected" on the next line.
    count=$(jq '(.providers // []) | length' "$CONFIG_JSON")
    [ "$count" -gt 0 ] || die "providers: section is empty or missing"

    # Per-provider checks
    local i=0
    local seen_pids=""   # line-based accumulator (no bash-4 associative arrays)
    while [ "$i" -lt "$count" ]; do
        local id label base_url token kind
        id=$(jq -r ".providers[$i].id // \"\"" "$CONFIG_JSON")
        label=$(jq -r ".providers[$i].label // \"\"" "$CONFIG_JSON")
        base_url=$(jq -r ".providers[$i].base_url // \"\"" "$CONFIG_JSON")
        token=$(jq -r ".providers[$i].token // \"\"" "$CONFIG_JSON")
        kind=$(jq -r ".providers[$i].kind // \"anthropic-api\"" "$CONFIG_JSON")

        [ -n "$id" ] || die "providers[$i].id: missing or empty"
        [[ "$id" =~ ^[a-z0-9-]+$ ]] || die "providers[$i].id: must match [a-z0-9-]+, got \"$id\""

        # Duplicate-id detection (Design §5 rule).
        case " $seen_pids " in
            *" $id "*) die "providers[$id]: duplicate id (defined twice)" ;;
        esac
        seen_pids="$seen_pids $id"

        [ -n "$label" ] || die "providers[$id].label: missing"
        case "$label" in *"|"*) die "providers[$id].label: must not contain '|' (breaks pipe-format list output)" ;; esac
        [ -n "$base_url" ] || die "providers[$id].base_url: missing"
        # iter-3 CONCERN-4: design §5 promises invalid-URL rejection, not just emptiness
        case "$base_url" in
            http://*|https://*) ;;
            *) die "providers[$id].base_url: invalid URL \"$base_url\" (must start with http:// or https://)" ;;
        esac
        [ -n "$token" ] || die "providers[$id].token: empty (replace REPLACE_ME)"
        # NOTE: REPLACE_ME placeholder check moved to cmd_export per iter-2 CONCERN-10.
        # Rationale: validate checks structural correctness; export checks readiness-for-use.
        # This lets config.example.yaml (which ships with REPLACE_ME) pass `validate` —
        # important for Task 21 Test 13 (validate the example). Fast-fail at export time
        # still gives users a clear pre-HTTP error.

        case "$kind" in
            anthropic-api|ollama-daemon) ;;
            *) die "providers[$id].kind: unknown value \"$kind\". Valid: anthropic-api, ollama-daemon" ;;
        esac

        i=$((i+1))
    done
}

validate_models() {
    local count
    count=$(jq '.models | length' "$CONFIG_JSON" 2>/dev/null || echo 0)
    [ "$count" -gt 0 ] || die "models: section is empty or missing"

    # Collect provider ids for cross-reference
    local provider_ids
    provider_ids=$(jq -r '.providers[].id' "$CONFIG_JSON" | tr '\n' ' ')

    local i=0
    local seen_ids=""   # line-based accumulator (no bash-4 associative arrays)
    while [ "$i" -lt "$count" ]; do
        local id label model
        id=$(jq -r ".models[$i].id // \"\"" "$CONFIG_JSON")
        label=$(jq -r ".models[$i].label // \"\"" "$CONFIG_JSON")
        model=$(jq -r ".models[$i].model // \"\"" "$CONFIG_JSON")

        [ -n "$id" ] || die "models[$i].id: missing"

        # slash check
        if [[ "$id" != */* ]]; then
            die "models[$i].id: must be \"<provider>/<short>\", got \"$id\""
        fi

        # multiple slashes
        local slash_count=$(echo "$id" | tr -cd '/' | wc -c)
        if [ "$slash_count" -gt 1 ]; then
            die "models[$i].id: only one \"/\" allowed in id, got \"$id\""
        fi

        local provider_prefix="${id%%/*}"
        local short="${id#*/}"

        [ -n "$short" ] || die "models[$i].id: short name after \"/\" is empty (id=\"$id\")"
        [[ "$short" =~ ^[a-z0-9._-]+$ ]] || die "models[$id].id: short name must match [a-z0-9._-]+, got \"$short\""

        # Provider must exist. Quoted case-membership (same idiom as the dup-check below):
        # both the list and the needle are double-quoted, so this is glob/word-split safe
        # regardless of contents — it does not rely on validate_providers having
        # normalized provider ids first.
        case " $provider_ids " in
            *" $provider_prefix "*) ;;
            *) die "models[$id] references missing provider \"$provider_prefix\"" ;;
        esac

        # Duplicate id check (line-based, no associative array).
        case " $seen_ids " in
            *" $id "*) die "models[$id]: duplicate id (defined twice)" ;;
        esac
        seen_ids="$seen_ids $id"

        [ -n "$label" ] || die "models[$id].label: missing"
        case "$label" in *"|"*) die "models[$id].label: must not contain '|'" ;; esac
        [ -n "$model" ] || die "models[$id].model: required field missing or empty"

        i=$((i+1))
    done
}

validate_codex_gemini() {
    if jq -e '.codex' "$CONFIG_JSON" >/dev/null 2>&1; then
        local model level
        model=$(jq -r '.codex.model // ""' "$CONFIG_JSON")
        level=$(jq -r '.codex.reasoning_level // ""' "$CONFIG_JSON")
        [ -n "$model" ] || die "codex.model: required when codex: section present"
        if [ -n "$level" ]; then
            case "$level" in
                low|medium|high|xhigh) ;;
                *) die "codex.reasoning_level: unknown value \"$level\". Valid: low, medium, high, xhigh" ;;
            esac
        fi
    fi

    if jq -e '.gemini' "$CONFIG_JSON" >/dev/null 2>&1; then
        local model
        model=$(jq -r '.gemini.model // ""' "$CONFIG_JSON")
        [ -n "$model" ] || die "gemini.model: required when gemini: section present"
    fi
}

validate_defaults() {
    if ! jq -e '.defaults' "$CONFIG_JSON" >/dev/null 2>&1; then
        return 0
    fi

    local has_codex has_gemini
    has_codex=$(jq -e '.codex' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
    has_gemini=$(jq -e '.gemini' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0)

    local model_ids
    model_ids=$(jq -r '(.models // [])[].id' "$CONFIG_JSON" | tr '\n' ' ')

    local presets=("code_review" "design_review")
    local preset
    for preset in "${presets[@]}"; do
        if ! jq -e ".defaults.$preset" "$CONFIG_JSON" >/dev/null 2>&1; then
            continue
        fi

        # Guard: builtin/models must be lists when present (a scalar slips past the
        # length-based loop and — with the quoted case-membership test — an empty
        # indexed value would false-accept. Fail closed with a clear message.)
        local btype mtype
        btype=$(jq -r ".defaults.$preset.builtin | type" "$CONFIG_JSON")
        case "$btype" in
            array|null) ;;
            *) die "defaults.$preset.builtin: must be a list, got $btype" ;;
        esac
        mtype=$(jq -r ".defaults.$preset.models | type" "$CONFIG_JSON")
        case "$mtype" in
            array|null) ;;
            *) die "defaults.$preset.models: must be a list, got $mtype" ;;
        esac

        # builtin entries
        local builtin_count
        builtin_count=$(jq ".defaults.$preset.builtin | length" "$CONFIG_JSON" 2>/dev/null || echo 0)
        local b=0
        while [ "$b" -lt "$builtin_count" ]; do
            local v
            v=$(jq -r ".defaults.$preset.builtin[$b]" "$CONFIG_JSON")
            case "$v" in
                claude) ;;
                codex)
                    [ "$has_codex" = "1" ] || die "defaults.$preset.builtin lists \"codex\" but no codex: section"
                    ;;
                gemini)
                    [ "$has_gemini" = "1" ] || die "defaults.$preset.builtin lists \"gemini\" but no gemini: section"
                    ;;
                *) die "defaults.$preset.builtin: unknown value \"$v\" (valid: claude, codex, gemini)" ;;
            esac
            b=$((b+1))
        done

        # model entries
        local m_count
        m_count=$(jq ".defaults.$preset.models | length" "$CONFIG_JSON" 2>/dev/null || echo 0)
        local m=0
        while [ "$m" -lt "$m_count" ]; do
            local mid
            mid=$(jq -r ".defaults.$preset.models[$m]" "$CONFIG_JSON")
            # Quoted case-membership (glob/word-split safe; same idiom as validate_models'
            # provider check). cmd_get_defaults calls validate_defaults WITHOUT validate_models,
            # so $model_ids is not pre-normalized — quoting both sides is required here.
            case " $model_ids " in
                *" $mid "*) ;;
                *) die "defaults.$preset.models[$m]: unknown model \"$mid\"" ;;
            esac
            m=$((m+1))
        done

        # run_mode (only for code_review)
        if [ "$preset" = "code_review" ]; then
            local rm_val
            rm_val=$(jq -r ".defaults.$preset.run_mode // \"\"" "$CONFIG_JSON")
            if [ -n "$rm_val" ]; then
                case "$rm_val" in
                    background|team) ;;
                    *) die "defaults.$preset.run_mode: unknown value \"$rm_val\" (valid: background, team)" ;;
                esac
            fi
        fi
    done
}

validate_runtime() {
    if ! jq -e '.runtime' "$CONFIG_JSON" >/dev/null 2>&1; then
        return 0
    fi

    local drm
    drm=$(jq -r '.runtime.default_run_mode // ""' "$CONFIG_JSON")
    if [ -n "$drm" ]; then
        case "$drm" in
            background|team) ;;
            *) die "runtime.default_run_mode: unknown value \"$drm\" (valid: background, team)" ;;
        esac
    fi

    local dps
    dps=$(jq -r '.runtime.do_plan_default_stop_tokens // ""' "$CONFIG_JSON")
    if [ -n "$dps" ]; then
        [[ "$dps" =~ ^[1-9][0-9]*$ ]] \
            || die "runtime.do_plan_default_stop_tokens: must be positive integer, got \"$dps\""
        [ "$dps" -ge 150000 ] \
            || die "runtime.do_plan_default_stop_tokens: must be >= 150000 (hook does not emit below 150k), got $dps"
    fi

    local mrd
    mrd=$(jq -r '.runtime.max_redispatch // ""' "$CONFIG_JSON")
    if [ -n "$mrd" ]; then
        [[ "$mrd" =~ ^[1-9][0-9]*$ ]] \
            || die "runtime.max_redispatch: must be positive integer, got \"$mrd\""
    fi

    local key
    for key in single_run_sec stall_sec global_sec max_retries; do
        local v
        v=$(jq -r ".runtime.timeouts.$key // \"\"" "$CONFIG_JSON")
        if [ -n "$v" ]; then
            [[ "$v" =~ ^[1-9][0-9]*$ ]] || die "runtime.timeouts.$key: must be positive integer, got \"$v\""
        fi
    done
}

validate_all() {
    # Single source of truth for the full validation pipeline.
    # Order matters: providers first (models reference providers),
    # then models, then sections that reference models (defaults), then runtime.
    validate_providers
    validate_models
    validate_codex_gemini
    validate_defaults
    validate_runtime
}

cmd_validate() {
    load_or_die
    validate_all
}

cmd_export() {
    local model_id="${1:-}"
    [ -n "$model_id" ] || die "export: model id required (e.g. zai/glm)"

    load_or_die
    # Full validation so malformed defaults/runtime/codex/gemini fast-fail BEFORE
    # ext-claude-exec spends 30+ minutes on a flawed config. See CRITICAL-10.
    # Latency cost is amortised by the JSON-snapshot strategy (CONCERN-12 / Risk #12).
    validate_all

    # iter-3 CRITICAL-1 + SUGGESTION-1: reads via jq on snapshot; REPLACE_ME check before model resolution.
    local provider_id="${model_id%%/*}"

    # Locate provider FIRST so a copied-but-unedited config (REPLACE_ME token) fails
    # promptly with a token error rather than after model-field resolution.
    local p_count j=0 pfound=-1
    p_count=$(jq '.providers | length' "$CONFIG_JSON")
    while [ "$j" -lt "$p_count" ]; do
        local pid
        pid=$(jq -r ".providers[$j].id" "$CONFIG_JSON")
        if [ "$pid" = "$provider_id" ]; then
            pfound="$j"; break
        fi
        j=$((j+1))
    done
    [ "$pfound" -ge 0 ] || die "internal: provider $provider_id missing after validation"

    local base_url token kind
    base_url=$(jq -r ".providers[$pfound].base_url" "$CONFIG_JSON")
    token=$(jq -r ".providers[$pfound].token" "$CONFIG_JSON")
    kind=$(jq -r ".providers[$pfound].kind // \"anthropic-api\"" "$CONFIG_JSON")

    # iter-2 CONCERN-10: REPLACE_ME check lives HERE (not in validate_providers), so that
    # the shipped config.example.yaml — which has REPLACE_ME everywhere — still passes
    # `validate`. The error fires at the moment the user actually tries to USE a provider.
    [ "$token" = "REPLACE_ME" ] && die "providers[$provider_id].token: still \"REPLACE_ME\" — edit $CONFIG_FILE with a real token for provider \"$provider_id\" before exporting"

    # Locate model (after provider + token check so the token error surfaces first).
    local m_count i=0 found=-1
    m_count=$(jq '.models | length' "$CONFIG_JSON")
    while [ "$i" -lt "$m_count" ]; do
        local id
        id=$(jq -r ".models[$i].id" "$CONFIG_JSON")
        if [ "$id" = "$model_id" ]; then
            found="$i"; break
        fi
        i=$((i+1))
    done
    [ "$found" -ge 0 ] || die "export: model \"$model_id\" not found in config"

    local model haiku_model opus_model sonnet_model subagent_model context_window
    model=$(jq -r ".models[$found].model" "$CONFIG_JSON")
    # SECURITY: bind the model fallback as DATA (--arg), not program text. validate_models
    # only checks .model non-empty (no charset), so a value containing `"` or `$` would
    # otherwise break out of the jq string literal and splice in arbitrary expressions
    # (e.g. `.providers[0].token` -> token leak). `\$m` is literal `$m` in the jq program;
    # `--arg m "$model"` binds it as a string. $found stays interpolated — validated integer.
    haiku_model=$(jq -r --arg m "$model" ".models[$found].haiku_model // \$m" "$CONFIG_JSON")
    opus_model=$(jq -r --arg m "$model" ".models[$found].opus_model // \$m" "$CONFIG_JSON")
    sonnet_model=$(jq -r --arg m "$model" ".models[$found].sonnet_model // \$m" "$CONFIG_JSON")
    subagent_model=$(jq -r --arg m "$model" ".models[$found].subagent_model // \$m" "$CONFIG_JSON")
    context_window=$(jq -r ".models[$found].context_window // \"\"" "$CONFIG_JSON")

    # Write export lines to a private tmpfile that the caller `source`s and unlinks.
    # Going through stdout + eval would put the token text in the Bash-tool transcript
    # captured by Claude Code — see CONCERN-1 / Design §11 OQ #2. The tmpfile is created
    # mode 600 BEFORE any sensitive content is written, then closed atomically.

    local env_file
    env_file=$(mktemp -t "claude-mesh-env-XXXXXX.sh") || die "export: mktemp failed"
    chmod 600 "$env_file"
    # Single redirect block so an early die() leaves a half-written file but doesn't
    # leak via the file handle. The caller is responsible for `rm -f` on success and trap-cleanup on failure.
    # Resolve timeouts BEFORE opening the redirect so any jq error fails fast,
    # not silently into the env file. Defaults match Design §4 values.
    local t_single t_stall t_global t_retries
    t_single=$(jq  -r '.runtime.timeouts.single_run_sec // 1800' "$CONFIG_JSON")
    t_stall=$(jq   -r '.runtime.timeouts.stall_sec // 600'       "$CONFIG_JSON")
    t_global=$(jq  -r '.runtime.timeouts.global_sec // 3600'     "$CONFIG_JSON")
    t_retries=$(jq -r '.runtime.timeouts.max_retries // 2'       "$CONFIG_JSON")
    # Timestamp via the bash builtin (no external `date`): GNU `date -Iseconds` is not
    # portable to BSD-`date` macOS, and require_gnu_coreutils does NOT verify `date`.
    # `%()T` printf format is bash 4.2+ (universal where we already require bash 4+).
    local now
    printf -v now '%(%Y-%m-%dT%H:%M:%S%z)T' -1

    {
        printf '# claude-mesh env — created %s for model %s — sensitive, delete after source\n' "$now" "$model_id"
        printf 'export ANTHROPIC_BASE_URL=%q\n' "$base_url"
        printf 'export ANTHROPIC_AUTH_TOKEN=%q\n' "$token"
        printf 'export ANTHROPIC_API_KEY=""\n'
        printf 'export ANTHROPIC_MODEL=%q\n' "$model"
        printf 'export ANTHROPIC_DEFAULT_OPUS_MODEL=%q\n' "$opus_model"
        printf 'export ANTHROPIC_DEFAULT_SONNET_MODEL=%q\n' "$sonnet_model"
        printf 'export ANTHROPIC_DEFAULT_HAIKU_MODEL=%q\n' "$haiku_model"
        printf 'export CLAUDE_CODE_SUBAGENT_MODEL=%q\n' "$subagent_model"
        printf 'export CLAUDE_CODE_USE_BEDROCK=""\n'
        printf 'export CLAUDE_CODE_USE_VERTEX=""\n'
        printf 'export CLAUDE_CODE_ATTRIBUTION_HEADER="0"\n'
        if [ -n "$context_window" ]; then
            printf 'export CLAUDE_CODE_AUTO_COMPACT_WINDOW=%q\n' "$context_window"
        else
            # Explicit unset prevents value from a prior `source` leaking across models.
            printf 'unset CLAUDE_CODE_AUTO_COMPACT_WINDOW\n'
        fi
        # Plugin-specific signal for skills to route precheck
        printf 'export CLAUDE_MESH_PROVIDER_KIND=%q\n' "$kind"
        # Task 2.5: export the resolved data dir so skills that source this env file get the
        # same self-discovered path the loader used (CLAUDE_PLUGIN_DATA is empty in skill Bash calls).
        printf 'export CLAUDE_MESH_DATA_DIR=%q\n' "$PLUGIN_DATA"
        # Timeouts exported so default mode and supervised mode read identical values.
        printf 'export CLAUDE_MESH_TIMEOUT_SINGLE_RUN_SEC=%q\n' "$t_single"
        printf 'export CLAUDE_MESH_TIMEOUT_STALL_SEC=%q\n'      "$t_stall"
        printf 'export CLAUDE_MESH_TIMEOUT_GLOBAL_SEC=%q\n'     "$t_global"
        printf 'export CLAUDE_MESH_TIMEOUT_MAX_RETRIES=%q\n'    "$t_retries"
    } > "$env_file"

    # The only output to stdout is the path — the transcript captures the path,
    # never the contents (which include the token).
    printf '%s\n' "$env_file"
}

cmd_get_flag() {
    # Query existence of optional config sections AND read small scalar config
    # values without bypassing the loader. Used by /mesh-review (feature gating),
    # /do-plan (default STOP threshold), etc.
    #
    # Output: "1"/"0" for has_* boolean flags, scalar value (string/integer) for
    #         documented getters. The exact contract is per-case.
    # Exit:   0 always (the answer is the stdout, not the exit code). die() fires
    #         only for unknown feature names.
    local feature="${1:-}"
    load_or_die
    case "$feature" in
        has_codex)
            jq -e '.codex' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        has_gemini)
            jq -e '.gemini' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        has_models)
            jq -e '.models[0]' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        has_defaults_code_review)
            jq -e '.defaults.code_review' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        do_plan_default_stop_tokens)
            # Returns the configured value or "250000" as the documented default.
            # Caller (commands/do-plan.md) trusts the integer, so we MUST run the
            # validator that owns this field BEFORE reading. iter-2 CRITICAL-2:
            # load_or_die does NOT invoke validators — `cmd_get_flag` historically
            # bypassed validate_all() and silently accepted out-of-range / non-integer
            # values. Pattern mirrors cmd_get_codex/cmd_get_gemini/cmd_get_defaults
            # (each typed getter calls only the validator that owns its section,
            # NOT the full validate_all — see iter-2 CONCERN-2/3).
            # has_* cases above are existence checks of the section only, so they
            # intentionally skip validation (validators run later, in the typed
            # getter that actually reads field values).
            validate_runtime
            jq -r '.runtime.do_plan_default_stop_tokens // 250000' "$CONFIG_JSON"
            ;;
        *)
            die "get-flag: unknown feature \"$feature\" (valid: has_codex, has_gemini, has_models, has_defaults_code_review, do_plan_default_stop_tokens)"
            ;;
    esac
}

cmd_list_models() {
    # Emit "<id>|<label>" per model (one line each). Used by /mesh-review Step 3
    # pagination to avoid bypassing the loader with raw yq calls.
    load_or_die
    validate_providers
    validate_models
    jq -r '.models[]? | .id + "|" + (.label // .id)' "$CONFIG_JSON"
}

cmd_list_providers() {
    # Emit "<id>|<label>|<kind>" per provider.
    load_or_die
    validate_providers
    jq -r '.providers[]? | .id + "|" + (.label // .id) + "|" + (.kind // "anthropic-api")' "$CONFIG_JSON"
}

# iter-2 CONCERN-2: typed getters for codex / gemini config — Tasks 13 (codex)
# and 14 (gemini) call these instead of raw `yq` so flavor-detect + JSON snapshot
# apply uniformly. Output: pipe-separated to match cmd_list_* convention.
cmd_get_codex() {
    load_or_die
    validate_codex_gemini
    # Format: <model>|<reasoning_level>
    # NOTE: when codex: is absent this still prints a lone "|" (empty model + level), exit 0.
    # Callers (Task 13) must gate on `get-flag has_codex` first, or split on "|" and test the
    # model field — do NOT treat a non-empty raw string as "codex configured".
    jq -r '(.codex.model // "") + "|" + (.codex.reasoning_level // "")' "$CONFIG_JSON"
}

cmd_get_gemini() {
    load_or_die
    validate_codex_gemini
    # Format: <model>
    jq -r '.gemini.model // ""' "$CONFIG_JSON"
}

# iter-2 CONCERN-3: typed getter for defaults.<category> — /mesh-review (Task 15a)
# and /mesh-design-review (Task 16) call this instead of raw yq to read the default
# reviewer set. <category> must be one of: code_review, design_review.
cmd_get_defaults() {
    local category="${1:-}"
    case "$category" in
        code_review|design_review) ;;
        *) die "get-defaults: unknown category \"$category\" (valid: code_review, design_review)" ;;
    esac
    load_or_die
    validate_defaults
    # iter-3 CONCERN-1: emit a JSON object so orchestrators get builtin + models + run_mode
    # (run_mode meaningful only for code_review) through the loader instead of raw yq. -c = one line.
    jq -c "{builtin: (.defaults.${category}.builtin // []), models: (.defaults.${category}.models // []), run_mode: (.defaults.${category}.run_mode // null)}" "$CONFIG_JSON"
}

# iter-3 CONCERN-1: typed getter for runtime UI defaults (default_run_mode) + the do-plan
# threshold, as a JSON object. /mesh-review and /do-plan read these without raw yq.
cmd_get_runtime() {
    load_or_die
    validate_runtime
    jq -c "{default_run_mode: (.runtime.default_run_mode // \"background\"), do_plan_default_stop_tokens: (.runtime.do_plan_default_stop_tokens // 250000), max_redispatch: (.runtime.max_redispatch // 1)}" "$CONFIG_JSON"
}

case "${1:-}" in
    validate) cmd_validate ;;
    data-dir)
        # Task 2.5: print the resolved plugin data dir WITHOUT load_or_die, so skills can
        # compute their runs/ path even on a fresh install (no config.yaml yet).
        printf '%s\n' "$PLUGIN_DATA"
        ;;
    export)
        shift
        cmd_export "$@"
        ;;
    get-flag)
        shift
        cmd_get_flag "$@"
        ;;
    list-models)
        cmd_list_models
        ;;
    list-providers)
        cmd_list_providers
        ;;
    get-defaults)
        shift
        cmd_get_defaults "$@"
        ;;
    get-runtime)
        cmd_get_runtime
        ;;
    get-codex)
        cmd_get_codex
        ;;
    get-gemini)
        cmd_get_gemini
        ;;
    *)
        echo "Usage: $0 {validate|data-dir|export <model-id>|get-flag <feature>|list-models|list-providers|get-defaults <category>|get-runtime|get-codex|get-gemini}" >&2
        exit 2
        ;;
esac
