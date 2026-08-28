#!/usr/bin/env python3
"""Extract output.txt + raw.json from a Claude stream-json raw.jsonl log.

Reads:  <work_dir>/raw.jsonl  (one stream-json event per line; may also contain
                               supervised-mode merged segments)
Writes: <work_dir>/raw.json   (entire JSONL re-serialised as a single JSON array
                               for backward compat with downstream tools)
        <work_dir>/output.txt (final assistant message text)

Exit codes:
  0 — success (or raw.jsonl empty / non-existent: writes empty output.txt and exits 0)
  2 — wrong number of arguments (usage)
  3 — raw.jsonl exists but contains no parseable JSON
  4 — could not write output files
"""
from __future__ import annotations
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <work_dir>", file=sys.stderr)
        return 2

    work = Path(sys.argv[1])
    src = work / "raw.jsonl"
    out_json = work / "raw.json"
    out_txt = work / "output.txt"

    events: list[dict] = []
    if src.is_file():
        with src.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Only object events are meaningful here. Real Claude stream-json
                # is always objects; corrupted/merged noise (bare arrays, strings,
                # numbers) is dropped so the reversed-scans below stay total and
                # raw.json remains a faithful array of the *object* events.
                if isinstance(obj, dict):
                    events.append(obj)

    # Always write outputs — even empty raw.jsonl produces empty output.txt
    # so downstream `[ -s output.txt ]` checks behave consistently.
    try:
        out_json.write_text(json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError as e:
        print(f"extract-result: failed to write raw.json: {e}", file=sys.stderr)
        return 4

    # iter-2 CRITICAL-3: Extract final text. The authoritative source is the
    # `type=="result"` event's `.result` field (this is what legacy progress-monitor.sh
    # writes — see claude-tools/skills/ccs-exec/progress-monitor.sh:170-174).
    # FALLBACK ONLY if no result event was emitted: concatenate `text` blocks from
    # the last `type=="assistant"` message. Many runs DO emit type=result, and the
    # assistant-message form would otherwise produce DIFFERENT bytes than the legacy
    # extractor — breaking parity between default mode (which still uses
    # progress-monitor.sh) and supervised mode (which calls this script).
    final_text: list[str] = []
    from_result = False
    for ev in reversed(events):
        if ev.get("type") == "result":
            r = ev.get("result")
            if isinstance(r, str) and r:
                final_text = [r]
                from_result = True
                break
    if not final_text:
        for ev in reversed(events):
            if ev.get("type") != "assistant":
                continue
            msg = ev.get("message")
            if not isinstance(msg, dict):
                continue
            content = msg.get("content") or []
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    final_text.append(block.get("text") or "")
            if final_text:
                break

    # F3 parity: no result and no assistant text — surface an API error event as
    # "API Error: <message>". Mirrors the legacy ccs-exec/ollama-exec supervised
    # extractor; without it an error-only stream (e.g. 401/403) yields empty output.txt.
    if not final_text:
        for ev in events:
            if ev.get("type") == "error":
                err = ev.get("error", {})
                if isinstance(err, dict):
                    # TWO shapes, nested arm FIRST so claude/codex/gemini stay
                    # byte-identical: those three nest the text under `.error.message`,
                    # while grok emits it TOP-LEVEL as `.message` — e.g.
                    # {"type":"error","message":"Couldn't set model to bogus-model"},
                    # the shape a typo in `-m` produces. Without the `ev.get("message")`
                    # arm such a stream rendered the literal "API Error: {}" and the
                    # message was lost. Guarded by test-extract-result.sh Test 15.
                    err_msg = err.get("message") or ev.get("message") or str(err)
                else:
                    err_msg = str(err)
                final_text = [f"API Error: {err_msg}"]
                break

    # NOTE: a `thinking`-block fallback was tried (b42161f) and reverted. Reasoning models
    # served via broken endpoints (e.g. deepseek-v4-pro:cloud via Ollama) emit their whole
    # answer — including tool-call grammar — inside a `thinking` block; surfacing it made
    # output.txt look non-empty but carried only DSML/reasoning junk, masking the failure.
    # We now leave output.txt EMPTY in that case; the mesh-review Step 6.0 guard classifies
    # the run BROKEN via the result event's num_turns<=1 (see verify-delegation.sh).

    # E parity: progress-monitor.sh (default mode) extracts the result via Python
    # print() — i.e. with a trailing newline. Match that for the result branch ONLY,
    # so default and supervised modes emit byte-identical output.txt for a successful
    # run. The assistant/error fallbacks have no default-mode counterpart, and an
    # empty result must stay 0 bytes so the `[ -s output.txt ]` gate still works.
    out_text = "".join(final_text)
    if from_result:
        out_text += "\n"
    try:
        out_txt.write_text(out_text, encoding="utf-8")
    except OSError as e:
        print(f"extract-result: failed to write output.txt: {e}", file=sys.stderr)
        return 4

    if src.is_file() and src.stat().st_size > 0 and not events:
        # raw.jsonl had bytes but nothing usable — surface that loudly.
        # (A file of only blank lines also lands here: non-empty, zero events.)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
