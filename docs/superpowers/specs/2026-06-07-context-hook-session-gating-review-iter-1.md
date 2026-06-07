# Review Iteration 1 — 2026-06-07

## Источник

- Design: `docs/superpowers/specs/2026-06-07-context-hook-session-gating-design.md`
- Plan: `docs/superpowers/plans/2026-06-07-context-hook-session-gating.md`
- Review agents: claude-self (Opus), codex (gpt-5.5 xhigh), ext-claude on zai/glm,
  alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax (preset
  `defaults.design_review`)
- Merged output: `docs/superpowers/specs/2026-06-07-context-hook-session-gating-review-merged-iter-1.md`
- Issue parse: `claude-mesh:review-discussion` → 18 deduplicated issues

**Empirical validation after edits:** the rewritten test suite + the Variant-B hook
gate were run against a copy of the real hook — **8 passed / 3 failed** against the
current (ungated) hook and **11 passed / 0 failed** against the gated hook, matching
the plan's Step 2 / Step 5 expectations exactly.

## Замечания

### [ISSUE-1 / ISSUE-2] Fallback session-id resolution broken two ways
> ISSUE-1: `CWD_ENC=$(pwd | sed 's|/|-|g')` only replaces `/`, but `~/.claude/projects/`
> dir names encode `.`/`_`→`-` too → on dotted/underscored paths the fallback globs a
> nonexistent dir → `/do-plan` aborts. ISSUE-2: `ls -t | head -1` can pick another
> session's transcript under concurrency → wrong binding.

**Источник:** все 7 (ISSUE-1 grounded by claude-self + review-discussion; ISSUE-2 grounded by codex)
**Статус:** Обсуждено (Вариант A авто-применён после анализа — единственный адекватный)
**Ответ:** Вариант A — выкинуть glob-fallback, fail-fast если `$CLAUDE_CODE_SESSION_ID` пуст. Никакой glob не способен опознать «свою» сессию (race нерешаем), а тихая мис-привязка хуже громкого отказа.
**Действие:** design «/do-plan changes» + «No transcript-dir glob fallback» абзац; plan Task 2 Step 1 (`SID="${CLAUDE_CODE_SESSION_ID:-}"` + `[ -n ]` abort, без `ls -t`). Task 4 сделан блокирующим.

### [ISSUE-3 / ISSUE-14] Per-cwd config ломает параллельные `/do-plan` (race)
> Один `do-plan-config-<cwd>.json` на cwd → вторая `/do-plan`-сессия перезаписывает
> `plan_session_id`, первая молча теряет STOP. ISSUE-14: пересмотреть отвергнутую
> per-session альтернативу.

**Источник:** 6/7 (ISSUE-3); пятеро (ISSUE-14)
**Статус:** Обсуждено с пользователем → **Вариант B**
**Ответ:** Per-session config-файл `do-plan-config-<cwd>-<session>.json`. Каждая сессия владеет своим файлом → race устранён, хук упрощён (gate = `[ -f ]`, без jq-match и поля `plan_session_id`). ISSUE-14 закрыт принятием альтернативы.
**Действие:** механизм переписан в design (Session-scoped gate, Hook changes, схема `{stop_threshold}`, Edge cases +concurrency) и plan (Architecture, тест-сьют, Task 1 Step 3 hook-edit, Task 2 do-plan).

### [ISSUE-4] Broken intermediate commit (gate раньше do-plan-записи)
> Task 1 (gate) коммитится до Task 2 (do-plan пишет конфиг) → на том коммите реальный
> `/do-plan` пишет старое имя, новый хук его не находит → silent внутри `/do-plan`.

**Источник:** codex (grounded)
**Статус:** Автоисправлено
**Ответ/Действие:** Добавлена нота «Commit ordering» (squash Tasks 1–2 или Task 2 первым) в plan File Structure + указатель в Task 1 Step 6.

### [ISSUE-5] Harness маскирует краш под «silent»
**Источник:** codex, glm, minimax
**Статус:** Автоисправлено
**Действие:** `run_hook` ловит rc; при rc≠0 добавляет маркер `[hook exited rc=N]` → `assert_silent` ловит краш. Проверено: все silent-кейсы дают rc=0.

### [ISSUE-6] «Fully silent» неточно (mkdir/jq до gate)
**Источник:** 6/7
**Статус:** Автоисправлено
**Действие:** design Goals + hook header: «silent = no model-visible output, not no work».

### [ISSUE-7] `printf %s` для JSON небезопасен
**Источник:** qwen, glm, codex
**Статус:** Обсуждено (в составе Варианта A)
**Действие:** `/do-plan` пишет через `jq -nc --argjson thr` атомарно (mktemp+mv). В Variant B тело = `{stop_threshold}` (сессия в имени файла).

### [ISSUE-8] Повторный `/do-plan` в одной сессии с новым порогом — STOP не сработает
**Источник:** kimi
**Статус:** Отклонено (out of scope)
**Ответ:** Pre-existing поведение `context-stop-<session>.txt`, не вводится этой правкой; «inside /do-plan unchanged». Кандидат на отдельное изменение (`rm -f context-stop-<sid>` в /do-plan), не в этом PR.

### [ISSUE-9] Legacy-config silent breaking change
**Источник:** kimi, deepseek
**Статус:** Автоисправлено (+ усилено Вариантом B)
**Действие:** CHANGELOG-нота. В Variant B старые per-cwd файлы имеют другое имя → игнорируются (ещё чище, чем mismatch).

### [ISSUE-10] Orphan `context-milestone-*`/`context-stop-*` не чистятся
**Источник:** 5/7
**Статус:** Автоисправлено (документально)
**Действие:** Явный Non-goal в design (cleanup вне scope; gate лишь не плодит новые в не-/do-plan сессиях).

### [ISSUE-11] Доковая неточность: session-scoped, не «while running»
**Источник:** codex, glm, minimax
**Статус:** Автоисправлено
**Действие:** Уточнено в design (Session-scoped gate), hook header, do-plan Step 6.

### [ISSUE-12] Пробелы тест-покрытия
**Источник:** 5/7
**Статус:** Частично автоисправлено / частично отклонено
**Действие:** Добавлены negative-STOP (порог из конфига) и malformed-own-config (set -e устойчивость). Отклонено (out of scope, тестируют неизменённое поведение): milestone-progression, compaction-reset, JSON-shape, two-pass transcript, 149999 boundary.

### [ISSUE-13] Хрупкий Edit-anchor + формат STOP
**Источник:** deepseek, claude-self
**Статус:** Автоисправлено
**Действие:** Anchor расширен (Variant B редактирует блок строк 68–75 целиком); STOP-кейс ассертит и `ctx:250k`, и `STOP`.

### [ISSUE-15] Hardening-мелочи
**Источник:** qwen, minimax, deepseek, glm
**Статус:** Частично
**Действие:** 15a (комментарий про `set -e`/`|| echo` на STOP_THRESHOLD jq) — добавлен. Отклонено: 15b (bash4-guard — плагин и так требует bash4, `set -euo pipefail` падает громко), 15c (double-find в do-plan — присуще изоляции slash-блоков), 15d (test-trap — текущая явная очистка `rm -rf` достаточна, EXIT-trap в функции некорректен).

### [ISSUE-16] Гарантирован ли `$CLAUDE_CODE_SESSION_ID` в slash-Bash?
**Источник:** все 7
**Статус:** Обсуждено (в составе Варианта A)
**Действие:** Fallback убран → допущение load-bearing. Task 4 блокирующий, печатает env-переменную отдельно и сверяет с именем файла/транскрипта.

### [ISSUE-17] Деактивировать хук при завершении `/do-plan`?
**Источник:** codex, glm
**Статус:** Отклонено
**Ответ:** Намеренный контракт (session-scoped, задокументирован design Edge cases). `plan_completed`-флаг — scope creep. Формулировки уточнены (ISSUE-11).

### [ISSUE-18] Стиль (`// empty` vs `// ""`, лишний `|| true`)
**Источник:** minimax
**Статус:** Отклонено (без действий)
**Ответ:** В Variant B gate = `[ -f ]` без jq-match, поэтому `// empty`/`|| true` на gate вообще исчезли.

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| `…-design.md` | Session-scoped gate → per-session файл + схема `{stop_threshold}`; Hook changes (CONFIG_FILE ниже SESSION_KEY, `[ -f ]` gate, threshold после gate); `/do-plan` fail-fast + jq + per-session имя; Edge cases (+concurrent, stale, continue-fresh переписаны); Testing (8 кейсов); Goals/Non-goals/Assumption (silent, orphan, session-scoped, fallback removed) |
| `…-gating.md` (plan) | Architecture + File Structure + Commit-ordering note; Task 1 тест-сьют (11 per-session кейсов, rc-check), Step 2/5 ожидания (8/3 → 11/0), Step 3 hook-edit (блок 68–75), Step 4 header; Task 2 (per-session do-plan write, prose+doc, Step 6, commit msg); Task 3 CHANGELOG; Task 4 блокирующий + per-session проверка; Self-Review |
| `…-merged-iter-1.md` | Создан (агрегат 7 ревью) |

README.md не трогался (формулировка Task 3 Step 1 уже совпадает с рекомендацией minimax).

## Статистика

- Всего замечаний: 18
- Автоисправлено (без обсуждения): 9 — ISSUE-4, 5, 6, 9, 10, 11, 12*, 13, 15a
- Авто-применено после анализа (один адекватный вариант): 4 — ISSUE-1, 2, 7, 16 (fallback → fail-fast)
- Обсуждено с пользователем: 2 — ISSUE-3, 14 (concurrency → Вариант B, per-session)
- Отклонено: ISSUE-8, 17, 18 + части 12, 15 (out of scope / pre-existing / стиль)
- Повторов (автоответ): 0 (первая итерация)
- Пользователь сказал «стоп»: Нет
- Агенты: claude-self, codex, zai/glm, alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax
- Эмпирическая проверка: тест-сьют 8/3 (current) → 11/0 (Variant B) ✓
