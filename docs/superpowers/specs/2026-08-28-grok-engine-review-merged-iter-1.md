# Merged Design Review — Iteration 1

Тема: `grok-engine`. Дата: 2026-08-28.

- Design: `docs/superpowers/specs/2026-08-28-grok-engine-design.md`
- Plan: `docs/superpowers/plans/2026-08-28-grok-engine.md`
- Preset: `defaults.design_review` (7 ревьюеров), `DISPATCH_EPOCH=1787938953`

## Состав ревьюеров и вердикты делегации

| Ревьюер | Движок | verify-delegation | Отчёт |
|---|---|---|---|
| `claude:opus` | built-in general-purpose | n/a (run dir не создаётся) | есть, 389 строк |
| `claude:fable` | built-in general-purpose | n/a | есть, 83 строки |
| `codex` | codex CLI | REAL | есть, 106 строк |
| `deepseek/v4-pro` | ext-claude | REAL (num_turns=22) | есть, 58 строк |
| `ollama/kimi` | ext-claude | REAL (num_turns=55) | есть, 54 строки |
| `ollama/minimax` | ext-claude | REAL (num_turns=21) | есть, 52 строки |
| `zai/glm` | ext-claude | **STALLED / FAILED** | нет — см. ниже |

**`zai/glm` не дал ревью.** Три попытки watchdog, каждая завершилась `is_error: true` с
`result: "Prompt is too long"` (последняя — 20 turns, 447 s), затем `bail: all_attempts_failed`.
Причина — исчерпание контекстного окна glm-5.3 на плане в 2466 строк плюс обход кодовой базы.
`output.txt` не создан. Перезапуск не производился: watchdog уже отработал свои три попытки,
и повторная попытка упёрлась бы в тот же лимит.

**Две обёртки не делегировали (FLIP).** `rv-zai-glm` и `rv-kimi` на первом заходе выполнили
ревью сами, на dispatch-модели сессии (opus), не вызвав `ext-claude-exec`; run dir не
создавался, `verify-delegation.sh` вернул FLIP («no run dir newer than dispatch time —
reviewer did not delegate»). Причина названа самой обёрткой: инструкция сессии «Do not call
the AgentTool unless the user requested it» была истолкована как запрет на делегирование.
После указания обе выполнили настоящую делегацию (kimi — успешно, z.ai — упёрся в контекст).
Их первые ревью содержательны и сохранены ниже ОТДЕЛЬНО: это второй и третий проход opus,
а не независимые голоса zai/glm и ollama/kimi, и как подтверждение находок `claude:opus`
они не засчитываются.

## Проверка оркестратора (первичные улики)

Собрано мной самостоятельно, командами на этой машине, а не со слов ревьюеров.


### grok models
```
You are logged in with grok.com.

Default model: codex-sol

Available models:
  - grok-4.6
  - grok-4.5
  - dks-ultra
  - deepseek-v4-flash
  - dks-vision
  - glm-5-3-flash
  - minimax-m3
  - <internal-model>
  - kimi-k3
  - minimax-m3-ollama
  - deepseek-v4-flash-ollama
  - deepseek-v4-pro-ollama
  - glm-5-3
  - glm-5-3-flash-zai
  - deepseek-v4-flash-api
  - deepseek-v4-pro
  - deepseek-v4-flash-vision-exp
  * codex-sol (default)
  - codex-terra
  - codex-luna
```

### ~/.grok/config.toml — [models] section
```
[models]
default = "codex-sol"
default_reasoning_effort = "low"

[model.dks-ultra]
```

### reasoning-effort set
```
--effort/--reasoning-effort: unknown effort level '__bogus__'; use one of: low, medium, high, xhigh, max
Error: --effort/--reasoning-effort: unknown effort level '__bogus__'; use one of: low, medium, high, xhigh, max
```

### Воспроизведение: extract-result.py теряет сообщение об ошибке grok

grok отдаёт верхнеуровневое `{"type":"error","message":"…"}`; extract-result.py:96-101 читает
ВЛОЖЕННЫЙ `ev["error"]["message"]`.

```
$ printf '%s\n' '{"type":"error","message":"Couldnt set model to bogus-model"}' > D/raw.jsonl
$ python3 skills/shared/extract-result.py D
$ cat D/output.txt
API Error: {}
```

Опровергает: (а) дизайн §2 «shared/extract-result.py consumes it unchanged»;
(б) комментарий плана Task 6 (~строка 1008) «extract-result.py surfaces as "API Error: …" in
output.txt (that is the shape an unknown model produces)».

### Префикс die() в config-loader.sh

```
$ grep -n 'die()' -A2 skills/shared/config-loader.sh
40:die() {
41-    echo "config-loader: $*" >&2
```

Печатается `config-loader: `, без `ERROR:`. Ожидаемый планом префикс `config-loader: ERROR:`
не существует.

### Хелперы в test-config-loader.sh (set -u, БЕЗ set -e)

```
14:assert_exit()   23:assert_stderr_contains()   33:assert_stderr_lacks()
```
`assert_eq_str` не определён нигде в skills/ и commands/; план вызывает его 7 раз.

### Инициализация HAS_* в preflight-env.sh

```
184:HAS_CODEX=0        <- вне OK-ветки
185:HAS_GEMINI=0       <- вне OK-ветки
285:if [ "$CONFIG_STATUS" = "OK" ]; then
308:    HAS_CODEX="$(... get-flag has_codex ...)"
309:    HAS_GEMINI="$(... get-flag has_gemini ...)"
```

### Row-order assert (не обновлён под grok)

```
826:assert_eq "row order is the documented one" \
827-  "plugin yq jq config builtin-claude claude-models codex gemini provider:zai provider:ollama git-remote gh glab clipboard bash-timeout "
```

### Лимит Q1

`commands/mesh-review.md:109` и `skills/mesh-design-review/SKILL.md:309` — «multiSelect, max 4»,
и опций в Q1 уже ровно четыре (claude, codex, gemini, external models).

---

## claude:opus

### Ревью дизайна и плана: grok as a third CLI engine

Ревьюер: claude:opus (итерация 1)
Дата: 2026-08-28
Ветка: `feat/grok-engine`
Документы:
- `docs/superpowers/specs/2026-08-28-grok-engine-design.md` (275 строк)
- `docs/superpowers/plans/2026-08-28-grok-engine.md` (2466 строк, 14 задач)

Прочитал оба документа и сверил их с кодом; часть утверждений дизайна проверил прогоном самого `grok 1.0.5` на этой машине. Первичные выводы команд — в приложении A в конце файла.

---

### Critical Issues

#### 1. Q1 переполнится: AskUserQuestion допускает 4 опции, станет 5

`commands/mesh-review.md:113-121` — `Use AskUserQuestion (multiSelect, max 4)`, и в списке уже ровно четыре опции: claude, codex, gemini, external models. То же в `skills/mesh-design-review/SKILL.md:309-317` (`multiSelect: true, max 4`). Task 11 Step 2 и Task 12 Step 3 говорят просто «добавить строку после gemini» — получится пятая опция. Ни дизайн, ни план этого не замечают, хотя механика пагинации в обоих файлах уже описана (Step 3 / Step 2.4 «chunk of 4»). Нужно решение: второй вопрос в том же вызове AskUserQuestion (до 4 вопросов на вызов), либо пагинация Q1, либо объединение CLI-движков в отдельный подвопрос. Без этого агент-исполнитель молча уронит одну из опций.

#### 2. `assert_eq_str` не существует — новые тесты станут вакуумными

Task 2 Step 2 и Task 3 Step 2 используют `assert_eq_str` ~10 раз. В `skills/shared/tests/test-config-loader.sh:14-40` определены только `assert_exit`, `assert_stderr_contains`, `assert_stderr_lacks`; в `lib-yq-doubles.sh` его тоже нет; `grep -rn assert_eq_str skills/` не даёт ничего. Suite работает под `set -u` **без** `set -e`, поэтому вызов даст `command not found` в stderr, счётчики PASS/FAIL не тронет, и Summary напечатает `0 failed`. То есть Task 2 Step 6 и Task 3 Step 5 («Expected: 0 failed») пройдут, а именно те проверки, ради которых написаны — `list-grok-models` в порядке конфига, `get-grok`, `has_grok`, `grok_models` как массив в `get-defaults` — не проверят ничего. Нужно либо добавить хелпер в suite, либо переписать на существующий инлайн-идиом (`if [ "$a" = "$b" ]; then PASS=…`).

#### 3. `HAS_GROK` не инициализируется — `set -u` убьёт `preflight-env.sh`

`skills/shared/preflight-env.sh:19` — `set -u`; `HAS_CODEX=0` / `HAS_GEMINI=0` объявлены на строках 184-185 **именно потому**, что реальное чтение (строки 308-309) выполняется только внутри `if [ "$CONFIG_STATUS" = "OK" ]`. Task 10 Step 4 предписывает добавить чтение рядом со строкой 308 и `GROK_MODELS=""` рядом со строкой 280, но про `HAS_GROK=0` в блоке 184-185 не говорит ни слова. Любой сценарий с `CONFIG_STATUS != OK` (`run_probe none`, невалидный конфиг, отсутствующий loader) даст `HAS_GROK: unbound variable` и падение всего probe. Бэкстоп `every verdict exits 0` (конец `test-preflight-env.sh`) это поймает, но задача написана так, что коммит Task 10 гарантированно красный.

#### 4. «Verified facts» дизайна расходятся с CLI — а план фиксирует их как Global Constraints

Прогнал сейчас, `grok 1.0.5 (5115b46bc9) [stable]`. Дословный вывод — в приложении A.

- **`grok models` → 20 моделей, не две.** Дизайн, строка 24: «Models are `grok-4.6` (default) and `grok-4.5`». Фактический список: `grok-4.6, grok-4.5, dks-ultra, deepseek-v4-flash, dks-vision, glm-5-3-flash, minimax-m3, <internal-model>, kimi-k3, minimax-m3-ollama, deepseek-v4-flash-ollama, deepseek-v4-pro-ollama, glm-5-3, glm-5-3-flash-zai, deepseek-v4-flash-api, deepseek-v4-pro, deepseek-v4-flash-vision-exp, codex-sol (default), codex-terra, codex-luna`. Посылка «grok offers only two models today», на которой строился спор про каталог (session context: «The designer recommended against it (grok offers only two models today)»), неверна — каталог оправдан сильнее, чем думал дизайнер, но таблица фактов дизайна просто неправдива.
- **Дефолтная модель — `codex-sol`, не `grok-4.6`.** Дизайн, строка 26: «`~/.grok/config.toml`: `[models] default = "grok-4.6"`, `default_reasoning_effort = "xhigh"`». Фактически: `[models] default = "codex-sol"`, `default_reasoning_effort = "low"`. Это тот самый файл, на который опирается решение «claude-mesh никогда не подставляет свою модель, пусть решает `~/.grok/config.toml`» (дизайн §1, строки 81-84; план, Global Constraints «Never hardcode a grok model»). Решение остаётся правильным, но его обоснование в дизайне описывает несуществующие значения.
- **Уровней reasoning не четыре, а пять — добавлен `max`.** Дизайн, строка 25: «Reasoning effort accepts `low`, `medium`, `high`, `xhigh`». Фактический текст ошибки CLI: `--effort/--reasoning-effort: unknown effort level '__bogus__'; use one of: low, medium, high, xhigh, max`. План жёстко фиксирует четыре в двух местах — Global Constraints («Known reasoning efforts: `low | medium | high | xhigh`») и в коде `validate_grok` (Task 2 Step 4: `case "$effort" in low|medium|high|xhigh) ;;`). Следствие: валидный `reasoning_effort: max` будет печатать WARN на каждом запуске загрузчика. Механика warn-and-pass-through спасает от отказа, но сообщение будет ложным с первого дня.

Это надо перемерить и переписать до Task 2 и Task 6, иначе фикстуры, `config.example.yaml`, README, Global Constraints и Task 14 несут неверные значения.

Хорошая новость, которую тоже стоит зафиксировать: **`--effort` — реальный алиас**, а не ошибка. CLI сам называет пару `--effort/--reasoning-effort`, и оба написания дают идентичную ошибку (приложение A). То есть инвокация в дизайне §2 и в Task 6 корректна; расхождение между §1 («the name the CLI flag (`--reasoning-effort`) … use») и §2 (`[--effort "$EFFORT"]`) — чисто редакторское, но лучше устранить, чтобы исполнитель не «чинил» рабочий флаг.

#### 5. Сломанная секция `grok:` уронит весь `/mesh-review` — это регресс класса «ultra incident»

Task 11 Step 1 делает `list-grok-models` **безусловным** чтением в Step 1 с `|| { … exit 1; }`. Эта подкоманда вызывает `validate_grok_catalog`, то есть опечатка в `grok.models` останавливает ревью целиком, включая codex-only прогон. Ровно этот класс отказа описан в комментарии `cmd_export` (`config-loader.sh:733-740`): «the `ultra` incident (2026-07-10) killed every ext-claude executor over a codex setting» — и на него же ссылается комментарий в собственном Test 57 плана. Для `claude:` такое поведение оправдано (встроенный ревьюер), для опционального движка — нет: `has_codex`/`has_gemini` в Step 1 читаются голым probe без валидации именно поэтому (`config-loader.sh:869-874` и комментарий на 885-899).

Хуже: Task 3 добавляет `validate_grok_catalog` в `validate_defaults` безусловно, а `cmd_get_defaults` вызывает только его — значит сломанная секция `grok:` роняет и `get-defaults`, который читается в трёх местах: `mesh-review.md:41` (режим `default`), `mesh-review.md:150` (Step 2.4 интерактивного пути), `mesh-design-review/SKILL.md:262`. Радиус поражения — вся команда, а не один движок.

Минимальное исправление: в `validate_defaults` безусловно выполнять только type-gate (он нужен, чтобы `jq -r '(.grok.models // [])[]'` не упал на `grok: false`), а полную валидацию каталога — только когда пресет реально ссылается на grok. В Step 1 при rc≠0 от `list-grok-models` — предупредить и выставить `HAS_GROK=0`, а не выходить.

Отдельно отмечу связку, которую это исправление затрагивает: дизайн §1 обосновывает отсутствие `has_grok_models` тем, что «the catalog cannot be empty while the section exists, so `has_grok` answers both questions», а Step 2.45 повторяет это как «`HAS_GROK=1` already guarantees `GROK_MODELS` is non-empty». Но `has_grok` — голый probe без валидации, так что инвариант держится **только** на том, что Step 1 аварийно выходит при плохой секции. Если чинить пункт 5, надо явно пересобрать это рассуждение, а не просто ослабить выход.

#### 6. Task 13 Step 1 противоречит сам себе и вписывает ложное утверждение в byte-pinned регион

Задача велит «найти два упоминания codex/gemini в каждом файле и расширить до codex / gemini / grok», и тут же — «Change nothing inside the `DO NOT` and `PREFLIGHT` regions». Но одно из двух упоминаний в каждом файле лежит **внутри** PREFLIGHT: `commands/code-review-fresh-session.md:177` и `commands/design-review-fresh-session.md:126` (секции 168-185 и 117-134; `test-command-sync.sh:144-145` пинит их по 17 строк, а Test 2/3 — побайтно).

И сам текст: «`OK` on the codex / gemini rows is a heuristic — binary present, section valid, endpoint answered; **NOT an auth check**». Для grok это ложь по построению: строка probe в Task 10 Step 3 гласит «`grok models` answered (checks login as well as network)» — это как раз auth-check. То есть добавление grok в эту фразу отгружает неверную инструкцию в специально выверенный регион, а не-добавление оставляет grok неописанным в обоих генераторах. Нужно отдельное предложение вне синхронизированных 17 строк.

---

### Concerns

#### `SUMMARY defaults` не разворачивает grok — probe начнёт ложно ругаться

`preflight-env.sh:799-807`: jq маппит `claude` → `claude:<model>` по `.claude_models`, остальные элементы `builtin` печатает как есть. С `builtin: [grok]` строка defaults покажет `grok`, а `SUMMARY available:` — `grok:grok-4.6`. Хелпер `defaults_not_available` (`test-preflight-env.sh:623-641`) имеет исключение только для голого `claude` и пометит `code_review/grok` как недоступный; сессия, читающая отчёт, сделает вывод, что `default`-режим сломан. Task 10 эту ветку не трогает. Правильнее расширить jq (grok разворачивается по `.grok_models` так же, как claude), а не хелпер теста — валидатор и так гарантирует непустой `grok_models`, когда grok есть в `builtin`.

#### Step 5b (team mode) не покрыт

`mesh-review.md:333` перечисляет «Wrapper reviewers (codex / gemini / ext-claude)», а точка 2 на строке 333 говорит «one task per selected reviewer — with several Claude models selected that means one task per Claude model». Task 11 упоминает только Step 5a (Interfaces и Step 6). `defaults.code_review.run_mode: team` — поддерживаемый режим (`validate_defaults`, `config-loader.sh:621-631`); grok-ревьюеры в нём не будут порождены. Список пар `engine:model` в Step 5b наследуется из Step 5a (строка 332), так что guard отработает, — но задач для grok не создастся, и guard увидит FLIP на пустом месте.

#### В design-review не покрыт Step 5.4

Task 12 в заголовке называет Step 5.4 «(dispatch)», хотя `mesh-design-review/SKILL.md:368` — это «Confirm selection» (диспетчеризация — Step 6, строка 385). В результате не покрыты три вещи, которые дизайн §3 требует:

1. разворот `grok` в буллеты на странице подтверждения (аналог `mesh-review` Step 2.5, который Task 11 Step 4 делает) плюс строка «grok: модели не выбраны — ревьюер не запускается»;
2. «Перевыбрать … (Step 5.2.5 re-runs too)» — надо добавить 5.2.6;
3. самое существенное — `SKILL.md:381`: «Remember the confirmed set (built-in TYPES + `SELECTED_CLAUDE_MODELS` + `SELECTED_IDS`) for all subsequent iterations in the loop». Без добавления `SELECTED_GROK_MODELS` в этот список grok-ревьюеры исчезнут на итерациях 2..N, а design review — итеративный по определению.

#### Там же не хватает второго обязательного пустого биндинга

Task 12 Step 3 пишет «If `grok` is not selected → skip Step 5.2.6 and run no grok reviewer», но не говорит «bind `SELECTED_GROK_MODELS` to the empty list». Файл специально настаивает на этом (`SKILL.md:328`: «Both bindings are mandatory… An undefined name in a shell script raises an error under `set -u`; in a prompt it raises nothing at all — the reader improvises»). В Task 11 Step 3 для `/mesh-review` оба биндинга прописаны — асимметрия между задачами не объяснена.

#### Проза DEGRADED в design-review не обновляется

`mesh-design-review/SKILL.md:488` прописывает ext-claude-специфичное лекарство: «the ext-claude run needs `--permission-mode bypassPermissions`, and an *installed* plugin only picks that up through a release». Task 11 Step 7 правит аналог в `mesh-review.md:390` («DEGRADED (exit 5, ext-claude only)»), Task 12 — нет. После того как grok попадает в ветку `ext-claude|grok`, эта проза станет неверной ровно для того движка, который уже передаёт нужный флаг.

#### Default-режим `grok-exec`: потерян load-bearing guard и цикл может вернуть 1

Task 6 Step 6 копирует форму из gemini, но выбрасывает первую строку тела цикла `echo "$line" | jq -e '.' >/dev/null 2>&1 || continue` (`gemini-exec/SKILL.md:230`). Без неё под `set -euo pipefail` присвоение `TYPE=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)` на битой или обрезанной строке возвращает ≠0 (статус присваивания = статус подстановки), и `set -e` убивает подоболочку цикла — остаток потока не попадёт в `raw.jsonl`.

Плюс ветка `assistant)` заканчивается на `[ -n "$TOOLS" ] && echo ":: Tools: $TOOLS"`, что даёт статус 1, когда инструментов в сообщении нет. У gemini каждая ветка `case` завершается `echo` или `if`, то есть всегда 0 — это не случайность. Статус `while` — статус последней итерации; он утекает в `PIPELINE_RC` и дальше в `exit "$PIPELINE_RC"`, то есть успешный прогон может завершиться «WARN: grok pipeline exited rc=1» и ненулевым кодом.

#### Supervised-блок теряет три страховки, которые есть у ext-claude

Сравнение Task 6 Step 7 с `ext-claude-exec/SKILL.md:325-356`:

- **(а)** там `extract-result.py` вызывается толерантно (`|| { echo "WARN: extract-result.py rc=$?" >&2; }`), в плане — звено `&&`-цепочки. Значит rc=3 («raw.jsonl есть, но ничего не парсится» — ровно сценарий «xAI поменял wire-формат», которого боится дизайн, §2 «The risk is that xAI maintains this as a compatibility layer and could change it») обрывает копирование наверх, генерацию отчёта и всю диагностику.
- **(б)** отсутствует блок «output.txt пуст при непустом raw.jsonl → печать stderr + хвоста + `exit 4`».
- **(в)** не копируется `stderr.txt` в корень (`for f in raw.jsonl stderr.txt; do … done` у ext-claude), хотя дизайн §2 перечисляет `stderr.txt` среди содержимого run-директории.

Плюс дизайн §2 обещает: «the post-run check requires at least one `"type":"result"` event and says so plainly when it finds none, instead of leaving an empty `output.txt` behind». Эта проверка есть только в default-ветке (Task 6 Step 6), а ревью всегда идёт через `SUPERVISED_MODE=shell` (Task 7 Step 5) — то есть обещанная дизайном страховка на боевом пути не срабатывает никогда.

И ещё: `raw.json`, заявленный в Interfaces Task 6 как содержимое `$WORK_DIR`, в supervised-режиме в корень не попадает — `extract-result.py` пишет его в `$FINAL`, а копируются только `raw.jsonl` / `output.txt` / `report.md`.

#### `HTTP_TIMEOUT` = 5 c для `grok models`

`preflight-env.sh:33,43` — `HTTP_TIMEOUT="${PREFLIGHT_HTTP_TIMEOUT:-5}"`. Command-probe в Task 10 Step 3 использует `timeout "$HTTP_TIMEOUT" $5`. Это холодный старт бинаря, который по признанию самого дизайна грузит `~/.claude/CLAUDE.md` и все установленные claude-плагины (§2 «The Claude Code world inside grok»), плюс сетевой запрос к grok.com. При превышении получим `NO-NETWORK` на здоровой машине и «grok недоступен» в SUMMARY, после чего оркестратор его не предложит. Надо замерить и/или ввести отдельный бюджет (`PREFLIGHT_CLI_TIMEOUT`, скажем 15 с). Это ровно тот вопрос, который дизайн вынес в «Checks the plan must run first» №1, но план на него не ответил — Task 10 Step 3 решает *куда* встроить probe, а не *сколько* ему давать времени.

#### `reasoning_effort` в самом CLI — per-model, и большинство каталога его не поддерживает

В `~/.grok/config.toml` `supports_reasoning_effort = true` встречается ровно три раза — у `codex-sol`, `codex-terra`, `codex-luna` (строки 140, 186, 232), и только у них есть собственные списки `[[model.X.reasoning_efforts]]` с полем `default = true`. У `dks-ultra`, `deepseek-v4-*`, `glm-5-3*`, `kimi-k3`, `minimax-m3`, `<internal-model>` этих полей нет вовсе (приложение A). То есть CLI моделирует effort как per-model свойство с per-model допустимым набором.

Дизайн выносит per-model effort из scope и делает одно значение на секцию («One value per section, not per model», §1) — но плагин передаст это одно `--effort` **каждой** модели каталога. Как решение по объёму это приемлемо, но нужно померить, что делает CLI с `--effort` на модели без поддержки: игнорирует или падает. Во втором случае один ревьюер из N упадёт на старте, guard покажет FLIP или STALLED, и причина будет невосстановима из отчёта. Минимум — оговорить это в `SKILL.md` и README; лучше — не передавать `--effort`, когда модель задана явно, а её поддержка неизвестна.

#### `grep -q '"type":"result"'` даёт ложноположительный результат

Task 6 Step 6: `if [ -s "$RAW_FILE" ] && ! grep -q '"type":"result"' "$RAW_FILE"`. Проверка идёт по `raw.jsonl`, куда попадает и текст ассистента. Ревью, цитирующее эту строку, «докажет» наличие terminal-события на порванном потоке. Task 14 — живое ревью **этого** репозитория, где строка встречается и в плане, и в `verify-delegation.sh:335`, так что вероятность не теоретическая. Дешевле проверять так же, как это уже делает guard: `jq -Rr 'fromjson? | objects | select(.type=="result")'`.

#### Кросс-движковая атрибуция

Каталог grok на этой машине содержит `deepseek-v4-pro`, `deepseek-v4-flash`, `glm-5-3`, `glm-5-3-flash-zai`, `kimi-k3`, `minimax-m3` — те же модели, которые ext-claude достаёт через своих провайдеров (z.ai, DeepSeek, Ollama). `grok:deepseek-v4-pro` и `ext-claude:<provider>/deepseek…` будут посчитаны в Step 6.1 как два независимых подтверждения одной находки, будучи одной моделью за двумя транспортами. Дизайн §3 строит корроборацию именно на именах ревьюеров («two grok models reporting one issue count as two independent corroborations, exactly like `claude:opus` and `claude:fable`») и этот случай не рассматривает. С каталогом из двух моделей проблемы бы не было; с реальным каталогом из двадцати она есть.

#### `validate_defaults` безусловно вызывает `validate_grok_catalog`

Отдельно от пункта 5: даже если Step 1 перестанет аварийно выходить, `cmd_get_defaults` останется отравлен сломанной секцией `grok:`, потому что типизированный геттер по принципу проекта запускает только свой валидатор. Это надо решать в `validate_defaults`, а не в оркестраторах.

---

### Suggestions

- **`validate_model_catalog` вшивает claude-специфичный пример в общее сообщение.** Task 1 Step 3: `die "$label[$i]: must be a string (got $etype) — quote it, e.g. - \"opus\""`. Для grok выйдет `grok.models[0]: must be a string (got number) — quote it, e.g. - "opus"`, при том что в Task 3 для `defaults.<preset>.grok_models` план аккуратно пишет `e.g. - "grok-4.6"`. Добавьте пятый параметр-пример; текст claude при этом остаётся байт-в-байт, и Step 5 (`diff … && echo IDENTICAL`) по-прежнему пройдёт.
- **`stdbuf -oL -eL` в supervised-инвокации — no-op.** `grok` — это `ELF 64-bit LSB pie executable … static-pie linked, stripped` (clap/Rust по виду ошибок), а `stdbuf` работает через `LD_PRELOAD` библиотеки `libstdbuf.so`, который статически слинкованный бинарь не подхватывает. Небуферизованность потока обеспечивает сам CLI — что дизайн и измерил (строка 30). Заодно: в default-ветке Task 6 Step 6 `stdbuf` вообще отсутствует, хотя дизайн §2 «Invocation» его показывает. Расхождение стоит устранить в любую сторону, но осознанно.
- **Дизайн §5 обещает покрытие `test-command-sync.sh` — «the grok wording shared by both orchestrators».** Этот suite (`test-command-sync.sh:2-4,35-36`) касается **только** двух `*-fresh-session` генераторов и никогда не читает `mesh-review.md` / `mesh-design-review/SKILL.md`. Кросс-оркестраторной проверки нет нигде, и план её не добавляет (Task 12 Step 5 просто прогоняет suite как регрессию). Консистентность Task 11 и Task 12 держится только на внимательности исполнителя.
- **Task 5 Step 2: не пять упоминаний, а шесть.** После `sed` в `ext-claude-exec/SKILL.md` остаются строки 223, 254, 343, 346, 379, 401. Причём 223 и 346 — не проза, а рантайм-строки `|| echo "WARN: generate-md.sh failed" >&2` внутри код-фенсов; «leaving the sentences otherwise as they are» оставит устаревшее имя в выводе скилла.
- **Task 3 Step 4: якорь вставки указан неоднозначно.** «after the whole `claude_models` block (immediately before the loop's closing `done` for the preset)» — между ними лежит блок `run_mode` (`config-loader.sh:621-631`), так что две половины фразы указывают на разные места. Функционально всё равно, но исполнителю надо дать одну точку.
- **`cli_row`: `$5` не только словоделится, но и глоббится.** План отмечает намеренную неквотированность ради word splitting; стоит добавить, что глоббинг тоже включён. `grok models` безопасен, но следующий probe может не быть — либо `set -f` вокруг, либо принимать массив.
- **README troubleshooting: «`grok models` lists them».** Реальный вывод — шапка (`You are logged in with grok.com.`, пустая строка, `Default model: …`, пустая строка, `Available models:`) плюс список с префиксами `  - ` и `  * … (default)`. Стоит сказать это явно, иначе читатель ожидает голый список.
- **Task 4 не гоняет suite**, потому что правит только `config.example.yaml` и `README.md` (Global Constraints требуют прогон лишь при изменениях в `skills/shared/`). Но `test-config-loader.sh` Test 31 (`config-loader.sh` тесты, строка 634) валидирует именно `config.example.yaml` — ошибка в примере всплывёт только в Task 6+. Ручная проверка в Step 2 это закрывает; стоит явно назвать Test 31, чтобы исполнитель понимал, что он дублирует.

---

### Questions

1. Как разрешается лимит Q1 в 4 опции — второй вопрос в том же вызове AskUserQuestion, пагинация Q1, или объединение CLI-движков в подвопрос? Это блокирует и Task 11, и Task 12.
2. Когда и в каком окружении измерялась таблица «Verified facts»? Сегодняшний прогон даёт другой каталог (20 моделей), другой default (`codex-sol`), другой `default_reasoning_effort` (`low`) и пятый уровень `max`. Если каталог на машине пользователя настраиваемый — а `~/.grok/config.toml` с блоками `[model.*]` и собственными `base_url` показывает, что да, — то «две модели» не свойство grok, а снимок конкретного конфига, и дизайн должен это сказать.
3. Что делает `grok -m <модель-без-supports_reasoning_effort> --effort xhigh` — игнорирует флаг или падает? От этого зависит, безопасно ли section-wide `reasoning_effort` при разнородном каталоге.
4. Осознанно ли `list-grok-models` сделан обязательным чтением Step 1 при том, что `has_codex` / `has_gemini` намеренно читаются без валидации? Если да — чем grok отличается от codex настолько, чтобы его опечатка останавливала codex-only ревью?
5. Кто-нибудь запускает `grok-exec` без `MODEL`? Ветка `runs/grok/<ts>-<task>/` описана в дизайне §2 и в Task 6, но ни guard, ни watcher её не адресуют (guard теперь явно требует модель и отвергает `-`), а `grok-code-review` без модели не стартует. Если она нужна только для ручных вызовов — это стоит написать; если не нужна — проще запретить и убрать «два уровня» из документации и из объяснения про коллизии.
6. Планируется ли какая-либо механическая проверка, что `SELECTED_GROK_MODELS` действительно связан во всех точках каждого оркестратора? Task 11 Step 10 предлагает `grep -c`, но для design-review аналогичного шага нет, а именно там пропущены Step 5.4 и второй пустой биндинг.

---

### Приложение A. Первичные данные к пункту 4

Все команды выполнены на машине пользователя 2026-08-28, в `/tmp`, без флагов, влияющих на вывод. Значения `api_key` в выводе `~/.grok/config.toml` заменены на `sk-REDACTED` — в файле лежат живые ключи сторонних эндпойнтов, и класть их в отчёт нельзя. Ничего другого не редактировалось.

#### A.1 Версия

```
$ grok --version
grok 1.0.5 (5115b46bc9) [stable]
```

#### A.2 `grok models` — 20 моделей, дефолт `codex-sol`

```
$ grok models
You are logged in with grok.com.

Default model: codex-sol

Available models:
  - grok-4.6
  - grok-4.5
  - dks-ultra
  - deepseek-v4-flash
  - dks-vision
  - glm-5-3-flash
  - minimax-m3
  - <internal-model>
  - kimi-k3
  - minimax-m3-ollama
  - deepseek-v4-flash-ollama
  - deepseek-v4-pro-ollama
  - glm-5-3
  - glm-5-3-flash-zai
  - deepseek-v4-flash-api
  - deepseek-v4-pro
  - deepseek-v4-flash-vision-exp
  * codex-sol (default)
  - codex-terra
  - codex-luna
rc=0
```

Сверка с дизайном, строка 24: «| Models are `grok-4.6` (default) and `grok-4.5` | `grok models` |».

#### A.3 Набор уровней reasoning — пять, включая `max`; `--effort` есть и является алиасом

```
$ grok -p x --reasoning-effort=__bogus__
--effort/--reasoning-effort: unknown effort level '__bogus__'; use one of: low, medium, high, xhigh, max
Error: --effort/--reasoning-effort: unknown effort level '__bogus__'; use one of: low, medium, high, xhigh, max
rc=1

$ grok -p x --effort=__bogus__
--effort/--reasoning-effort: unknown effort level '__bogus__'; use one of: low, medium, high, xhigh, max
Error: --effort/--reasoning-effort: unknown effort level '__bogus__'; use one of: low, medium, high, xhigh, max
rc=1
```

Сверка с дизайном, строка 25: «| Reasoning effort accepts `low`, `medium`, `high`, `xhigh` | `grok -p x --reasoning-effort=__bogus__` names the set in its error |» — та же команда, но набор в ответе содержит пятый элемент `max`.

Заодно подтверждено, что `--effort` — не выдумка плана: CLI сам печатает пару `--effort/--reasoning-effort`, и оба написания дают идентичную ошибку с rc=1.

Для полноты — соответствующая строка `grok --help`:

```
      --reasoning-effort <EFFORT>
```

(алиас `--effort` в `--help` не показан, но принимается; проверено выше.)

#### A.4 `~/.grok/config.toml` — дефолты не те, что в дизайне

```
$ sed -n '1,30p' ~/.grok/config.toml      # api_key redacted
[cli]
installer = "internal"

[marketplace]
default_skills_installs_purged = true
official_marketplace_auto_installed = true

[[marketplace.sources]]
name = "xAI Official"
git = "https://github.com/xai-org/plugin-marketplace.git"

[ui]
max_thoughts_width = 120
fork_secondary_model = "grok-4.6"
yolo = false
compact_mode = false
voice_stt_language = "ru"
permission_mode = "always-approve"

[privacy]
privacy_banner_acked = "2026-08-26T08:31:37Z"

[models]
default = "codex-sol"
default_reasoning_effort = "low"

[model.dks-ultra]
model = "DKS-Ultra"
base_url = "<internal-endpoint>"
name = "DKS-Ultra (LANIT)"
```

Сверка с дизайном, строка 26: «| The CLI carries its own defaults | `~/.grok/config.toml`: `[models] default = "grok-4.6"`, `default_reasoning_effort = "xhigh"` |». Фактически `default = "codex-sol"`, `default_reasoning_effort = "low"`.

#### A.5 Структура файла: модели объявлены пользователем, effort — per-model

```
$ grep -n '^\[' ~/.grok/config.toml
1:[cli]
4:[marketplace]
8:[[marketplace.sources]]
12:[ui]
20:[privacy]
23:[models]
27:[model.dks-ultra]
34:[model.deepseek-v4-flash]
41:[model.dks-vision]
48:[model.glm-5-3-flash]
55:[model.minimax-m3]
62:[model.<internal-model>]
69:[model.kimi-k3]
76:[model.minimax-m3-ollama]
83:[model.deepseek-v4-flash-ollama]
90:[model.deepseek-v4-pro-ollama]
97:[model.glm-5-3]
104:[model.glm-5-3-flash-zai]
111:[model.deepseek-v4-flash-api]
118:[model.deepseek-v4-pro]
125:[model.deepseek-v4-flash-vision-exp]
132:[model.codex-sol]
143:[[model.codex-sol.reasoning_efforts]]
150:[[model.codex-sol.reasoning_efforts]]
157:[[model.codex-sol.reasoning_efforts]]
164:[[model.codex-sol.reasoning_efforts]]
171:[[model.codex-sol.reasoning_efforts]]
178:[model.codex-terra]
189:[[model.codex-terra.reasoning_efforts]]
196:[[model.codex-terra.reasoning_efforts]]
203:[[model.codex-terra.reasoning_efforts]]
210:[[model.codex-terra.reasoning_efforts]]
217:[[model.codex-terra.reasoning_efforts]]
224:[model.codex-luna]
235:[[model.codex-luna.reasoning_efforts]]
242:[[model.codex-luna.reasoning_efforts]]
249:[[model.codex-luna.reasoning_efforts]]
256:[[model.codex-luna.reasoning_efforts]]
263:[[model.codex-luna.reasoning_efforts]]
```

Модель С поддержкой effort:

```
$ sed -n '132,155p' ~/.grok/config.toml    # api_key redacted
[model.codex-sol]
model = "gpt-5.6-sol"
base_url = "http://127.0.0.1:8317/v1"
name = "GPT-5.6 Sol (Codex Plus)"
description = "Latest frontier agentic coding model via ChatGPT Plus / Codex"
api_backend = "responses"
api_key = "sk-REDACTED"
context_window = 272000
supports_reasoning_effort = true
reasoning_effort = "xhigh"

[[model.codex-sol.reasoning_efforts]]
id = "low"
value = "low"
label = "Low"
description = "Fast responses with lighter reasoning"
default = false

[[model.codex-sol.reasoning_efforts]]
id = "medium"
value = "medium"
label = "Medium"
description = "Balanced speed and reasoning"
default = false
```

Модель БЕЗ поддержки effort (типичный вид):

```
$ sed -n '27,34p' ~/.grok/config.toml      # api_key redacted
[model.dks-ultra]
model = "DKS-Ultra"
base_url = "<internal-endpoint>"
name = "DKS-Ultra (LANIT)"
api_key = "sk-REDACTED"
context_window = 204800

[model.deepseek-v4-flash]
```

Сколько моделей вообще объявляют поддержку:

```
$ grep -c 'supports_reasoning_effort' ~/.grok/config.toml
3
$ grep -n 'supports_reasoning_effort' ~/.grok/config.toml
140:supports_reasoning_effort = true
186:supports_reasoning_effort = true
232:supports_reasoning_effort = true
```

То есть из 20 моделей каталога effort объявлен поддерживаемым у трёх (`codex-sol`, `codex-terra`, `codex-luna`), и у каждой из них — собственный список допустимых значений со своим `default = true`. Это первичное основание для Concern «`reasoning_effort` в самом CLI — per-model».

#### A.6 Тип бинаря (к Suggestion про `stdbuf`)

```
$ file "$(readlink -f "$(command -v grok)")"
/home/zinin/.grok/downloads/grok-linux-x86_64: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), static-pie linked, BuildID[sha1]=df459c3cd090505e639a83d8a3a50d63add79245, stripped
```

`stdbuf` подменяет буферизацию через `LD_PRELOAD=libstdbuf.so`; статически слинкованный бинарь его не подхватывает.

#### A.7 Прочие флаги, проверенные по `grok --help` (все существуют, план корректен)

```
  -m, --model <MODEL>
      --no-plan
      --output-format <OUTPUT_FORMAT>
          Possible values:
          - plain
          - json
          - streaming-json:          NDJSON of the agent native ACP session updates
          - streaming-messages-json: NDJSON in the Anthropic Messages API wire format
          [default: plain]
      --permission-mode <MODE>
          [possible values: default, acceptEdits, auto, dontAsk, bypassPermissions, plan]
      --prompt-file <PATH>
          Single-turn prompt from a file
      --reasoning-effort <EFFORT>
```

Все флаги из инвокации дизайна §2 и Task 6 приняты CLI; `streaming-messages-json` описан самим CLI как «NDJSON in the Anthropic Messages API wire format», что подтверждает центральную ставку дизайна на переиспользование `extract-result.py` и ext-claude-ветки guard'а.

---

## claude:fable

### Ревью дизайна и плана grok-engine — claude:fable (итерация 1)

Ревьюер: claude:fable
Дата: 2026-08-28
Документы: `docs/superpowers/specs/2026-08-28-grok-engine-design.md`, `docs/superpowers/plans/2026-08-28-grok-engine.md`
Метод: оба документа прочитаны полностью и сверены построчно с кодовой базой (`config-loader.sh`, `verify-delegation.sh`, `preflight-env.sh`, `watch-runs.sh`, `watchdog.sh`, `extract-result.py`, gemini-exec/ext-claude-exec, оба оркестратора, все четыре тестовых сьюта и их хелперы).

Общая оценка: дизайн зрелый, план необычно детальный и в основном честный к коду — но в нём есть дефекты, которые сломают исполнение или продукт, если их не поправить до старта.

### Critical Issues

**C1. Q1 переполняет лимит AskUserQuestion в обоих оркестраторах (дефект и дизайна §3, и Tasks 11/12).**
`commands/mesh-review.md:109-121` — Q1 сегодня имеет ровно 4 опции (claude, codex, gemini, external models) при заявленном «multiSelect, max 4»; вся пагинация проекта (Step 2.4, Step 3, design-review 5.2.5/5.3) построена на том, что 4 опции — жёсткий потолок инструмента. Добавление «grok CLI ★ default» даёт 5 опций, когда `HAS_CODEX=HAS_GEMINI=HAS_GROK=HAS_MODELS=1` — а это ровно конфигурация машины автора (Task 14 Step 1 сам её создаёт). То же в `skills/mesh-design-review/SKILL.md:309-319`. Ни Task 11 Step 2, ни Task 12 Step 3 не говорят, как Q1 должен уместиться: нужна явная инструкция (двухстраничный Q1 по механике Step 2.4, либо перестройка списка). Без неё исполняющий агент либо молча нарушит лимит, либо импровизирует.

**C2. Task 12 диспатчит не того агента — grok в design review будет ревьюить git-diff вместо документов.**
Design review работает через **executor**-агентов с готовым составленным промптом: `skills/mesh-design-review/SKILL.md:416-443` — `codex-executor`, `gemini-executor`, `ext-claude-executor` получают `Execute this prompt via …: PROMPT: [composed prompt] … SUPERVISED_MODE: shell` (для ext-claude — `MODEL=<id>` первой строкой, :428). План же в Task 12 Step 2 и Step 4 велит диспатчить `claude-mesh:grok-code-reviewer` — агента, чей skill (Task 7) сам резолвит диапазон диффа через `BASE_BRANCH`/`merge-base` и рендерит `shared/code-review-prompt.md`. Результат: grok-ревьюеры в `/mesh-design-review` проигнорируют design/plan-документы и отревьюят рабочее дерево. Правильно: `claude-mesh:grok-executor` (Task 6 Step 9 уже задаёт ему контракт `MODEL=` первой строкой — он готов к этой форме) + обёртка `Execute this prompt via grok-exec:` + `SUPERVISED_MODE: shell`. Сопутствующее в том же Task 12 Step 4: (а) секция в merged-файле должна называться `## grok-executor (<model>)` по конвенции Step 7 (:522-536), не `## grok-code-reviewer`; (б) «add `grok:grok-4.6` to the spec loop» — в этом файле нет spec loop, guard вызывается одиночной командой (:480-485); инструкция написана по шаблону mesh-review и в design-review не находима.

**C3. Тесты Tasks 2–3 вызывают несуществующий хелпер `assert_eq_str` — сьют «позеленеет», не выполнив утверждений.**
В `skills/shared/tests/test-config-loader.sh` определены только `assert_exit`, `assert_stderr_contains`, `assert_stderr_lacks` (строки 14-41); `assert_eq_str` нет нигде. План использует его 8 раз (Test 57: has_grok×2, list-grok-models, get-grok, формат get-codex; Test 58: grok_models в get-defaults ×2 и type-check). Сьют работает под `set -u` без `set -e`: «command not found» (rc 127) не инкрементирует `FAIL`, и суммарная строка покажет `0 failed` при фактически не выполненных проверках — худший вид красного теста. План должен либо определить `assert_eq_str` рядом с остальными хелперами, либо переиспользовать `assert_exit` (он сравнивает строки, но его FAIL-сообщение говорит «rc=» — вводит в заблуждение).

**C4. Набор уровней reasoning effort в дизайне и плане не совпадает с фактическим набором CLI; написание `--effort` при этом подтверждено как алиас.**
*Что снимается.* Первоначальное опасение ревью — что `--effort` есть неизмеренное написание флага (таблица фактов дизайна измеряла `--reasoning-effort`), и при его невалидности каждый запуск с настроенным effort умирал бы на старте CLI (под watchdog — трижды, до исчерпания бюджета). Контрольный замер team-lead на grok 1.0.5 закрывает это: `grok -p x --reasoning-effort=__bogus__` отвечает «`--effort/--reasoning-effort: unknown effort level '__bogus__'; use one of: low, medium, high, xhigh, max`» — CLI сам называет обе формы алиасами. Инвокация плана (`--effort "$EFFORT"`) валидна, правка написания не нужна.
*Что остаётся дефектом.*
1. Тот же замер показывает **пять** уровней — в наборе есть `max`, — тогда как таблица фактов дизайна утверждает «Reasoning effort accepts `low`, `medium`, `high`, `xhigh`» со ссылкой именно на эту команду. В «measured facts», фундаменте дизайна, лежит неверно записанное измерение.
2. Четвёрка растиражирована по плану как «known set»: Global Constraints («Known reasoning efforts: low | medium | high | xhigh»), `case "$effort" in low|medium|high|xhigh)` в `validate_grok` (Task 2 Step 4), комментарий в `config.example.yaml` (Task 4 Step 1), README-строка (Task 4 Step 3), контракт REASONING_EFFORT в grok-exec (Task 6 Step 3 — «the set the CLI itself names», что фактически неверно: CLI называет пять) и в агенте `grok-executor` (Task 6 Step 9). Пользователь, поставивший легальный `max`, получит WARN «unknown value» на каждом validate/get-grok — постоянный шум, подрывающий доверие к валидатору. (Попутно это подтверждает правильность pass-through-решения дизайна: будь набор enum'ом, `max` был бы hard error.)
3. Правка дешёвая и должна случиться до исполнения Task 2: добавить `max` в case-набор и во все перечисления документации; переформулировать «the set the CLI itself names», чтобы список не выдавался за исчерпывающий; в Test 57 добавить кейс «`max` проходит без WARN». Остаточная страховка — передавать `--effort low` в smoke-инвокации (Task 6 Step 10): тогда алиас и приём флага закреплены исполняемым тестом, а не только сегодняшним ручным замером.
Severity после замера: уже не блокер запуска, но дефект класса «дизайн противоречит собственной таблице фактов»; оставлен в Critical-списке как условие старта, потому что правится одной строкой case плюс документацией — до того, как четвёрка разойдётся по восьми файлам.

### Concerns

**N1. «No-skills»-ограничение не попадает в design-review-путь.** Констрейнт из §2 добавляется только в `grok-code-review` (Task 7 Step 4). В design review составленный промпт уходит в `grok-exec` напрямую — и grok, видящий `claude-mesh:mesh-review` среди своих скиллов (факт из таблицы), в design-review-прогоне ничем не ограничен. Task 12 должен добавить ограничение в PROMPT-блок grok-диспатчей (или в составленный промпт — тогда решить, приемлемо ли оно для остальных ревьюеров).

**N2. Task 7 Step 4 нарушает главное правило собственного скилла.** Фенс начинается с `cat >> "$PROMPT_FILE"`, но `$PROMPT_FILE` создан в предыдущем Bash-вызове (gemini-code-review.md:123-130 — mktemp внутри Step 3), а «Variables DO NOT persist between calls» — это КРИТИЧЕСКИЙ раздел каждого exec-скилла. Пустая переменная даст «ambiguous redirect». Правильно: включить heredoc-дописывание в единый фенс Step 3 (перед финальным `cat "$PROMPT_FILE"`), либо начать новый фенс с явного `PROMPT_FILE="<путь, напечатанный Step 3>"`. Заодно: keep-список Task 7 Step 1 не упоминает Process Step 3 и Step 5 («Steps 2-4 below replace the rest» противоречит Step 4, который *редактирует* Step 3) — агент может удалить рендеринг целиком.

**N3. В Task 12 нет обязательного пустого биндинга `SELECTED_GROK_MODELS` для интерактивного пути.** Step 3 говорит лишь «If grok is not selected → skip Step 5.2.6 and run no grok reviewer» — без «bind to the empty list», который claude-аналог 5.2.5 (:325-328) делает явным и о котором файл сам предупреждает («an unbound name in a prompt raises nothing at all»). Биндинг есть только в 5.1 (default). В mesh-review (Task 11 Step 3) биндинг есть — асимметрия выглядит как недосмотр, а не решение.

**N4. `validate_grok_catalog` внутри `validate_defaults` «заземляет» всё окружение при сломанной grok-секции — в противоход собственному Test 57.** Task 3 вызывает каталог-валидатор безусловно; `cmd_get_defaults` его исполняет, а CONFIG-ряд preflight проверяет `get-defaults design_review` (preflight-env.sh:226-238). Итог: `defaults:` присутствует (типичный конфиг — example его содержит) + опечатка в `grok.models` ⇒ CONFIG=INVALID ⇒ все CLI-ряды SKIPPED — при том, что комментарий preflight-env.sh:224-225 фиксирует обратный принцип («a broken optional section fails its own row, never the whole environment»), а Test 57 плана демонстрирует «broken grok must not ground the other engines». Это парность с сегодняшним `claude:` (та же связка), так что выбор защитим — но план его нигде не называет, а INVALID-тест Task 10 проходит только потому, что `broken-grok-valid-codex.yaml` случайно не содержит `defaults:` — один «улучшенный» фикстур от этого сломается. Минимум: комментарий в фикстуре + тест «defaults присутствует + сломанный grok ⇒ config INVALID, grok SKIPPED». Максимум: скоупить каталог-валидацию на пресеты, упоминающие grok (чтение тогда через error-safe `.grok.models?`).

**N5. Дизайн §5 обещает grok-тесты на все шесть вердиктов — в Task 8 нет KILLED, и не покрыт grok-вариант FLOOR_NOTE.** KILLED для grok (watchdog.log с cleanup 143 без watchdog.exit — по образцу существующего ext-claude-теста на test-verify-delegation.sh:1197-1214) отсутствует. STALLED-floor-ветка с `$FLOOR_NOTE` для grok («the floor is 400 non-space bytes», и отсутствие «archive is 460») не проверяется ни одним кейсом — единственная из двух engine-ветвящихся строк, оставшаяся без теста (DEGRADED-remedy покрыт `assert_no_match`).

**N6. 5 секунд на `grok models` — неизмеренный бюджет.** `timeout "$HTTP_TIMEOUT"` = `PREFLIGHT_HTTP_TIMEOUT:-5` (preflight-env.sh:33) — бюджет, калиброванный под один curl. `grok models` — это Node-старт CLI, который по данным самого дизайна загружает `~/.claude/CLAUDE.md` и все плагины, плюс сетевой auth-round-trip. Дизайн, гордящийся «every claim measured», латентность не мерил; хронический ложный NO-NETWORK («no network, or not logged in») на здоровой машине — постоянный шум. Замерить `time grok models` или дать командному пробу собственный дефолт (10–15 с).

**N7. Task 13 Step 1 внутренне противоречив и способен внести ложное утверждение.** Перечисления «codex / gemini» в обоих fresh-session-файлах находятся внутри byte-identical-регионов (code-review-fresh-session.md:177-178 в PREFLIGHT, :207 в прилегающей прозе; в design-review — :126-127, :155), которые план запрещает трогать. При этом сентенция «`OK` on codex / gemini is a heuristic … NOT an auth check» для grok семантически **неверна**: строка grok в Task 10 прямо говорит «checks login as well as network». Слепое «extend each enumeration» либо нарушит регион (Test 2/3 sync-сьюта с закреплёнными длинами блоков: 7/17 строк), либо припишет grok чужой caveat. План должен назвать конкретные строки для правки и явно оставить heuristic-caveat как codex/gemini-only с причиной.

**N8. Заявленное поведение `extract-result.py` на `{"type":"error"}` не совпадёт с реальностью.** Fallback читает `ev.get("error", {}).get("message", …)` (extract-result.py:96-102) — вложенную форму; grok по таблице фактов шлёт message **верхним уровнем** (`{"type":"error","message":"Couldn't set model …"}`). output.txt получит `API Error: {}`; текст ошибки дойдёт до пользователя только через stderr-ветку PIPELINE_RC. Комментарий Task 6 («extract-result.py surfaces … "API Error: …" — that is the shape an unknown model produces») закрепляет ложное утверждение. Либо расширить fallback (top-level `.message`, плюс кейс в test-extract-result.sh), либо исправить комментарий.

**N9. Устаревающие перечисления, не покрытые Tasks 11/12.** После правок останутся «codex / gemini / ext-claude» в: mesh-review.md:334 (Step 5b, team mode — а Task 11 вообще не трогает 5b, хотя тот наследует пары и промпты Step 5a), :357 (шапка Step 6.0 «Wrapper reviewers … flip» — читатель решит, что grok вне guard'а), design-review :397 (Dispatch-model exception), :447 (collect output paths); плюс «Never mirror»-заметки цитируют старую формулировку пункта 6 в обоих файлах (:324, :501), а mesh-review.md:311 продолжит приписывать `report.md` скрипту `generate-md.sh` после Task 5. Ни один из них не блокер, но план, настолько дотошный к формулировкам, должен их перечислить.

**N10. Нумерация тестов Task 9 конфликтует с существующей.** «Test 31» и «Test 32» уже есть (test-watch-runs.sh:510, 524; файл доходит до Test 39). Grep из Step 2 (`grep -A4 'Test 31\|Test 32'`) выдаст и старые тесты — ожидание «they PASS immediately» замусорится. Нумеровать 40/41.

### Suggestions

**S1. Пресетная сторона — третья ручная копия охраны.** Блок `grok_models` в Task 3 повторяет type/empty/charset/dup + membership из блока `claude_models` — ровно тот класс дублирования, из-за которого §Approach отверг вариант A («would drift on the first edit»). Общий валидатор закрыл только каталоги; обе пресетные петли остаются близнецами. Либо дать `validate_model_catalog` опциональный параметр «каталог для membership» и посадить обе петли на него, либо хотя бы связать четыре копии перекрёстным комментарием.

**S2. Клод-специфика в сообщениях общего хелпера.** `— quote it, e.g. - "opus"` и `(a model alias or id)` захардкожены в `validate_model_catalog` и попадут в grok-ошибки: совет заквотить «opus» в сообщении про `grok.models` выглядит чужеродно. Пятый параметр-пример (или осознанная фиксация компромисса комментарием) — дёшево.

**S3. `list-grok-models` валидирует только каталог — сломанный `reasoning_effort` (`reasoning_effort: 3`) проходит гейты Step 1 обоих оркестраторов и preflight-summary, а падает лишь внутри grok-exec посреди диспатча (STOP на `get-grok`).** Это совпадает с прецедентом codex (mesh-review читает только `has_codex`), а preflight-ряд ловит через `get-$1`=get-grok — но, в отличие от codex, у grok есть дешёвый ранний гейт: пусть Step 1 читает и `get-grok` (rc-aware), или зафиксируйте выбранное поведение комментарием.

**S4. §5 дизайна обещает *регрессионный тест* на побайтовую идентичность claude-сообщений — план даёт лишь одноразовый ручной diff (Task 1 Steps 1/5).** Существующий Test 47 проверяет подстроки; хвосты сообщений (пример, charset-дисплей) не закреплены. Рассмотрите постоянный тест, пиновавший полные тексты.

**S5. Мелочи Task 7:** полноширинная скобка `）` в фенсе Step 3 (`…tr '\n' ' ')）"`) уйдёт в поставляемый skill; в том же фенсе `$("$LOADER" list-grok-models | …)` без rc-guard напечатает «OK: grok: section present ()» на сломанном каталоге при прямом вызове скилла (has_grok — bare probe, он пропустит).

**S6. Task 4 стоит прогонять test-config-loader:** Test 51 валидирует `config.example.yaml` в каждом прогоне сьюта, а Task 4 меняет example, не запуская сьют (глобальное правило привязано к `skills/shared/`); поломка обнаружится только в Task 14.

**S7. Бухгалтерия фикстур расходится:** дизайн §5 называет 11 файлов, File Structure — «valid-grok.yaml and 9 siblings», шаги создают 8 (duplicate/unknown-model/no-grok-models — inline printf, что нормально; `valid-codex-gemini-grok.yaml` не материализуется нигде — тройное сосуществование де-факто покрывает только Test 51 после Task 4). Синхронизируйте числа, иначе Self-Review Record неточен.

**S8. Новое правило «no fallback» живёт в четырёх местах** (mesh-review Step 0 / 2.45, design-review 5.1 / 5.2.6) — по прецеденту claude-правила (mesh-review.md:48, :172) ему положены такие же `<!-- SYNC: -->`-маркеры; план их не добавляет.

### Questions

**Q1.** ~~Проверялось ли, что `--effort` — валидный алиас `--reasoning-effort` в grok 1.0.5?~~ **Закрыт** контрольным замером team-lead: обе формы — алиасы, набор уровней — пять значений (включая `max`); последствия учтены в переформулированном C4.

**Q2.** Как автор предпочитает решить переполнение Q1 (C1): пагинация Q1 по механике Step 2.4 в обоих оркестраторах, или иная перестройка списка типов?

**Q3.** Осознан ли выбор в N4 — что сломанная grok-секция при существующем `defaults:` роняет `get-defaults`, CONFIG-ряд preflight и весь `default`-режим даже без единого упоминания grok в пресетах (паритет с claude), — или предпочтителен скоуп каталог-валидации на пресеты, ссылающиеся на grok?

**Q4.** Дизайн §5: «test-command-sync.sh — the grok wording shared by both orchestrators» — но сьют покрывает только два fresh-session-генератора (test-command-sync.sh:140-205), и план его justifiably не расширяет. Где должна жить обещанная проверка — или строку из дизайна убрать?

**Q5.** Мерился ли холодный старт `grok models` (N6)? Одно измерение сняло бы вопрос о бюджете пробы.

### Итог

Дизайн-решения (общий каталог-валидатор, переиспользование wire-формата и ext-claude-ветви guard'а, `--prompt-file` без STDIN_FILE, коллизионные правила run-каталогов, «no hardcoded model») выдерживают построчную сверку с кодом — C2 и C1 при этом показывают, что интеграция с design-review-оркестратором писалась по шаблону mesh-review, и именно там план расходится с реальным файлом. После закрытия C1–C3 и правки набора уровней из C4 план исполним агентами без автора.

---

## codex-executor

### Design review: grok-engine (iteration 1)

Reviewer: codex (gpt-5.5, xhigh) via claude-mesh codex-exec, supervised shell watchdog.
Run dir: `/home/zinin/.claude/plugins/data/claude-mesh-zinin/runs/codex/2026-08-28-20-45-02-490667-design-review-grok-engine-iter-1`
Documents: `docs/superpowers/specs/2026-08-28-grok-engine-design.md`, `docs/superpowers/plans/2026-08-28-grok-engine.md`

---

#### Critical Issues

1. **В design-review выбран неправильный wrapper.** Task 12 трижды предписывает `claude-mesh:grok-code-reviewer`: в default-режиме, при dispatch и в merged output ([план:2207](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2207), [план:2235](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2235), [план:2248](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2248)). Этот агент запускает `grok-code-review`, заново строит git diff и игнорирует составленный design-review prompt. Здесь нужен `claude-mesh:grok-executor`, как для существующих codex/gemini/ext-claude executors ([текущий design-review:416](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:416)). Иначе Grok выполнит code review вместо ревью документов.

2. **Обе Q1-формы превысят лимит AskUserQuestion.** Сейчас в каждой форме четыре варианта при явно указанном `max 4` ([mesh-review:109](/opt/github/zinin/claude-mesh/commands/mesh-review.md:109), [design-review:309](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:309)). План просто добавляет пятый — grok — сохраняя external models ([план:2008](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2008), [план:2220](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2220)). Нужна пагинация/вторая страница типов либо иной UI до начала реализации.

3. **Runtime-проверка `MODEL` не соответствует валидатору и допускает выход из `runs/grok`.** В Task 6 модель обрабатывается через `tr … | head -c 64` ([план:930](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:930)), после чего вставляется в путь ([план:937](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:937)). Проверкой команды подтверждено:

   - `MODEL=..` остаётся `..`, поэтому запись идёт в `runs/grok/../<run>`;
   - валидный по конфигу 70-символьный id обрезается до 64 символов;
   - CLI затем получает исходный, необрезанный `MODEL`, а guard/watcher ищут каталоговый полный id — результатом будет ложный `FLIP`/`MISSING`.

   Нужно не «санитизировать», а отклонять runtime-значение по точному `GROK_IDENT_RE`, без неоговорённого обрезания. Если нужен лимит длины, он должен одинаково присутствовать в config validator, executor, watcher и guard.

4. **Task 10 оставляет `preflight-env.sh` сломанным и логически неполным.**

   - `HAS_GROK` читается только внутри ветки usable-config ([план:1916](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1916)), но план велит заранее инициализировать только `GROK_MODELS` ([план:1923](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1923)). При missing/invalid config последующий `"$HAS_GROK"` под `set -u` оборвёт весь probe.
   - `SUMMARY defaults …` сейчас оставляет все builtin, кроме Claude, в голом виде ([preflight-env.sh:799](/opt/github/zinin/claude-mesh/skills/shared/preflight-env.sh:799)). Поэтому preset выдаст `grok`, тогда как available-line содержит `grok:<model>`. Fresh-session membership check сочтёт исправный `default` небезопасным. План добавляет только available expansion, но не defaults expansion.
   - Точный тест порядка строк также останется со старым ожидаемым списком без grok ([test-preflight-env.sh:826](/opt/github/zinin/claude-mesh/skills/shared/tests/test-preflight-env.sh:826)).

5. **Контракт “MODEL на первой строке” нарушается при `BASE_BRANCH`.** Агент требует `MODEL=` именно на первой строке ([план:1480](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1480)), но mesh-review с base branch формирует `BASE_BRANCH=<branch> MODEL=<entry> …` ([план:2104](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2104)). Такой wrapper обязан остановиться. Формат должен быть, например:

   ```text
   MODEL=grok-4.6
   BASE_BRANCH=main
   Review the changes…
   ```

   И agent definition должна явно распознавать и передавать `BASE_BRANCH`, а не только `MODEL`/`CONTEXT`.

6. **Интеграция оркестраторов не покрывает все состояния.**

   - Task 11 изменяет только background Step 5a; team-mode продолжает явно перечислять `codex / gemini / ext-claude` ([mesh-review:330](/opt/github/zinin/claude-mesh/commands/mesh-review.md:330)). Для полного parity нужны grok dispatch, roster и wrapper-list в Step 5b.
   - В текущем design-review Step 5.4 — подтверждение, а не dispatch ([design-review:368](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:368)). План ошибочно называет его dispatch ([план:2191](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2191)) и не требует добавить grok expansion на confirmation page, очистку при reselect и сохранение `SELECTED_GROK_MODELS` для итераций 2..N ([design-review:383](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:383)).
   - Если единственным выбранным типом был grok, а список моделей оставлен пустым, эффективный roster равен нулю. План разрешает продолжить, но не определяет, как не вызвать пустой watcher/dispatch.

7. **Утверждение “`extract-result.py` служит grok без изменений” неверно для уже измеренного error event.** Grok сообщает ошибку модели как верхнеуровневый `{"type":"error","message":"…"}`, а extractor ищет `.error.message` ([extract-result.py:95](/opt/github/zinin/claude-mesh/skills/shared/extract-result.py:95)). Проверка дала `API Error: {}`, а не текст ошибки, вопреки комментарию плана ([план:1007](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1007)). Нужна поддержка верхнеуровневого `.message` и regression case в `test-extract-result.sh`.

   Кроме того:

   - отсутствие terminal result в unsupervised mode даёт только WARN ([план:1017](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1017)); assistant fallback может оставить непустой output и вернуть успех;
   - supervised mode вообще не проверяет terminal result после watchdog;
   - extractor запускается на `final/`, но в root копируются только `raw.jsonl` и `output.txt` ([план:1093](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1093)). Обещанные root-level `raw.json` и `stderr.txt` ([план:809](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:809)) там не появятся.

8. **Семантика `has_grok` и scoped validation противоречива.** Дизайн говорит, что `has_grok` отвечает и за gate, и за наличие валидного каталога ([design:90](/opt/github/zinin/claude-mesh/docs/superpowers/specs/2026-08-28-grok-engine-design.md:90)), но реализация — голый truthiness probe без `validate_grok_catalog` ([план:402](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:402)). Поэтому malformed object возвращает `1`, а `grok: false` выглядит как отсутствие секции.

   Одновременно:

   - `validate_defaults` планирует безусловно валидировать grok catalog при наличии любого `defaults:` ([план:542](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:542)), даже если preset вообще не использует grok;
   - interactive mesh-review безусловно вызывает `list-grok-models` и останавливает весь review на сломанной grok-секции ([план:1994](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1994));
   - preflight, напротив, трактует invalid optional CLI section как локальную проблему одной строки, сохраняя другие reviewers доступными ([preflight-env.sh:356](/opt/github/zinin/claude-mesh/skills/shared/preflight-env.sh:356));
   - fixture `broken-grok-valid-codex` проверяет только прямой `get-codex`, поэтому это расхождение не ловит.

   До реализации нужна единая политика: malformed grok блокирует весь orchestrator или только grok.

9. **План в текущем виде не гарантирует зелёные коммиты.**

   - Само извлечение `validate_model_catalog` сохраняет четыре loop-guard и тексты Claude корректно. Но обещанной постоянной byte-identical регрессии нет: Task 1 не добавляет тестов ([план:69](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:69)), текущий Test 47 проверяет только подстроки ([test-config-loader.sh:939](/opt/github/zinin/claude-mesh/skills/shared/tests/test-config-loader.sh:939)), а golden diff живёт только во временных `/tmp`-файлах. Более того, ожидаемый префикс `config-loader: ERROR:` в плане неверен: `die` печатает просто `config-loader:` ([config-loader.sh:40](/opt/github/zinin/claude-mesh/skills/shared/config-loader.sh:40)).
   - Почти все команды вида `bash test.sh | tail -3` скрывают rc теста без `pipefail`. Финальная acceptance-команда делает то же со smoke test ([план:2434](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2434)), а цикл suite не накапливает failure и сам возвращает успех ([план:2428](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2428)). Контрольная проверка `false | tail` действительно вернула rc=0.
   - `test-command-sync.sh` проверяет только fresh-session generators ([test-command-sync.sh:1](/opt/github/zinin/claude-mesh/skills/shared/tests/test-command-sync.sh:1)); он ничего не утверждает о двух оркестраторах, хотя дизайн обещает grok sync coverage.

#### Concerns

- **Guard оставляет ложный общий текст для Grok.** Новая remedy ветвится, но emit всё равно говорит, что reviewer “was confined to its working directory” ([план:1684](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1684)). Для Grok с `bypassPermissions` denial может означать совсем другую deny-rule. Также header всё ещё документирует `DEGRADED` как ext-claude-only. Предложенные тесты не покрывают grok `KILLED`, короткий output/floor-note и не требуют положительного присутствия новой remedy.

- **Config coverage неполно.** Нет grok-specific тестов на non-string/empty catalog element, non-string/empty/unsafe `reasoning_effort`, unset `get-grok` → пустая строка rc=0, absent `list-grok-models`, scalar/non-string/empty/charset `defaults.*.grok_models`. Большинство этих ветвей можно удалить, не сломав предложенный Test 57/58.

- **Smoke test не проверяет unbuffered growth.** Он измеряет только финальный размер ([план:1290](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1290)); полностью буферизованный stream даст тот же результат. Это не выполняет design check “файл растёт внутри stall window”. Кроме того, smoke не исполняет Markdown-launcher, optional arrays, model/effort resolution, run-dir logic или supervised path.

- **Shared renderer формально читает Grok wire format, но теряет блоки.** Он смотрит только `.message.content[0]` ([generate-md.sh:81](/opt/github/zinin/claude-mesh/skills/ext-claude-exec/generate-md.sh:81)). На собственной fixture плана с `text` и последующим `tool_use` ([план:742](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:742)) проверка дала `0` tool headings. Byte-identical move доказывает лишь отсутствие изменений, но не пригодность renderer для Grok.

- **Preflight объявляет доступными модели, которых `grok models` не перечислил.** Shim печатает только `grok-4.6`, но тест требует добавить в available также каталоговый `grok-4.5` ([план:1818](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1818), [план:1834](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:1834)). Это закрепляет ложноположительный `SUMMARY available`.

- **Task 13 неправильно трактует fresh-session wording.** Два существующих упоминания `codex / gemini` — это не перечень engines, а предупреждение, что их OK является HTTP-эвристикой без проверки auth ([code-review-fresh-session.md:177](/opt/github/zinin/claude-mesh/commands/code-review-fresh-session.md:177)). Для Grok это неверно: `grok models` как раз проверяет login. План одновременно велит расширить оба упоминания и ничего не менять в PREFLIGHT-region ([план:2290](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-28-grok-engine.md:2290)). Нужна отдельная фраза о более сильной семантике grok-row. Заодно `LOADER_SUBCMDS` в sync test должен получить `list-grok-models|get-grok`, иначе запрет чтения локального конфига не покрывает новые команды.

- **Промежуточный порядок коммитов не release-safe.** Task 4 добавляет grok в оба default preset примера до появления skills, agents и orchestrators. Такой промежуточный commit предлагает пользователю конфигурацию, которую установленный код ещё не способен выполнить.

#### Suggestions

- Вынести реальный grok launcher в исполняемый shell-скрипт и вызывать его и из `SKILL.md`, и из smoke tests. Сейчас самые рискованные 150 строк существуют только как непроверяемый Markdown, а smoke дублирует небольшую безопасную часть команды.

- Хранить direct/no-model runs под фиксированным namespace вроде `runs/grok/_default/<run>/`, а не рядом с model directories. Это устраняет возможность коллизии с моделью, чьё имя само похоже на timestamp-run.

- Добавить один статический orchestrator-contract test: правильный agent type (`grok-code-reviewer` только в mesh-review, `grok-executor` только в design-review), default binding, confirmation binding, watcher spelling `grok/<model>`, guard spelling `grok:<model>`, first-line `MODEL`, team-mode и iteration reuse.

- Для Claude message freeze добавить committed golden fixture с полным stderr. В shared helper можно параметризовать пример значения, чтобы grok type error советовал `"grok-4.6"`, сохранив для Claude байт-в-байт `"opus"`.

- Сам `--effort` корректен: в локальном `grok 1.0.5` он указан как alias `--reasoning-effort`. Форма `${arr[@]+"${arr[@]}"}` также соответствует заявленной поддержке Bash 4.2; менять их не требуется.

#### Questions

- Должна ли сломанная, но не выбранная `grok:` секция блокировать весь `/mesh-review default`/interactive run или только скрывать grok? Сейчас plan, preflight и fixture `broken-grok-valid-codex` дают три разных ответа.

- Считается ли YAML `grok:` без значения отсутствующей секцией или ошибкой “models required”? Дизайн говорит “section present → required”, а `validate_grok_catalog` трактует `null` как отсутствие.

- Должен ли preflight сверять каждый `grok.models` id с выводом `grok models`, или `SUMMARY available` сознательно означает лишь “CLI залогинен”, а не “эта модель доступна”?

- Что должен делать orchestrator, когда после model-selection эффективный набор пуст — например, выбран только grok, но не выбрана ни одна grok-модель: завершаться чисто без запуска или останавливать подтверждение как “ничего не выбрано”?

---

## ext-claude-executor (deepseek/v4-pro)

### Design review: grok-engine — deepseek/v4-pro (iter 1)

- Model: `deepseek/v4-pro` (`deepseek-v4-pro[1m]`), engine: ext-claude, supervised
- Run dir: `/home/zinin/.claude/plugins/data/claude-mesh-zinin/runs/ext-claude/deepseek/v4-pro/2026-08-28-20-45-58-492899-design-review-grok-engine-iter-1`

---

Прочитал оба документа и сверил их с текущим кодом (`config-loader.sh`, `verify-delegation.sh`, `watch-runs.sh`, `preflight-env.sh`, `watchdog.sh`, `extract-result.py`, `generate-md.sh`, оба оркестратора, тестовые сюиты). Ниже — только то, что я проверил по файлам, с конкретными ссылками.

Предварительно — короткая позитивная сверка по главному фокусу ревью, чтобы зафиксировать, где план точен:

- **Извлечение `validate_model_catalog` сохраняет сообщения claude побайтово.** Сверил тело `validate_claude` (`config-loader.sh:406-462`) с хелпером из Task 1 Step 3 построчно: type-gate, `empty value`, charset `[A-Za-z0-9._:@-]` + `(a model alias or id)`, duplicate — все четыре формулировки идентичны, включая эм-дэш и кавычки. Аргументы вызова `'.claude.models' 'claude.models' "$IDENT_RE" '[A-Za-z0-9._:@-]'` воспроизводят их точно.
- **Повторное использование ветки `ext-claude|grok` в guard корректно.** `FLOOR_NOTE` и `DENIAL_REMEDY` для `*` (ext-claude) дают байт-идентичный текст текущим строкам `verify-delegation.sh:428` и `:468`; grok-варианты не задевают ext-claude-тексты.
- **Порядок задач 1→14 зависимостей не нарушает** (5 потребляется 6, 1→2, 2→3/6/8/10/11/12, 6→7, 7→11/12, 8→11/12/14).

---

#### Critical Issues

**1. `assert_eq_str` не существует — тесты Tasks 2 и 3 молча не проверяют ничего.**
`test-config-loader.sh` определяет только `assert_exit` (стр. 14), `assert_stderr_contains` (23), `assert_stderr_lacks` (33). Хелпера `assert_eq_str` в файле нет (проверил grep по всему `skills/shared/tests/` — есть только локальный `assert_eq` в `test-watch-runs.sh`). Plan Task 2 Step 2 и Task 3 Step 2 вызывают `assert_eq_str` ~8 раз (`has_grok=0/1`, `list-grok-models` вывод, `get-grok` вывод, `get-codex` вывод, `.grok_models` значение, тип `array`). В bash вызов несуществующей функции даёт `command not found` (rc 127) и **не инкрементит FAIL** — при этом `set -u` тут не спасает (это не переменная). Итог: сюита прошла бы с «0 failed», а все проверки значений геттеров просто не выполнились. Это ровно тот случай из фокуса ревью «сломается ли регрессия, если правило сломать» — нет, не сломается. План обязан либо добавить `assert_eq_str`, либо явно сослаться на существующий хелпер.

**2. `HAS_GROK` не инициализирован под `set -u` — no-config/сломанный-toolchain путь роняет весь probe.**
`preflight-env.sh:184-185` инициализирует `HAS_CODEX=0` / `HAS_GEMINI=0` на верхнем уровне, потому что `cli_row codex/gemini … "$HAS_CODEX"` вызываются безусловно (стр. 421-422). Plan Task 10 Step 4 добавляет чтение `HAS_GROK=$(… get-flag has_grok)` **внутрь** `if [ "$CONFIG_STATUS" = "OK" ]` (~стр. 308) и инициализацию `GROK_MODELS=""` (~стр. 280), но **не** добавляет `HAS_GROK=0` рядом с `HAS_CODEX=0`. Когда `CONFIG_STATUS != OK` (нет `config.yaml`, отсутствует yq/jq, провал `mktemp` — то есть ровно те сценарии «несконфигурированной машины», ради которых файл и существует), `cli_row grok … "$HAS_GROK"` разворачивает несвязанную переменную → `set -u` абортит скрипт на ~стр. 422, до git-remote, bash-timeout и SUMMARY. Ломаются: `run_probe none` (rc≠0 → BAD_RC-gate), все `SUMMARY available:`-ассерты для no-config, и финальный gate «every scenario printed exactly one SUMMARY» (стр. 834). Лечится одной строкой `HAS_GROK=0` у `HAS_CODEX=0`.

**3. Row-order assertion в `test-preflight-env.sh` не обновлён — Task 10 оставит сюиту красной.**
Строка 827 жёстко зашивает последовательность `"plugin yq jq config builtin-claude claude-models codex gemini provider:zai …"`. `cli_row grok` (Task 10 Step 5) печатает строку `grok` между `gemini` и `provider:zai` — причём **всегда**, даже с `valid-full.yaml` без секции `grok:` (там будет `grok MISSING`). Ассерт не содержит `grok` → провал. Plan Task 10 Step 6 говорит «0 failed», но ни один шаг не правит этот ассерт. Это «коммит, оставляющий сюиту красной» — прямой сигнал в фокусе ревью.

**4. Q1 превышает лимит «max 4» AskUserQuestion — выбор типов ломается при включённом grok.**
Оба оркестратора явно пишут лимит: `mesh-review.md:109` («multiSelect, max 4», сейчас 4 опции: claude/codex/gemini/external) и `mesh-design-review/SKILL.md:309` («multiSelect: true, max 4»). Добавление `"grok CLI ★ default"` (Task 11 Step 2, Task 12 Step 3) даёт **5 опций** при `HAS_GROK=1` (в типичном «всё включено» конфиге — ровно 5). Пагинация «chunk of 4» существует именно из-за этого лимита, но для Q1 никакой пагинации/слияния план не предусматривает. Ни design, ни plan этот момент не адресуют.

#### Concerns

**5. `SUMMARY defaults` и сверка `defaults_not_available` не расширены под grok — ложный «default mode небезопасен».**
Plan Task 10 Step 5 трогает только `SUMMARY available/unavailable` блок. jq-развертка `SUMMARY defaults` (`preflight-env.sh:796-813`) раскрывает не-claude записи `builtin` **буквально**: `builtin: [grok]` даст на defaults-строке голое `grok`, тогда как available-строка даёт `grok:grok-4.6`. Хелпер `defaults_not_available` (стр. 623) имеет спец-случай «голое `claude` удовлетворяется `claude:<model>`» (стр. 635-637), но никакого grok-аналога. Читающая сессия, выполняющая «каждое имя на defaults-строке должно быть в SUMMARY available», заключит, что `default`-режим с grok небезопасен. Плюс это противоречит решению дизайна «имя ревьюера везде `grok:<model>`».

**6. Default (unsupervised) запуск `grok` без `stdbuf -oL -eL`.**
Дизайн §2 «Invocation» и supervised-блок (Task 6 Step 7) используют `stdbuf -oL -eL`; default-блок (Task 6 Step 6) — нет, он пайпит grok в `while read`. Замер дизайна «поток небуферизован» сделан для **перенаправления в файл**, а не для pipe. Если grok буферизует при pipe, прогресс-строки `:: Tools:` и живая запись `raw.jsonl` будут идти кусками. Это зеркалит существующее разделение gemini (default без stdbuf, supervised с stdbuf), так что, вероятно, осознанно — но факт из дизайна этот случай не покрывает, стоит подтвердить.

**7. `has_grok` — «bare-probe», а не валидирующий.**
`has_grok` = `jq -e '.grok'` (`config-loader.sh` Task 2 Step 5) возвращает `1` для `grok: {models: []}`, хотя каталог невалиден. Тезис дизайна «`has_grok` отвечает за оба вопроса» верен только *после* валидирующего чтения (`list-grok-models`/`get-grok`). В оркестраторах порядок это обеспечивает (Step 1 сначала `list-grok-models`), но связка хрупкая и не отражена комментарием.

**8. Косметика сообщений каталога grok.** Общий хелпер зашивает `(a model alias or id)` — поэтому ошибки `grok.models[i]` говорят «alias or id», а ошибки preset-уровня `grok_models[i]` — «(a grok model id)». Несогласованность, не баг.

**9. `DSML` в тексте BROKEN для grok.** Ветка `ext-claude|grok` в `verify-delegation.sh:421` говорит «thinking-only / DSML / …». DSML — грамматика codex; grok (как и ext-claude) её не использует. Для ext-claude это уже так, поэтому не новое, но Task 11 Step 7 пропагирует «thinking-only / num_turns≤1», не отметив формулировку.

#### Suggestions

- В Task 2/3: вместо ссылки на несуществующий `assert_eq_str` — добавить локальный `assert_eq` (как в `test-watch-runs.sh:35`) или явно указать хелпер, который надо ввести в `test-config-loader.sh`.
- Для Q1 (находка 4): либо слить grok с codex/gemini в общий шаг «внешние CLI-движки», либо пагинировать выбор типов; это решение нужно поднять пользователю до реализации.
- `validate_grok` третирует `reasoning_effort: ""` как `die` («empty value»), тогда как `codex.reasoning_level` пустую строку просто пропускает (`if [ -n "$level" ]`). Либо привести к codex-семантике, либо задокументировать расхождение.
- Для command-probe в `cli_row` стоит отдельный таймаут: `timeout "$HTTP_TIMEOUT" $5` с дефолтом 5 с для `grok models` на медленной машине даст ложный NO-NETWORK.

#### Questions

1. «max 4» — это жёсткий лимит инструмента в целевом harness (тогда Q1 нужно перепроектировать), или конвенция (тогда аннотацию «max 4» в обоих файлах надо править)?
2. Нужен ли `stdbuf -oL -eL` в default-запуске grok — замер дизайна покрывает только redirect-to-file, а не pipe (находка 6)?
3. Должен ли `get-defaults <category>` падать целиком при malformed `grok:` секции, даже если grok отсутствует в `builtin` запрашиваемого пресета? Это зеркалит `validate_claude`, но это новая fail-closed связка — стоит подтвердить, что она желаема (иначе сломается `/mesh-review` на конфиге, где пользователь оставил `grok: reasoning_effort: xhigh` без `models`, хотя grok не выбран).

---

## ext-claude-executor (ollama/kimi)

### Design review: grok-engine (iter 1) — ollama/kimi

**Движок:** `ext-claude` / `ollama/kimi` → `kimi-k3:cloud`, `SUPERVISED_MODE=shell`
**Run dir:** `runs/ext-claude/ollama/kimi/2026-08-28-20-58-25-505251-design-review-grok-engine-iter-1`
**Guard:** REAL, `num_turns=55`
**Источник:** `output.txt` (дословно, без сокращений)

---

Изучил оба документа и сверил ключевые утверждения плана с кодом (`config-loader.sh`, `verify-delegation.sh`, `watch-runs.sh`, `preflight-env.sh`, `watchdog.sh`, `extract-result.py`, SKILL-файлы трёх существующих движков, оба оркестратора, тестовые хелперы всех четырёх затрагиваемых suites). Ниже — только те находки, которые подтверждаются конкретными строками кода.

#### Critical Issues

1. **Q1 в обоих оркестраторах вырастает до 5 опций при аппаратном пределе 4.** `AskUserQuestion` принимает максимум 4 опции на вопрос (сам план это знает — пагинация Step 3 «chunks of 4» существует именно из-за этого лимита). Сейчас Q1 в `mesh-review.md:117-120` содержит ровно 4 опции: claude, codex, gemini, external models. Дизайн §3 и план (Task 11 Step 2, Task 12 Step 3) добавляют «grok CLI ★ default» пятой — ни слова о перестройке вопроса. У полностью сконфигурированного пользователя (все четыре `has_*`=1) Q1 перестанет вызываться. Нужно решение на уровне дизайна: объединить CLI-движки в одну опцию с под-вопросом, либо разбить Q1 на два вопроса. То же самое в `mesh-design-review/SKILL.md:309-319` (`multiSelect: true, max 4`).

2. **Task 12 dispatch'ит в design-review не тот агент.** Файл `mesh-design-review` исторически dispatch'ит **`-executor`-агентов**, потому что оркестратор сам компонует промпт в Step 4 и передаёт его через «Execute this prompt via …»: `codex` → `claude-mesh:codex-executor` (Step 5.1, строка 300), `gemini` → `gemini-executor`, модели → `ext-claude-executor` (строки 439-445). План (Task 12 Step 2, Step 4 bullet 1) прямо пишет `claude-mesh:grok-code-reviewer` — а это агент git-diff-ревью (`merge-base origin/$BASE_BRANCH HEAD`), который в design-ревью нечего ревьюить: весь составленный промпт попадёт в него как «CONTEXT» второго сорта. Должен быть `claude-mesh:grok-executor`. Более того, `grok-executor` по Task 6 Step 9 требует `MODEL=` на **первой строке** — значит шаблон dispatch'а для grok обязан быть в форме ext-claude («put MODEL first, then the wrapper», строка 433), а не в обёрнутой форме codex/gemini, и план этого шаблона не даёт вообще. Побочное подтверждение: в per-executor output-секции Step 7 существующие блоки названы `## codex-executor`, `## gemini-executor` (строки 522-528), а план добавляет `## grok-code-reviewer (<model>)`.

3. **`assert_eq_str` не существует.** Tests 57/58 (Task 2 Step 2, Task 3 Step 2) используют `assert_eq_str` восемь раз, но этот хелпер не определён ни в `test-config-loader.sh` (там есть только `assert_exit`, `assert_stderr_contains`, `assert_stderr_lacks`), ни в одной другой suite репозитория. Файл работает под `set -u` без `set -e` → вызовы напечатают `assert_eq_str: command not found` в stderr, счётчики PASS/FAIL не сдвинутся, и сводка может показать `0 failed` при фактически невыполненных утверждениях. Хуже красной suite — молча зелёная. Нужно либо добавить хелпер в Task 2, либо переписать утверждения на существующие.

4. **Task 10 оставляет `test-preflight-env.sh` красным.** В этой suite есть контракт порядка строк: `assert_eq "row order is the documented one" "plugin yq jq config builtin-claude claude-models codex gemini provider:zai provider:ollama git-remote gh glab clipboard bash-timeout "` (строка 826-829). Task 10 Step 5 вставляет `grok`-row между gemini и provider-строками, но план не содержит правки эталонной строки — шаг 6 «Expected: 0 failed» недостижим. Комментарий в самой suite прямо говорит, что эта проверка ловит ровно этот случай («catches a block appended in the wrong place»).

#### Concerns

- **Несогласованность имени флага effort.** Дизайн §1 утверждает, что CLI-флаг называется `--reasoning-effort` (и «измеренное» доказательство использовало именно его: `grok -p x --reasoning-effort=__bogus__`), а §2 invocation и весь план (Task 6 Steps 6-7, таблица опций, `--effort <level>`) используют `--effort`. Одно из двух неверно; smoke-тест (Task 6 Step 10) не передаёт ни `-m`, ни effort — так что ошибочное имя флага проскочит и всплывёт только на реальном review-dispatch с заданным `grok.reasoning_effort` (как раз в config.example).
- **Утечка rc из цикла прогресса в default-режиме.** В fence Task 6 Step 6 последняя команда тела цикла при assistant-событии без tool_use — `[ -n "$TOOLS" ] && echo …` — возвращает 1. rc цикла `while = rc последней итерации; под `pipefail` при оборванном стриме, заканчивающемся такой строкой, pipeline даст 1 при `grok rc=0`, и блок завершится `exit 1` после WARN. У gemini-exec тело цикла оканчивается `esac`/`fi` с rc=0 — там проблемы нет. Закрыть `:` в конце тела или заменить на `if/then` (что и проповедует сам план в комментарии про SC2015).
- **`stdbuf` есть в дизайне и в supervised-ветке, но не в default-ветке.** Дизайн §2 Invocation: `timeout 1800 stdbuf -oL -eL grok …`. Task 6 Step 6 пишет `timeout 1800 grok …` без `stdbuf`; Step 7 (supervised) — со `stdbuf`. Либо измерение «стрим не буферизуется» отменяет необходимость (тогда убрать и из дизайна, и из supervised), либо default-ветка должна его иметь — решение не зафиксировано нигде.
- **Покрытие guard'а неполное относительно обещания дизайна.** Дизайн §5: «grok scoring REAL, STALLED, BROKEN, FLIP, DEGRADED **and KILLED**». Task 8 Step 1 содержит пять вердиктов + usage-error, KILLED-теста нет (хотя путь engine-агностичен через `fail()`, `verify-delegation.sh:255-258`). Кроме того, ветка `FLOOR_NOTE` по `$ENGINE` (Task 8 Step 4) ничем не закреплена: есть `assert_no_match` для DEGRADED-ремеди, но нет теста, что grok-STALLED-floor сообщение **не** содержит «the shortest genuine review in the archive is 460». Заголовок файла при этом останется врать: строка 54 `DEGRADED=5 ext-claude only` и строки 44-45 («BROKEN also becomes KILLED for ext-claude») не входят в список правок Task 8 Step 5.
- **Task 12 не закрывает confirmation-page design-review.** В `mesh-design-review` Step 5.4 (строки 368-381) expand'ит claude по `SELECTED_CLAUDE_MODELS` и имеет ветку «Перевыбрать», сбрасывающую выбор. Task 11 для mesh-review расширяет оба места (Step 4), а Task 12 — ни того, ни другого: на странице подтверждения будет голый пункт «grok», пустой выбор моделей не будет показан («ревьюер не запускается» — правило, которое сам план формулирует в 5.2.6), и `SELECTED_GROK_MODELS` не сбрасывается при перевыборе. Два оркестратора разъедутся ровно в том месте, где требуется взаимная согласованность.
- **Task 13 предписывает записать ложное утверждение.** Инструкция «Extend each "codex / gemini" enumeration to "codex / gemini / grok"» затрагивает предложение в fresh-session-генераторах: «`OK` on codex / gemini is a heuristic — binary present, section valid, endpoint answered; NOT an auth check» (`design-review-fresh-session.md:126-128`). Для grok проба — `grok models`, т.е. это как раз auth+network check, не heuristic. Механическое расширение списка вставит grok в утверждение, которое о нём неверно. Sync-тест это пропустит (он сравнивает два файла друг с другом — оба будут изменены одинаково).
- **Task 5 неверно считает оставшиеся упоминания и оставляет runtime-строки.** После `sed` по `"$SKILL_DIR/generate-md.sh"` в `ext-claude-exec/SKILL.md` остаются шесть попаданий `generate-md.sh` (строки 223, 254, 343, 346, 379, 401), из которых 223 и 346 — это **исполняемые** `echo "WARN: generate-md.sh failed"` внутри code-fences, а не проза. План говорит «the remaining five mentions … rewrite those» — и по числу промахивается, и не замечает, что две строки видит пользователь в stderr работающего скилла: они будут указывать на не существующий более файл.
- **`validate_model_catalog`-рефакторинг теряет комментарии-обоснования.** Task 1 Step 4 заменяет весь цикл `validate_claude` вместе с его внутренними комментариями (строки 449-455: forward-compatible charset — «новая Claude-модель не должна требовать правки валидатора», leading-alnum anchor — «отсечение flag-injection `-opus`/`.foo`») одним вызовом. Новый комментарий helper'а покрывает type/empty/charset/duplicates generically, но эти два обоснования — нет. Сами сообщения, структура цикла и порядок проверок перенесены корректно — я сверил helper с `validate_claude` (строки 406-462) построчно, байтовая идентичность сохраняется.
- **Гарды пресет-цикла снова в двух копиях.** Мотивация подхода C — «три тонких гарда начнут дрейфовать» — реализована наполовину: shared validator покрывает каталоги (`claude.models`/`grok.models`), но цикл `defaults.<preset>.claude_models` (строки 576-621: type-gate, empty, charset-перед-membership, span-attack) остаётся отдельным, и Task 3 Step 4 пишет рядом второй рукописный экземпляр для `grok_models` (~45 строк, те же четыре гарда). Решение осознанное (подход C не претендовал на большее), но план обязан это зафиксировать комментарием, иначе первая же правка claude-цикла (а они правятся — см. историю Test 45) не доедет до grok-цикла.
- **Позиция `grok_models`-блока в `validate_defaults`.** План говорит «immediately before the loop's closing `done`» — это ставит grok-проверки **после** блока `run_mode` (строки 623-633), в то время как `claude_models` идёт перед ним. Функционально безразлично, но исполнитель, читающий «after the whole claude_models block», может интерпретировать иначе; стоит указать якорь по строке явно.
- **Санитизация MODEL в grok-exec — только для пути.** Step 5 профильтровывает MODEL через `tr -cd '[:alnum:]._-'` для имени каталога, но ничего не persist'ит; Step 6 заново читает `{MODEL}` из heredoc **без** фильтра и кладёт в `GROK_ARGS+=(-m "$MODEL")`. К тому же ни один фильтр не отсекает ведущий `-` (anchor `^[A-Za-z0-9]` есть у `GROK_IDENT_RE`, но не у tr-allowlist), так что `MODEL=-x` переживёт обе стадии. Риск низкий (аргумент массива не станет флагом), но асимметрия «валидатор строже скила» нарушает собственное обоснование плана («the skill must not trust a caller more than a config file» — этот комментарий стоит у фильтра для пути, а для флага доверие оказывается выше).
- **Коллизия нумерации тестов в Task 9.** `test-watch-runs.sh` уже содержит Test 31 (пустой roster entry, строка 510) и Test 32 (unsupervised run, строка 524), suite идёт до Test 39. План добавляет свои «Test 31»/«Test 32» — вставка «before its summary block» даст дубли номеров. Счётчики не сломаются, но отчёты о падениях станут неоднозначными. Взять 40/41. (Кстати, проверка pin'а строки stall-floor в Step 3 проведена планом корректно: Test 23 не ассертит точный текст, только «600» — подтверждаю.)
- **Мелкие расхождения плана с дизайном и собой.** (a) Дизайн §5 обещает fixtures `valid-codex-gemini-grok.yaml`, `invalid-grok-model-duplicate.yaml`, `invalid-defaults-grok-models-unknown.yaml`, `invalid-defaults-builtin-grok-no-grok-models.yaml` — план их не создаёт (случаи inline-printf в тестах); (b) Task 6 «Produces» обещает `raw.json` в корне run-dir безусловно, но supervised-блок копирует вверх только `raw.jsonl`/`output.txt`/`report.md`; (c) опечатка полноширинной скобки `）` в echo Task 7 Step 3; (d) baseline в Task 1 Step 1 описан как «six … lines naming `claude.models[…]`», но scalar-case (`models: opus`) падает на type-gate с сообщением без индекса — diff-проверка от этого не ломается, формулировка неточна; (e) `echo "… add: grok:\n  models: …"` в Task 14 Step 1 без `-e` напечатает `\n` литерально.

#### Suggestions

- Расширить smoke-тест (Task 6 Step 10) вызовом с явными `-m grok-4.6 --effort low` (или `--reasoning-effort` — по итогам сверки) — это закрепит имена флагов против реального CLI и закроет Concern про `--effort`/`--reasoning-effort` фактом, а не памятью автора.
- В grok-exec persist'ить отсанитизированный MODEL: `printf '%s' "$MODEL" > "$WORK_DIR/.model"` в Step 5, чтение из файла в Step 6 — ровно по образцу `.task_name`, который уже persist'ится. Заодно убрать двойное чтение heredoc.
- Добавить в Task 8 два теста: grok KILLED (watchdog.log с cleanup 143 без watchdog.exit + num_turns=1 → KILLED, не BROKEN) и grok floor-STALLED с `assert_no_match "archive"`. Это закроет и обещание дизайна §5, и обе ветки `case "$ENGINE"` в Task 8 Step 4.
- Решение про пятую опцию Q1 поднять в дизайн (сейчас это «Implementation detail», решаемое исполнителем на ходу): либо одна опция «CLI-движки (codex/gemini/grok)» с каскадным под-вопросом, либо Q1a/Q1b. От решения зависят формулировки ★-маркеров и gate-логика в обоих файлах — в план её нет.
- В Task 10 явно добавить правку эталонной строки row-order и упомянуть закрытое множество статусов (оно уже покрывает все grok-вердикты, но комментарий в шапке gate просит расширять фильтр при новых не-row строках — grok тут чист, стоит это отметить).
- В Task 12: заменить агента на `grok-executor`, дать шаблон dispatch'а по образцу ext-claude (`MODEL=<entry>` первой строкой, затем wrapper-строка, затем `PROMPT:`/`TASK_NAME:`/`SUPERVISED_MODE: shell`), и добавить правки Step 5.4 (expand + «Перевыбрать» drop-list) — по аналогии с Task 11 Step 4.
- Task 13: не расширять предложение про heuristic; вместо этого переписать его с разделением: «OK on codex / gemini — heuristic (endpoint answered, не auth-check); OK on grok — это уже проверка логина, проба идёт через сам CLI». Одинаково в обоих файлах, sync-тест пройдёт.

#### Questions

- `--effort` — реальный флаг grok 1.0.5 или сокращение, придуманное при написании §2? Доказательство в дизайне использует `--reasoning-effort`; если работают оба, выбранный вариант стоит зафиксировать в дизайне явно.
- «Grok Build» (Task 6 frontmatter, Task 7 pre-flight «install Grok Build», README Task 13) — дизайн про CLI говорит только «grok CLI»; откуда взято имя продукта и проверено ли оно (иначе инструкция установки уведёт пользователя не туда)?
- Порядок `BASE_BRANCH=<branch> MODEL=<entry> …` в dispatch-промпте (Task 11 Step 6) противоречит буквальному «MODEL is REQUIRED on the first line» в обоих grok-агентах — тот же разрыв существует у ext-claude (mesh-review.md:265 vs ext-claude-code-reviewer.md:26) и де-факто работает. Подтверждаете, что для grok это осознанное копирование прецедента, а не случайность?
- `GROK_IDENT_RE` и tr-allowlist допускают имя модели из одних цифр и дефисов, совпадающее с формой timestamp (`2026-08-28-11-00-00-x`) — такой каталог-модель создаст dir, который guard/watcher не отличат от run-dir. Та же дыра де-факто есть у ext-claude (provider/short), так что это не новый риск, а унаследованный; принимаете осознанно, или заякорить charset на ведущую букву?
- Дизайн фиксирует: «grok loads ~/.claude/CLAUDE.md and every installed claude-* plugin, with no flag to suppress it». Означает ли это, что grok-review, запущенный из /mesh-review внутри этого репозитория, увидит скиll `claude-mesh:grok-code-review` в собственном инвентаре и строку-запрет, которую мы ему же и отсылаем? Не проверялся ли запуск grok в репозитории, где CLAUDE.md содержит инструкции Superpowers (`invoke skills BEFORE any response`) — не конфликтует ли строка-запрет в промпте с ними по приоритету, и не тестировался ли этот случай в Task 14 (приёмка — как раз live-run на этом репозитории)?

---

## ext-claude-executor (ollama/minimax)


WORK_DIR: runs/ext-claude/ollama/minimax/2026-08-28-20-46-10-493049-design-review-grok-engine-iter-1
verify-delegation: REAL (num_turns=21), output.txt 47.8 KB

Предупреждение исполнителя о качестве: модель отформатировала под «Critical Issues» 8 пунктов,
но 2 из них сама же по ходу текста опровергает и закрывает (см. блок «Шум»).

#### Critical Issues

**1. Baseline в Task 1 не покрывает четыре пути ошибок `validate_claude`.**
Снимок из шести кейсов (тип элемента / charset / duplicate / empty-value) и диф в Task 5 не поймают регрессию в сообщениях для:
- пустой список `claude.models: []`
- отсутствие ключа `.models` (`mtype == null`, ранний `return 0`)
- не-массив `claude.models: "opus"` -> `claude.models: must be a list…`
- скалярная секция `claude: false` -> `claude: must be a mapping…`
Рекомендация: добавить эти четыре фикстуры в baseline Task 1.

**2. Task 8, тест grok DEGRADED — нет позитивного утверждения.**
Сейчас только `assert_no_match "the ext-claude run needs"`. Тест пройдёт, если ветка для grok напечатает пустую или generic-строку. Нужно `assert_match "grok-exec already passes" "$REASON"`.
Оговорка: обоснование модели («тест пройдёт даже если для grok напечатан ext-claude-текст») неверно — этот случай `assert_no_match` как раз ловит. Но пробел (не проверяется наличие grok-текста) реальный.

**3. Task 12 не выписывает Step 5.2.6 для mesh-design-review.**
План говорит «written for this file» и перечисляет четыре места расхождения оркестраторов, но самого текста секции не даёт. Все остальные таски прописаны дословно. Агент-исполнитель без автора будет сочинять самый нетривиальный кусок интеграции сам.

#### Concerns

- **Task 6 vs Task 8: model-less run dir.** grok-exec умеет создавать `runs/grok/<ts>-<task>` без модели, а guard жёстко требует `MODEL` (`''|'-'` -> exit 1). Технически верно, но план не проговаривает, что bare-запуск вне scope guard'а.
- **Task 11: двойной bind `SELECTED_GROK_MODELS`** (Step 0 из `defaults.code_review.grok_models` и Step 2.45 из выбора). Порядок перезаписи не задокументирован.
- **Асимметрия «пустой выбор grok».** В `default` mode недостижим (валидатор запрещает пустой `grok_models`), в интерактивном — достижим. Не объяснено.
- **Task 10: мёртвая ветка `else add_avail grok`.** У claude bare-fallback валиден, у grok такого пути нет по дизайну. Плюс Q3: при не-OK статусе добавляется `grok ($STATUS)`, хотя bare-`grok` в available никогда не появляется.
- **Task 7: frontmatter агентов.** У `ext-claude-executor.md` есть блок `tools:`, у скопированных с codex/gemini — нет. Сверить, что Claude Code принимает вариант без `tools:`.
- **Task 6 smoke: SKIP на отсутствии jq/python3.** SKIP при отсутствии `grok` корректен (opt-in), но отсутствие jq/python3 — поломка окружения, уместнее `exit 1`.
- **Task 10: `cli_row` $5 без кавычек.** Word-splitting сделан намеренно ради `grok models`, но пятый позиционный аргумент становится публичным контрактом функции; план это не фиксирует. Альтернатива: две функции (`cli_row_http` / `cli_row_cmd`).
- **Task 4: config.example.yaml не прогоняется через preflight-env.sh** (ожидаемая строка `grok MISSING` не проверена).
- **Task 13 и test-command-sync.sh.** Расширение `codex / gemini` -> `codex / gemini / grok` может задеть sync-паттерн; план не фиксирует, что именно паттерн должен пережить.
- **Дизайн: bypassPermissions проверен только для Read.** DEGRADED реагирует на любые `permission_denials` (в т.ч. Bash), измерение сделано на чтении файла вне cwd.
- **Косметика Task 8:** `got '${MODEL:-}'` при пустом MODEL печатает `got ''`.
- **Q6:** smoke-тест opt-in через `GROK_SMOKE=1` коммитится в Task 6, а запускается в Task 14 — забытый флаг даёт тихий SKIP.
- **Q9:** коллизия имени, если у пользователя уже есть своя секция `grok:` под другие нужды.

#### Suggestions / Alternatives

- Аргумент против Approach A («три тонких guard'а разойдутся») применим и к Approach C: в `verify-delegation.sh` появляются две engine-specific текстовки, подверженные тому же дрейфу.
- Не обсуждён вариант `grok.models` как list-of-objects `{id, label}`. Выбор строк правильный (путь), но мотивировка в дизайне отсутствует.
- Не обсуждён вариант «grok как sub-dispatch внутри `claude:` через provider kind».

#### Шум (самоотменённые пункты — не тратить итерацию)

- «Critical 1» в первой половине: расхождение из-за `$charset_display` — модель перепроверила и признала байт-идентичность.
- «Critical 8» (Task 14 якобы редактирует config.yaml): шаг только печатает и проверяет.
- C2, Q2, Q5, Q8, S2, S10, C6, C9, C10 — проверены и закрыты как корректные.

---

## Провалившаяся делегация: ревью на dispatch-модели (opus)

Ниже — два ревью, выполненные обёртками `zai/glm` и `ollama/kimi` до того, как им было
указано делегировать. Оба выполнены на Opus 5. Держать их отдельно обязательно: три
совпадающих голоса одной модели — это один голос, а не три.

### Через обёртку zai/glm (Opus 5, делегации не было)

##### Design review: grok-engine (прогон Opus 5 — FLIP, не zai/glm)

Ревьюер: `rv-zai-glm`, но фактически выполнено на модели сессии (Opus 5) без делегации.
Run dir отсутствует по определению — Skill `claude-mesh:ext-claude-exec` в момент составления
этого текста не вызывался. Настоящий прогон zai/glm запущен отдельно.

Документы: `docs/superpowers/specs/2026-08-28-grok-engine-design.md` (275 строк),
`docs/superpowers/plans/2026-08-28-grok-engine.md` (2466 строк, 14 задач).
Все находки сверены с живым кодом в `/opt/github/zinin/claude-mesh` и с реальным `grok 1.0.5`
на этой машине.

---

##### Critical Issues

##### C1. `assert_eq_str` не существует — Задачи 2 и 3 дадут ложно-зелёный прогон

`/opt/github/zinin/claude-mesh/skills/shared/tests/test-config-loader.sh` определяет ровно три
хелпера: `assert_exit`, `assert_stderr_contains`, `assert_stderr_lacks` (строки 14–40).
Сравнение значений в этом файле пишется inline — см. строку 1086:

```bash
if [ "$GOT" = "opus,fable," ]; then PASS=$((PASS+1)); ... else FAIL=$((FAIL+1)); ... fi
```

План вызывает `assert_eq_str` **8 раз** (5 в Task 2 Step 2, 3 в Task 3 Step 2) и нигде её не
создаёт. В файле стоит `set -u`, но **не** `set -e` — значит `assert_eq_str: command not found`
вернёт 127, ни `PASS`, ни `FAIL` не изменятся, и Step 6 обеих задач («Expected: `0 failed`»)
выполнится успешно, хотя проверки `has_grok`, порядка `list-grok-models`, `get-grok` и
`.grok_models` в `get-defaults` **не выполнялись вообще**.

Это худший класс дефекта: зелёная сьюта, которая ничего не проверила.

Починка: добавить `assert_eq_str` в блок хелперов первым шагом Task 2, либо переписать
проверки на inline-идиому файла.

##### C2. `HAS_GROK` — unbound variable под `set -u` (Task 10)

`/opt/github/zinin/claude-mesh/skills/shared/preflight-env.sh:19` — `set -u`.
`HAS_CODEX=0` и `HAS_GEMINI=0` инициализируются на строках **184–185**, вне ветки
`if [ "$CONFIG_STATUS" = "OK" ]`, именно потому что `cli_row … "$HAS_CODEX"` на строке 421
выполняется безусловно.

Task 10 Step 4 добавляет только чтение «beside the `HAS_CODEX` / `HAS_GEMINI` reads
(~line 308)» — а это **внутри** OK-ветки — и предобъявляет только `GROK_MODELS`.

Итог: любой сценарий с `CONFIG_STATUS != OK` (нет config.yaml, сломан yq, отсутствует yq)
падает на `HAS_GROK: unbound variable`, preflight выходит ненулевым, а гейт `run_probe`
(«every verdict exits 0», `BAD_RC`) красит всю сьюту — в сценариях, к grok отношения не
имеющих.

Нужен `HAS_GROK=0` на строке 186.

##### C3. Гейт порядка строк в `test-preflight-env.sh:826` не обновлён

```bash
assert_eq "row order is the documented one" \
  "plugin yq jq config builtin-claude claude-models codex gemini provider:zai provider:ollama git-remote gh glab clipboard bash-timeout " \
  "$ORDER"
```

Task 10 вставляет строку `grok` после `gemini`, но эту ассерцию не трогает. Task 10 Step 6
(«Expected: `0 failed`») гарантированно упадёт, и агент, следующий плану дословно, будет
искать ошибку в своей реализации. Комментарий над ассерцией прямо предупреждает: «catches a
block appended in the wrong place».

##### C4. Task 13 Step 1 даёт взаимоисключающие инструкции

Перечисление «codex / gemini», которое нужно расширить, находится в
`/opt/github/zinin/claude-mesh/commands/code-review-fresh-session.md:177` и
`/opt/github/zinin/claude-mesh/commands/design-review-fresh-session.md:126` — то есть
**внутри** региона `## PREFLIGHT` (168–184 и 117–133 соответственно), который тот же шаг
запрещает трогать и который `test-command-sync.sh:144-145` пинит как «17 lines» и
байт-идентичный между файлами.

Второе упоминание (строки 207 / 155) лежит под `## WHEN THE USER SAYS GO`, вне регионов.
Агент либо пропустит основное упоминание (сгенерированный промпт продолжит называть два
движка), либо отредактирует его и решит, что нарушил контракт.

Правильная формулировка: править эту строку **одинаково в обоих файлах, не меняя числа
строк** — тогда обе ассерции остаются зелёными.

##### C5. `/mesh-design-review` теряет grok после первой итерации

`/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md`, Step 5.4 заканчивается
строкой:

> Remember the confirmed set (built-in TYPES + `SELECTED_CLAUDE_MODELS` + `SELECTED_IDS`) for
> all subsequent iterations in the loop.

Это итеративный оркестратор — набор ревьюеров фиксируется один раз и переиспользуется на
итерациях 2..N. Task 12 нигде не добавляет туда `SELECTED_GROK_MODELS`. Следствие:
grok-ревьюеры отработают на первой итерации и молча исчезнут на второй, причём без единого
сообщения — ровно тот класс бага («silently ignored list»), который комментарий в
`validate_defaults` называет причиной существования fail-closed правила для `claude_models`.

Кроме этого Task 12 не трогает ещё четыре места, для которых Task 11 симметричные правки
прописывает явно:

1. **Разворот `grok` в буллеты на странице подтверждения (Step 5.4).** Дизайн §3 прямо
   требует: «When grok is selected but no model is checked, no grok reviewer runs, and the
   confirmation page says so». Task 11 Step 4 это делает для `/mesh-review`; для
   `/mesh-design-review` требование остаётся невыполненным.
2. **Клауза «Перевыбрать»** в Step 5.4: «restarts Step 5.2 from Q1 with the same DEFAULT_IDS /
   CLAUDE_DEFAULT_IDS (Step 5.2.5 re-runs too)» — должна упоминать и 5.2.6, иначе перевыбор
   оставит старый `SELECTED_GROK_MODELS`.
3. **Предложение в Step 6:** «`DISPATCH_MODEL` still governs the codex / gemini / ext-claude
   executors and the `review-discussion` agent in Step 8» — grok сюда не добавлен, хотя
   Task 11 Step 6 требует править ровно этот абзац в близнеце. Без правки неясно, чем
   управляется модель обёртки grok-ревьюера.
4. **Team-режим / строка «Wrapper reviewers (codex / gemini / ext-claude)»** — то же
   перечисление обёрток, которое Task 11 Step 6 расширяет в `/mesh-review`.

Попутно — расхождение в нумерации: дизайн §3 и строка «Files» в Task 12 называют Step 5.4
«dispatch». В файле 5.4 — это **Confirm selection**, а диспатч, вотчер и гвард живут в Step 6
и его подпунктах. Агент, исполняющий Task 12 буквально, будет искать роутинг не в том разделе.

---

##### Concerns

##### K1. Коллизия номеров тестов

`test-watch-runs.sh` уже содержит тесты до **39** включительно; Task 9 добавляет «Test 31» и
«Test 32». Нужны 40/41.

##### K2. Санитайзер `MODEL` слабее валидатора, который он якобы копирует

Task 6 Step 5:

```bash
MODEL=$(printf '%s' "$RAW_MODEL" | tr -cd '[:alnum:]._-' | head -c 64)
```

с комментарием «Same allow-list the config validator enforces on grok.models». Это не так:
`GROK_IDENT_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'` якорит первый символ, а `tr -cd` — нет.

`MODEL=".."` проходит целиком, и `WORK_DIR="$PLUGIN_DATA/runs/grok/../<ts>-task"` уезжает в
`runs/`, где `verify-delegation.sh grok <model>` его никогда не найдёт → FLIP на реально
состоявшемся ране. `MODEL="-p"` тоже выживает.

У `TASK_NAME` этой экспозиции нет (он всегда суффикс после таймстампа), у `MODEL` — есть,
потому что это самостоятельный компонент пути.

Лучше отвергать, а не переписывать:
`[[ "$MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "STOP: …"; exit 1; }`.

##### K3. Пятисекундный бюджет на `grok models`

`HTTP_TIMEOUT` по умолчанию 5 (`preflight-env.sh:33,43`), и новая ветка тратит его на запуск
процесса плюс сетевой round-trip. Здесь измерено 1.1 s, но это тёплый CLI на релее. У
git-строки есть собственный `PREFLIGHT_GIT_TIMEOUT` (8) ровно по этой причине — стоит завести
`PREFLIGHT_CLI_TIMEOUT`, иначе медленный, но здоровый логин отчитается как `NO-NETWORK`.

##### K4. Обещание DEGRADED для grok измерениями не подтверждено

Таблица фактов дизайна сама фиксирует: у рана под `bypassPermissions` поля
`permission_denials` **нет**, и §4 повторяет «absent on grok». Значит путь DEGRADED для grok
сегодня мёртв: тест в Task 8 Step 1 изготавливает поле, которого ни одна наблюдавшаяся сборка
не эмитит, а CHANGELOG из Task 13 утверждает как факт — «grok reaches the `DEGRADED` verdict,
which codex and gemini cannot».

Либо снять одно измерение без `bypassPermissions` и увидеть поле, либо смягчить формулировку
до «сможет достичь, если xAI добавит поле». Сейчас это единственный из трёх заявленных
выигрышей от переиспользования формата, который ничем не подкреплён.

##### K5. У ставки на wire-format нет постоянного детектора

`test-grok-exec-smoke.sh` — единственное, что заметит смену формата, и он opt-in
(`GROK_SMOKE=1`). После Task 14 в обычном прогоне сьюты его не будет. Оставшийся страж —
`grep -q '"type":"result"'` — не отличает ACP-поток от рваного Anthropic-потока.

Дёшево усилить: в смоук-тесте дополнительно утверждать отсутствие ACP-образных строк, и
записать в SKILL.md, что `--include-partial-messages` (флаг существует, по умолчанию выключен)
при включении даст `stream_event`-строки, которые `extract-result.py` молча проигнорирует.

##### K6. Таблица «Verified facts» уже неверна в двух строках

`grok models` на этой машине (grok 1.0.5) печатает:

```
Default model: codex-sol
Available models:
  - grok-4.6
  - grok-4.5
  - dks-ultra
  - deepseek-v4-flash
  - glm-5-3
  - minimax-m3
  - kimi-k3
  … (15+ ids)
```

То есть «Models are `grok-4.6` (default) and `grok-4.5`» и тезис сессии «grok offers only two
models today» ложны.

Для решения это хорошая новость — аргумент *против* каталога держался именно на «двух
моделях», и выбор пользователя оказался прав, — но требует правок: `config.example.yaml`
(Task 4) не должен подразумевать, что `[grok-4.6, grok-4.5]` — это весь набор, а
«run `grok models`» стоит вынести в первую строку комментария. Строка README о
`unknown model id` при этом сформулирована верно.

##### K7. `--effort` — это алиас, а не канонический флаг

Проверено в `grok --help`: `--reasoning-effort <EFFORT>  [aliases: --effort]`. Работает, так
что это не блокер, но дизайн в таблице фактов называет `--reasoning-effort`, а инвокация §2 и
таблица опций Task 6 Step 8 — `--effort`. Алиасы отмирают раньше канонических имён; лучше
писать `--reasoning-effort` в обеих фенсах.

##### K8. `stdbuf` расходится между дизайном и планом

Дизайн §2 показывает `timeout 1800 stdbuf -oL -eL grok`, Task 6 Step 6 (default mode) `stdbuf`
не содержит, Step 7 (supervised) — содержит.

Прав план: codex/gemini/ext-claude ставят `stdbuf` только там, где поток редиректится в файл
(`skills/codex-exec/SKILL.md:362`, `skills/gemini-exec/SKILL.md:342`,
`skills/ext-claude-exec/SKILL.md:311`). Но таблица опций Task 6 Step 8 при этом не упомянет
`stdbuf` вообще — надо согласовать три места.

##### K9. `[ -n "$TOOLS" ] && echo` противоречит собственному Global Constraint плана

План требует «if/then, not `test && cmd`: the second form is the SC2015 shape this codebase
avoids», и тут же использует запрещённую форму.

Конкретное следствие: статус `while` — это статус последнего выполнения тела. Поток, чья
последняя строка — текстовый `assistant` без `tool_use` (ровно тот рваный поток, о котором
рапортует следующая проверка), оставит `PIPELINE_RC=1`, и блок напечатает «WARN: grok pipeline
exited rc=1» и выйдет с 1, хотя извлечение прошло успешно.

Заменить на `if … then … fi` либо закрыть тело `:`.

##### K10. Свип ссылок в Task 5 неполон

`/opt/github/zinin/claude-mesh/commands/mesh-review.md:311` называет `generate-md.sh` в живой
прозе о том, какой файл читать; проверочный `grep -rn 'ext-claude-exec/generate-md'` его не
увидит — там голое имя.

Плюс счёт «five mentions» занижен: в `skills/ext-claude-exec/SKILL.md` не-`$SKILL_DIR`
попаданий шесть — строки 223, 254, 343, 346, 379, 401.

И учтите, что в репозитории остаются ещё два файла `generate-md.sh` (`skills/codex-exec/`,
`skills/gemini-exec/`), так что grep по голому имени шумный: искать надо по
`ext-claude-exec/generate-md` **и** отдельно `generate-md` в пределах `skills/ext-claude-exec`
+ `commands/`.

---

##### Suggestions

##### S1. Task 1 сверен построчно — паритет сообщений держится

Сравнил хелпер против живого `validate_claude`
(`/opt/github/zinin/claude-mesh/skills/shared/config-loader.sh:406-462`): все четыре `die` при
`label=claude.models` и `charset_display=[A-Za-z0-9._:@-]` байт-идентичны. Тип-гейт («must be a
list of Claude model aliases») и ранний `return 0` на `null` корректно остаются в
`validate_claude`.

Замечание только стилистическое: «immediately above `validate_claude`» — в bash функции
резолвятся в момент вызова, порядок в файле не обязателен.

##### S2. Словарь в сообщении о charset стоит параметризовать

Хелпер зашивает хвост «(a model alias or id)» — это claude-лексика, а
`defaults.*.grok_models` в Task 3 говорит «(a grok model id)». Две grok-ошибки о charset
получатся разными между собой. Пятый параметр решает.

##### S3. Task 3 смешивает `-gt 0` и `= 0`

Для одних и тех же jq-целых (`grok_in_builtin`, `gm_count`), тогда как claude-блок везде
использует `-gt`. Косметика, но `= 0` ломается, если jq когда-нибудь выдаст ` 0`.

##### S4. Порядок задач в целом корректен

Task 10 потребляет фикстуры `valid-grok.yaml` / `broken-grok-valid-codex.yaml` из Task 2;
Task 6 — `stream-json-report.sh` из Task 5; Tasks 11/12 — Tasks 2/3/7/8.

Единственный коммит, оставляющий сьюту красной, — Task 10 (C2, C3). Tasks 2/3 оставляют её
**ложно-зелёной** (C1), что хуже.

##### S5. Узкий charset защищает не только пути

Дизайн обосновывает `GROK_IDENT_RE` только через путь и ростер (`watch-runs.sh:104`). Есть
третья, более важная причина: спека гварда в обоих оркестраторах — `grok:<model>`, и парсится
она сплитом по `:`. Стоит записать это явно: то же самое делает `ext-claude:zai/glm`, а
`claude.models` такой защиты не требует, потому что claude-моделей в спеках гварда нет.

##### S6. Про `--no-plan`

При `--permission-mode bypassPermissions` (а не `plan`) нужен ли он вообще? Одна измеренная
фраза в SKILL.md лучше предположения — флаг безвреден, но обоснование в дизайне подано как
факт.

---

##### Questions

1. **Task 14 Step 1 редактирует пользовательский `config.yaml`**, тогда как Global Constraints
   плана запрещают это в каждой задаче («Never edit `config.yaml`. It is user-owned»). Должен
   ли шаг быть строго «попросить пользователя добавить секцию», без варианта «or have them do
   it»?

2. **Ран без модели невозможно верифицировать.** Дизайн разрешает `runs/grok/<ts>-<task>/` для
   прямого вызова `grok-exec`, но новая ветка `verify-delegation.sh` требует модель и
   отвергает `-`. Значит такой ран навсегда вне гварда. Отдельно: является ли голая запись
   ростера `grok` (без модели) поддерживаемой для `watch-runs.sh`? Shape-фильтр её спасает, но
   план об этом молчит.

3. **Task 12 Step 3 запрещает копировать текст Step 2.45**, но не приводит собственную фенсу
   для Step 5.2.6 («this file resolves the loader from `SKILL_BASE` and asks it for
   `data-dir`»). Без явного кода агент скопирует 2.45 — то есть сделает ровно то, что
   запрещено. Выписать фенсу целиком?

4. **`defaults.<preset>.grok_models` обязателен в обе стороны.** Пользователь, желающий видеть
   grok в UI, но не запускать его в `default`-режиме, должен держать `grok:` в конфиге и не
   упоминать `grok` в `builtin` — тогда `grok_models` тоже обязан отсутствовать, и Step 2.45
   покажет список без единой ★. Это задуманное поведение?

### Через обёртку ollama/kimi (Opus 5, делегации не было)

##### Design review: grok-engine (iter 1)

**Прогон:** Opus 5 (модель сессии). Это НЕ прогон `ollama/kimi` — делегация на kimi запущена отдельно
(`runs/ext-claude/ollama/kimi/2026-08-28-20-58-25-505251-design-review-grok-engine-iter-1`).
Учитывать как opus-ревью.

**Документы:**
- `docs/superpowers/specs/2026-08-28-grok-engine-design.md` (275 строк)
- `docs/superpowers/plans/2026-08-28-grok-engine.md` (2466 строк, 14 задач)

**Метод:** оба документа прочитаны целиком и сверены с кодом (`skills/shared/config-loader.sh`,
`skills/shared/verify-delegation.sh`, `skills/shared/preflight-env.sh`, `skills/shared/watch-runs.sh`,
`skills/shared/watchdog.sh`, `skills/shared/extract-result.py`, `commands/mesh-review.md`,
`skills/mesh-design-review/SKILL.md`, сьюты в `skills/shared/tests/`, `config.example.yaml`),
а также с живым `grok 1.0.5` на этой машине. Часть находок подтверждена запуском, а не чтением.

---

##### Critical Issues

##### C1. Q1 в обоих оркестраторах уже содержит ровно 4 опции — а `AskUserQuestion` ограничен четырьмя

`commands/mesh-review.md:108` — «Use AskUserQuestion (multiSelect, **max 4**)», и опций там уже четыре:
`claude` (показывается всегда), `codex`, `gemini`, `external models` (`commands/mesh-review.md:115-121`).
То же в `skills/mesh-design-review/SKILL.md:309-317`.

Task 11 Step 2 и Task 12 Step 3 велят «добавить строку после gemini» — это **пятая** опция на конфиге,
где все гейты подняты (а это ровно целевой конфиг пользователя: codex + gemini + models + grok).
Ни дизайн, ни план проблему не упоминают, при этом Task 14 Step 2 (приёмка) требует, чтобы grok был
виден в Q1 и выбираем.

Это блокер уровня «шаг невыполним как написан». Решение — архитектурное (пагинация Q1 теми же
механиками, что Step 2.4/Step 3, либо одна опция «CLI-движки» с отдельной страницей выбора),
и его должен принять дизайн, а не исполнитель Task 11.

##### C2. Task 3 вносит `validate_grok_catalog` в `validate_defaults` — и любая ошибка в `grok:` кладёт весь конфиг, а не свою строку

`skills/shared/preflight-env.sh:225` формулирует принцип прямым текстом:
*«codex/gemini stay out of this gate on purpose: a broken optional section fails its own row, never the
whole environment»*. `validate_claude` из этого принципа уже выпадает (`config-loader.sh:480`),
и Task 3 добавляет туда же grok.

Проверено эмпирически на существующем аналоге (`claude: false` + непустой `defaults:`):

```
config-loader get-defaults design_review  → rc=1
preflight:  config    INVALID
            codex     SKIPPED
            gemini    SKIPPED
            SUMMARY available: —
```

`CONFIG_STATUS` считается через `get-defaults design_review` (`preflight-env.sh:226-240`),
а `/mesh-review` Step 1 читает `get-defaults` и падает по rc=1. То есть у пользователя, который
написал `grok:` и забыл `models:` — самая вероятная ошибка, раз каталог обязателен, — перестаёт
стартовать **весь** оркестратор и обнуляется вся строка preflight, включая codex и gemini.

Фикстура `broken-grok-valid-codex.yaml` (Task 2 Step 1) намеренно **без** `defaults:`, поэтому
Test 57 (`«get-codex still works with a broken grok section»`) пройдёт зелёным, а реальный случай — нет.
Дизайн §5 при этом заявляет её назначением «a malformed grok section must not block a codex run»;
для конфигов с `defaults:` (то есть для `config.example.yaml` и любого настоящего) это утверждение ложно.

##### C3. `SUMMARY defaults <preset>` в preflight не знает про grok — заявленный инвариант ломается

`skills/shared/preflight-env.sh:794-802` разворачивает в `claude:<model>` **только** `claude`;
остальные builtin-имена проходят как есть. После Task 10 Step 5 в `SUMMARY available` попадают
`grok:grok-4.6` / `grok:grok-4.5`, а в `SUMMARY defaults code_review` — голый `grok`.

Инвариант объявлен в комментарии над этим блоком: *«every name on a defaults line must appear in
SUMMARY available»*, и он механически проверяется в сьюте — `defaults_not_available()`
(`skills/shared/tests/test-preflight-env.sh:625-643`) сравнивает **целые** записи и имеет ровно одно
исключение, захардкоженное под `claude`:

```bash
if [ "$dname" = claude ]; then
    case "$aname" in claude:*) found=1; break ;; esac
fi
```

Для `grok` такого исключения нет. Ни Task 10, ни Task 11/12 ни jq в `preflight-env.sh`,
ни этот хелпер не трогают. Правка нужна в одном из двух мест, и это надо дописать в Task 10.

##### C4. В `grok-exec` модель для пути и модель для `-m` — два разных значения

Task 6 Step 5 (Step 1 процесса):
```bash
MODEL=$(printf '%s' "$RAW_MODEL" | tr -cd '[:alnum:]._-' | head -c 64)
WORK_DIR="$PLUGIN_DATA/runs/grok${MODEL:+/$MODEL}/${TIMESTAMP}-${TASK_NAME}"
```
Task 6 Step 6 и Step 7 (Step 2 процесса) читают `{MODEL}` **заново, из плейсхолдера, без санитайза**,
и передают его в `-m "$MODEL"`.

Если значения расходятся (символ вне charset, длина > 64), рун ложится в `runs/grok/<санитизированное>/`,
а `verify-delegation.sh grok <сырое>` резолвит `runs/grok/$MODEL` по сырому — директории нет →
**FLIP на здоровом ране**. У ext-claude такого нет: там `PROVIDER="${MODEL%%/*}"` /
`SHORT="${MODEL#*/}"` (`skills/ext-claude-exec/SKILL.md:142-150`) — просто split, обе стороны видят
одну строку.

Молчаливая перезапись значения здесь хуже отказа: валидатор конфига уже гарантирует charset для
review-пути, значит для прямого вызова корректнее `die`, а не `tr -cd`. Либо санитизировать один раз
в Step 1 и передавать результат в Step 2 как `{WORK_DIR}`.

Других Critical, кроме C1–C4, нет.

---

##### Concerns

**N1. Дизайн §5 обещает покрытие в `test-command-sync.sh` — «the grok wording shared by both
orchestrators». Такого покрытия там быть не может.** Сьют
(`skills/shared/tests/test-command-sync.sh:1-28`) держит в синхроне два
`commands/*-fresh-session.md` и про `mesh-review.md` / `mesh-design-review/SKILL.md` ничего не знает.
План новых кейсов туда не добавляет вовсе — Task 12 Step 5 и Task 13 Step 2 только *запускают*
существующий сьют. Итог: единственный механический guard за консистентностью двух оркестраторов
по grok отсутствует, хотя дизайн его обещает.

**N2. Дизайн §5 требует grok-кейс `KILLED`; в Task 8 Step 1 его нет.** Есть FLIP / REAL / BROKEN /
STALLED / DEGRADED + usage-ошибка. `KILLED` идёт не через ту же ветку, а через `fail()` и разбор
`watchdog.log` (`skills/shared/verify-delegation.sh:236-247, 300-305`) — это ровно тот сценарий,
который убил пять ext-claude-ранов 2026-08-05, и для grok он тоже достижим: supervised-режим
пишет `watchdog.log`.

**N3. Task 9: номера Test 31 и Test 32 уже заняты.** `skills/shared/tests/test-watch-runs.sh:510`
и `:524`; файл идёт до Test 39 (`:612`). Новые кейсы вставляются «before its summary block»,
то есть после Test 39 → в выводе будет 39, 31, 32.

**N4. Task 11/12 покрывают не все места, где перечислены движки.** План называет
«CRITICAL paragraph» и «Dispatch-model exception». Кроме них grok нужен минимум в:

- `commands/mesh-review.md:334` — Step 5b (team mode): «Wrapper reviewers (codex / gemini / ext-claude)».
  Step 5b план не упоминает вообще;
- `commands/mesh-review.md:357` — «Wrapper reviewers (codex / gemini / ext-claude) non-deterministically flip»;
- `commands/mesh-review.md:324` и `skills/mesh-design-review/SKILL.md:501` — «Never mirror these four», пункт 4;
- `skills/mesh-design-review/SKILL.md:416` — «codex / gemini executors parse PROMPT / MODEL / …»;
- `skills/mesh-design-review/SKILL.md:447` — «Collect output paths from every executor (codex / gemini / ext-claude)»;
- `skills/mesh-design-review/SKILL.md:493` — «This loop covers the codex / gemini / ext-claude executors only».

Для плана, который исполняется по шагам без автора, «найди остальные упоминания» не сработает —
их надо перечислить поимённо.

**N5. Верифицированные факты о CLI устарели за сутки.** На этой машине сейчас:

```
grok models → grok-4.6, grok-4.5, dks-ultra, deepseek-v4-flash-api,
              deepseek-v4-pro, deepseek-v4-flash-vision-exp,
              * codex-sol (default), codex-terra, codex-luna
```

и `~/.grok/config.toml` **не содержит** секции `[models]` вовсе (в нём
`[ui] fork_secondary_model = "grok-4.6"`). Значит два утверждения дизайна
(«Models are `grok-4.6` (default) and `grok-4.5`» и «`[models] default = "grok-4.6"`») неверны,
а обоснование «claude-mesh не подставляет модель — решает `~/.grok/config.toml`» на практике
означает «решает серверный дефолт». Прямой `/claude-mesh:grok-exec` без MODEL пойдёт сейчас
на `codex-sol` — не-grok модель — и запишет ран в `runs/grok/<ts>-<task>/`, где модель не
зафиксирована нигде: ни в пути, ни в шапке отчёта (`stream-json-report.sh` получает литерал
`"grok"` как `profile`). Такой ран неатрибутируем. Решение про каталог это, наоборот, подтверждает —
но факты в §«Verified facts» надо перемерить, иначе Task 6 будет писать SKILL.md по неверному описанию.

**N6. `stdbuf` есть в supervised-блоке и нет в default-блоке.** Дизайн §2 показывает
`timeout 1800 stdbuf -oL -eL grok`, план Task 6 Step 6 (default) — `timeout 1800 grok ... | while`.
В default stdout — pipe, то есть полная буферизация вероятнее, чем при redirect в файл
(мерили именно файл). codex/gemini тоже без `stdbuf` в default (`skills/gemini-exec/SKILL.md:223`),
так что это не регресс — но дизайн и план расходятся, и в SKILL.md попадёт та версия,
которую напишет исполнитель.

**N7. `has_grok` — «голый» probe, а дизайн трактует его как гарантию непустого каталога.**
`cmd_get_flag has_grok` (Task 2 Step 5) валидацию не запускает, как `has_codex`/`has_gemini`
(`skills/shared/config-loader.sh:869-874`). На `grok: {}` он вернёт `1` при отсутствующем каталоге.
В `/mesh-review` это спасает rc-aware чтение `list-grok-models` рядом, но формулировки Step 2.45
и Step 5.1 («HAS_GROK=1 уже гарантирует непустой GROK_MODELS») приписывают гарантию флагу,
а не соседнему чтению. Либо сказать это явно, либо сделать `has_grok` валидирующим — прецедент
есть, `has_claude_models` (`skills/shared/config-loader.sh:882-891`).

**N8. Task 5: проверка «нет устаревших ссылок» слишком узкая.**
`grep -rn 'ext-claude-exec/generate-md'` не поймает `commands/mesh-review.md:311`
(«report.md … rendered by `generate-md.sh`»), а `skills/codex-exec/generate-md.sh` и
`skills/gemini-exec/generate-md.sh` продолжают существовать с тем же basename, так что более
широкий grep шумит. Плюс план говорит «пять прозаических упоминаний» — в
`skills/ext-claude-exec/SKILL.md` их шесть (строки 223, 254, 343, 346, 379, 401).

**N9. Косметика с последствиями в выводе.** Task 7 Step 3, pre-flight:
`echo "OK: grok: section present ($("$LOADER" list-grok-models | tr '\n' ' ')）"` —
закрывающая скобка полноширинная, `U+FF09`.

---

##### Suggestions

**S1 (чинит C2).** Вызывать `validate_grok_catalog` в `validate_defaults` **лениво** — только когда
пресет реально ссылается на grok (`grok` в `builtin` или непустой `grok_models`). Ни одна проверка
не слабеет: если grok нигде не упомянут, каталог всё равно валидируется в `validate_all` и в
`get-grok`, но не утаскивает за собой `get-defaults`, `preflight-env.sh` и Step 1 обоих
оркестраторов. Тот же приём стоит рассмотреть и для `validate_claude` — он создаёт этот же
blast radius уже сегодня, а grok просто делает его заметным.

**S2.** `broken-grok-valid-codex.yaml` должна содержать `defaults:` — иначе она не проверяет то,
ради чего заведена. И добавить кейс: `grok: {}` + `defaults.code_review.builtin: [codex]` →
`get-defaults` должен вернуть rc=0, а `get-grok` — rc=1.

**S3 (для C1).** Наименее инвазивный вариант — свернуть `codex` / `gemini` / `grok` в одну опцию Q1
(«CLI-движки») с последующей страницей выбора движков по механике Step 2.4. Второй вариант —
пагинация самого Q1. В любом случае это решение дизайна, а не исполнителя.

**S4.** Проба `grok models` в preflight уже получает полный каталог подписки за ~1 с (замерено).
Стоит сверить его с `grok.models` и выдавать строку вида «`grok.models` содержит `grok-4.4`,
которого нет в подписке». Это ровно тот сбой, под который Task 13 Step 3 добавляет
troubleshooting-строку `unknown model id`, только пойманный до диспатча, а не после создания
рун-директории.

**S5.** В `verify-delegation.sh` заодно с `''|'-'` отвергать `$MODEL`, не проходящий
`^[A-Za-z0-9][A-Za-z0-9._-]*$` — тот же charset, что в конфиге. Иначе `MODEL=../codex` резолвит
`runs/grok/../codex`.

**S6.** В разделяемой ветке `ext-claude|grok` план правит две строки, но ложными для grok станут
ещё две: комментарий про `progress-monitor.sh:171-175` (grok-exec его не использует — у него
`extract-result.py` в обоих режимах) и слово «DSML» в пользовательском тексте вердикта BROKEN
(`skills/shared/verify-delegation.sh:415`) — это грамматика инструментов z.ai/GLM, к grok отношения
не имеющая. Пройти ветку целиком, а не только две названные строки.

---

##### Questions

1. **Q1 при пяти доступных типах ревьюеров** — пагинация, группировка CLI-движков, или grok
   сознательно доступен только в `default`-режиме? Без ответа Task 11 Step 2 / Task 12 Step 3
   не реализуемы.
2. **`grok:` в `config.example.yaml` (Task 4) добавляется «живым»** — с `grok` в обоих `builtin`
   и `grok_models` в обоих пресетах. Учитывая, что каталог обязателен, а CLI и подписка есть
   не у всех: это осознанное решение сделать grok частью дефолтного пресета из коробки?
3. **Подписка отдаёт девять моделей, включая не-grok семейства** (`codex-*`, `deepseek-*`),
   и charset `grok.models` их допускает. Каталог задумывался как «модели grok» или как «всё,
   что отдаёт grok CLI»? От ответа зависит и текст ошибки, и формулировка `config.example.yaml`.
4. **Прямой `grok-exec` без MODEL** пишет в `runs/grok/<ts>-<task>/` и нигде не фиксирует
   фактическую модель (сейчас это был бы `codex-sol`). Стоит ли писать `.model` из события
   `system`/`init`, чтобы такой ран был атрибутируем — и не передавать ли её в
   `stream-json-report.sh` вместо литерала `"grok"`?

---

##### Проверено и НЕ является находкой

- `--effort` действительно документированный алиас `--reasoning-effort` (`grok --help`:
  `[aliases: --effort]`), так что расхождение §«Verified facts» и §«Invocation» безвредно.
- `--prompt-file` — «Single-turn prompt from a file», headless; `-p` рядом не нужен.
- Roster-паттерн `skills/shared/watch-runs.sh:104`
  (`^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`) принимает `grok/grok-4.6` без изменений.
- Номера `Test 57` / `Test 58` в `test-config-loader.sh` не конфликтуют (последний там — 56).
- `config.example.yaml` валидируется Test 31 (`test-config-loader.sh:634-642`), и порядок
  Task 3 → Task 4 это учитывает.
- Извлечение `validate_model_catalog` в Task 1 действительно сохраняет все четыре гварда
  (тип элемента, пустое значение, charset, дубликаты) и байт-в-байт тексты claude-сообщений —
  сверено построчно с `skills/shared/config-loader.sh:406-462`. Ранний `return 0` на
  `.claude.models == null` остаётся в `validate_claude` до вызова хелпера, поэтому семантика
  «нет каталога» не меняется.
- `watchdog.sh:58` действительно трактует `STDIN_FILE` как опциональный
  (`STDIN_FILE="${STDIN_FILE:-}"`), так что launch без stdin корректен.
- `${GROK_ARGS[@]+"${GROK_ARGS[@]}"}` — правильная форма для bash 4.2 под `set -u`.
