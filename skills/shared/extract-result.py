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
    # The LONGEST result event, ties going to the LAST — not simply the last. When a run
    # dispatches a background subagent, progress-monitor.sh appends every segment to one
    # raw.jsonl, and the closing segment is a wake-up turn carrying an acknowledgement rather
    # than the review. Measured over 904 archived streams: 59 ext-claude runs hold more than one
    # result event and in 36 of them the LAST is shorter than the longest — up to 16817 of 17882
    # characters of review discarded, this repository's own 2026-08-29 review among them.
    #
    # Ties go to the last so single-result streams (845 of the 904, and every default-mode run)
    # keep byte-parity with progress-monitor.sh: with one event the longest IS the last.
    #
    # NOT "skip .origin.kind == task-notification", which reads like the semantic fix and was
    # REFUTED by the same sweep: that marker records how a turn STARTED, not what it carries, so
    # it also sits on 22 of the 23 tails that are the genuine answer, and 42 streams have no
    # other result event at all — they would extract to nothing, which verify-delegation.sh reads
    # as STALLED and answers with a re-dispatch. Length is a proxy for "carries the review", and
    # on the whole archive it is the only rule that is right everywhere.
    # is_error:true results are a SEPARATE, fallback-only pool. The guard judges the LAST
    # result event (verify-delegation.sh's ext-claude/grok branch), so a failed segment
    # longer than the review would put failure text into output.txt on a run the guard
    # scores REAL — {"subtype":"success","is_error":true,"result":"Prompt is too long"} is
    # a real shape, five historical run dirs hold it. Never merged into one pool with a
    # demotion rule: across 1095 archived streams (swept 2026-08-30) an error candidate and
    # a success candidate never co-occur, and 56 error-only streams depend on the fallback
    # keeping the CLI's own message ("API Error: 402 …") — excluding errors outright would
    # extract those to empty, the silence the errors[] arm below exists to prevent.
    best_len = -1
    err_len = -1
    err_text: list[str] = []
    for ev in events:
        if ev.get("type") == "result":
            r = ev.get("result")
            if not (isinstance(r, str) and r):
                continue
            if ev.get("is_error") is True:
                if len(r) >= err_len:
                    err_text = [r]
                    err_len = len(r)
            elif len(r) >= best_len:
                final_text = [r]
                from_result = True
                best_len = len(r)
    if not final_text and err_text:
        # from_result stays True: these streams took the result branch before the split,
        # and its trailing-newline parity (E) must survive byte for byte.
        final_text = err_text
        from_result = True
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

    # F4: a terminal RESULT event that carries its reason in `errors[]` and no `type:"error"`
    # event anywhere. That is the shape a grok argument-parse failure produces — observed live
    # on 2026-08-30 when `--effort max` met grok-4.6, which accepts only xhigh|high|medium|low.
    # Every arm above misses it: `.result` is absent, there are no assistant messages, and the
    # type is `result`, not `error`. The extractor therefore exited 0 over a ZERO-BYTE
    # output.txt and the reason survived only in stderr.txt, which nothing downstream reads —
    # verify-delegation.sh saw an empty review and scored the run STALLED, "killed mid-flight",
    # for a run that had died deterministically in fifteen seconds. Worse, STALLED means
    # "re-dispatch", so a whole max_redispatch round was spent on an error no retry can fix.
    #
    # Gated on a NON-EMPTY errors list, so a healthy result event cannot reach this arm; the
    # `not final_text` guard above already excludes every run that produced an answer.
    if not final_text:
        for ev in events:
            if ev.get("type") != "result":
                continue
            errs = ev.get("errors")
            if not isinstance(errs, list) or not errs:
                continue
            # Every entry, not the first: a run can fail for more than one reason, and one
            # message that looks complete while hiding the rest is how a diagnosis goes wrong.
            # Entries are strings on every grok failure measured so far; a dict is defended
            # against because the alternative is a Python repr reaching the user as the whole
            # diagnosis — `{'message': '...'}` instead of the message.
            final_text = ["API Error: " + "; ".join(
                str(e.get("message") or e) if isinstance(e, dict) else str(e)
                for e in errs)]
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
