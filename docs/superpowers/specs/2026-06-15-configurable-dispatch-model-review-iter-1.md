# Review Iteration 1 — 2026-06-15

## Источник

- Design: `docs/superpowers/specs/2026-06-15-configurable-dispatch-model-design.md`
- Plan: `docs/superpowers/plans/2026-06-15-configurable-dispatch-model.md`
- Review agents (preset `default`): codex (gpt-5.5, xhigh); ext-claude × {`zai/glm` — FAILED (стал в runaway-thinking, 2 попытки, без вывода), `alibaba/qwen`, `deepseek/v4-pro`, `ollama/kimi`, `ollama/minimax`}. Завершено 5/6.
- Merged output: `docs/superpowers/specs/2026-06-15-configurable-dispatch-model-review-merged-iter-1.md`
- Преамбула: ревью запущено через `/claude-mesh:mesh-design-review default` из установленного плагина 0.1.0; документы — из рабочего репо (ветка `feature/configurable-dispatch-model`). Классификация выполнена оркестратором напрямую (iter-1 без предыдущих решений; критические замечания верифицированы против реального кода), а не через `review-discussion` агент.

## Замечания

### [CRITICAL-A1] `/mesh-review default` (Step 0) не резолвит `dispatch_model`
> codex C1, deepseek Q2, ollama/minimax C1–C2, zai (partial lead). **Verified:** `mesh-review.md:10-22` Step 0 пропускает Steps 1–3 и идёт в Step 5a/5b; план читал `dispatch_model` только в Step 1 (интерактив).
**Источник:** codex, deepseek, ollama/minimax, zai
**Статус:** Автоисправлено
**Ответ:** Реальный пробел — `/mesh-review default` всегда наследовал бы session-модель, молча игнорируя `runtime.dispatch_model`.
**Действие:** Plan Task 5 переписан: (a) Step 0 извлекает `DISPATCH_MODEL` из `get-runtime`, который он уже читает (валидируется, покрывает default-путь); (b) Step 1 — rc-aware чтение (fast-fail). Files-list и Step 5 verify обновлены.

### [CRITICAL-A2] do-plan status-line хардкодит `opus`/`Fable` против собственного grep
> codex C3, deepseek #8, ollama/minimax C3, alibaba C2. **Verified:** `do-plan.md:119` + план Task 4 Step 2 (`opus`) vs Step 4 grep (`fable|opus|sonnet|haiku`).
**Источник:** codex, deepseek, ollama/minimax, alibaba
**Статус:** Автоисправлено
**Ответ:** Самопротиворечие плана; литерал `opus` ломал бы собственный grep и цель «no model literal».
**Действие:** Plan Task 4 Step 2 → пример использует `<DISPATCH_MODEL>`; Step 3 → reworded bullet 135 (его «Same for external reviewers» больше не висит на удалённом fable-bullet).

### [IMPORTANT-A3] rc-handling голым `$()` + mislabel Step 5.0/5.1
> codex C2, alibaba C1, deepseek #1/#3, ollama/kimi #2. **Verified:** `has_codex`/`list-models` НЕ зовут `validate_runtime`; `get-runtime`/typed getter — зовут (`config-loader.sh:559,624`).
**Источник:** codex, alibaba, deepseek, ollama/kimi
**Статус:** Автоисправлено
**Ответ:** charset-invalid `dispatch_model` тихо наследовал бы (нет `set -e`); план называл блок «Step 5.1», а это Step 5.0.
**Действие:** Plan Tasks 5/6 → rc-aware чтение (fast-fail на невалидном значении); Task 6 переименован в Step 5.0, вставка после `echo "$DEFAULTS_JSON"`, отмечено что Step 5.0 покрывает оба пути (default + интерактив).

### [MINOR-A4] финальный grep (Task 9 Step 3) не ловит `sonnet`/`haiku`
> deepseek #2/#13.
**Статус:** Автоисправлено
**Действие:** Task 9 Step 3 grep → `\b(fable|opus|sonnet|haiku)\b` (repo-wide sweep Step 4 оставлен `fable|opus`, чтобы не матчить `ANTHROPIC_DEFAULT_SONNET_MODEL` и подобное).

### [MINOR-A5] design «non-empty string» расходится с кодом
> codex C4/Q1, deepseek Q1, alibaba W6, ollama/minimax #6.
**Статус:** Автоисправлено
**Действие:** Design §validation: пустая/отсутствующая `dispatch_model` = inherit (не ошибка), синхронизировано с `// ""` + `[ -n ]` в коде.

### [MINOR-D1] charset пропускает leading dash/dot
> alibaba W1, deepseek #4/#12, ollama/kimi #4.
**Источник:** alibaba, deepseek, ollama/kimi
**Статус:** Обсуждено с пользователем → ужесточить (Вариант B)
**Ответ:** Пользователь выбрал ужесточение charset (нулевая forward-compat цена; ловит опечатку на config-валидации).
**Действие:** Regex → `^[A-Za-z0-9][A-Za-z0-9._-]*$` (Task 1 Step 3 + die-сообщение); design §validation обновлён с явным regex; Test 36 расширен (reject `-opus`, accept `claude-fable-5`).

### Отклонённые замечания (с обоснованием)

- Test 36 использует `validate` (намеренно self-contained — session context). [alibaba Q1]
- Test 39 bundling / стиль теста (mirrors Tests 33–35). [alibaba W2]
- `echo DISPATCH_MODEL` stdout→prose (намеренно, как `$DEFAULT_STOP`). [ollama/kimi Q1]
- coercion `123`/`true` (accepted forward-compat; упадёт на dispatch). [codex Q2]
- `opus` — текущая модель, не legacy. [deepseek #15 — неверно]
- `fable` как пример alias в config.example (норм — иллюстрирует alias-or-id). [alibaba S2]
- `sed -i` GNU-only (maintainer на Linux; исполнитель может Edit). [ollama/kimi #5]
- пустая строка после frontmatter (sed удаляет одну строку, blank не появляется). [deepseek #10]
- дубли Test-номеров 14/15 (pre-existing cruft, отдельная чистка). [ollama/kimi #3]
- потеря пина у `review-discussion` (accepted limitation, покрыто при заданном конфиге). [deepseek #9]
- builtin `claude` + model override (Agent tool принимает override; план уже покрывает). [ollama/kimi #6]
- `verify-delegation.sh` (ортогонально dispatch-модели). [ollama/minimax #7]
- tier-ordering для «cheaper» (вернёт литералы — против approved design). [alibaba Q3]
- fresh-session / exec-plan пути (**verified:** нет литералов; dispatch идёт через do-plan policy). [ollama/kimi Q3, alibaba Q4]
- `LOADER_ERR` reuse без `:>` (shell `2>` усекает каждый раз). [alibaba W5]
- README sweep design/plan mismatch / grep `AGENTS.md` (косметика). [codex concern, alibaba S4]
- отдельный positive-validation test (Tests 37–39 уже гоняют валидное значение; явный кейс добавлен в Test 36). [ollama/kimi S1]

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| plan Task 1 | charset hardened `^[A-Za-z0-9][A-Za-z0-9._-]*$` + die-msg; Test 36 расширен (reject `-opus`, accept `claude-fable-5`) |
| plan Task 4 | status-line `<DISPATCH_MODEL>` вместо `opus`; reworded bullet 135 |
| plan Task 5 | Step 0 default-path read (из `get-runtime`) + Step 1 rc-aware; Files-list + verify |
| plan Task 6 | rc-aware read; relabel Step 5.0 (не «5.1»); вставка после `echo`; покрывает оба пути |
| plan Task 9 | Step 3 grep + `sonnet`/`haiku` |
| design §validation | empty/absent = inherit (не ошибка); hardened charset + явный regex |

## Статистика

- Всего замечаний (значимых): 6 (+ ~16 отклонённых)
- Автоисправлено (без обсуждения): 5 (A1 Critical, A2 Critical, A3 Important, A4, A5)
- Авто-применено после анализа: 0
- Обсуждено с пользователем: 1 (D1 — ужесточить charset)
- Отклонено: ~16
- Повторов (автоответ): 0 (итерация 1)
- Пользователь сказал «стоп»: Нет
- Агенты: codex (gpt-5.5/xhigh), ext-claude {alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax}; `zai/glm` FAILED (model stall)
