#!/usr/bin/env bash
# Fake `yq` binaries and flavor discovery, shared by test-config-loader.sh and
# test-preflight-env.sh. Sourced, never executed.
#
# WHY A DOUBLE HAS TO REALLY TRANSCODE. config-loader.sh no longer asks a `yq` who it is; it
# asks whether the output is JSON. The Go-yq stub this file replaces answered `--version` with
# a mikefarah banner and `exit 0` to everything else — under the new loader it writes nothing,
# `jq .` accepts the empty file, the first form "succeeds" with an empty snapshot and the
# scenario passes while testing nothing at all. Identity can be faked with a banner; capability
# cannot.
#
# All three doubles are built out of the python-yq already required by both suites, so they add
# no install step.

# Resolved once, at source time. The doubles must NOT call bare `yq`: they are placed ON PATH
# under exactly that name, so a bare call would recurse into itself.
#
# KNOWN BROKEN WHEN THIS MACHINE'S OWN `yq` IS A GO-YQ. This takes whatever PATH offers, and
# the doubles are then built on top of it. Under mikefarah that substrate is wrong twice over:
# mkyq_go's `-o=json` branch runs a bare `.`, which yields JSON only from kislyuk and prints
# YAML there, and mkyq_go's default branch — plus every call in mkyq_nojson — passes `-y`,
# kislyuk's `--yaml-output` short form and not a mikefarah v4 flag. Both forms therefore fail,
# the loader correctly reports that this `yq` cannot produce JSON, and scenarios in BOTH suites
# go red for a reason that is not config-loader.sh's fault. mkyq_yaml11 is unaffected: it
# drives python3 directly and never touches $YQ_REAL.
#
# The durable fix is to make YQ_REAL overridable, so a caller can pin the doubles to a kislyuk
# binary while PATH points at a Go-yq. Deliberately not taken here: no machine this was
# developed on had both flavors at once, so the mikefarah arm of such a fix could not be
# exercised by the change that would have introduced it.
YQ_REAL="$(command -v yq)"

mkyq_go() {             # mkyq_go <dir> — Go-yq v4: bare '.' prints YAML, -o=json prints JSON
    local dir="$1"; mkdir -p "$dir"
    cat > "$dir/yq" <<SH
#!/usr/bin/env bash
[ "\$1" = --version ] && { echo "yq (https://github.com/mikefarah/yq/) version v4.44.1"; exit 0; }
if [ "\$1" = "-o=json" ]; then shift 2; exec "$YQ_REAL" '.' "\$@"; fi
shift; exec "$YQ_REAL" -y '.' "\$@"
SH
    chmod +x "$dir/yq"
}

mkyq_nojson() {         # mkyq_nojson <dir> — emits YAML whatever it is asked for
    local dir="$1"; mkdir -p "$dir"
    cat > "$dir/yq" <<SH
#!/usr/bin/env bash
[ "\$1" = --version ] && { echo "yq 0.0-nojson"; exit 0; }
if [ "\$1" = "-o=json" ]; then shift 2; else shift; fi
exec "$YQ_REAL" -y '.' "\$@"
SH
    chmod +x "$dir/yq"
}

mkyq_yaml11() {         # mkyq_yaml11 <dir> — emits JSON, but resolves scalars per YAML 1.1
    local dir="$1"; mkdir -p "$dir"
    cat > "$dir/yq" <<'SH'
#!/usr/bin/env bash
[ "$1" = --version ] && { echo "yq 1.1-flavour 0.1"; exit 0; }
if [ "$1" = "-o=json" ]; then shift 2; else shift; fi
exec python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1"
SH
    chmod +x "$dir/yq"
}

have_pyyaml() { python3 -c 'import yaml' >/dev/null 2>&1; }

# Finds a REAL Go-yq anywhere on PATH, even when a python-yq earlier in the search order
# shadows it — the usual arrangement on a machine that has both.
#
# These tests deliberately ask the identity question production no longer asks. The two are not
# in conflict: production needs "can this one do the job", a test needs "is the implementation I
# must exercise here installed at all".
find_real_go_yq() {
    local b
    for b in $(type -a yq 2>/dev/null | awk '{print $NF}' | sort -u); do
        [ -x "$b" ] || continue
        case "$("$b" --version 2>&1 | head -1)" in
            *mikefarah*) printf '%s\n' "$b"; return 0 ;;
        esac
    done
    return 1
}
