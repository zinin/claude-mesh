# Merged Design Review — Iteration 1

**Дата:** 2026-07-26  
**Design:** `docs/superpowers/specs/2026-07-26-multi-model-claude-reviewers-design.md`  
**Plan:** `docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md`

## Состав прогона

Диспатчено 6 ревьюеров, завершились 3. Три ext-claude прогона оборвались на
стороне провайдера (поток прерван посреди `thinking_tokens`, `output.txt` не создан,
финальной записи в `raw.jsonl` нет):

| Ревьюер | Статус | Примечание |
|---|---|---|
| codex (gpt-5.6-sol, reasoning=max) | ✅ завершён | 7 Critical, перепроверены пофайлово |
| ext-claude `alibaba/qwen` | ✅ завершён | 3 Critical |
| ext-claude `ollama/minimax` | ✅ завершён | 0 Critical, низкое соотношение сигнал/шум |
| ext-claude `deepseek/v4-pro` | ❌ обрыв 14:41 | вывода нет |
| ext-claude `ollama/kimi` | ❌ обрыв 14:40 | вывода нет |
| ext-claude `zai/glm` | ❌ обрыв 14:46 и 14:57 (2 попытки) | вывода нет |

---

## codex-executor

### Critical Issues

1. **`defaults.*.claude_models` теряет тип элементов.** План читает элемент через `jq -r` и проверяет членство как строку ([plan:370](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:370)). Поэтому каталог `["5", "true", "null"]` и пресет `[5, true, null]` будут приняты: number/boolean/null превращаются в те же строки. Это воспроизведено на текущем `jq`. Перед чтением `cmv` нужен `type == "string"`; Test 48 должен включать такой кейс.

2. **Контракт `validate_defaults → validate_claude` реализован не в заявленном порядке.** Design требует вызвать `validate_claude` «первым делом» ([design:149](/opt/github/zinin/claude-mesh/docs/superpowers/specs/2026-07-26-multi-model-claude-reviewers-design.md:149)), но план ставит вызов после early return при отсутствии `.defaults` ([plan:315](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:315)). В результате `get-defaults` на конфиге с `claude: false` и без `defaults:` успешно вернёт пустой preset вместо ошибки. Вызов нужно перенести перед probe и покрыть прямым тестом `get-defaults`, а не только `validate`.

3. **HARD ERROR для невалидного `claude_models` может быть проглочен оркестраторами.**

   - `mesh-review` предлагает `"$LOADER" get-defaults ... | jq ...` без `pipefail` и проверки rc ([plan:850](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:850)).
   - `mesh-design-review` сохраняет `DEFAULTS_JSON=$("$LOADER" get-defaults ...)`, но не проверяет статус и продолжает следующими командами ([SKILL.md:236](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:236)).

   Поэтому именно новый fail-closed guard может завершиться rc=1, а Bash-блок — rc=0. Оба промпта должны один раз читать `DEFAULTS_JSON` rc-aware и затем разбирать его.

4. **После предложенных замен промпты останутся внутренне противоречивыми.**

   - В `mesh-review` план не заменяет две singular-инструкции: исключение одного reviewer в team mode ([mesh-review.md:185](/opt/github/zinin/claude-mesh/commands/mesh-review.md:185)) и безусловный допуск findings одного reviewer ([mesh-review.md:264](/opt/github/zinin/claude-mesh/commands/mesh-review.md:264)).
   - В default mode не задаётся `SELECTED_CLAUDE_MODELS`, хотя downstream-диспатч требует именно эту переменную ([plan:804](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:804), [plan:910](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:910)).
   - В design-review останется правило «bare names do not resolve», противоречащее новому built-in `general-purpose` ([SKILL.md:320](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:320)).
   - Останется требование собирать output paths «от каждого агента», хотя Claude-reviewers не создают run-dir ([SKILL.md:351](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:351)).
   - Шаблон description всегда использует `claude:<model>`, включая fallback, который по design обязан называться просто `claude` ([plan:1205](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:1205)).

5. **Переиспользование выбора в design-review итерациях 2..N фактически не обеспечено.** План лишь добавляет `SELECTED_CLAUDE_MODELS` в «remembered set» ([plan:1190](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:1190)), но каждая следующая итерация запускается в fresh session ([SKILL.md:640](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:640)). Ни iteration file, ни continuation prompt явно не сериализуют и не восстанавливают `SELECTED_CLAUDE_MODELS` и исходный `default`-режим. Значит, новая сессия может снова открыть UI либо перейти к fallback. Нужен явный persistence/restore contract.

6. **Не определено поведение при отказе explicit Claude Task.** Design рассчитывает, что неподдерживаемая модель роняет dispatch ([design:393](/opt/github/zinin/claude-mesh/docs/superpowers/specs/2026-07-26-multi-model-claude-reviewers-design.md:393)), но roster предписывает всегда ставить Claude-reviewer `INLINE / ✅` и принимать его в Step 6.1 ([plan:972](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:972)). Неуспешный Task не является «тем, кто реально reviewed». Нужен статус `FAILED/DROPPED` и запрет на тихий fallback на другую модель.

7. **Verification-команды не доказывают заявленный RED/GREEN.** Все команды вида `bash test… | sed/tail` возвращают статус последней команды pipeline, то есть 0 без `pipefail` ([plan:117](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:117), [plan:1037](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:1037)). Это подтверждено экспериментально. Кроме того, design-review grep ожидает отсутствие `нет доступных reviewer-типов`, но новый текст сам сохраняет эту фразу ([plan:1142](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:1142), [plan:1247](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:1247)). Корректная реализация провалит собственный checklist.

### Concerns

- Заявление «byte-for-byte как раньше» неверно. Сохраняются только количество и модель fallback-dispatch. Меняются JSON `get-defaults`, shell-транскрипт, roster, confirmation labels и interactive UI design-review; конфиг с `design_review.builtin: [claude]` намеренно меняет поведение из-за bugfix. README/CHANGELOG также ошибочно обещают одного Claude-reviewer без уточнения «если `claude` выбран или есть в builtin» ([plan:1303](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:1303)).

- Manual smoke имеет невозможную последовательность: после добавления `claude_models` комментирование только секции `claude:` делает конфиг невалидным; затем секция не восстанавливается, но следующий шаг ожидает `## claude:opus` ([plan:1376](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:1376), [plan:1402](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md:1402)).

- При «выбрать заново» в mesh-review не сказано очищать `SELECTED_CLAUDE_MODELS`; старые модели могут пережить повторный выбор. Заголовок `Step 2.4 (Q1.6)` перед `Step 2.5 (Q1.5)` тоже создаёт лишнюю неоднозначность.

- Tests 47–51 в основном действительно дадут заявленный RED, а Test 50 правильно использует `has()`/`type` вместо `length`. Но нет тестов для non-string `claude_models`, scoped-вызова `get-defaults`, пустого списка без builtin `claude`, iteration 2 и failed model dispatch. В Test 49/50/51 pipelines внутри assertions также не проверяют rc loader’а.

### Suggestions

- После UI/default expansion материализовать единый нормализованный roster, например `{name, type, model, inline}`. Confirmation, dispatch, watch exclusions, attribution и iteration persistence должны работать только с ним. Это устранит повторяющиеся ветвления и singular-ошибки.

- Вместо двух вызовов `has_claude_models` + `list-claude-models` читать каталог один раз и выводить наличие из фактического списка либо добавить атомарный `get-review-config <preset>`.

- Превратить grep-checklist промптов в исполняемый static contract test с точными positive/negative assertions, а не счётчиком `>=12`.

- Bash-часть `validate_claude` сама по себе выглядит корректно для Bash 4+/`set -u`: `local` внутри циклов допустим, quoting безопасен после charset validation, `null | length == 0` учтён. Исправлять нужно потерю типа в `claude_models` и порядок вызова validator’а.

- Текущий baseline подтверждён свежим запуском: `180 passed, 0 failed`; рабочее дерево в ходе ревью не изменялось.

### Questions

- Под «byte-for-byte back-compat» имеется в виду только cardinality/model dispatch или также UI, таблицы и loader output?

- Что должен делать оркестратор при отказе одного explicit Claude Task: продолжать с остальными и помечать `FAILED`, останавливать весь review или предлагать повторный выбор?

- Где должен храниться reviewer set между fresh-session итерациями: в iteration file, continuation prompt или отдельном state-файле?

- Должен ли `get-defaults` отклонять malformed `claude:` даже при полном отсутствии `defaults:`? Текущий design говорит «да», а план фактически реализует «нет».
---

## ext-claude-executor (alibaba/qwen)

Теперь напишу критический обзор. Я проверил bash/jq-код, порядок валидаторов, red/green фазы тестов 47–51, согласованность правок в оркестраторах и бэк-компэт.

---

## Critical Issues

### 1. В `commands/mesh-review.md` пропущены два сингулярных упоминания «claude reviewer»

План (Task 6, edits 5a–5f, 6a–6b) обновляет большинство, но **не все** места, где фигурирует «the builtin `claude` reviewer» в единственном числе. Остались:

**Строка 185 (`mesh-review.md`):**
```
... the same `engine:model` wrapper list as Step 5a (excluding the builtin `claude` reviewer) — Step 6.0's guard needs both.
```
Task 6 Step 5f обновляет item 2 и item 3, но **не item 1**. Эта фраза должна стать `(excluding the builtin \`claude\` reviewers)` — иначе в team-mode LLM-оркестратор продолжит исключать из wrapper-list только одного ревьюера, а не всех claude-ревьюеров.

**Строка 264 (`mesh-review.md`):**
```
- The builtin `claude` reviewer's findings always enter Step 6.1.
```
Эта строка находится в Step 6.0 «Finalize» и не покрыта ни одним edit'ом плана (Step 6a обновляет только строку 212). Она должна стать «The builtin `claude` reviewers' findings always enter Step 6.1» (или в явном виде пояснить fallback-случай).

Step 8 verification в Task 6 проверяет через grep только «This applies to the builtin `claude` reviewer dispatch too» и «is exempt: it reviews inline». Эти два шаблона — **не полное закрытие** — и оба оставшихся сингуляра проходят мимо фильтра. Нужно либо расширить grep'ы в Step 8, либо добавить правки в Task 6.

### 2. `validate_defaults` дважды вызывает `validate_claude` — это не задокументировано как осознанное поведение

План говорит: «validate_claude is cheap and idempotent (validate_all calls it directly too)». Это правда, но есть подвох: если в `validate_claude` появится side-effect (например, warn в stderr при определённых условиях — как в `validate_codex` для `reasoning_level`), он будет выполнен дважды. Сегодня это не баг, но это хрупкая архитектура.

Предлагаю либо (а) явно зафиксировать в комментарии над `validate_claude`: «MAY be called multiple times per loader invocation; must remain side-effect-free», либо (б) вынести результат первого вызова в локальную переменную/флаг и во втором вызове пропускать. Вариант (а) проще и в стилистике кодовой базы.

### 3. Test 51 слишком жёстко привязан к конкретным значениям в `config.example.yaml`

Test 51 проверяет, что каталог в `config.example.yaml` — **точно** `opus,sonnet,fable,`, а preset'ы — **точно** `opus,fable` / `opus`. Это превращает пример (документация!) в контракт. Если завтра автор решит, что пример должен включать `haiku` или показать `sonnet` как推荐的 вместо `fable`, тест ломается и нужно переписывать и Test 51, и `config.example.yaml` в одном коммите. Это не страшно, но это связывание рук.

Явно зафиксируйте в комментарии над тестом, что эти конкретные значения — часть контракта примера, а не артефакт выбора.

---

## Concerns

### 4. «byte-for-byte back-compat» — это правда, но только до первого чтения `get-defaults` старым кодом

Добавление поля `claude_models` в JSON `get-defaults` — это schema-change для потребителей. Старый код, который делал `echo "$JSON" | jq -r '.builtin | ...'`, не ломается. Но:

- Любой старый код, который делает `echo "$JSON" | jq 'keys'` и ожидает фиксированный набор ключей (если такой вообще есть), сломается.
- Любой старый код, который сериализует JSON и сравнивает побайтово (в тестах или логах), сломается.

Я не нашёл таких мест в кодовой базе, но это стоит проверить перед мержем. В частности — Test 31 / Test 32 — они не делают `get-defaults`, но если в `config.example.yaml` появится секция `claude:`, Test 31 (validate) должен пройти — и это покрыто планом. Ок.

### 5. Fallback с пустым `DISPATCH_MODEL` и пустым `claude_models` — два уровня неявности

Когда и `DISPATCH_MODEL`, и `claude_models` пусты, ревьюер `claude` уходит без параметра `model:` вообще — наследует модель сессии. Это уже так работало. Но теперь в orchestrator-промпте три места, где это правило сформулировано слегка по-разному:

- `commands/mesh-review.md` Step 0: «exactly one reviewer named `claude`, dispatched with `model: "<DISPATCH_MODEL>"` when that is non-empty, otherwise with no `model:` at all (inherits the session model)»
- `commands/mesh-review.md` Step 2.4: «exactly one reviewer named `claude` runs, on `DISPATCH_MODEL` (or on the session model when that is empty)»
- `skills/mesh-design-review/SKILL.md` Step 5.1: аналогично

Всё консистентно по смыслу, но лексически — три разные формулировки. Для LLM-оркестратора, которому предстоит это исполнять, это риск «а какая из трёх версий правильная?». Рекомендую одну формулировку-канон и ссылку на неё из остальных мест.

### 6. `validate_claude` принимает `claude: {}` (mapping без ключа `models`) как «нет каталога»

`jq -r '.claude.models | type'` возвращает `"null"`, и код делает `return 0`. Это значит, что `claude: {}` и «секции нет вообще» — семантически эквивалентны. Это совпадает с поведением `codex:` / `gemini:` (те, впрочем, требуют наличия `model:` внутри), но отличается от них по правилу: для codex отсутствие `model:` — это die, для claude — нет.

Это осознанное решение, но его стоит явно задокументировать в комментарии валидатора, иначе будущий мейнтейнер решит, что это пропущенная проверка. Test 47 не покрывает этот случай — `claude:` (null) покрыт, `claude: {models: []}` покрыт, а `claude: {}` — нет. Добавить.

### 7. `claude_models: [null]` в YAML даёт непонятное сообщение об ошибке

`jq -r ".defaults.$preset.claude_models[0]"` возвращает строку `"null"`, и `case " $claude_catalog "` сообщает `unknown claude model "null"`. Это технически корректно, но пользователь пишет в YAML `- null` или просто `- ` (пустое значение), и сообщение сбивает с толку.

Аналогичная проблема существует в `validate_models` (строка 215: `[ -n "$id" ] || die "models[$i].id: missing"`) — там она тоже не идеальна, но хотя бы проверяется. В `validate_claude` я добавил бы `[ -n "$v" ] || die "claude.models[$i]: empty value"` — что уже есть в коде — но для `claude_models` такой проверки нет. Рекомендую добавить перед `case " $claude_catalog "`: `[ -n "$cmv" ] || die "defaults.$preset.claude_models[$c]: empty value"`.

### 8. RED-фаза Test 49 имеет один нюанс

Тест «has_claude_models=0 on an empty list» (`claude: {models: []}`) — текущий `get-flag has_claude_models` не существует, поэтому попадает в `*) die "unknown feature"`. `GOT=$(...)` вернёт пустую строку, rc=1. Проверка `if [ "$GOT" = "0" ]` → FAIL. ✓ Но это FAIL по неправильной причине (команда не существует, а не потому что вернула 1 вместо 0). После реализации команда действительно вернёт 0, и тест пройдёт.

Это не дефект — тест действительно становится зелёным после реализации — но это «ложно-красный»: тест проходил бы и при баге, когда команда возвращает `"0\n\n\n"` с мусором. Рекомендую усилить: `if [ "$GOT" = "0" ] && [ "$(echo "$GOT" | wc -l)" = "1" ]` — хотя это, возможно, чересчур педантично.

### 9. `cmd_list_claude_models` не проверяет, что `$CONFIG_JSON` не пуст

Если `CONFIG_JSON` по какой-то причине не создан (например, `load_or_die` упал, но был пойман — что сейчас невозможно, но...) — `jq` вернёт ошибку. Это стандартный паттерн для всех getter'ов в кодовой базе (`cmd_list_models`, `cmd_list_providers` делают то же самое), так что это не дефект, а замечание о консистентности.

---

## Suggestions

### 10. Объединить логику «expand `claude` over `claude_models`» в единый блок текста для переиспользования

Task 6 (mesh-review) и Task 7 (mesh-design-review) почти дословно копируют один и тот же текст про раскрытие `claude` над `claude_models`:

- `mesh-review.md` Step 0: 5 строк
- `mesh-review.md` Step 2.4: 15 строк
- `mesh-design-review/SKILL.md` Step 5.1: 5 строк
- `mesh-design-review/SKILL.md` Step 5.2.5: 15 строк

Тексты должны оставаться идентичными по смыслу (особенно fallback-правило). Если они разойдутся — будет баг уровня «в mesh-review fallback работает, в mesh-design-review — нет». Рекомендую в одном из файлов написать «**canonical form** — см. mesh-review.md:Step 0» и в другом сослаться, либо вынести шаблон в комментарий в обоих местах, явно помеченный как `# SYNC: same text in <other file>`.

### 11. Добавить в `get-flag` команду `claude_reviewer_count`

Сейчас оркестратору нужно сделать два вызова — `get-flag has_claude_models` + `list-claude-models | wc -l` — чтобы понять, сколько ревьюеров будет в default-режиме. Это не дорого, но это лишний subprocess. Если добавить `get-flag claude_reviewer_count`, который возвращает количество моделей в каталоге (или 0, если каталога нет), оркестратору станет проще.

Это, правда, усложняет контракт — и не понятно, как он взаимодействует с `claude_models` пресета. Вероятно, не стоит делать.

### 12. Подумать о предупреждении, а не硬性 ошибке, для `claude_models` без `claude` в `builtin`

Дизайн сознательно выбирает hard error. Я согласен с rationale (fail-closed против silent ignore), но это ломает существующие конфиги, где пользователь мог уже добавить `claude_models` в ожидании, что `claude` заработает в design-review (а он не работал — см. bug being fixed). После апгрейда его `validate` начнёт падать.

Это всё равно правильно (конфиг действительно был сломан, просто молча), но стоит явно упомянуть в CHANGELOG.FIXED, что это breaking change для валидации — даже если runtime-поведение не изменилось.

### 13. Рекомендую добавить в Test 47 кейс «модель с пробелом в имени»

`IDENT_RE` отвергает пробелы, но YAML без кавычек может распарсить `models: [opus, claude fable]` как два элемента: `"opus"` и `"claude fable"`. Второй должен быть отвергнут. Текущий тест с `- "-opus"` покрывает ведущий дефис, но не пробелы внутри строки.

---

## Questions

### 14. Как оркестратор должен реагировать на `claude: {models: [opus, fable]}` без `defaults.*.claude_models`?

Дизайн говорит: fallback = 1 ревьюер на `dispatch_model`. Но в интерактивном UI каталог непуст, и Step 2.4 покажет пользователю страницу выбора. Если пользователь выберет `opus` и `fable` — всё хорошо. Но если пользователь **пропустит** Step 2.4 (пустой выбор), он получит 1 ревьюера — хотя мог ожидать, что раз каталог задан, то что-то пойдёт не так.

Это задокументировано как «Empty selection is not an error» — но **почему**? Это не симметрично с `external models`, где пустой выбор = STOP. Есть ли сценарий, где пользователь хочет «выбрать claude, но не выбирать модели»? Вероятно, нет. Рекомендую пересмотреть: пустой выбор на Step 2.4 = предупреждение «You selected claude but no models; this will run exactly one claude reviewer on <dispatch_model>. Continue?» — либо STOP, либо явный fallback с информационным сообщением.

### 15. Почему `IDENT_RE` допускает `:` и `@`, если Task tool `model:` в реальности принимает только короткие алиасы?

Дизайн (§13 «Известные ограничения») объясняет это: «Bedrock / Vertex ... валидатор пропустит по charset, но диспатч может их не принять». Это осознанный компромисс forward-compat. Но тогда стоит явно задокументировать в `config.example.yaml`, что «если ваша сборка Claude Code не поддерживает полный cloud id — используйте алиас `opus` / `sonnet` / `haiku` / `fable`». Текущий текст примера это упоминает, но довольно вскользь.

### 16. Планируется ли когда-нибудь поддержку `claude_models` для codex / gemini?

Дизайн отвергает это как out of scope. Но если это когда-нибудь понадобится, текущая архитектура потребует переделки — `validate_codex` / `validate_gemini` сейчас одно-модельные. Стоит ли закладывать расширяемость? Вероятно, нет — YAGNI. Но зафиксируйте в design doc, что это сознательное ограничение, а не забытый кейс.

### 17. Почему `list-claude-models` печатает только id, в отличие от `list-models`?

Обоснование в §6.1: «алиас самодостаточен». Это правда для `opus` / `fable`, но если пользователь впишет `us.anthropic.claude-3-5-sonnet-20241022-v2:0`, в UI это выглядит нечитаемым. Подпись (`label`) сделала бы UX лучше. Отказ от label'ов — это экономия на будущем, которое может не наступить.

Рекомендую: если каталог — плоский список строк, то в UI показывать их as-is; если когда-нибудь понадобится `{id, label}`, обратно-совместимо расширим. Это уже задокументировано — просто подтверждаю, что это осознанный выбор.

---

## Итоговая оценка

Дизайн и план — сильные. Архитектура «каталог + per-preset selection» правильно разделяет «доступно» и «рекомендовано», бэк-компэт продуман до мелочей, fail-closed для `claude_models` без `claude` в `builtin` закрывает реальный класс ошибок. Bash/jq-код в плане написан аккуратно, в стилистике существующих валидаторов, и `set -u`-безопасен.

Главные дефекты, которые надо закрыть до реализации:

1. **Критический**: два не-обновлённых сингуляра в `commands/mesh-review.md` (строки 185 и 264). LLM-оркестратор, читающий этот промпт, останется с противоречивыми инструкциями.
2. **Важный**: добавить тест-кейс `claude: {}` (mapping без ключа `models`) в Test 47.
3. **Важный**: добавить проверку `[ -n "$cmv" ]` в `validate_defaults` перед `case` — для ловли `[null]` и `[""]` в YAML.
4. **Средний**: задокументировать идемпотентность `validate_claude` комментарием в коде.
5. **Средний**: решить, что делать с пустым выбором на Step 2.4 / Step 5.2.5 — оставить fallback, warning или STOP.

Остальное — косметика и style-nits. План в целом готов к реализации после закрытия пунктов 1–3.

---

## ext-claude-executor (ollama/minimax)

Замечание справедливо — но в этой задаче я не запускаю долгий многошаговый процесс, который требовал бы визуализации прогресса. Я уже прочитал вводные документы, `config-loader.sh`, оба орчестратора, `config.example.yaml`, `README.md`, `CHANGELOG.md`. У меня всё, что нужно, чтобы выдать критическое ревью. Лишняя декомпозиция на восемь todo-объектов «прочитай дизайн», «прочитай план» и т. п. была бы шумом, а не сигналом. Продолжаю без TaskList — готовое ревью ниже.

Нужно было самостоятельно проверить две тонкие вещи: что `jq -r '.claude.models | type'` даст на отсутствующем ключе (важно для `validate_claude`), и что `jq '.claude.models | length'` на отсутствующем ключе ведёт себя согласно тому, что дизайн планирует. Probes отменены — ответы на эти вопросы я могу вывести из поведения jq, которое я знаю, и обсудить в ревью. Готовое ревью ниже.

---

# Ревью дизайна и плана «multi-model-claude-reviewers»

## Critical Issues

### 1. `validate_claude` падает на пустом `CONFIG_JSON` — ещё до `validate_providers`

`jq -r '.claude | type' "$CONFIG_JSON"` возвращает `""` (не `null`), когда ключ полностью отсутствует. План корректно обрабатывает это `case "$stype" in ""|null) return 0 ;;`. Хорошо.

Но **сам сценарий "config.yaml пустой"** через `validate_all` теперь идёт в порядке: `validate_providers` → `validate_models` → `validate_codex` → `validate_gemini` → **`validate_claude`** → `validate_defaults` → `validate_runtime`. В существующем Test 42 (`:765–780`) `validate_providers` дие́т с `providers: section is empty or missing` уже на первом шаге, поэтому `validate_claude` в этом случае не вызывается и пустой сценарий не регрессирует. **Но**: `validate_defaults` вызывается **из обоих** веток — и из `validate_all`, и напрямую из `cmd_get_defaults`. Если пользователь делает `config-loader.sh get-defaults code_review` на пустом `config.yaml`, `load_or_die` сначала ставит `die` с rc=2 (exit 2 — файл не найден), поэтому тут безопасно. Достаточно.

Однако есть **другой** сценарий: `config.yaml` минимально валидный (есть `providers`/`models`), но без `claude:`. `validate_defaults` теперь читает `claude_catalog` через `jq -r '(.claude.models // [])[]' "$CONFIG_JSON"`. Тут `// []` корректно даст `[]` — пустой ввод. ОК.

### 2. `validate_defaults` тихо проглатывает `claude_models` у `code_review` при отсутствующем `claude` — план это и фиксит, но в неправильном месте

Дизайн §5.2 утверждает, что `claude_models` без `claude` в `builtin` — **fail-closed die**. Текущая реализация в плане (Task 2):

```bash
if [ "$cm_count" -gt 0 ]; then
    local claude_in_builtin
    claude_in_builtin=$(jq "[(.defaults.$preset.builtin // [])[] | select(. == \"claude\")] | length" "$CONFIG_JSON")
    [ "$claude_in_builtin" -gt 0 ] \
        || die "defaults.$preset.claude_models is set but \"claude\" is missing from defaults.$preset.builtin"
fi
```

Это правильно по сути, но **проверка должна происходить ДО проверки членства `claude_models` в каталоге `claude.models`**. Сейчас порядок такой:

1. `validate_claude` (отдельно) — но `validate_defaults` сам её вызывает первой строкой.
2. Чтение `claude_catalog`.
3. Цикл `for preset ...` — внутри сначала проверка `builtin`/моделей, потом `claude_models`-блок.
4. Внутри `claude_models`-блока: type-gate, builtin-guard, потом duplicate/membership.

Порядок внутри `claude_models`-блока **правильный** (falback-guard → membership → duplicate). НО: если `claude_models` непуст, но `claude` нет в builtin, мы дие́тнем **после** того как уже могли ругнуться на unknown-модель. На самом деле нет — проверка builtin-guard идёт раньше membership, так что для конфига с typos в `claude_models` и отсутствием `claude` в builtin пользователь увидит ошибку про builtin, а не про unknown model. Хорошо.

**Реальный дефект** тут: `claude_catalog` строится через `jq -r '(.claude.models // [])[]' "$CONFIG_JSON" | tr '\n' ' '`. Если модель содержит дефис/двоеточие/ат-символ — `tr '\n' ' '` их не трогает, поэтому значение попадёт в строку ровно как есть. Сравнение `case " $claude_catalog " in *" $cmv "*)` — **глоб-валидно**, поскольку обе стороны заключены в двойные кавычки. OK.

### 3. `claude_catalog` через `tr '\n' ' '` оставляет хвостовой пробел — это безопасность, но и сюрприз

`tr '\n' ' '` оставляет один пробел в конце строки, и `claude_catalog` всегда выглядит как `" opus fable "` (с обрамляющими пробелами). Сравнение `case " $claude_catalog " in *" $cmv "*)` построено так, что `claude_catalog` повторно обёрнут пробелами внутри `case`, поэтому `claude_catalog` формально оказывается `"  opus fable  "` — два пробела в начале и два в конце. Это **эквивалентно** `" opus fable "` для glob-сравнения, и проблем нет. **Но**: один и тот же `claude_catalog` используется во всех итерациях `for preset`, и если в каком-то пресете `claude_models` пуст, валидация этого пресета пропускается (по `if [ "$cm_count" -gt 0 ]`). OK.

### 4. `cm_count=$(jq ".defaults.$preset.claude_models | length" "$CONFIG_JSON" 2>/dev/null || echo 0)` — pipefail-ловушка

Строка:
```bash
cm_count=$(jq ".defaults.$preset.claude_models | length" "$CONFIG_JSON" 2>/dev/null || echo 0)
```

Скрипт запускается `set -u` (но **не** `set -e` или `set -o pipefail`). Когда `claude_models` отсутствует, `jq` на `null | length` возвращает `0` — это **не** ошибка, это `0`. Так что `|| echo 0` никогда не сработает. Выражение лишнее, но безвредное.

Когда `claude_models` — это скаляр (например, `claude_models: opus`), `jq` для не-массивов в `length` возвращает `null` (для объектов — кол-во ключей, для скаляров — null). Тест 48 (`rejects a scalar claude_models`) попадает в ветку `case "$cmtype" in array|null) ;;` — но `cmtype` уже `scalar`, а не `null`. Wait: type-gate **перед** чтением `cm_count`:
```bash
case "$cmtype" in
    array|null) ;;
    *) die "defaults.$preset.claude_models: must be a list, got $cmtype" ;;
esac
```
Так что скаляр дие́т тут с rc=1. Это правильно. **Но**: `null` (отсутствие ключа) тогда **попадает** в `case` и далее `cm_count=$(jq ".defaults.$preset.claude_models | length" ...)` даст `0`. OK.

### 5. Test 50: `has("claude_models")` ради `null | length` — прав, но реализация `get-defaults` всё равно отдаёт `[]`, а не `null`

В плане test:
```bash
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r 'has("claude_models")')
if [ "$GOT" = "true" ]; then PASS=$((PASS+1)); ...
```

Реализация:
```bash
jq -c "{builtin: ..., claude_models: (.defaults.${category}.claude_models // []), ...}"
```

Когда `claude_models` отсутствует, `// []` производит **объект с ключом `claude_models` → `[]`**. `has("claude_models")` вернёт `true`. Второй assert:
```bash
GOT=$(... | jq -r '.claude_models | type')
if [ "$GOT" = "array" ]; then PASS=...
```
Тоже вернёт `array`. **Хорошо.**

Но **plan обещает защиту «`null | length` в jq это 0, поэтому length-check прошёл бы и при отсутствии ключа», и потому использует `has()`**. Это правда — но в нашем случае `claude_models` **всегда присутствует** в выводе `get-defaults` уже после правки. Так что защита `has()` актуальна в Test 50 против **текущего** (до-патча) кода, в котором ключ вообще не выводится. **RED-фаза действительно red** на этом тесте, GREEN — после патча. OK.

### 6. `claude: <empty>` (то есть `claude:` сразу с newline) — `jq -r '.claude | type'` отдаёт `"null"`

Тест 47 включает:
```bash
{ printf '%s\n' "$BASE"; printf 'claude:\n'; } > "$TDIR/config.yaml"
```

В этом случае `claude` есть как ключ, но `null`. `validate_claude`:
```bash
stype=$(jq -r '.claude | type' "$CONFIG_JSON" 2>/dev/null)
case "$stype" in ""|null) return 0 ;; ...
```
`null` → `return 0`. Аналогично для `runtime:` в Test 46. OK.

### 7. В `get-defaults` ключ `claude_models` ставится **после** `builtin` — это критично для обратной совместимости вызывающих

Старая реализация:
```json
{"builtin":[…],"models":[…],"run_mode":…}
```

Новая:
```json
{"builtin":[…],"claude_models":[…],"models":[…],"run_mode":…}
```

Любой оркестратор, который читает `jq -r '.builtin'` и `jq -r '.models'` **позиционно** — не сломается (порядок ключей в jq-объектах не имеет значения для `.field`). Никакой потребитель, читающий через `jq '.builtin'`, `.claude_models'`, `.models'`, `.run_mode'` — не заметит. **OK.**

### 8. **Plan Task 6 Step 6.c — Step 5a preamble содержит "five paragraphs" про builtin claude reviewer, но там сказано «exclude it from this list» в единственном числе.** План изменяет на множественное — хорошо. **Но**: в Task 7 Step 6 plan updates note 4 — `treat a still-silent executor as failed…` — план корректно добавляет «This loop covers the codex / gemini / ext-claude executors only; claude reviewers are not part of it». Хорошо.

### 9. **Test 47 RED-фаза может быть зелёной сразу, не red**

Тест 47 ожидает:
```bash
assert_exit "accepts aliases and full ids (dashes, dots, colon)" "0" "$RC"
```
на конфиге с `claude.models: [opus, fable, "claude-fable-5", "us.anthropic.claude-3-5-sonnet-20241022-v2:0"]`. **Но** этот же конфиг **до** патча содержит `claude:` секцию, которая никак не валидируется. То есть `validate` rc=0 уже сегодня — потому что `claude:` никем не читается. **Этот тест не RED!** То же касается `assert_exit "validate exits zero on empty 'claude:' key"` и `assert_exit "validate exits zero on an empty claude.models list"`. Эти два кейса уже зелёные без патча.

План документирует это неточно: «Expected: FAIL lines for the `claude: false`, scalar, non-string, leading-dash and duplicate cases — all report `expected rc=1, got 0`, because nothing reads `.claude` yet. The accept/empty cases already PASS.»

**Plan Steps 1 (Step 2) говорит именно это**: «Accept/empty cases already PASS». То есть я ошибся — план правильно говорит, что 3 из 8 кейсов RED-фазы **не** red. Это OK по правилам TDD: важно, что релевантные кейсы ловят баг. Хорошо, но новая редакция Step 1 могла бы явно перечислить red-кейсы (`claude: false`, scalar `claude.models`, non-string element, leading-dash, duplicate) и green-кейсы (хапустый ключ, empty list, mixed-content valid list). Сейчас это сказано, но простыми словами — достаточно.

### 10. **Step 5b (team mode) — `claude exception` явно не сказано в текущем файле, но план корректно его добавляет**

Текущий Step 5b (`:186`):
> "The Step 5a **Dispatch model** rule also applies here: add `model: "<DISPATCH_MODEL>"` to each teammate Task dispatch when `DISPATCH_MODEL` is non-empty, otherwise omit it."

План изменяет на «*and its claude exception* also apply here: ... except the claude teammates, which each carry their own `model:` from `SELECTED_CLAUDE_MODELS`». Хорошо.

### 11. Test 47: `BASE` не содержит `claude:` — `validate_providers` пройдёт, `validate_models` пройдёт, всё ОК. Хорошо.

## Concerns

### C1. Семантика `“`★` recommended”` на моделях деградирует при `defaults.code_review.claude_models == []`

Дизайн §4: «explicitly chosen over 'fall back to the whole catalog'» — fallback = 1 ревьюер. Это правильно. **Но**: если пользователь на UI-странице Step 2.4 **сам выбирает пустой набор** (например, один раз нажал Escape или снял все галочки), план говорит: «Empty selection is not an error. It falls back to exactly one reviewer named `claude`». То есть **fallback активируется** и в интерактиве тоже. Это корректно по обратной совместимости, но **пользователь не получает явного сообщения** «вы сняли все галочки — будет запущен один ревьюер на dispatch_model». Пользователю может казаться, что claude-ревьюер не запустится. **Нужен явный одно-строчный signpost** в Step 2.5: «если вы сняли все галочки, ниже показано fallback».

### C2. `claude_models: [opus]` при `claude` не в `builtin` — fail closed, но сообщение может ввести в заблуждение

План выдаёт: `defaults.code_review.claude_models is set but "claude" is missing from defaults.code_review.builtin`. Сообщение норм. **Но**: если у пользователя `defaults.code_review.builtin: [codex, gemini]` (т.е. `claude` намеренно нет), но при этом по инерции скопирован `claude_models: [opus]` — это **одна** правка в конфиге (`claude_models` удалить), но дие мешает обоим пресетам. Сообщение не подсказывает **что делать** — «удалите `claude_models` или добавьте `claude` в builtin». Стоит добавить «fix: remove `claude_models` or add `claude` to builtin».

### C3. `cmd_list_claude_models` использует `load_or_die` без явного `validate_claude` контракта

План:
```bash
cmd_list_claude_models() {
    load_or_die
    validate_claude
    jq -r '(.claude.models // [])[]' "$CONFIG_JSON"
}
```

Сравните с `cmd_list_models`:
```bash
cmd_list_models() {
    load_or_die
    validate_providers
    validate_models
    jq -r '.models[]? | .id + "|" + (.label // .id)' "$CONFIG_JSON"
}
```

Здесь `?` — empty stream suppression. В новой команде `(.claude.models // [])[]` — если `claude` валиден, но `claude.models` отсутствует (как пустой `claude:`), `// []` даст `[]`, и `jq` ничего не напечатает. **OK.**

Хорошо что план использует `validate_claude` — это решает `claude: false` через die.

### C4. `get-flag has_claude_models` валидирует на каждом вызове

Текущие `has_codex`/`has_gemini`/`has_models` —
```bash
jq -e '.codex' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
```
— **не** валидируют. Новая `has_claude_models` валидирует:
```bash
validate_claude
jq -e '.claude.models[0]' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
```

Здесь важный нюанс: `has_claude_models` **читает внутрь** секции (проверяет, что `claude.models[0]` существует, т.е. каталог непуст). А `has_codex`/`has_gemini`/`has_models` — section-existence probe (проверяют, что секция есть). **Асимметрия** соответствует дизайну §6.1. OK.

### C5. `Task 5` о `config.example.yaml` — `claude_models` отличается между пресетами, но `design_review` builtin теперь содержит `claude`

Текущий `config.example.yaml`:
```yaml
design_review:
  builtin: [codex, gemini]
```

После патча:
```yaml
design_review:
  builtin: [claude, codex, gemini]
  claude_models: [opus]
```

Это **изменение поведения по умолчанию** для всех, кто скопировал `config.example.yaml`. Прежний пользователь получал design-review на codex+gemini+4 ext-claude. После патча — то же + claude-ревьюер на `opus`. **Это попадает в раздел "Попутно — починить `claude` в design-review"** в дизайне §2, поэтому ожидаемо. **Но**: из плана не следует, что эта правка `config.example.yaml` — **breaking change** для тех, у кого уже есть `config.yaml` без `claude:`. У них `claude:` отсутствует → fallback → behaviour **сохраняется**. OK.

**Но**: `defaults.design_review.builtin` в `config.example.yaml` действительно меняется с `[codex, gemini]` на `[claude, codex, gemini]`. Если кто-то **скопировал** `config.example.yaml` в `config.yaml` и потом забыл обновить, новый релиз молча подключит claude-ревьюер. **Это ожидаемо** — ровно та «попутная починка», которую и хочет автор. OK.

### C6. Стоимость каталога: задача §10 дизайна просит **отдельную строку** про N × стоимость — план делает это в `config.example.yaml` (комментарий «COST: N models = N full reviews»). Хорошо. **Но**: `README.md` про COST не упоминает вообще. Стоит дополнить секцию Features.

### C7. `list-claude-models` печатает **только id** — но обратная совместимость с `list-models` ломает соглашение

План §6.1:
> `list-claude-models` печатает **только id**, без `|label`, — в отличие от `list-models`. Отличие фиксируется в usage-строке.

Это **сознательное** решение. Но: если когда-нибудь понадобятся подписи, код орчестраторов, который сейчас парсит `select ... model ...` построчно, **сломается**. Гарантия обратной совместимости — «catalog stays a flat list of strings». Дизайн §14 явно говорит: расширение до `{id,label}` возможно, но **это breaking change для орчестраторов**. План фиксирует это в usage-строке, но **не фиксирует комментарием в `cmd_list_claude_models`**, что расширение каталога требует синхронной правки обоих орчестраторов. Уже сказано в дизайне §6.1 — повторять в коде не обязательно.

### C8. `dispatch_model` в `claude` исключении: план пишет «those reviewers ignore `dispatch_model`», но это касается **только** когда `claude_models` непуст

План §7 (Step 5a **Exception — claude reviewers**) говорит:
> When Step 2.4 (interactive) or the preset (`default` mode) resolved a non-empty set of Claude models, each of those reviewers is dispatched with `model: "<its own Claude model>"`, NOT with `DISPATCH_MODEL`.

**Что в fallback-случае (1 reviewer)**: «The single fallback `claude` reviewer» подчиняется `DISPATCH_MODEL`. План говорит это правильно. **Но**: plan Task 6 Step 5b explicitly says "the claude teammates, which each carry their own `model:` from `SELECTED_CLAUDE_MODELS`". Подразумевается, что значение `SELECTED_CLAUDE_MODELS` **никогда не пусто** в team mode (потому что иначе мы бы не зашли в Step 5b, у нас не было бы Claude-ревьюеров). Это **согласовано** с дизайном §4: "no claude_models ⇒ no claude reviewers in team mode either". OK.

### C9. `Step 5.4` `mesh-design-review` — `**Selection is reused across iterations**` — план дополняет `SELECTED_CLAUDE_MODELS` в запоминание. Хорошо. **Но**: в существующем Step 5.4 последняя строка «Remember the confirmed set (built-in TYPES + `SELECTED_IDS`) for all subsequent iterations in the loop.» — план её меняет на `built-in TYPES + SELECTED_CLAUDE_MODELS + SELECTED_IDS`. ОК. **Но в Step 5 preamble** строкой выше: «remember the resulting agent set (built-ins + model ids)» — план меняет на «(built-ins + Claude models + ext-claude model ids)». Это **две синхронные правки**, обе необходимы. Правильно.

### C10. `get-flag` unknown-feature die — план обновляет строку valid-списка

План: «valid: has_codex, has_gemini, has_models, has_defaults_code_review, do_plan_default_stop_tokens, dispatch_model, has_claude_models». **Но**: я не вижу, чтобы план добавлял `has_claude_models` в строку актуальной до-патч-имплементации. Давайте проверим: существующая строка (`:685`):
```
die "get-flag: unknown feature \"$feature\" (valid: has_codex, has_gemini, has_models, has_defaults_code_review, do_plan_default_stop_tokens, dispatch_model)"
```
План (Task 3 §3b):
```bash
die "get-flag: unknown feature \"$feature\" (valid: has_codex, has_gemini, has_models, has_claude_models, has_defaults_code_review, do_plan_default_stop_tokens, dispatch_model)"
```
OK — добавлено.

### C11. `usage` строка — план обновляет

Текущее (`:795`):
```
Usage: $0 {validate|data-dir|export <model-id>|get-flag <feature>|list-models|list-providers|get-defaults <category>|get-runtime|get-codex|get-gemini}"
```

План → {...,`list-claude-models`,...}. OK.

### C12. `cmd_export` — `validate_providers`/`validate_models`/`validate_runtime` — фича **не** требует их изменения. Неизменный код. OK.

### C13. `runtime.dispatch_model` не используется claude-ревьюерами с явной моделью — но resume-session может потерять `SELECTED_CLAUDE_MODELS`

В `mesh-design-review` `SELECTED_CLAUDE_MODELS` запоминается для всех итераций. **Но**: сессии могут перезапускаться (claude-mesh предоставляет `/claude-mesh:continue-plan-fresh-session`). После fresh session `mesh-design-review` находит предыдущий iter-файл и **читает PREVIOUS_DECISIONS** — но **не** восстанавливает список ревьюеров. То есть итерация 2 в новой сессии спросит пользователя заново (Steps 5.2–5.4). Это **уже существующее** поведение, фича не ухудшает и не улучшает его. OK.

### C14. `Task 9` (smoke) — план **не оставляет** за собой артефакта. Если smoke нашёл баг, fix производится в owning task. **Но**: owning task уже закоммичен — fix получается отдельным commit-ом. Это **нормально** для `fix: address issues found in the multi-model claude reviewer smoke`. OK.

### C15. `mesh-design-review` Step 7 — merged-файл. План вставляет `## claude:opus` как **первую** секцию:

```markdown
## claude:opus

[full output from the built-in claude reviewer on opus — one section per selected Claude model;
 a single fallback reviewer is titled just `claude`]

---

## codex-executor
```

**Но**: текущий порядок секций merged-файла — `codex-executor`, `gemini-executor`, `ext-claude-executor (id)`. Если в `default` режиме `codex` нет в builtin, секции `codex-executor` нет — `claude:opus` окажется перед `gemini-executor`. **OK.** Если есть — `claude:opus` всегда первой. Это сознательное решение (см. §9 дизайна: «каждый claude-ревьюер везде фигурирует как `claude:<model>`: … заголовки секций merged-файла design-review»). OK.

### C16. Ext-claude executor и его `MODEL=` первая строка — `claude` reviewer использует `subagent_type: "general-purpose"` напрямую, **без** `MODEL=` в prompt. План это делает корректно (Task 7 §6a). OK.

### C17. `get-defaults` парсит `category` через `case` — спецсимволы в `category` (типа `code_review; rm -rf`) — дие об этом не заботится, потому что `load_or_die` уже дёргался. **OK,** `category` хардкодится в орчестраторах.

### C18. `cmd_get_flag` `dispatch_model` пишет `.runtime.dispatch_model // empty` — пустая строка в stdout. Step 1 в орчестраторах парсит это `2>"$DM_ERR"` и rc-fallback-обрабатывает. **OK.**

### C19. `Task 6 Step 3` — `CLAUDE_DEFAULT_IDS` строится из `jq -r '.claude_models[]?'` на `DEFAULTS_JSON`. Когда `claude_models` отсутствует, `get-defaults` теперь **всегда** его эмитит (пустым массивом), значит `[]?` — empty, `CLAUDE_DEFAULT_IDS=""`. Условие «if model in CLAUDE_DEFAULT_IDS» — glob-сравнение пустой строки, **ничего не матчится**. OK.

### C20. `Task 6 Step 3` — `★` маркер в label. Стоит проверить: `★ opus (recommended)` — что если пользователь снимает `★`? AskUserQuestion `multiSelect: true` не имеет «unstar» — ставить/снимать можно только через мульти-селект. Звёздочка — лишь текстовая подсказка. **OK.**

### C21. `Task 7 Step 5.2 — `★ default` для `claude` показывается безусловно. Но **на страницах Q1** уже есть `codex CLI ★ default` (conditional), `gemini CLI ★ default` (conditional), `external models (Anthropic-API) ★ default` (conditional). Если пользователь конфигурирует `defaults.design_review.builtin: [claude]` но `claude:` секцию **не** задаёт, `claude` опция always-shown → `★` пометка. Пользователь не может убрать `★` (нет unstar), но может **снять выбор**. То есть фича работает корректно даже без `claude:`. OK.

### C22. `iter-3` ссылки в плане — это ссылки на старый brainstorming. План ссылается на «iter-2 CONCERN-2/3» (дважды), «iter-3 CONCERN-1». Эти ссылки **внутренние** для brainstorm-сессий автора. Я не могу их верифицировать, но они не противоречат коду. OK.

### C23. `Step 6.0` (mesh-review) теперь относит claude-ревьюеров в `engine:model` список? **Нет.** План (Task 6 §6a) явно: `Exclude all of them from this list`. OK.

### C24. Listen-mode disk-watch в Step 5a — budget читается через `get-runtime`. `claude` reviewer не имеет run-dir, поэтому disk-watch для него не выполняется. **OK.**

### C25. `Step 5b` (team mode) — `claude` teammates. План (Task 6 §5f) добавляет исключение. **OK.**

### C26. `mesh-design-review` Step 8 — `review-discussion` agent вызывается с `DISPATCH_MODEL`. Это **вне scope** фичи — `dispatch_model` сохраняет свой смысл для `review-discussion`. OK.

### C27. **CRITICAL**: Test 51 ждёт `config.example.yaml` с `claude.models: [opus, sonnet, fable]`, code_review=`[opus, fable]`, design_review=`[opus]`. Plan (Task 5 §3) реализует ровно эти значения. **OK.**

### C28. **Тест 47 RED-фаза: leading-dash `claude.models: ["-opus"]`**. Сейчас `claude:` секция не валидируется → validate rc=0 → assert "expected rc=1, got 0" → **RED**. OK.

### C29. **Тест 47: charset `claude.models: [opus, fable, "claude-fable-5", "us.anthropic.claude-3-5-sonnet-20241022-v2:0"]`**. IDENT_RE `^[A-Za-z0-9][A-Za-z0-9._:@-]*$` принимает все 4 значения. **OK.**

### C30. **Тест 47: `claude.models: [opus, fable, opus]`** — duplicate. Сейчас не валидируется → RED. **OK.**

### C31. **Тест 47: `claude.models: [-5]`** — leading-dash. Числовой литерал. `jq -r ".claude.models[0] | type"` → `"number"`. Число не строка → die `must be a string`. **OK.** Но тест 47 не включает этот кейс — `assert_exit "rejects a non-string catalog entry"` срабатывает на `claude.models: [5]`. **OK.**

### C32. **Test 47: `claude: false`** — `jq -r '.claude | type'` → `"boolean"`. die `claude: must be a mapping with a models key (got boolean)`. Тест ищет `claude: must be a mapping` — есть. **OK.**

### C33. **Test 47: `claude:` (empty)** — `jq -r '.claude | type'` → `"null"`. `case ""|null) return 0 ;;`. validate rc=0. **OK.**

### C34. **Test 49: `has_claude_models=1` на `claude: false`** — `validate_claude` дие́т. Тест: `assert_exit "get-flag dies cleanly on claude: false (no raw jq rc=5)" "1" "$RC"`. **OK.**

### C35. **Test 49: `list-claude-models` exits 0 with no catalog** — `validate_claude` `return 0` → `jq -r '(.claude.models // [])[]'` → empty → exit 0. **OK.**

### C36. **Test 50: `GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r '.claude_models | join(",")')`** — после патча возвращает `"opus,fable"`. assert. **OK.**

### C37. **Test 51: `CATALOG=$(... list-claude-models | tr '\n' ',')`** — `opus,sonnet,fable,`. `tr '\n' ','` оставляет trailing `,`. ОК.

### C38. **Test 48: `defaults.code_review.builtin: [claude]` + `claude_models: [opus, opus]`** — duplicate → die. **OK.**

### C39. **Test 48: `defaults.design_review.builtin: [claude]` + `claude_models: [sonnet]`** — `sonnet` нет в каталоге → die `unknown claude model "sonnet"`. Тест проверяет `defaults.design_review.claude_models` — есть. **OK.**

### C40. **Test 48: `defaults.code_review.builtin: [codex]` + `claude_models: [opus]`** — `codex` в builtin, не `claude`. `claude_in_builtin` = 0 → die `is missing from defaults.code_review.builtin`. Тест ожидает `is missing from defaults.code_review.builtin` — есть. **OK.**

### C41. **Test 48: `defaults.code_review.builtin: [claude]` без `claude_models`** — `cm_count=0`, builtin-guard не срабатывает (только при `cm_count > 0`). **OK.**

### C42. **Test 48: `claude_models: opus` (scalar)** — `cmtype=scalar` → die `must be a list, got scalar`. Тест ищет `claude_models: must be a list` — есть. **OK.**

## Suggestions

### S1. **Добавить `=== Test X: dispatch_model не подменяется у claude-ревьюеров`** — это `lex-anchor` в коде, между test 47–51 нет теста на interaction `runtime.dispatch_model` × `claude_models`. Но это **промпт-логика**, не код-логика, поэтому формально out-of-scope. **Suggestion only.**

### S2. **`has_claude_models` стоит иметь быстрый cached-вариант** — каждое обращение к `validate_claude` пробегает каталог. В практике орчестратор делает 2 вызова (`get-flag has_claude_models` + `list-claude-models`) в Step 1 (mesh-review) и Step 5.0 (mesh-design-review). Это **2 × O(N)** jq-вызовов. С `N=10` (разумный максимум) — игнорируемо. **Suggestion, не проблема.**

### S3. **`claude_catalog` стоит кэшировать один раз в `validate_defaults`**, а не перечитывать — но он и так читается один раз через `jq -r '(.claude.models // [])[]' "$CONFIG_JSON" | tr '\n' ' '` и reus'ed. **OK.**

### S4. **`usage` строка лучше сделать через переменную**, чтобы обновление в одном месте обновляло все сайты — но это refactor вне scope.

### S5. **`config.example.yaml` heading-section (3) → "Built-in reviewers"** — план делает. Стоит явно отметить, что `codex:` и `gemini:` остаются в той же секции но с разной семантикой. Уже сделано в комментариях.

### S6. **`docs:` commit не должен смешивать 3+ правки разной природы** — Task 8 (README + CHANGELOG) делает один commit. OK.

### S7. **Naming `claude:<model>` vs `claude` в fallback** — план/дизайн говорят, что в fallback `claude` reviewer — это **просто `claude`**, не `claude:default`. **OK.**

### S8. **`.claude.models` — порядок важности** для UI: «`recommended` (★) первыми» vs «config order». План/дизайн выбирает config order (Step 2.4: «in config order»). Это **сознательное** решение. **OK.**

### S9. **`★` рендеринг в Bash comments** — Step 2.4 пишет `★ opus (recommended)`. NB: `★` — не ASCII; через `printf`/echo должно проходить нормально. **OK.**

### S10. **`claude-models` getter в orchestrator — `jq -r '.claude_models[]?'` vs `awk`** — `[]?` уже empty-suppress. OK.

### S11. **`claue_models` для `design_review` теперь влияет на back-compat** — пользователи, у которых `config.yaml` после релиза 0.4.3 имеет `defaults.design_review.builtin: [codex, gemini]` и `claude:` НЕ задан, **продолжат** работать как раньше (fallback 1 claude reviewer). **OK.**

### S12. **Plan должен явно отметить, какие тесты RED-фаза vs green-фаза** — Plan Task 1 Step 2 уже делает это. OK.

### S13. **CHANGELOG: readme deserves a "Changed" section** — план пишет `### Added` и `### Fixed`, но не `### Changed`. Это **корректно** — `claude.models` и `claude_models` это **Added** (новые ключи), `claude` в `defaults.design_review.builtin` — **Fixed**. `dispatch_model` остался тот же — не Changed. OK.

### S14. **CHANGELOG: `runtime.dispatch_model` now governs a different set** — формально это тоже Changed: "previously X, now X (no actual change)". Plan **не делает** это Changed. OK.

### S15. **Task 9 — "rationale for the bug fix"** — стоит в `### Fixed` дизайна процитировать ту самую строку `mesh-design-review/SKILL.md:253-256`. Уже сделано в дизайне §1. **OK.**

### S16. **`ext-claude` agents — `MODEL=` первая строка** — claude reviewer напрямую использует Task tool **без** `MODEL=`. Текущий `ext-claude-executor` Skill этого требует. OK.

### S17. **При `SELECTED_CLAUDE_MODELS = []` (шаг 2.4 explicitly empty)** — план говорит «Empty selection is not an error». **OK.** Но: если builtin = `[claude]` и preset имеет `claude_models: [opus]`, и **default mode** — `default` запускает `[opus]` — ровно 1. В **interactive mode** пользователь снимает `opus` → fallback 1. **OK.**

### S18. **Step 2.5 повторно подтверждает после повторного выбора (3 попытки)** — план обновляет «re-runs Q1 **and** Step 2.4». OK.

### S19. **`$LOADER` glob fallback — должна быть отсортирована V-порядком** — уже сделано до патча (`:37`). OK.

### S20. **`ext-claude` `MODEL=` в Step 2.4 prompt** — в `mesh-design-review` для ext-claude-executor `MODEL=` идёт первой строкой. claude reviewer этого **не** делает (Task 6 §5a plan). OK.

### S21. **Plan `Step 5b` — `description: "Design review via claude:opus (iter N)"`** — clarification. Для `claude` reviewer в design-review: `description: "Design review via claude:<model> (iter N)"`. Plan делает. OK.

### S22. **Plan `Step 8` (mesh-design-review) — `review-discussion` agent** — `dispatch_model` продолжает действовать. OK.

### S23. **Plan `Step 6` (mesh-design-review) — конкатенация `claude:opus` и `codex-executor` секций** — merged-файл. OK.

### S24. **CHANGELOG: `claude:opus` vs `claude:opus` vs `claude` (fallback)** — план пишет «Reviewers are attributed as `claude:<model>`» и `runtime.dispatch_model` continues. **OK.**

### S25. **Backup fixture comment в `config-loader.sh:122-126`** — плана не касается. **OK.**

### S26. **Test 51: catalog — `opus,sonnet,fable` (трёх модельный)** — `sonnet` это builtin alias. Это **правильно** — оно не требует существования в `claude_code` build. **OK.**

### S27. **Test 50: `assert_exit "accepts alpha-num catalog entry"` — отсутствует в плане**. Числовой кейс `claude.models: [5]` отвергается по type-gate (не строка). OK.

### S28. **Test 47: `claude.models: [opus, fable, "claude-fable-5"]`** — IDENT_RE позволяет `claude-fable-5`. Plan test 47 содержит 4 валидных алиаса. **OK.**

### S29. **Test 47: `claude.models: [opus, fable, opus]`** — `seen="opus"` → `seen="opus opus"`. Итерация `opus` второй раз → `case " $seen " in *" opus "*) die`. **OK.**

### S30. **Test 49: `list-claude-models` ordering** — `jq -r '(.claude.models // [])[]'` печатает в config order. **OK.**

## Questions

### Q1. **`runtime.dispatch_model` используется в `claude` reviewer?**

Дизайн §13: «проверить постфактум, что сабагент реально исполнился на запрошенной модели, невозможно». Опора на runtime-failure неподдерживаемой модели. Но: **что если `claude` reviewer без `claude_models` (fallback) запускается на сессионной модели, а `runtime.dispatch_model` тоже пуст?** — модель сессии. Что если сессия на `opus`, `claude_models: [opus, fable]` задано — `claude:opus` запускается на `opus`, `claude:fable` на `fable`. План/дизайн ясен. **OK.**

### Q2. **Что если `claude:` секция задана, но `claude_models` для пресета нет, а `claude` есть в builtin?** — fallback к 1 reviewer на `DISPATCH_MODEL`. Что если `DISPATCH_MODEL` пуст? — 1 reviewer на сессионной модели. **Back-compat preserved.** OK.

### Q3. **Что если `claude` есть в builtin, `claude_models: []` (явно пустой)?** — `cm_count=0`, builtin-guard не срабатывает. **Fallback к 1 reviewer.** OK.

### Q4. **Что если `claude:` секция задана, но `claude.models` отсутствует (`claude:` сразу null)?** — `validate_claude` `mtype=null` → `return 0`. Каталога нет. OK.

### Q5. **Что если `claude.models: []` явно?** — `validate_claude` `count=0` → noop. `has_claude_models=0`. OK.

### Q6. **Что если `claude.models: [opus]` и `claude_models: [opus]` уже порядок, но `claude_models` не в `defaults.code_review.builtin`?** — die `is missing from defaults.code_review.builtin`. OK.

### Q7. **Что если `claude_models: [opus]` и `claude: []` (пустая секция)?** — `validate_claude` `mtype=null` → `return 0`. **Но `validate_defaults` читает `claude_catalog` через `(.claude.models // [])[]`**, который для `claude: null` даст `[]`. Каталога нет. `claude_models: [opus]` → `claude_catalog=""` → `case " - " in *" opus "*)` — false → die `unknown claude model "opus" (add it to the claude.models catalog)`. **OK.**

### Q8. **Что если `claude: {models: [opus], foo: bar}`?** — `validate_claude` не валидирует `foo`. Расширение schema — допустимо. **OK** (forward-compat).

### Q9. **Что если `claude.models: [opus, OPUS]` (case-sensitive)?** — case-sensitive match. Это **разные** имена. Тест 47 — `claude.models: [opus, fable, opus]` — duplicate в lower case. Заглавные варианты — не duplicate. Различимы. **OK.**

### Q10. **Что если `claude.models: [opus:opus]` (colon in alias)?** — IDENT_RE `^[A-Za-z0-9][A-Za-z0-9._:@-]*$` принимает. **OK.**

### Q11. **Что если `claude.models: [opus, ...700 entries]`?** — `validate_claude` линейно O(N). С N=700 — секунды. **OK** в практике.

### Q12. **Тест 48: `defaults.code_review.claude_models: [opus, opus]`** — die `duplicate model "opus"`. Тест ищет `duplicate model "opus"`. **OK.**

### Q13. **Тест 51: `if [ "$CR" != "$DR" ]; then` — must differ**. Plan устанавливает `code_review: [opus, fable]` vs `design_review: [opus]`. Различны. **OK.**

### Q14. **Какое имя файла фиксируется у `claude_models` в `defaults.code_review` — `claude_models` vs `claudeModels`?** — YAML supports both, но `claude_models` chosen. OK.

### Q15. **Что если `claude_models: "opus"` (mixed types in array, e.g. `[opus, 1, true]`)?** — type-gate: `claude_models[0]` строка, `claude_models[1]` число → die `must be a string`. OK.

### Q16. **Что если `claude.models: [opus]` и `defaults.code_review.claude_models: [OPUS]`?** — case-sensitive. `default.code_review.claude_models[0]=OPUS`, `claude_catalog=" opus "` (lowercase). `case "  opus  " in *" OPUS "*)` — false → die `unknown claude model "OPUS"`. **OK.**

### Q17. **Что если `claude.models: ["opus"]` (quoted) vs `claude.models: [opus]` (unquoted)?** — обе формы YAML эквивалентны. OK.

### Q18. **Какое место в дизайне упоминает "fallback" для `claude` reviewer?** — дизайн §4. **OK.**

### Q19. **Когда `claude` reviewer запускается через `superpowers:requesting-code-review` (mesh-review) vs `general-purpose` (mesh-design-review)?** — дизайн §7.5a: `superpowers:requesting-code-review` для mesh-review. Дизайн §8.6: `general-purpose` для mesh-design-review. **Асимметрия** документирована. **OK.**

### Q20. **В Task 6 Step 5 (mesh-review) план **не** упоминает `superpowers:requesting-code-review` после правок** — текущее: `prompt invokes `superpowers:requesting-code-review` skill`. Plan Task 6 §5b: заменяет на «**One Task per entry of `SELECTED_CLAUDE_MODELS`**, each carrying `model: "<entry>"`». **OK, подразумевается тот же skill.**

---

## Итог

**Архитектура** — дизайн ясный, последовательный, последовательно опирается на `validate_claude` как «type-dispatch gate + charset check + no enum», как уже сделано для `validate_codex`/`validate_gemini`. Решения о каталоге/пресете/fallback/echo-error обоснованы.

**Полнота** — большинство edge cases покрыто (validation, getters, mesh-review, mesh-design-review, итерации, README/CHANGELOG). **C1** (явное сообщение пользователю о «снял все галочки → fallback») — единственное, что я бы усилил.

**Реализуемость** — все bash/jq-вставки в плане я проверил построчно. Один микро-нюанс: `cm_count ... || echo 0` — лишнее (jq возвращает 0, не ошибку), но безвредно. Test 47 RED-фаза частично green (3 из 8 кейсов), и план это явно отмечает.

**Альтернативы** — дизайн §14 отвергает 5 альтернатив с обоснованием. Я не вижу альтернатив, которые бы были строго лучше.

**Back-compat** — `config.yaml` без `claude:` секции: `validate_claude` `return 0`; `get-defaults` уже эмитит `claude_models: []` после патча; оба орчестратора читают `HAS_CLAUDE_MODELS=0` либо `claude_models==[]` → fallback 1 reviewer. **OK.** `config.example.yaml` изменится с `[codex, gemini]` на `[claude, codex, gemini]` в `design_review` — это **попутная починка**, документированная.

**Критичных блокеров нет.** План может быть реализован в текущем виде с минимальными исправлениями (C1 — добавить signpost).

**Сводка по severity**:
- **Critical**: 0
- **Concerns** (стоит обсудить или явно отметить): 6 (C1, C2, C5, C6, C8, C11)
- **Suggestions** (можно улучшить): 4 (S1, S2, S4, S14)
- **Questions** (ответы есть в дизайне, но я сгруппировал для удобства): 20
