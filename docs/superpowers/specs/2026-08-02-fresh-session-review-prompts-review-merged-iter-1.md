# Merged Design Review — Iteration 1

- Topic: fresh-session-review-prompts
- Design: docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md
- Plan: docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md
- Reviewers: claude:opus, claude:fable, codex (gpt-5.6-sol, reasoning=max), ext-claude zai/glm, alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax — все 8 завершились успешно
- Note: deepseek/v4-pro стартовал прогон на ~9 минут позже остальных (ранний MISSING watcher'а был ложной смертью — каталог ещё не существовал).
- Note: у alibaba/qwen секция взята из output-full.txt — output.txt содержит только финальную реплику (особенность extract-result.py на многосообщенческом стриме).

## claude:opus

Проверил оба документа против кода: прочитал `config-loader.sh`, оба прекчека, оркестраторы (`commands/mesh-review.md`, `skills/mesh-design-review/SKILL.md`), фикстуры и существующие сьюты, а также эмпирически проверил семантику bash, на которую опирается план (subshell-присваивания, `env` с повторным ключом) и поведение loader'а без `yq`.

### Critical Issues

**C1. `SUMMARY available: claude` — ложное обещание, ровно в том состоянии, ради которого делается весь дизайн.**

Инвариант «встроенный claude доступен всегда, ему не нужна секция конфига» проходит через дизайн (решение 6, таблица Error handling), Global Constraints плана и четыре ассерта теста (`built-in claude survives no config`, `no config -> catalog SKIPPED`, `no config still yields a usable line`, `claude survives a dead network`). Код говорит обратное:

- `commands/mesh-review.md:53` — при rc=2 (`config.yaml` отсутствует) печатает «config.yaml ещё не создан…» и делает `exit 0`;
- `commands/mesh-review.md:54` — при rc=1 выводит сообщение валидатора и `exit 1`;
- `skills/mesh-design-review/SKILL.md:229-230` — то же самое, дословно.

Ни один из оркестраторов не откатывается на «только встроенный claude». То есть сценарий получается такой: проба честно печатает `config MISSING`, но тут же обещает `SUMMARY available: claude`; промпт велит сессии «выбирать только то, что проба отметила OK»; сессия вызывает `/claude-mesh:mesh-review` — и получает отказ на первом же Bash-блоке. Хуже того, деградационная ветка самого промпта («preflight не найден → считай `claude` единственным доступным ревьюером → спроси, продолжать ли на нём одном») ведёт пользователя в тот же тупик.

Развилка: либо понизить обещания пробы (`builtin-claude` зависит от `CONFIG_STATUS`; при MISSING/INVALID — строка вида `MISSING — mesh-review откажется стартовать без config.yaml в <data-dir>`, а `SUMMARY available` пустой), либо расширить scope и добавить в оба оркестратора fallback на rc=2. Второе прямо противоречит разделу Scope («Out»), поэтому реалистичен первый вариант — но тогда решение 6 и текст обоих промптов надо переписывать, а не подправлять.

**C2. Тест-харнес устроен так, что проверки «exit 0» и «env-файлы удалены» не могут упасть.**

`run_probe` присваивает `RC` и `CFG_DIR`, но вызывается исключительно как `OUT="$(run_probe …)"` — то есть в command substitution. Присваивания остаются в subshell. Проверил:

```
RC after command-substitution call = 0   (probe really exited 3)
CFG_DIR after call = ''
```

Следствия: все ассерты `assert_eq "… exits 0" 0 "$RC"` сравнивают начальное `RC=0` с нулём — они пройдут, даже если проба упадёт с кодом 7. Проверка утечки env-файлов вырождается в `find "" -name 'claude-mesh-env-*'` → ошибка в `/dev/null` → `0` → PASS. Комментарий в плане (`CFG_DIR=""    # set by run_probe, readable by the caller afterwards`) утверждает ровно то, чего не происходит.

Оба главных инварианта — «every verdict exits 0» (Global Constraints, решение 5) и «no exported env file left behind» (раздел Secrets: «This is a test assertion, not an intention») — оказываются непроверяемыми. Домашний идиом уже есть и он правильный, `skills/shared/tests/test-verify-delegation.sh:43`:

```bash
run() { VERDICT=$(bash "$SCRIPT" "$@" 2>/dev/null); RC=$?; }
```

функция присваивает в переменные и вызывается как отдельная команда. `run_probe` надо переписать по этому образцу.

**C3. `CURRENT_ENVF` не доходит до trap — заявленная защита токена не реализована.**

`probe_provider` вызывается как `VERDICT="$(probe_provider "$MID")"`, а внутри делает `CURRENT_ENVF="$envf"`. Присваивание уходит в subshell; родительский `cleanup()` всегда видит пустую строку. Проверил:

```
parent CURRENT_ENVF=''
TRAP saw CURRENT_ENVF=''
```

Штатный путь спасает `rm -f "$envf"` внутри самой функции, но именно аварийный путь (Ctrl-C, SIGTERM, внешний таймаут между `export` и `rm`) — тот, ради которого trap и написан — оставляет mode-600 файл с токеном провайдера в TMPDIR. И тест этого не ловит (см. C2).

Это тот же класс дефекта, который уже был найден и исправлен для `cli_row` («глотал собственную строку через command substitution»); в `probe_provider` он остался. Лечится тем же приёмом: пусть `probe_provider` пишет вердикт в глобал (как `cli_row` пишет в `CLI_STATUS`), а не эхает его наружу.

**C4. Статус `INVALID` смешивает «конфиг плохой» и «на машине нет тулчейна».**

`CONFIG_STATUS` выводится из кода возврата `list-models`, а `load_or_die` вызывает `require_yq` / `require_gnu_coreutils` / проверку `jq` и умирает через `die` (rc=1). Проверил на копии `valid-full.yaml` с вычищенным PATH:

```
rc=1
config-loader: yq not found. claude-mesh requires Python-yq (kislyuk/yq)…
```

Проба назовёт это `config INVALID`, хотя `config.yaml` безупречен. Дизайн определяет `INVALID` как «config only — the validator rejected it», так что оператор пойдёт править конфиг вместо `pipx install yq`. В песочнице отсутствие Python-yq заметно вероятнее битого конфига — это отдельный тулчейн, ставящийся руками, — а последствие тяжелее: при rc=1 оркестраторы делают `exit 1`.

При этом у пробы нет строк `yq`, `jq`, `bash-4`; раздел Dependencies перечисляет bash 4 / `timeout` / `curl` / `git`, но не `yq` и `jq` — жёсткие зависимости всего плагина. Строку `curl` при этом решили печатать. Нужны отдельные строки для `yq`/`jq` перед `config` и отдельный статус (или хотя бы честный detail), отличающий «toolchain missing» от «config rejected».

### Concerns

**K1. Discovery-блок может найти не тот экземпляр плагина, что оркестратор.** Промпт ищет `find "$HOME"/.claude/plugins … | sort -V | tail -1`, то есть самую высокую версию **в кэше**. Оркестраторы резолвят иначе: `mesh-review` Step 1 — сначала `${CLAUDE_PLUGIN_ROOT}` (гармонь подставляет его в текст командного файла), `mesh-design-review` Step 5.0 — от `SKILL_BASE`. При dev-загрузке `--plugin-dir <репозиторий>` активный плагин — рабочая копия, а `find` найдёт только кэш (на этой машине это 0.3.0…0.6.0, ни в одном нет `preflight-env.sh`) → сработает деградация решения 6, хотя нужный скрипт лежит в двух шагах. Решение 2 правильно отвергает `${CLAUDE_PLUGIN_ROOT}` для промпта, но замену выбрало не рассматривая dev-загрузку.

**K2. Бюджет времени занижен примерно вдвое, и «worst case» в песочнице — это норма.** `ollama-precheck.sh` не принимает аргумент таймаута вовсе: 3 попытки × `--max-time 2` + 2 × `sleep 2` ≈ 10 s на ollama-провайдера, и `PREFLIGHT_HTTP_TIMEOUT` на это не влияет. Для конфига «3 anthropic + 1 ollama» без сети: 3×5 + 10 + codex 5 + gemini 5 + git 8 ≈ 43 s; пять провайдеров — под минуту, а не «~35 s». Побочно: строка вердикта `NO-NETWORK|endpoint did not answer within ${HTTP_TIMEOUT}s` для ollama-kind просто неверна фактически.

**K3. `config OK` не означает «конфиг годен для review».** `cmd_list_models` валидирует только `providers` и `models`. Секции `defaults`, `runtime`, `claude`, `codex`, `gemini` не проверяются — а `mesh-design-review` Step 5.0 вызывает `get-defaults design_review`, `get-flag dispatch_model` и `get-flag has_claude_models`, каждый из которых валидирует свою секцию и при ошибке даёт `exit 1`. Итог: проба скажет `config OK`, review умрёт на Step 5.0. В `tests/fixtures/` лежат ровно такие конфиги (`invalid-defaults-*`, `invalid-runtime-*`, `broken-codex-valid-gemini.yaml`), и ни один не попал в сценарии теста. Либо использовать `config-loader.sh validate` (полный линт) для строки `config`, либо явно сузить в дизайне, что именно эта строка утверждает.

**K4. `claude-models MISSING` маскирует битую секцию `claude:`.** `list-claude-models` вызывает `validate_claude` и умирает rc=1 при поломанной секции; код в Task 1 глотает это (`|| CLAUDE_MODELS=""`) и печатает «no claude.models catalog» — то есть «каталога нет». А `mesh-review` Step 1 на том же чтении делает `exit 1` с сообщением валидатора. Проба снова оптимистичнее реальности.

**K5. Задача 5 — 13 запусков субагентов на критическом пути.** 3 baseline + 5 control + 5 candidate, каждый читает design+plan этой же ветки целиком; Task 6 заблокирован результатом. Дорого и недетерминированно. Отдельный риск: baseline-агенту сказано «Work in `<SCRATCH>/repo`», но по построению он должен начать реализовывать план, а CWD сессии — исходный репозиторий; пути к документам он видит внутри клона, но ничто не мешает ему поправить оригинал. Нужен явный запрет трогать что-либо вне `$SCRATCH` плюс проверка `git status` и в исходном репозитории тоже.

**K6. Шаги верификации Task 6/7 скорее всего не выполнимы как написаны.** Новые `commands/*-fresh-session.md` лежат в рабочей копии, а активный плагин — `~/.claude/plugins/cache/zinin/claude-mesh/0.6.0`. Пока плагин не переустановлен (или не загружен через `--plugin-dir`), `/claude-mesh:design-review-fresh-session` не зарезолвится, и «Run the command in this session» упадёт. В плане нет ни шага установки, ни альтернативы.

**K7. Асимметрия перезаписи prompt-файлов.** Для code-review явно прописан суффикс `-2`/`-3` и «never overwrite an earlier prompt». Для design-review — ничего: повторная генерация для той же итерации N молча затрёт файл. Обоснования асимметрии нет.

**K8. Нормализация TOPIC зафиксирована неоднозначно — ровно там, где решение 4 требует точного совпадения.** `mesh-design-review` Step 1 говорит «Remove suffixes `-review`, `-design` if present» с примером `iterative-review-design.md → iterative`, то есть снимает **два** суффикса подряд. Дизайн и план формулируют «stripping a trailing `-design` or `-review`» — читается как один. На текущем topic разницы нет, но решение 4 держится именно на побайтовом совпадении правила. Заодно «the matching `docs/superpowers/plans/*.md`» нигде не определено, а в репозитории сосуществуют три конвенции имени плана: `-plan.md` (exec-plan-fresh-session), `-implementation.md` (mesh-design-review Step 1) и голое `<topic>.md` (этот план).

**K9. Мелочи по строкам.** `probe_provider` схлопывает любую ошибку `cmd_export` в «token not configured» — а `cmd_export` умирает ещё и на невалидных `providers`/`models`/`runtime` и на «model not found». И: Task 2 печатает строки с именем `provider` (без суффикса) в двух ветках, но документированный row order в дизайне и в Global Constraints такого имени не содержит.

### Suggestions

**S1. Искать пробу сначала в рабочей копии.** Песочница монтирует рабочую копию — значит самая свежая `preflight-env.sh` лежит прямо там, по построению новее любого кэша. Первым кандидатом `./skills/shared/preflight-env.sh`, вторым — `find` по кэшу. Это одновременно закрывает K1 и снимает деградацию решения 6 для ревью самого claude-mesh (а это самый частый случай). Оговорка обязательна: локальный путь существует только когда ревьюится этот репозиторий, поэтому он кандидат, а не единственный источник.

**S2. Печатать строку с версией и путём самой пробы.** `SCRIPT_DIR` она уже вычисляет; строка вида `plugin OK 0.6.0 @ /home/…/cache/zinin/claude-mesh/0.6.0` стоит три строки кода и мгновенно объясняет и K1, и «почему тут нет строки X». Сейчас читающая сессия не может отличить «проба старая» от «возможности нет».

**S3. Явно запретить генератору разворачивать `$HOME`.** Блок в промпте содержит `"$HOME"/.claude/plugins`, но пишет этот файл модель, а не `cat`. Ей ничего не мешает подставить `/home/zinin/…` и воспроизвести ровно ту ошибку, от которой защищает решение 2. Соседство усугубляет: `<DESIGN_PATH>` в том же промпте подставлять как раз нужно. Нужна отдельная строка в командном файле: emit `$HOME` literally.

**S4. `grep -qF` в leak-скане.** Task 6 Step 3 использует `grep -q -- "$id"`, где `$id` — это regex. `zai/glm` безобиден, но id с `.` или `+` дадут ложные `LEAK:`. Флаг `-F` убирает вопрос.

**S5. Режим без сети (`PREFLIGHT_SKIP_NETWORK=1`).** С учётом K2 повторный прогон пробы стоит около минуты, а перезапускать её будут (сессия длинная, оператор переспрашивает). Локальные строки — config, claude-models, наличие CLI, clipboard, наличие remote — считаются мгновенно.

**S6. Ассерт «SUMMARY согласован с построчными вердиктами».** Дизайн перечисляет это среди assertions, но в Task 4 его нет — только точечные `assert_match` на конкретные подстроки. Проверка «каждый `provider:X OK` ⇒ все модели X в available, каждый не-OK ⇒ все в unavailable» ловит рассинхрон `PROBED` при любой будущей правке; сейчас разъезд заметит только человек.

### Questions

1. Что печатать в `SUMMARY available`, когда `config MISSING`, — учитывая, что оба оркестратора в этом состоянии просто отказываются стартовать (C1)? От ответа зависит и текст решения 6, и деградационная ветка обоих промптов («proceed on claude alone»), и четыре ассерта в тесте.
2. Готовы ли расширить scope и добавить в `mesh-review` / `mesh-design-review` fallback на rc=2 («нет конфига → один встроенный claude-ревьюер»)? Сейчас это в «Out», но без него C1 закрывается только понижением обещаний пробы — то есть признанием, что в песочнице без конфига review невозможно вообще.
3. Как предполагается запускать новые слэш-команды на шагах верификации Task 6 Step 2 и Task 7 Step 2/3 до переустановки плагина (K6) — `/plugin update`, `--plugin-dir`, или верификация вручную по тексту файла?
4. Бывают ли `codex` / `gemini` в целевой песочнице вообще? Если там заведомо только `claude` и ext-claude, две сетевые эвристики (10 s из бюджета K2) можно снять целиком и заменить одной строкой «CLI не установлен».
5. Артефакты верификации (`docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`) попадают под глобальное правило «`git rm` всё из `docs/superpowers/` перед PR», то есть baseline и GREEN-результаты, названные в Done criteria, в PR не попадут и останутся только в истории ветки. Это осознанно, или доказательствам работы гейта место вне `docs/superpowers/`?

---

## claude:fable

Проверено по коду: семантика rc loader'а (0/1/2), имя env-файла `claude-mesh-env-*` и REPLACE_ME-отказ именно в `export` (config-loader.sh:697,731), коды 0/5/6 обоих прекчеков, содержимое фикстур `valid-full.yaml` / `invalid-token-replace-me.yaml`, правила Step 1/2/13/15 в mesh-design-review, контракт «every verdict exits 0» в watch-runs.sh:31, правило базовой ветки в ext-claude-code-review, discovery-блок в mesh-review.md:34-42, README-буллет для Task 9. Архитектурные решения 1, 2, 5 подтверждаются кодом. Ниже — что не сходится.

### Critical Issues

**C1. `probe_provider` вызывается через command substitution — трап-гарантия удаления токен-файла не работает.**
План, Task 2 Step 3: `VERDICT="$(probe_provider "$MID")"` исполняет функцию в сабшелле, поэтому `CURRENT_ENVF="$envf"` никогда не достигает родительского шелла, а `trap cleanup EXIT INT TERM` (Task 1, строки 227-229) всегда видит пустую переменную. Заявленная гарантия «the trap removes it even if the probe is interrupted between export and rm» и дизайн-раздел Secrets («deletes it from a trap … EXIT») фактически не выполняются: Ctrl-C во время token-precheck оставляет на диске файл с реальным токеном провайдера. Тест не ловит — ассерция «exported env files removed» проверяет только штатный путь. Показательно, что `cli_row` уже переведён на глобальную `CLI_STATUS` ровно из-за command substitution; `probe_provider` требует того же паттерна: прямой вызов + вердикт через глобалы.

**C2. Сценарии Task 1 после реализации Task 2 ходят в реальную сеть с фикстурным токеном.**
`run_probe` (план, строки 148-157) по умолчанию подставляет только git-шим; curl-шим появляется лишь в секции Task 2 — ниже по файлу теста. Итоговая сьюта исполняется сверху вниз, значит прогоны `run_probe valid-claude-models.yaml` и `run_probe valid-full.yaml` из Task 1 будут гонять token-precheck против настоящего https://api.z.ai (POST с токеном `tkn-zai`) и ollama-precheck против 127.0.0.1:11434 (3 попытки + два `sleep 2`). FAIL'ов не будет (статусы там не ассертятся), но сьюта становится сетезависимой, медленной (+15-25 s оффлайн) и при каждом прогоне шлёт фикстурный токен на публичный эндпоинт — против её же идеологии шимов. Фикс симметричен git'у: дефолтный curl-шим и PATH прямо в `run_probe`, сценарии переопределяют.

**C3. Task 6 Step 4 переиспользует `$SCRATCH` из Task 5 — между задачами переменная не существует.**
Task 5 создаёт `SCRATCH` и удаляет его в своём Step 5; Task 6 Step 4 говорит «Clone the repo again (`git clone --no-hardlinks . "$SCRATCH/repo"`)». При subagent-driven-development каждую задачу исполняет свежий сабагент: `$SCRATCH` пуст, клон летит в `/repo`, а `rm -rf "$SCRATCH"` в Step 5 — no-op. Нужен собственный `SCRATCH="$(mktemp -d)"` в Task 6 Step 4.

### Concerns

**N1. Сломанная секция `claude:` репортится как «каталога нет», хотя selection UI на ней жёстко падает.** `CLAUDE_MODELS="$(… list-claude-models …)" || CLAUDE_MODELS=""` (Task 1, строка 261) склеивает rc≠0 (`validate_claude` умер на `claude: false` и т.п.) с пустым каталогом → строка `claude-models MISSING "…one claude reviewer on the dispatch model"`. Но mesh-review Step 1 на том же конфиге завершается «config.yaml невалиден (секция claude)». Обещание «rows report what the selection UI will actually offer» нарушено, а статус INVALID для этой строки недостижим. Нужен rc-aware разбор, как уже сделано для list-models.

**N2. `PREFLIGHT_HTTP_TIMEOUT` не действует на ollama-kind, и detail врёт.** ollama-precheck.sh не принимает таймаут: зашиты `--max-time 2` × 3 попытки + два `sleep 2` (строки 18-23) — недоступный ollama это ~10 s, а не «within ${HTTP_TIMEOUT}s», как напишет вердикт. Претензия дизайна «override the per-probe budgets» и оценка «≈35 s worst case» для этого kind неверны. Либо добавить необязательный аргумент таймаута в ollama-precheck (обратносовместимо), либо оговорить исключение в дизайне и в detail.

**N3. Discovery-блок слеп к `--plugin-dir`.** `find ~/.claude/plugins` покрывает marketplace/cache, но не dev-загрузку — тот самый случай, который mesh-review.md:34-41 решает подстановкой плейсхолдера в текст команды. Вставленному промпту подстановка недоступна: в песочнице с `--plugin-dir` find вернёт либо ничего, либо молча выберет старую кэшированную копию (sort -V). Минимум — зафиксировать в decision 6; лучше — S1 ниже.

**N4. Односторонние sync-notes.** Генератор получает SYNC-комментарии на Step 1/2/13 скилла, но Task 8 не добавляет встречных пометок в SKILL.md — конвенция репозитория двусторонняя («Change all four or none»). Правка деривации TOPIC в Step 1 молча разъедет генератор. Три однострочных `<!-- SYNC -->` в SKILL.md решают.

**N5. Близнецы-шаблоны в двух command-файлах без взаимного sync-note.** DO NOT / ENVIRONMENT / PREFLIGHT / THEN STOP скопированы дословно (Task 7 прямо требует verbatim), но ничем не связаны. Тот же класс дрейфа, который репо уже дважды прожил между mesh-review и mesh-design-review.

**N6. Случай «curl отсутствует» противоречив.** Строка `curl MISSING "network verdicts below are UNKNOWN without it"` обещает UNKNOWN, но провайдерные строки дадут NO-NETWORK: прекчеки берут curl из PATH, command-not-found → 000 → exit 6. Либо при HAVE_CURL=0 не гонять provider-пробы (UNKNOWN «no curl»), либо переформулировать detail. Комбинация в тестах не покрыта (в no-curl-сценарии на PATH остаётся шим).

**N7. `git ls-remote` может встать на интерактивном запросе кредов/host key и быть засчитан как NO-NETWORK.** timeout спасает от зависания, но вердикт неточный. `GIT_TERMINAL_PROMPT=0` (+ `GIT_SSH_COMMAND='ssh -oBatchMode=yes'`) даёт честный и мгновенный ответ.

**N8. GREEN-прогон — прокси, а не приёмка.** Сабагент host-сессии отличается от свежей sandbox-сессии (системный промпт, teammate-обвязка, host-CLAUDE.md; «ended by waiting» для сабагента — аппроксимация: он просто завершает ход). Дизайн сам называет отставший плагин песочницы главным риском, но ручной прогон в реальной песочнице нигде не является шагом плана. Стоит добавить как явный (пусть и ручной) шаг приёмки.

### Suggestions

**S1. Обернуть пробу в микрокоманду `/claude-mesh:preflight`** (плейсхолдер + существующий find-fallback + запуск). Генерируемый промпт говорит «run /claude-mesh:preflight»: это закрывает `--plugin-dir` (подстановка сработает в командном файле песочницы), убирает find-заклинание из промптов и даёт оператору переиспользуемый инструмент. Деградация не хуже текущей: старый плагин не имеет ни команды, ни скрипта. Raw-блок можно оставить как fallback.

**S2. Передавать `TOPIC=` в строке «WHEN THE USER SAYS GO».** Генератор уже дериватнул TOPIC; передача его в mesh-design-review снимает половину риска «generator derives a different topic → wrong N», ради которого и заведены sync-notes.

**S3. Пробрасывать endpoint в detail провайдерной строки.** Примеры дизайна печатают URL («http://localhost:11434 timed out after 5s»), реализация не может — URL живёт в сабшелле. base_url не секрет, оператору он нужен первым делом; заодно примеры дизайна перестанут расходиться с фактическим выводом (это касается и git-remote detail).

**S4. Зафиксировать поведение при перегенерации design-review-промпта.** Для code-review есть правило коллизий (-2/-3), для `…-design-review-prompt-iter-N.md` — нет: повторная генерация молча перезапишет файл (такой iter-1 уже лежит untracked в репо). Если перезапись желаема (та же итерация) — сказать это явно.

**S5. SUMMARY не раскрывает claude-каталог.** Для провайдеров принцип «report per model» выдержан, а `claude` остаётся одной позицией, хотя строкой выше перечислены opus/fable. Дёшево: `claude (opus, fable)`.

**S6. Мелочи одним списком:** (а) `%-16s` переполняется уже на `provider:deepseek` — парсинг пословный и ничего не ломается, но оговорите, чтобы будущий «фикс красоты» не порезал имена; (б) в PREFLIGHT-блоке `[ -x "$PF" ]` → `[ -f "$PF" ] && bash "$PF"` — страховка от потерянного exec-бита; (в) микротест Task 5 Step 3 тестирует DO NOT с болтающейся ссылкой «the preflight block below», которого в кандидат-промпте нет — либо заглушка секции, либо явная оговорка, что полный контекст проверяет Task 6 Step 4; (г) «if the control does not fail, the block should be dropped» (Task 5) противоречит фиксированному списку секций в decision 3 — правильный исход там «вернуться к дизайну», а не молча выкинуть блок.

### Questions

**Q1.** INVALID сейчас накрывает и «тулчейн отсутствует»: без Python-yq/jq loader умирает rc=1 → `config INVALID "config-loader: yq not found…"`. Detail самообъясняющий, но семантически это не «validator rejected it», а для свежей песочницы случай вполне вероятный. Оставляем и дописываем в дизайн, или мапим на UNKNOWN?

**Q2.** Проба сознательно не показывает `defaults.*` песочницы. Оператор, привыкший к `/mesh-review default`, может запустить пресет с мёртвым ревьюером — промпт лишь советует «select only OK rows». Достаточно, или добавить строку `defaults` (локальное чтение, без сети)?

**Q3.** Дизайн цитирует инцидент как «four of five executors died … 38 minutes»; в SKILL.md:425 38 минут относятся к 2026-07-26 («none of six got a watchdog, four executors died»), а «four of five» — уже 2026-07-27. Поправить цитату в Problem?

---

## codex-executor (gpt-5.6-sol, reasoning=max)

Использую `superpowers:using-superpowers`, чтобы сначала проверить обязательный рабочий процесс; затем прочитаю оба документа и сверю их с релевантным кодом и тестовой инфраструктурой. Изменять файлы не буду — это только ревью.Навык не добавил специального шаблона для такого ревью. Начинаю с самих design/plan, как вы потребовали; после этого проверю заявленные точки интеграции, конфиг-loader и тестовые соглашения.Документы прочитаны полностью. Теперь сверяю план с фактическими контрактами кода; особое внимание уделю exit-code/`set -u`, секретам, выбору моделей, обнаружению plugin path, git-base и тому, действительно ли предложенные тесты ловят заявленные свойства.Нашёл несколько не косметических расхождений: обещанный Claude-only fallback сейчас несовместим с обоими mesh-потоками, а два ключевых тестовых утверждения фактически пустые из-за subshell. Перед итогом использую `superpowers:verification-before-completion`, чтобы перепроверить каждое критическое замечание по точным контрактам и строкам.Текущие design/plan пока не готовы к реализации: есть несколько прямых расхождений между обещанным поведением, фактическими контрактами mesh-команд и предложенными тестами.

### Critical Issues

1. **Claude-only fallback фактически не работает.** Design обещает `SUMMARY available: claude` при отсутствующем/невалидном конфиге и при старом плагине без probe ([design](/opt/github/zinin/claude-mesh/docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md:271)). Но `/mesh-design-review` и `/mesh-review` на loader rc=2 сразу предлагают создать конфиг и завершаются до выбора ревьюера ([mesh-design-review](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:224), [mesh-review](/opt/github/zinin/claude-mesh/commands/mesh-review.md:48)). Следовательно, после `GO` обещанный fallback не может запустить ревью. Нужно либо расширить scope и добавить в оба orchestrator явную ветку `no config → один builtin claude`, либо убрать обещание продолжения без конфига.

2. **`config OK` не означает, что конфиг пригоден для запуска mesh-review.** Probe определяет состояние через `list-models` ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:247)), а эта команда проверяет только `providers` и `models` ([config-loader](/opt/github/zinin/claude-mesh/skills/shared/config-loader.sh:859)). Позже orchestrator отдельно валидирует `defaults`, `runtime` и `claude`; ошибка там остановит review уже после того, как preflight объявил среду доступной ([mesh-design-review](/opt/github/zinin/claude-mesh/skills/mesh-design-review/SKILL.md:242)). Первичная классификация должна использовать полный `config-loader.sh validate`, а не `list-models`.

3. **Доступность external-provider reviewer завышена.** `provider:* OK` проверяет только token/endpoint, хотя `ext-claude-exec` требует как минимум `claude`, `jq`, `bc`, `curl` и `python3` ([ext-claude-exec](/opt/github/zinin/claude-mesh/skills/ext-claude-exec/SKILL.md:80)). При отсутствующем `claude` или `bc` модель окажется в `SUMMARY available`, но немедленно упадёт после dispatch — именно тот класс ошибки, который preflight должен предотвращать. Нужна runtime-строка или общий prerequisite gate для всех ext-claude моделей.

4. **Гарантия удаления token-файла при прерывании не выполняется.** `CURRENT_ENVF` выставляется внутри `probe_provider`, но сама функция вызывается через `VERDICT="$(probe_provider ...)"` ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:373), [вызов](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:414)). Это subshell: родительский `trap` не увидит присвоенное значение. При сигнале между export и обычным `rm` sensitive-файл может остаться. Кроме того, обработчики `INT/TERM` только вызывают `cleanup` и не завершают probe ненулевым кодом. Следует выполнять функцию в текущем shell с результатом через globals либо устанавливать локальный trap внутри фактического владельца файла; отдельно протестировать `TERM/INT`.

5. **Контракт `PREFLIGHT_CURL_BIN` и timeout нарушен.** Spec обещает, что указанный binary применяется ко всем пробам и позволяет работать с нестандартно установленным curl ([design](/opt/github/zinin/claude-mesh/docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md:221)). План прямо признаёт, что borrowed prechecks продолжают искать обычный `curl` в `PATH` ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:421)); сами скрипты действительно hardcode-ят его ([token-precheck](/opt/github/zinin/claude-mesh/skills/ext-claude-exec/token-precheck.sh:36), [ollama-precheck](/opt/github/zinin/claude-mesh/skills/ext-claude-exec/ollama-precheck.sh:19)). Поэтому таблица может одновременно показать `curl MISSING` и `provider:zai OK`. Ollama также игнорирует `PREFLIGHT_HTTP_TIMEOUT`, используя фиксированные 2/5 секунд. Контракт или реализацию prechecks необходимо изменить до начала работ.

6. **Два важнейших unit-test assertion сейчас фиктивны.** Все вызовы сделаны как `OUT="$(run_probe ...)"`; значит, присвоенные внутри функции `RC` и `CFG_DIR` теряются вместе с subshell ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:146)). Проверка exit code всегда видит исходный `RC=0`, а проверка оставшегося env-файла выполняет `find` по пустому пути и также проходит. Прямая shell-проверка воспроизвела это как `OUT=output RC=0 CFG_DIR=` при присвоении `RC=7` внутри функции. `run_probe` должен выполняться в текущем shell и складывать output в файл/global.

7. **Тест probe не герметичен.** Первые сценарии с валидными конфигами запускаются до создания curl-shim ([ранние вызовы](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:161), [создание shim](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:312)). После завершения реализации эти ранние вызовы пойдут в реальные z.ai/Ollama endpoints. Unit suite не должна зависеть от сети или отправлять fixture-токены наружу; default curl-shim нужен до первого `run_probe`.

8. **GREEN-сценарий из Task 6 технически не воспроизводим в описанном виде.** `SCRATCH` создаётся в Task 5 и там же удаляется ([создание](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:767), [удаление](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:823)), но Task 6 снова клонирует в `$SCRATCH/repo` без нового `mktemp` ([Task 6](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:1003)). Кроме того, subagent наследует исходный cwd и настоящий `HOME`: проверка чистоты clone может пройти, даже если изменения сделаны в исходном repo, а discovery найдёт установленный старый plugin вместо скрипта из clone. Нужен новый temp-dir, гарантированный cwd и изолированный HOME/plugin installation.

9. **Ветка code review без документов ломается на обычных branch names.** План берёт `TOPIC` непосредственно из branch name ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:1074)) и вставляет его в путь файла ([output](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:1172)). Текущая ветка `feat/fresh-session-review-prompts` уже создаст несуществующий вложенный каталог. Нужна нормализация branch → безопасный filename slug и тест с `/`, detached HEAD и пустым именем.

10. **`do-plan` оставляет неверный порядок завершения.** Сейчас Step 7 требует обычный `superpowers:finishing-a-development-branch` ([do-plan](/opt/github/zinin/claude-mesh/commands/do-plan.md:204)), а план предлагает лишь дописать после этого новый текст ([Task 8](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:1248)). В результате merge/push может произойти до fresh-session code review. Step 7 нужно переписать как явную последовательность: implementation review → генерация fresh-session review prompt → остановка → только после внешнего review и его fixes разрешено finishing.

### Concerns

- **Порядок providers не соответствует spec.** План выводит их по первому появлению модели и называет это “config order” ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:368)). Это порядок `models`, а не `providers`; provider без модели вообще исчезнет. У loader уже есть `list-providers` ([config-loader](/opt/github/zinin/claude-mesh/skills/shared/config-loader.sh:879)).

- **Любая ошибка `export` объявляется отсутствующим token.** Ошибка `mktemp`, повреждённый install или иной internal failure попадёт в `MISSING — token not configured` ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:375)). Следует отличать конкретный `REPLACE_ME` от `UNKNOWN`/broken probe.

- **Loader rc=1 ошибочно всегда означает `config INVALID`.** Тот же rc возвращается при отсутствующих `yq`/`jq`, несовместимом окружении и внутренних ошибках loader. Это не “validator rejected config”, как определено в закрытом status set.

- **Git verdict слишком грубый.** Любой ненулевой `ls-remote` — timeout, auth failure, TLS error, отсутствующий `HEAD`, неверный URL — превращается в `NO-NETWORK` с текстом “silent” ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:607)). Нужно хотя бы различать timeout, auth и прочую ошибку.

- **Code-review range игнорирует незакоммиченные изменения.** Генератор записывает только `BASE_SHA..HEAD_SHA` и commit log ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:1083)). При dirty worktree часть реализации будет молча исключена. Проверять чистоту нужно до записи самого prompt-файла.

- **Тесты генераторов не являются regression suite.** Design обещает fixture-based output test, но plan предлагает один раз запустить недетерминированную slash-команду и сделать несколько `grep`. Два больших template-блока копируются вручную, поэтому drift между design/code версиями почти гарантирован.

- **Wording micro-test не соответствует финальному prompt.** Candidate содержит ссылку на “preflight block below”, но фактического блока в тестовом prompt нет ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:799)). Измеряется только изменение файлов, хотя design также заявляет reviewer assumptions и push/PR behaviour.

- **Финальная test-команда маскирует exit code.** Цикл всегда заканчивается успешным `echo "all suites done"` ([plan](/opt/github/zinin/claude-mesh/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:1332)). Ошибка заметна только при ручном поиске строки.

- **Discovery по “самой новой” cache-копии не гарантирует active plugin.** Пин на старую версию может сосуществовать с более новой cache-директорией. Тогда probe и вызванный затем mesh-skill окажутся из разных версий.

### Suggestions

- Добавить тонкую `/claude-mesh:preflight-env` command-обёртку. В свежей сессии её `${CLAUDE_PLUGIN_ROOT}` будет разрешён уже sandbox harness-ом, поэтому probe гарантированно берётся из active plugin без glob по cache.

- Вынести сборку prompt в общий детерминированный renderer/template. Slash-команды должны собирать только session-specific `CONTEXT`; порядок секций, escaping, collision handling и отсутствие config reads лучше обеспечить скриптом.

- Добавить loader-команду вроде `preflight-metadata`, возвращающую проверенный JSON/TSV из одного config snapshot: полный validation status, providers, models, Claude catalog и gates. Это уменьшит количество процессов и исключит внутренне противоречивую таблицу при изменении конфига во время probe.

- После исправления корректности можно выполнять независимые provider probes с ограниченным параллелизмом, сохраняя результаты во временные файлы и печатая их затем в детерминированном config order.

- Расширить test matrix: malformed `claude/defaults/runtime`, отсутствующий и нестандартный curl, отсутствующие `claude/bc/python3`, SIGTERM во время provider probe, provider order, быстрый git auth failure, branch с `/`, dirty worktree, active-vs-newest plugin.

### Questions

- Отсутствующий `config.yaml` — действительно поддерживаемый режим запуска review на одном Claude или только диагностическое состояние? Сейчас design обещает первое, а код реализует второе.

- Что именно означает `OK`: “проверена одна предпосылка” или “этого reviewer безопасно выбирать”? Текст prompt требует второе, но текущий probe реализует первое.

- Fresh-session code review должен завершиться до любого действия `finishing-a-development-branch`, включая merge локально, или запрещены только push/PR?

- При dirty worktree генератор должен остановиться и попросить commit, либо review обязан включать staged/unstaged/untracked изменения?

- Допустимо ли добавить active-plugin command wrapper для preflight, или glob является жёстким внешним требованием, а не только выбранной реализацией?
---

## ext-claude-executor (zai/glm)

Проверил всё необходимое против кода. Контракт `watch-runs.sh` «каждый вердикт → exit 0» существует (стр. 31, 363), `claude:`/`codex:`/`gemini:` секции в `config.example.yaml` есть — фикстуры реалистичны. Ниже — критический разбор.

---

# Ревью: fresh-session review prompts (design + plan)

Архитектурно дизайн сильный: ключевое решение «генераторы никогда не читают `config.yaml`» элегантно решает реальную проблему двух сред (генерирующая машина ↔ sandbox), переиспользование существующих `token-precheck.sh`/`ollama-precheck.sh` разумно, а SYNC-примечания, привязанные к конкретным шагам `mesh-design-review`, — зрелая практика, которой репо уже следует. SYNC verified: Step 1 (TOPIC), Step 2 (итерации), Step 13 (дата из design-файла) совпадают дословно (`SKILL.md:68-93`, `695-698`). Ниже — что не сходится.

## Critical Issues

### 1. Probe валидирует codex/gemini слабее, чем их читает selection UI → ложный `OK`
Это пробел в центральном контракте дизайна. Decision 5 прямо обещает: *«codex / gemini rows report what the selection UI will actually offer»*. Но реализация (Task 3, `cli_row`) решает предлагабельность через `get-flag has_codex`/`has_gemini`, а это — голый `jq -e '.codex'` **без валидации** (`config-loader.sh:800-805`). Между тем `mesh-review`/`mesh-design-review` при выборе codex читают конфиг через `get-codex`, который вызывает `validate_codex` (`config-loader.sh:891`) и умрёт на malformed-секции — а такой класс ошибок репо систематически ловит (type-dispatch gate в `validate_codex:260-272`, fix wave 5).

Сценарий: в sandbox `codex: { model: gpt-5.5, reasoning_level: 3 }` (некорректный тип) или скалярный `codex: false`. `has_codex` → `1`, CLI на месте, сеть отвечает → probe печатает `codex OK`. Оператор выбирает codex → `get-codex` делает `die` (rc=1) → review падает в рантайме. Та же схема для gemini (`validate_gemini:319`) и, в меньшей степени, `claude-models` (`cmd_list_models` не вызывает `validate_claude`, а probe использует `list-claude-models || ""` — malformed `claude:` молча даст `MISSING` с неточным detail).

**Фикс на этапе дизайна дешев:** заменить зондирование через `has_*` на фактический typed-getter — вызывать `get-codex`/`get-gemini` (они сами валидируют) и трактовать rc≠0 как `MISSING`/`INVALID` с реальной причиной из stderr. После реализации это переписывание probe + тестов.

*Вероятность в реальном sandbox низкая (оператор обычно копирует валидный `config.example.yaml`), но это именно тот класс несоответствий, ради которого в репо существует typed-getter principle — и нарушение обещания decision 5.*

## Concerns

### 2. `probe_provider` стирает различие причин отказа `export`
В `probe_provider` (Task 2): `envf="$("$LOADER" export "$mid" 2>/dev/null)" || { echo "MISSING|token not configured ..."; }`. Любой rc≠0 от `export` становится «token not configured». Но `cmd_export` вызывает `validate_runtime` (`config-loader.sh:668-670`), а `cmd_list_models` — **нет** (`:862-866`). Значит: конфиг, валидный по providers/models (→ `CONFIG_STATUS=OK`), но с невалидным `runtime:` приведёт к тому, что `export` умрёт на `validate_runtime`, а probe сообщит для всех моделей «token not configured» — неточно. `2>/dev/null` глотает настоящую ошибку, так что и оператор, и тест не видят реальной причины. Это выпадает из тщательной диагностики, принятой в остальном дизайне. Минимум — различить REPLACE_ME (читаемое из stderr) от прочего; или обобщить detail до «export refused — token not set or config section invalid».

### 3. `ollama-precheck.sh` игнорирует `PREFLIGHT_HTTP_TIMEOUT`
Дизайн заявляет `PREFLIGHT_HTTP_TIMEOUT (default 5) ... override the per-probe budgets`. Но `ollama-precheck.sh` (проверено) имеет захардкоженные `--max-time 2` (×3 retry с `sleep 2`) + `--max-time 5` на `/api/tags` — итог до ~11 с на один ollama-провайдер, **независимо** от `PREFLIGHT_HTTP_TIMEOUT`. Провайдеры последовательные, поэтому при недостижимом ollama бюджет «≈35 s worst case» из дизайна реально ближе к 40–45 с, и настройка таймаута эту часть не сокращает. Либо оговорить ollama как исключение явно, либо прокидывать таймаут в `ollama-precheck.sh` (меняет существующий скрипт — вне scope, но тогда уточнить обещание).

### 4. Wording-микротест (Task 5) измеряет поведение конкретной модели, а не всех
RED-baseline и A/B-микротест (5+5 прогонов) прогоняются на dispatch-модели генерирующей машины. Но review в sandbox идёт на модели sandbox'а (`zai/glm`, ollama и т.д.), поведение которых может существенно отличаться. Закреплённое wording может не держаться на другой модели — а дизайн неявно предполагает универсальность блока `DO NOT`. Это фундаментальная ограниченность подхода «тестировать wording», в рамках дизайна не устранимая; стоит хотя бы явно записать как assumption (сейчас в рисках её нет).

### 5. Стоимость Task 5: ~13 реальных subagent-диспетчей
3 baseline + 5 + 5 микротеста = тринадцать живых LLM-вызовов до того, как написана первая команда. Это медленно и заметно расходует токены; для итеративной доработки wording'а каждый пересчёт дорого обходится. Iron Law из `writing-skills` соблюдён, но стоит зафиксировать ожидание в плане (и, возможно, ограничить повторы микротеста явным ceiling).

### 6. Асимметрия маршрутизации: design-review-loop закрыт, code-review — нет
`mesh-design-review` Step 15 автоматически направляет следующую итерацию в `design-review-fresh-session` (Task 8). Аналогичного автоматического триггера для `code-review-fresh-session` нет — только ручной hint в `do-plan` Step 7. Если план исполнен не через `/do-plan` (напрямую через `exec-plan-fresh-session` или вручную), путь к code-review потерян. Возможно намеренно (code review разовый), но стоит подтвердить.

### 7. Мелочи реализации
- В `probe_provider` объявлены `local mid envf kind url rc`, но `kind` и `url` не используются (значения читаются из env-файла как `CLAUDE_MESH_PROVIDER_KIND`/`ANTHROPIC_BASE_URL`) — мёртвые переменные, lint-noise.
- Row `provider SKIPPED` (Task 2, при `CONFIG_STATUS != OK`) печатается с именем `provider` **без двоеточия**, тогда как проённые провайдеры — `provider:zai`. Парсер `field()` в тестах их различает (`field provider` vs `field provider:zai`), но интерфейс строки неоднороден — стоит либо `provider:-`, либо явный комментарий.

## Suggestions

### 8. Параллельные пробы провайдеров
5 последовательных проб с ollama — это 35–45 с ожидания на старте review-сессии. Провайдеры независимы: `probe_provider "$mid" &` в цикле + `wait` соберёт вердикты за `max(одна проба)` ≈ 5–11 с. Цена — усложнение кода (сбор результатов из фоновых процессов, сохранение «always exit 0», корректный cleanup env-файлов в `trap`) и более хитрый тест. Дизайн выбрал последовательность ради простоты — осознанно, но для UX review-сессии это заметно; как минимум достойно записи в risks как будущий improvement.

### 9. Уточнить правило TOPIC из branch name (code-review generator)
Task 7 Step 1: «take `TOPIC` from the branch name». Формат не определён: `feat/fresh-session-review-prompts` → strip `feat/`? `-design`/`-review`? Без точного правила два запуска дадут разный TOPIC, а он ключит имя выходного файла. Добавить явное правило (например: убрать `feat/`/`fix/`/`chore/` префикс, затем применить общий `-design`/`-review` strip).

### 10. SUMMARY мог бы группировать unavailable по причине
Сейчас плоско: `codex (MISSING), gemini (MISSING), ollama/kimi (NO-NETWORK)`. Группировка по статусу (`NO-NETWORK: ollama/kimi; MISSING: codex, gemini`) дала бы оператору паттерн одним взглядом — особенно полезно при «всё NO-NETWORK» (явный сигнал «сети нет вообще»).

## Questions

**Q1.** Codex-зонд использует GET на `api.openai.com/v1/models` и трактует любой ответ ≠ `000` как `OK` — т.е. 403/404/500 тоже `OK`, и auth не проверяется вовсе. Дизайн честно называет это эвристикой, но является ли GET правильным выбором? `token-precheck.sh` доказал, что POST с пустым телом различает auth (401) от reachability. Для codex это дало бы чуть более сильный сигнал без новой зависимости. Почему выбран более слабый зонд?

**Q2.** Code-review generator: `git merge-base HEAD "$BASE_BRANCH"`, fallback `origin/$BASE_BRANCH`. В sandbox без сети с **shallow clone** (typical для shared-folder mount?) `merge-base` может не разрешиться, и `origin/$BASE_BRANCH` тоже отсутствует. Покрыт ли shallow-clone явно, или подразумевается full clone? Если shallow — стоит ли предлагать `--depth`-нейтральный путь (например, `git rev-parse "$BASE_BRANCH"` если локальный ref есть)?

**Q3.** При нескольких установках плагина `find | sort -V | tail -1` берёт старшую версию `preflight-env.sh`. Эта версия соответствует старшей версии **всего** плагина (config-loader, precheck'и) — atomic по версии, ок. Но уточните: гарантирует ли Claude Code, что все файлы одной версии лежат в одном plugin-dir, или возможна смесь (например, cached 0.4.0 `config-loader` + installed 0.4.2 `preflight`)? Если смесь возможна, probe старшей версии может вызвать loader младшей — стоит ли защить `/docs`-проверкой версии или это over-engineering?

**Q4.** `do-plan` Step 7 добавляет условный параграф «If this session is running in a sandbox...». Как сессия-исполнитель узнаёт, что она в sandbox? Префлайта там ещё нет (это не review-сессия). Оставить определение на эвристику сессии (нет `origin`/`gh`), или прокидывать явный сигнал?

---

## ext-claude-executor (alibaba/qwen)

Прочитал оба документа. Теперь нужно изучить кодовую базу, чтобы оценить выполнимость и правильность проектных решений.


I'll explore the codebase systematically, running parallel reads and searches for each section.


Пока agent исследует кодовую базу, проверю несколько критических деталей напрямую.


Now let me read all the critical files in parallel.


Now let me gather the remaining pieces: test files, preflight searches, and docs.


Excellent! The design document for the feature already exists. Let me read it along with test files.


I now have everything needed to produce a comprehensive report. Let me send the findings back to the main agent.


У меня достаточно информации. Жду agent-исследователь, но я уже могу начать писать ревью на основе того, что уже прочитал. Позволю себе подождать agent, чтобы дополнить ревью его находками.

Пока жду — подготовлю черновик критики.


Let me deliver the report directly to the user instead of trying to send it via the messaging tool.

# Fresh-Session Review Prompts — Design Review Report

Working directory: `/opt/github/zinin/claude-mesh`

The design document under review lives at:
`/opt/github/zinin/claude-mesh/docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md`
(branch `feat/fresh-session-review-prompts`, status "approved for planning").

---

## 1. Existing fresh-session commands

### `commands/exec-plan-fresh-session.md`
- **Prompt structure**: 4 sections — `TASK` (one line: "execute the plan"), `DOCUMENTS` (Design + Plan paths), `IMPORTANT: DO NOT START WORK YET` (read, summarize, WAIT), `SESSION CONTEXT` (decisions, rejected alternatives, edge cases, warnings), `PLAN QUALITY WARNING` (stop-and-describe if issues found).
- **Config.yaml**: Does NOT call `config-loader.sh`. No model ids, no provider ids flow through.
- **Clipboard**: Linux = `cat <file> | xclip -selection clipboard` (or `xsel --clipboard`); macOS = `pbcopy`. OS auto-detected. Suggests `sudo apt install xclip` if missing.
- **Discovery**: Searches `docs/superpowers/specs/*design*` and `docs/superpowers/plans/*plan*`. If not found, asks the user.
- **Output**: `docs/superpowers/plans/YYYY-MM-DD-<topic>-execution-prompt.md`.

### `commands/continue-plan-fresh-session.md`
- **Prompt structure**: `TASK` (continue), `CRITICAL: DO NOT START WORKING` (even more forceful stop-read-wait block), `DOCUMENTS`, `PROGRESS` (completed/remaining), `SESSION CONTEXT`, `PLAN QUALITY WARNING`, `INSTRUCTIONS` (1-5 numbered stop-and-wait).
- **Config.yaml**: Does NOT read config.
- **Clipboard**: Same mechanism (xclip/pbcopy, OS auto-detect).
- **Discovery**: Same glob. Extra step: **trims completed tasks** from the plan file itself, replacing body with `✅ Done — see commit(s): abc1234`, commits the trimmed plan, then generates the prompt.
- **Output**: `...-continuation-prompt.md`.

**Key observation for the design**: neither existing command calls `config-loader.sh`. The design's decision ("neither generator reads config.yaml") is **consistent with the current pattern**.

---

## 2. mesh-design-review SKILL.md

### Step 1 (TOPIC derivation) — exact rule
At lines 81–85:
> "Extract TOPIC from design filename: `YYYY-MM-DD-<topic>-design.md` → topic"
> "Normalize TOPIC: Remove suffixes `-review`, `-design` if present."
> Example: `iterative-review-design.md` → `iterative` (not `iterative-review`).

The design document (section 4) explicitly names this rule and carries a sync note: "A generator that derives a different topic counts a different set of iteration files, and would hand the review session an iteration number the skill then disagrees with."

### Step 2 (iteration counting) — exact rule
Lines 89–93:
```bash
ls docs/superpowers/specs/*-{TOPIC}-review-iter-*.md 2>/dev/null | sort -V
```
"Count existing iterations. Next iteration = max + 1 (or 1 if none)."

The design document's Decision 4 mirrors this rule exactly with a sync note naming the step.

### Step 5 / Step 5.2 (reviewer selection UI)
- **Step 5.0** (line 207–263): single Bash block calls `get-flag has_codex`, `get-flag has_gemini`, `get-flag has_models`, `get-flag has_claude_models`, `list-models`, `list-claude-models`, `get-defaults design_review`, `get-flag dispatch_model`. rc-aware: rc=0 proceed; rc=2 → copy-config hint + exit 0; rc=1 → surface validator stderr + exit 1.
- **Step 5.1** (line 265–281): `default` argument — uses `defaults.design_review` preset, skipping selection UI.
- **Step 5.2 (Q1)** (line 283–299): Where codex/gemini are offered. Exact text:
```
options:
  - "claude ★ default (свой Claude Code)"          — show ALWAYS; ★ if "claude" in defaults.builtin
  - "codex CLI ★ default"                          — show only if HAS_CODEX=1; ★ if "codex" in defaults.builtin
  - "gemini CLI ★ default"                         — show only if HAS_GEMINI=1; ★ if "gemini" in defaults.builtin
  - "external models (Anthropic-API) ★ default"    — show only if HAS_MODELS=1; ★ if defaults.models is non-empty
```
`get-flag` calls used: `has_codex`, `has_gemini`, `has_models`, `has_claude_models`.

### Step 6 — failure case (reviewers died mid-stream)
Documented at lines 429–474. The watch loop runs `shared/watch-runs.sh` as a **background** Bash task. Key rules:
- Status table: `DONE` (finished with output), `FAILED` (no usable output), `RUN`, `SILENT` (no writes past stall threshold), `MISSING`.
- **Point 4**: "A SILENT, FAILED or MISSING run is a dead executor — treat it per Error Handling ('One agent fails, others succeed'): note the failure in the merged file, omit its section, continue with the rest. Do not re-dispatch it. `watchdog.sh` already restarts the CLI up to twice inside the run, and that is this file's only retry layer."
- **Point 6**: "Repeat until every dispatched executor has reported, is dead, or the watch budget expires — never interpret silence as 'no findings'. This loop covers the codex / gemini / ext-claude executors only; claude reviewers are not part of it."
- **Sync note** at lines 475–481 explicitly names four differences from `/mesh-review` Step 5a (path resolution, inline `verify-delegation.sh` gate before ping, retry routing, closing clause).

### Step 13 (date source rule)
Lines 694–696:
> "Date source: Use the date from design document filename (`YYYY-MM-DD`), NOT current date."
> Example: design `2026-01-27-checksum-design.md` → iter file `2026-01-27-checksum-review-iter-1.md`

The design doc's Decision 4 explicitly preserves this rule: "The output filename takes its date from the design document's filename, not from today — the rule mesh-design-review Step 13 already applies to iteration files."

### Step 15 (next-iteration branch) — current text
Lines 760–786. AskUserQuestion with two options:
```
- label: "Новая итерация (fresh session)"
  description: "Сгенерировать prompt для запуска следующей итерации review в новой сессии"
- label: "Остановиться и начать работу (fresh session)"
  description: "Сгенерировать prompt для продолжения работы над планом в новой сессии"
```
- "Новая итерация" → invoke `/claude-mesh:continue-plan-fresh-session` skill to run `/claude-mesh:mesh-design-review` in new session.
- "Остановиться и начать работу" → invoke `/claude-mesh:continue-plan-fresh-session` skill.

**The design doc edits this**: branch 1 switches to `/claude-mesh:design-review-fresh-session` (the new generator). Option labels unchanged.

---

## 3. mesh-review command (`commands/mesh-review.md`)

### Step 1 — `$CLAUDE_PLUGIN_ROOT`
Lines 34–42. The comment block explains exactly how it works:
> "CLAUDE_PLUGIN_ROOT is EMPTY as a shell VARIABLE here (Task 2.5, CC 2.1.156), but the harness substitutes the placeholder into this command's TEXT — inside bash fences too — before the Bash call, so the line below arrives as a literal path naming the ACTIVE plugin copy, including a `--plugin-dir <repo>` dev load. Fallback for harnesses that do not substitute: a VERSION-sorted glob — plain `find | head -1` is directory order and was observed picking a stale cached 0.4.0 over the installed 0.4.2."

```bash
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
```

### Steps 1-3 — reviewer selection
- **Step 1**: calls `get-flag has_codex`, `get-flag has_gemini`, `get-flag has_models`, `get-flag has_claude_models`, `list-models`, `list-claude-models`, `get-flag dispatch_model`, `get-defaults code_review`. rc-aware error handling.
- **Step 2 (Q1)**: AskUserQuestion multiSelect max 4 for reviewer types: claude (always), codex (if HAS_CODEX=1), gemini (if HAS_GEMINI=1), external models (if HAS_MODELS=1).
- **Step 2.4**: Claude-model selection (runs only if claude selected AND HAS_CLAUDE_MODELS=1). Paginated, 4 per page, with ★ markers for recommended.
- **Step 2.5 (Q1.5)**: Confirmation step.
- **Step 3**: Paginated ext-claude model selection (only if "external models" selected).
- **Step 3.5**: Final confirmation.

### Sync notes — mirrored between mesh-review and mesh-design-review
- **Iron Rules 3–8** (lines 303–313 of mesh-review): "rules 3–8 are mirrored in `skills/mesh-design-review/SKILL.md` (Iron Rules / Step 12)".
- **Step 5a watch loop** (lines 280–286, 287+): "points 1–6 are mirrored in `skills/mesh-design-review/SKILL.md` (Step 6) — in substance, not byte for byte, and four things are not mirrored at all." The four exceptions are enumerated:
  1. Path resolution differs by construction (CLAUDE_PLUGIN_ROOT substitution vs SKILL_BASE).
  2. Design review runs `verify-delegation.sh` inline BEFORE pinging; mesh-review pings on DONE.
  3. Dead run routing differs (Error Handling vs Step 6.0).
  4. Closing clause of point 6 differs (mesh-review hands to Step 6.0; design review records the loop scope).

---

## 4. config-loader.sh (`skills/shared/config-loader.sh`)

### Subcommands and exit codes
Usage string at line 980:
```
validate | data-dir | export <model-id> | get-flag <feature> | list-models |
list-claude-models | list-providers | get-defaults <category> | get-runtime |
get-codex | get-gemini
```

Exit codes:
- **rc=0**: success.
- **rc=1**: any validator/loader error (`die()` function). `load_or_die` also dies rc=1 for yaml syntax error, missing yq, missing jq, missing GNU coreutils on macOS. `cmd_get_flag` dies rc=1 for an unknown feature name.
- **rc=2**: specifically `load_or_die` when config.yaml is missing (line 110-113):
  > "iter-2 CONCERN-11: 'config not found' gets a DISTINCT exit code (2) so user-invoked commands like /do-plan can tolerate the genuinely-tolerable 'no config yet' case during first-run, while every other class of error (yaml malformed, env binaries missing, validator die) still fast-fails via the canonical die (rc=1)."
- **rc=2** also on usage (unknown subcommand, line 981).
- **rc=1** for `export` when token is still `REPLACE_ME` (line 697).
- **rc=1** for `get-flag has_claude_models` / `list-claude-models` / `get-defaults` when the `claude:` section is malformed (they call `validate_claude`).

### `export <model-id>`
- Exists. Takes a required `<model-id>` argument (dies if missing).
- **Refuses REPLACE_ME tokens** — at line 697:
  ```bash
  [ "$token" = "REPLACE_ME" ] && die "providers[$provider_id].token: still \"REPLACE_ME\" — edit $CONFIG_FILE with a real token for provider \"$provider_id\" before exporting"
  ```
- Output: the **path** to a mode-600 env file (NOT the exports themselves to stdout — secret hygiene).

### `list-claude-models`
- Exists (line 868-877). Emits one Claude model alias per line, in config order. NO `<id>|<label>` pair.
- Prints nothing (exit 0) when there is no catalog.

### `get-flag has_codex|has_gemini`
- Both exist (lines 799-808). Both emit "1" or "0" (NOT "true"/"false").
- **Bare-probe**: these do NOT validate their sections — `jq -e '.codex'` / `jq -e '.gemini'` is the whole check, so a malformed section reads as "absent" (0) rather than failing. Comment explicitly: "The bare-probe has_* cases above (has_codex / has_gemini / has_models / has_defaults_code_review) skip validation on purpose".
- **Exception**: `has_claude_models` DOES validate first (calls `validate_claude`), because it indexes into the section.

---

## 5. Prechecks (`skills/ext-claude-exec/`)

### `token-precheck.sh`
- **Exit codes**:
  - 0 = token appears valid (any non-401/403/000 response)
  - 5 = authentication failed (HTTP 401 or 403)
  - 6 = endpoint unreachable (curl error / HTTP 000)
- **Uses SKIP_TOKEN_PRECHECK**: Yes, at line 24:
  ```bash
  if [ "${SKIP_TOKEN_PRECHECK:-0}" = "1" ]; then
    echo "token-precheck: skipped (SKIP_TOKEN_PRECHECK=1)" >&2
    exit 0
  fi
  ```
- **curl usage**: `curl -sS -o "$BODY_FILE" -w "%{http_code}"` — uses `-sS` (silent with show-error), NOT `-sf`. Captures HTTP code via `-w`, then switch-cases on it.

### `ollama-precheck.sh`
- **Exit codes**:
  - 0 = daemon up and /api/tags reachable
  - 5 = auth/signin missing or expired
  - 6 = daemon unreachable after 3x2s retry
- **Does NOT use SKIP_TOKEN_PRECHECK**.
- **curl usage**: Uses `-sf` flag (silent + fail): `curl --max-time 2 -sf "$BASE_URL/" >/dev/null 2>&1` and `curl --max-time 5 -sf "$BASE_URL/api/tags" >/dev/null 2>&1`. Tests return status (0/1), not HTTP code.

The design document (section "Reuse, do not reimplement") plans to route providers through these prechecks via the provider `kind`: "providers are probed through the existing token-precheck.sh (exit 0 → OK, 5 → AUTH-FAILED, 6 → NO-NETWORK) and ollama-precheck.sh, routed by the provider kind exactly as ext-claude-exec routes it."

---

## 6. Existing tests style

Confirmed from two test files.

### `skills/shared/tests/test-config-loader.sh`
- **Style**: `set -u` at top. `TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"` to locate the script. `FIXTURES="$TESTS_DIR/fixtures"`.
- **Counters**: `FAIL=0; PASS=0` at top.
- **assert_* functions**:
  - `assert_exit` (desc, expected_rc, actual_rc)
  - `assert_stderr_contains` (desc, needle, stderr_file) — uses `grep -q --`
- **Fixture pattern**: `TDIR=$(mktemp -d)`; `cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"`; run under `CLAUDE_PLUGIN_DATA="$TDIR"`; cleanup with `rm -rf "$TDIR" "$ERR"`.
- **Summary**: `echo "=== Summary: $PASS passed, $FAIL failed ==="; [ "$FAIL" = "0" ]` at end.
- **Test naming**: `echo "=== Test 1: missing config file ==="`; descriptive titles.
- **51 tests**, covering every validator branch.

### `skills/shared/tests/test-verify-delegation.sh`
- **Style**: `set -u`, same TESTS_DIR pattern.
- **Counters**: `FAIL=0; PASS=0`.
- **assert_* functions**:
  - `assert_eq` (desc, expected, actual)
  - `assert_match` (desc, pattern, actual) — uses `case "$actual" in *"$pattern"*)`
- **Fixture pattern**: `TDIR=$(mktemp -d)`; `mk_run()` helper builds run dirs with attempt-1 subdirs.
- **`run()` helper**: `VERDICT=$(bash "$SCRIPT" "$@" 2>/dev/null); RC=$?;` — captures stdout and exit code.
- **28 tests**, covering REAL/FLIP/STALLED/BROKEN verdicts, run identity, session-id stamping.

**The design document explicitly plans the new test to follow this pattern**: "fixture `config.yaml` pinned via `export CLAUDE_PLUGIN_DATA=<tmpdir>` plus PATH shims for curl, git, codex, gemini."

---

## 7. do-plan Step 7 — current text

At `commands/do-plan.md` lines 204–206:
> "## Step 7 — End of plan
> If the plan reaches completion before STOP fires, follow `superpowers:subagent-driven-development` normally — final full-implementation review, `superpowers:finishing-a-development-branch`, and so on. No special handling needed."

**The design doc edits this**: replace with "After the final full-implementation review, suggest `/claude-mesh:code-review-fresh-session`. State plainly that inside a sandbox `superpowers:finishing-a-development-branch` cannot finish the job — push and PR creation need the network that is not there — so the branch is left for the operator to finish outside. Short paragraph; no behavioural change to the rest of `/do-plan`."

---

## 8. Pitfalls and collision search

### Existing `preflight` / `PREFLIGHT_` references
Only one hit in the entire repo, at `README.md` line 78:
> "A bash 4.2+ shell is also required (macOS system bash is 3.2). `brew install bash` provides this; ensure `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash` (Intel) appears in `$SHELL` or your terminal config. `config-loader.sh` and `ext-claude-exec` preflights detect Darwin and fail fast with these instructions if the setup is missing"

The word "preflights" here is prose describing `token-precheck.sh`/`ollama-precheck.sh`. No `PREFLIGHT_` env vars exist anywhere yet.

### Does `skills/shared/preflight-env.sh` exist?
**NO** — confirmed by `ls`:
```
preflight-env.sh does NOT exist
```
The file is planned by the design doc as a NEW artifact (`skills/shared/preflight-env.sh` in the "Artifacts" table).

### Other pitfalls
1. **The design doc plans the probe to be discovered by glob, never by `${CLAUDE_PLUGIN_ROOT}`** (Decision 2): the prompt would freeze the host's plugin path into a file executed on another machine. This is correct — `CLAUDE_PLUGIN_ROOT` is empty in skill Bash calls anyway, and is substituted only into *command files*.
2. **`config.yaml` in the sandbox may differ from the host's** (Decision 1): the generators intentionally do NOT read `config.yaml` so one prompt is correct in two environments.
3. **The prechecks use two different curl styles** (`-sS -w` vs `-sf`). The design doc must pick one convention for `preflight-env.sh` — likely `-sS -w "%{http_code}"` to get HTTP codes for the probe's SUMMARY.
4. **`SKIP_TOKEN_PRECHECK` must be unset** when the probe calls token-precheck (the design doc section "Secrets" explicitly notes: "The prechecks are invoked through `env -u SKIP_TOKEN_PRECHECK`").
5. **`export <model>` writes mode-600 files** containing tokens — the probe sources them in a subshell and must `trap ... EXIT` to delete them. The design doc pins this.
6. **The iteration-numbering rule must match exactly** — a generator that counts differently than Step 2 would produce an iter-N the skill then disagrees with.
7. **No existing file collides** with the planned `preflight-env.sh`, `design-review-fresh-session.md`, or `code-review-fresh-session.md`.
8. **Sync notes**: any edit to the Step 15 branch of mesh-design-review must be mirrored in mesh-review (which has its own analogous branch via the shared Iron Rules).
Хватит собирать информацию — у меня достаточно данных, чтобы написать ревью. Не буду ждать agent, его находки дополнят, но не изменят основную критику.

---

# Ревью дизайна и плана fresh-session review prompts

## Критические проблемы

Критических проблем, блокирующих реализацию, не обнаружено. Архитектура выдержана, решения согласованы с ограничениями среды, контракты precheck-ов используются корректно.

## Concerns

### 1. Фактический worst-case длительности probe — не 35 s, а ~55 s

Дизайн и план заявляют «five providers ≈ 35 s worst case». На деле `ollama-precheck.sh` имеет **встроенные** таймауты, не управляемые `PREFLIGHT_HTTP_TIMEOUT`:
- `ollama-precheck.sh` делает 3 попытки × 2 s `sleep` (daemon ping) + 5 s на `/api/tags` — итого **до 11 s на одного unreachable ollama-провайдера** (`skills/ext-claude-exec/ollama-precheck.sh:16-36`).
- `token-precheck.sh` использует только `PREFLIGHT_HTTP_TIMEOUT` (через 3-й аргумент, по умолчанию 30, в preflight передаётся 5) — до 5 s.

При двух unreachable ollama-провайдерах в конфиге счёт: `2 × 11 + 3 × 5 = 37 s`, и это ещё без `git ls-remote` (до 8 s). Заявленный «~35 s worst case» выполняется только если ollama-провайдеров не больше одного.

**Рекомендация:** либо (а) вынести retry-цилл ollama-precheck под управление `PREFLIGHT_HTTP_TIMEOUT` (это правка в существующем файле, не в этом PR), либо (б) явно задокументировать в design §5 / preflight's header-comment, что worst-case считается по формуле `N_ollama × 11 + N_other × HTTP_TIMEOUT + GIT_TIMEOUT`, и привести верхнюю границу для типичного конфига.

### 2. Статус `claude-models MISSING` — нормальное поведение под видом проблемы

Когда в `config.yaml` нет секции `claude.models`, probe печатает:
```
claude-models    MISSING      no claude.models catalog — one claude reviewer on the dispatch model
```

Это **штатная ситуация** — до появления фичи four-model claude reviewers именно так работал весь репозиторий. Статус `MISSING` в закрытом наборе `{OK, MISSING, NO-NETWORK, AUTH-FAILED, INVALID, SKIPPED, UNKNOWN}` зарезервирован под «инструмент/секция отсутствует», и формально тут всё корректно. Но читатель таблицы, видящий `MISSING` рядом с `codex MISSING` и `gemini MISSING`, может решить, что всё сломано, и отказаться от `claude`-ревьювера.

**Рекомендация:** рассмотреть альтернативу: `OK` c detail «no catalog, one reviewer on dispatch model» или новый статус `PARTIAL` (если готов расширять закрытый набор). Как минимум — переформулировать detail так, чтобы первое слово было не отрицанием: `claude-models  OK  single reviewer on dispatch model (no claude.models catalog)`.

### 3. Деградация для новых команд в старом sandbox не описана

Design Decision 6 описывает деградацию, когда в sandbox нет `preflight-env.sh`. Но есть симметричный риск: в Step 15 mesh-design-review (после редактирования в Task 8) сессия вызывает `design-review-fresh-session`. Если в sandbox стоит **старый плагин**, у него нет этого command-файла. `Skill("design-review-fresh-session")` вернёт «skill not found», и пользователь в sandbox зайдёт в тупик — у него есть iter-файл, но нет пути к следующей итерации.

Это не covered ни Decision 6, ни Error Handling table («situation: preflight-env.sh not found» покрыта, «command not found» — нет).

**Рекомендация:** добавить в дизайн ещё одну деградацию:
> Если `design-review-fresh-session` отсутствует, mesh-design-review Step 15 выводит предупреждение и откатывается к старому поведению — `continue-plan-fresh-session` с инструкцией вручную запустить mesh-design-review в новой сессии. Оператор видит, что что-то не так, но цикл не обрывается.

Либо, минимально, упомянуть этот сценарий в Assumptions and risks явно.

### 4. Discovery-блок промпта жёстко привязан к `$HOME/.claude/plugins`

```bash
PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' ...)"
```

Это работает в стандартной установке Claude Code. Но если sandbox использует `--plugin-dir <repo>` (dev load, который `commands/mesh-review.md` Step 1 явно упоминает как поддерживаемый сценарий), preflight-env.sh лежит в `<repo>/skills/shared/`, не в `$HOME/.claude/plugins/`. Discovery вернёт пустую строку, и промпт пойдёт по ветке «script not found — treat claude as the only available reviewer».

Сам `mesh-review.md` Step 1 решает это через `${CLAUDE_PLUGIN_ROOT}` (подставляемый хarness-ом) с fallback-ом на `find`. Но **generated prompt не имеет harness-substitution** — он выполняется в свежей сессии как paste.

**Рекомендация:** discovery-блок должен сначала попробовать `${CLAUDE_PLUGIN_ROOT:-}` (если хarness новой сессии его подставит), затем `find`. Либо явно задокументировать, что `--plugin-dir` load в sandbox не поддерживается fresh-session prompts.

### 5. `cli_row` и precheck-и используют разный curl

В Task 3 Step 3 Block A вводится `PREFLIGHT_CURL_BIN` и `probe_http`, использующие `$CURL_BIN`. Но в Task 2 Step 3 `probe_provider` вызывает `token-precheck.sh` / `ollama-precheck.sh` напрямую — те находят `curl` через `PATH`, игнорируя `PREFLIGHT_CURL_BIN`.

В плане это уже явно сказано («Note for the implementer: the two prechecks are reused verbatim… Do not 'simplify' either away»), так что баг не проектировочный, а документационный: в финальном `preflight-env.sh` должен быть комментарий, что `PREFLIGHT_CURL_BIN` governs только `probe_http` и `cli_row`, а заёмные precheck-и берут `curl` c `PATH`. Иначе следующий читатель кода попытается «исправить» очевидную непоследовательность.

## Suggestions

### 1. Прогресс-индикатор в probe

35–55 s без вывода выглядят как hang, особенно в свежей сессии, которая ещё и не знает, что preflight — это надолго. Рекомендую добавить в `probe_provider()` и `probe_http()` одну строку на stderr перед каждым запросом:
```bash
echo "  probing $PROV ($URL)…" >&2
```
Это не ломает контракт «stdout — только таблица», потому что stderr и так игнорируется (в test assertion и в generated prompt table). Оператор же видит, что скрипт живой.

### 2. Усилить `claude-models` detail

Текущий detail: `no claude.models catalog — one claude reviewer on the dispatch model`. Рекомендую:
```
claude-models    OK    single reviewer (dispatch model); no catalog configured
```
Статус `OK` вместо `MISSING` точнее передаёт семантику: это не «отсутствует», а «работает в fallback-режиме».

### 3. Task 5 (RED baseline) — явная смета бюджета

Task 5 требует 3 baseline + 10 micro-test (2 варианта × 5 повторений) = 13 subagent-запусков. При цене ~$1-3 за запуск это $13-39 на валидацию wording. Если бюджет ограничен, стоит явно разрешить пропуск micro-test при условии, что baseline (3 runs) пройден, и зафиксировать это в acceptance criteria.

Альтернатива: использовать более дешёвый `haiku`-модель для micro-test — задача не требует сильных моделей, нужно только проверить, что gate binding работает.

### 4. Task 6 Step 3 — leak scan должен проверять и `defaults.*` пресеты

Текущий leak scan проверяет model ids из `list-models`. Но `get-defaults design_review` возвращает JSON с `.builtin`, `.claude_models`, `.models` — пресеты тоже leak-кандидаты. Если генератор случайно вставит `"codex"` в промпт как recommended reviewer, это нарушение Decision 1.

Расширить скрипт:
```bash
"$LOADER" get-defaults design_review 2>/dev/null | jq -r '.builtin[], .claude_models[], .models[].id' | while read -r id; do
    [ -n "$id" ] && grep -q -- "$id" "$P" && echo "LEAK: $id"
done
```

### 5. Task 8 Step 2 — усилить diff-ограничение

Текущая проверка:
```bash
git diff skills/mesh-design-review/SKILL.md | grep -c '^[-+]'
```
не проверяет, что изменения в пределах Step 15. Рекомендую добавить:
```bash
git diff skills/mesh-design-review/SKILL.md | grep '^@@' | grep -v 'Step 15' && echo "DIFF OUTSIDE STEP 15"
```

### 6. Неочевидная инвариантность итерационного цикла

В iter 2+ review-сессия в sandbox должна уметь вызвать `design-review-fresh-session` для iter 3. Это работает, если в sandbox свежий плагин (team-shared working copy). Но: если оператор обновляет плагин на хосте, а sandbox использует shared folder, то обновление автоматически видно в sandbox. Это стоит явно зафиксировать в design assumptions — это ключевое свойство, на котором держится весь механизм.

### 7. `probe_provider()` subshell и `set -u`

```bash
rc="$(
    . "$envf"
    case "${CLAUDE_MESH_PROVIDER_KIND:-anthropic-api}" in
        ...
    esac
    echo "$?"
)"
```

Если `. "$envf"` по какой-то причине не установит `ANTHROPIC_BASE_URL`, а precheck попытается её прочитать — в `set -u` subshell умрёт до `echo "$?"`, и `rc` станет пустой строкой. `case "$rc"` попадёт в `*` → `UNKNOWN|precheck exited `. Это безопасная деградация, но `UNKNOWN` с пустым detail — неинформативно. Рекомендую:
```bash
*) echo "UNKNOWN|precheck exited $rc" ;;
```
…что уже есть. OK, но добавить stderr-трассировку внутри subshell для отладки.

## Questions

1. **Iter 2+ и dev load:** если sandbox использует `--plugin-dir <repo>` (а не стандартный install), discovery-блок не найдёт `preflight-env.sh`. Это intentional limitation или стоит добавить `${CLAUDE_PLUGIN_ROOT:-}` fallback?

2. **Code-review-fresh-session и `finishing-a-development-branch`:** в do-plan Step 7 сказано, что finishing не работает в sandbox. Но если code-review-fresh-session вызван НЕ в sandbox (например, на host-машине после реализации), то finishing должен работать. Промпт как-то различает эти случаи, или оператор сам решает?

3. **`claude-models` и `defaults.*` пресеты:** когда в config.yaml есть `defaults.design_review.builtin = [claude]`, но нет `claude.models`, — mesh-design-review Step 5.1 expand `claude` в "one reviewer on dispatch model". Пробе это сообщает как `claude-models MISSING`. Не лучше ли, чтобы probe читал `defaults` и в этом случае печатал `OK  defaults-only, one reviewer`?

4. **SUMMARY unavailable:** при `codex MISSING` (нет секции в config) SUMMARY печатает `codex (MISSING)`. Если же у оператора нет ни одного ext-провайдера, ни codex, ни gemini, SUMMARY available содержит только `claude`. Это корректно, но стоит проверить, что mesh-design-review / mesh-review selection UI не сломается, когда SUMMARY available содержит только одно значение — не будет ли оно требовать multiSelect?

## Итог

Дизайн и план в целом крепкие. Основные достоинства:
- Чистое разделение ответственности (генераторы не знают о config, probe — единственный источник правды о среде).
- Переиспользование существующих контрактов (`token-precheck.sh`, `config-loader.sh`, `watch-runs.sh`-style exit-0).
- TDD-подход с фикстурами и PATH-shims — соответствует house style.

Основные риски:
- Недооценён worst-case duration probe при нескольких unreachable ollama-провайдерах (Concern 1).
- Не покрыта деградация для свежих команд в старом sandbox (Concern 3).
- `--plugin-dir` dev load не поддерживается discovery-блоком (Concern 4).

Перед реализацией стоит устранить Concern 3 и 4 — добавить в дизайн явные деградации или явные ограничения. Остальное — на усмотрение автора.
Ревью уже отправлено выше. Agent-исследователь нашёл несколько дополнительных деталей, которые стоит добавить к уже отправленной критике. Проверю одну важную находку — действительно ли в `mesh-review` есть аналог Step 15, который тоже нужно обновить.


Проверил: агент ошибся — в `commands/mesh-review.md` нет аналогичной ветки "Новая итерация", синхронизация не требуется. Code review не итеративный в том же смысле, что design review, и точка входа для `code-review-fresh-session` одна — `do-plan` Step 7, что и зафиксировано в плане (Task 8). Это правильно.

Ревью выше полно и не требует дополнений. Если коротко резюмировать главные точки для автора:

**Что стоит поправить до реализации:**
- Concern 3 — добавить деградацию для случая, когда в sandbox старый плагин и нет новых команд. Это симметрично Decision 6, но про команды, а не про preflight.
- Concern 4 — discovery-блок в промпте не поддерживает `--plugin-dir` dev load. Либо добавить `${CLAUDE_PLUGIN_ROOT:-}` fallback, либо явно задокументировать ограничение.

**Что стоит обсудить:**
- Concern 1 — реальный worst-case probe при нескольких ollama-провайдерах.
- Concern 2 — `claude-models MISSING` как нормальное поведение.

**Опциональные улучшения:**
- Suggestions 1, 3, 4, 5 — прогресс-индикатор, смета бюджета для Task 5, расширенный leak scan, diff-ограничение в Task 8.

**Вопросы, на которые стоит ответить:**
- Вопрос 1 — поддержка `--plugin-dir`.
- Вопрос 2 — code-review-fresh-session вне sandbox.
- Вопрос 3 — должен ли probe читать `defaults.*` для различения fallback-режима.

> Примечание executor'а (alibaba/qwen): вердикт ревьюера — «Критических проблем, блокирующих реализацию, не обнаружено». Suggestion 7 ревьюер сам снял как самоотменяющийся; ложную тревогу его Explore-субагента про зеркалирование Step 15 в commands/mesh-review.md ревьюер сам проверил и опроверг.

---

## ext-claude-executor (deepseek/v4-pro)

Теперь у меня есть полное понимание обоих документов и релевантных частей кодовой базы. Напишу критический разбор.

---

# Рецензия: Fresh-session review prompts — design & plan

## Critical Issues

### 1. `config-loader.sh`: непроверенные зависимости от ещё не существующих subcommands

План (Task 1, Interfaces) говорит, что probe «consumes: `config-loader.sh` subcommands `list-claude-models`, `get-flag has_claude_models`». Но план нигде не проверяет, существуют ли эти subcommands в текущей версии `config-loader.sh`. Если они были добавлены в PR #9 (watch-loop-stall-detection) — они есть. Если нет — Task 1 упадёт на первом же прогоне, потому что `list-claude-models` вызывается в skeleton'е probe безусловно при `CONFIG_STATUS=OK`. План должен содержать precondition-check: либо убедиться, что subcommands есть, либо добавить их в scope.

Я проверил: PR #9 (`e640ef1`) действительно добавил `claude.models` в config-loader. Но факт, что план этого не проверяет — архитектурная хрупкость. Любой будущий читатель плана не обязан знать историю мержей.

### 2. Последовательный probe: 35 секунд — неоправданная цена

Design Decision 5: «probes are sequential — five providers is a ~35 s worst case.» Но bash позволяет параллелить:

```bash
probe_provider "$mid" &  # фоном
# собрать pid'ы, сделать wait, разобрать результаты
```

Пять провайдеров → худший случай ~7 секунд (самый медленный), а не ~35. Разница между «подождать 7 секунд» и «подождать 35 секунд» — это разница между «прочитал таблицу и сразу выбрал» и «отвлёкся, забыл, потерял контекст».

Дизайн аргументирует: «That is the price of one check, against six reviewers hanging for minutes.» Но это ложная дихотомия — параллельный probe даёт ту же защиту за 1/5 времени. Никакого дополнительного риска: каждый probe уже изолирован в subshell, network-таймауты индивидуальны.

**Это не просто оптимизация.** 35 секунд в UI, который просят прочитать перед выбором ревьюеров — это точка, где оператор уходит. Параллельный probe сокращает worst-case до приемлемого.

### 3. `codex`/`gemini`: статус `OK` для heuristic probe вводит в заблуждение

Probe codex/gemini тестирует `https://api.openai.com/v1/models` и `https://generativelanguage.googleapis.com/`. Статус — `OK`, detail содержит `(heuristic: not an auth check)`.

Проблема: `OK` в столбце статуса читается как «можно использовать». Человек сканирует таблицу вертикально по статусам — детали читают потом, если вообще читают. Codex CLI может использовать Azure endpoint, прокси, или вообще другую auth-схему — и тогда `OK` означает только «есть HTTP-маршрут до публичного интернета», а не «codex заработает».

**Рекомендация:** заменить `OK` на `LIKELY` для heuristic-проб (codex/gemini/gh/glab). Закрытый набор статусов позволяет это без нарушения контракта — `LIKELY` нигде не зарезервирован как «нельзя использовать». Это честнее: probe не гарантирует работу CLI, и статус не должен притворяться, что гарантирует.

### 4. `PREFLIGHT` discovery block: `exit 1` при отсутствии скрипта противоречит «every verdict exits 0»

Design Decision 5: **«Every verdict — including 'everything is unreachable' — exits 0.»** Контракт: не-ноль = probe сломан.

Но сгенерированный промпт содержит блок:

```bash
[ -x "$PF" ] || { echo "preflight-env.sh not found..." >&2; exit 1; }
```

Этот `exit 1` — не probe, а wrapper. Но читающая сессия видит `exit 1` в блоке под заголовком `## PREFLIGHT — run this first`. Если probe не найден, сессия получает «exited with code 1» и **не знает**, сломан ли probe или это ожидаемая деградация. Промпт инструктирует «if the script is not found, say so, treat claude as the only available reviewer» — но к этому моменту сессия уже увидела non-zero exit и может начать «чинить» probe вместо того чтобы следовать инструкции.

**Исправление:** `exit 0` после диагностического сообщения. Или печатать таблицу-degradation вручную (только `builtin-claude OK`, остальное `MISSING`). Контракт «всегда exit 0» должен соблюдаться и здесь, иначе это баг, маскирующийся под деградацию.

### 5. `CONTEXT` для итерации 1: генератор не имеет доступа к brainstorming-контексту

Design tail для `design-review-fresh-session` говорит: «Iteration 1: CONTEXT is the brainstorming residue — decisions, rejected alternatives, constraints.» План (Task 6) говорит: «Collect the context that is not in the documents. For iteration 1: decisions and why, alternatives rejected and why, known constraints, sharp edges.»

Но `commands/design-review-fresh-session.md` — это Claude Code command file. Он выполняется в сессии, где **уже закончился design review итерации 1**. Brainstorming-контекст этой сессии — это её transcript, к которому command file не имеет программного доступа. Генератор полагается на то, что модель «помнит» обсуждение — но:
- В fresh session после `/claude-mesh:mesh-design-review` контекст может быть около 200k+ токенов, и brainstorming-часть уже вытеснена из context window.
- Если генератор запущен отдельно (не из mesh-design-review), brainstorming-контекста может не быть вовсе.

**Это архитектурный разрыв между намерением дизайна и возможностями реализации.** Генератор должен либо явно запрашивать этот контекст у пользователя («What decisions did you make during brainstorming?»), либо признать, что CONTEXT для итерации 1 будет неполным.

## Concerns

### 6. `sort -V` в discovery block: требование GNU, не проверяется в песочнице

Сгенерированный промпт содержит `find ... | sort -V | tail -1`. `sort -V` — GNU-специфичный флаг. Если песочница — macOS или Alpine Linux (где sort — busybox), команда молча падает: busybox sort игнорирует `-V` и сортирует лексикографически, а BSD sort падает с ошибкой. В обоих случаях `PF` либо пуст, либо указывает не на ту версию.

Кодовая база уже использует `sort -V` в `mesh-review.md` и `do-plan.md` с комментарием почему. Но там это fallback для машин разработчика (где GNU sort есть). Здесь это **основной путь в песочнице**, где никто не гарантирует GNU userland.

**Смягчение:** `2>/dev/null` на `sort` скроет stderr; `tail -1` на пустом вводе даст пустую строку; `[ -x "$PF" ]` упадёт — и сработает деградация. Так что это не Critical (отказ обработан), но оператор получит «preflight-env.sh not found» вместо работающего probe, потому что `sort` не справился, а не потому что скрипта нет. Диагностика вводит в заблуждение.

### 7. Два источника `curl`: `PREFLIGHT_CURL_BIN` для probe и `PATH` для precheck'ов

Task 2 содержит явное предупреждение: «The two prechecks are reused verbatim and they find curl on PATH, which is why the test puts the shim on PATH AND passes PREFLIGHT_CURL_BIN. Do not 'simplify' either away.»

Это архитектурно нечисто. Один и тот же концепт (curl) управляется двумя разными механизмами. Если кто-то в будущем «почистит» дублирование (убрав `PATH` shim, потому что «PREFLIGHT_CURL_BIN же есть»), precheck'и сломаются. Предупреждение в плане — это не защита, а записка на скотче.

**Рекомендация:** обернуть `token-precheck.sh` и `ollama-precheck.sh` так, чтобы они тоже принимали `PREFLIGHT_CURL_BIN`. Или задокументировать это как технический долг с явным тикетом.

### 8. `valid-full.yaml` не содержит `claude.models` — тест Task 1 зависит от стороннего фикстура

Task 1 тест проверяет: `run_probe valid-full.yaml` → `claude-models MISSING`. Но `valid-full.yaml` — это фикстура, созданная для других тестов. Если кто-то добавит в него `claude.models`, этот тест молча сломается. Правильное решение — создать отдельный фикстуру `valid-no-claude-models.yaml` для этого теста, как это уже сделано для `valid-claude-models.yaml`.

## Suggestions

### 9. Предварительная валидация фикстур в CI

План должен включать шаг: `config-loader.sh validate` на всех фикстурах, которые использует probe. Если фикстура `valid-full.yaml` валидна (она должна быть — она используется другими тестами), это просто дополнительная проверка. Но если probe добавит новую фикстуру, которая невалидна по мнению loader'а, тесты probe пройдут (probe обрабатывает INVALID), а настоящая причина — битый фикстур — будет скрыта.

### 10. `ollama-precheck.sh`: нет `set -e`

`token-precheck.sh` имеет `set -euo pipefail`. `ollama-precheck.sh` имеет только `set -u`. Если `curl` в `ollama-precheck.sh` упадёт до проверки exit code (например, `curl` not found), скрипт продолжит выполнение и вернёт неверный статус. Это существующий баг в кодовой базе, не созданный этим планом, но probe теперь зависит от корректности `ollama-precheck.sh`. План должен либо исправить это, либо задокументировать как known risk.

### 11. `provider:*` rows при `CONFIG_STATUS=INVALID`: `SKIPPED` вместо диагностики

Когда config INVALID, probe печатает `provider SKIPPED "no usable config — providers not probed"`. ОК. Но если config был валиден час назад, а стал INVALID сейчас (например, кто-то испортил YAML в shared folder), единственная диагностика — это строка `config INVALID <ошибка>`. Оператор может не заметить её в середине таблицы.

**Предложение:** `SUMMARY unavailable` должен включать причину пропуска провайдеров, когда config INVALID. Сейчас он просто молчит о провайдерах.

### 12. Тесты Task 5: 13+ subagent'ов для baseline — дорого и недетерминировано

Три baseline-прогона + 5 control + 5 candidate = 13 subagent-диспатчей. Каждый нужно прочитать «by hand». При модели с thinking это сотни тысяч токенов на просмотр. План не оценивает стоимость.

Более практичный подход: один baseline-прогон, затем итеративное ужесточение формулировки с одним candidate-прогоном за итерацию. План уже допускает это: «tighten the wording and re-run before moving on». Но требует 5+5 как baseline, а не как максимум. Стоит инвертировать: начинать с 1+1, добавлять повторения только если variance высокая.

### 13. Название `SUMMARY available: claude` может ввести в заблуждение

Когда нет config, `SUMMARY available: claude`. Но `claude` в этой строке — это НЕ model id. Это имя built-in ревьюера из selection UI. А `SUMMARY available: zai/glm` в той же строке — это model id. Семантическая перегрузка: `claude` в SUMMARY значит «built-in claude reviewer всегда доступен», а `zai/glm` значит «этот конкретный model id из конфига прошёл probe».

Когда читающая сессия передаёт эти значения в selection UI, она должна понимать разницу. Промпт говорит «select only reviewers the preflight marked OK» — но не объясняет, что `claude` в SUMMARY≠`zai/glm`. Это может привести к тому, что сессия попытается использовать `claude` как model id для ext-claude.

**Предложение:** `SUMMARY available: built-in:claude, zai/glm, ollama/kimi` — префикс явно разделяет категории.

## Questions

1. **Существуют ли `config-loader.sh list-claude-models` и `get-flag has_claude_models` в текущем состоянии ветки?** План должен это проверять явно.

2. **Было ли рассмотрено параллельное выполнение provider probes?** 35s → 7s — это разница между «приемлемо» и «оператор ушёл».

3. **Как именно генератор получает «decisions, rejected alternatives, constraints» для CONTEXT итерации 1?** Из transcript'а сессии? Из ответа пользователя? Из отдельного файла? Дизайн говорит «Collect the context that is not in the documents» но не указывает механизм.

4. **Что если `config-loader.sh` в песочнице сам зависит от инструментов, которых там нет?** Например, `yq` (Python) или `jq`. Probe сейчас требует `config-loader.sh` для работы — если loader падает потому что нет `yq`, probe сообщит `config MISSING (config-loader.sh not found)` или `INVALID`, а настоящая причина — отсутствующий runtime dependency. Стоит ли probe проверять наличие `yq`/`jq` и сообщать об этом?

5. **Почему `ollama-precheck.sh` без `set -e`?** Это выглядит как баг, и probe теперь наследует его поведение. План должен либо исправить, либо явно исключить из scope.

---

**Итог:** дизайн систематичен и хорошо проработан в части degradation-сценариев и контрактов (exit 0, закрытый набор статусов, «never read config.yaml»). Архитектурные решения 1–6 обоснованы. Но три проблемы требуют обязательного исправления до реализации: (1) последовательный probe вместо параллельного при цене 35s, (2) `exit 1` в PREFLIGHT wrapper'е, нарушающий контракт «every verdict exits 0», (3) `OK` вместо `LIKELY` для heuristic-проб, вводящий в заблуждение. И один архитектурный разрыв — CONTEXT для итерации 1 — требует уточнения механизма.

---

## ext-claude-executor (ollama/kimi)

Я прочитал design- и plan-документы, а также связанные command- и skill-файлы (`mesh-design-review/SKILL.md`, `do-plan.md`, `mesh-review.md`, `token-precheck.sh`, `ollama-precheck.sh`, `config-loader.sh`, fixtures). Ниже — критический разбор.

---

### Critical Issues

1. **Несоответствие между graceful degradation для `config MISSING/INVALID` и реальным поведением `mesh-design-review` / `mesh-review`.**
В design decision 6 и в сгенерированном промпте заявлено, что при отсутствующем или невалидном `config.yaml` можно продолжить только с встроенным `claude`. Но `skills/mesh-design-review/SKILL.md:224-230` при `get-flag` rc=1 выводит ошибку и останавливается, а при rc=2 — печатает hint и выходит; она не падает до кадра «выберите только claude». То же самое в `commands/mesh-review.md:48-55`. Таким образом, `claude` как reviewer не требует секции, но сама оркестрация review-скилла без валидного `config.yaml` не запускается.
Сгенерированный промпт должен явно различать: если `config` в таблице `OK` — можно вызывать review-скилл с доступными reviewerами; если `MISSING` / `INVALID` — **не вызывать** скилл, а остановиться и попросить пользователя исправить конфиг. Сейчас этого нет, и рискуем получить сессию, которая по таблице видит «claude available», вызывает `/claude-mesh:mesh-design-review`, и тут же ударяется в ошибку конфига.

2. **Противоречие между `exit 1` в discovery-блоке и заявленным graceful degradation.**
В `docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md:161-164` и в plan Task 6 (`docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:933-936`) bash-блок выходит с `exit 1`, если `preflight-env.sh` не найден. Но design decision 6 требует: сессия должна «report it, treat only `claude` as available, ask whether to proceed». `exit 1` в Bash-tool трактуется как сбой инструмента, а не как «в песочнице старая версия плагина». Нужно либо убрать `exit 1` и печатать структурированную строку таблицы (`preflight-env.sh MISSING not installed here`) с `exit 0`, либо чётко разделить «не найден» и «проба не удалась».

3. **Некорректная формулировка «via the Skill tool» для command-файлов.**
Plan Task 8 Step 1 (`docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:1230-1233`) предлагает заменить действие Step 15 на «Execute `/claude-mesh:design-review-fresh-session` via the Skill tool». Но `commands/design-review-fresh-session.md` и `commands/code-review-fresh-session.md` — это slash-команды, а не skills. Skill tool вызывает skills. Существующий Step 15 (`skills/mesh-design-review/SKILL.md:785`) содержит ту же ошибку для `continue-plan-fresh-session`, но новый план её повторяет. Нужно сказать «invoke the slash command» или «run `/claude-mesh:design-review-fresh-session`».

---

### Concerns

1. **Интерактивный UI `mesh-design-review` не позволяет агенту «выбрать только OK».**
Промпт говорит: «select only reviewers the preflight marked available». Но в интерактивном режиме `mesh-design-review` Step 5.2/5.3 используется `AskUserQuestion`, где выбор делает пользователь, а не агент. Агент может только подсказать. Если пользователь ошибётся и выберет `codex` со статусом `NO-NETWORK`, review зависнет на минуты. Стоит добавить в промпт инструкцию агенту: при появлении UI явно перечислить доступные варианты и предупредить пользователя; при наличии `default` preset и всех его reviewerах OK — использовать `/claude-mesh:mesh-design-review default`.

2. **Хьюристика `codex` / `gemini` может ввести в заблуждение.**
Probe проверяет публичные endpoint'ы, но не auth и не то, куда смотрит CLI. В design это признано риском, но в сгенерированном промпте строка «select only reviewers the preflight marked OK» читается как гарантия. Стоит добавить напоминание: OK здесь — это «binary на PATH + endpoint отвечает», не «CLI авторизован».

3. **RED baseline и GREEN тест используют subagent, а не настоящую fresh Claude Code session.**
Plan Task 5 Step 2 (`docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:780-793`) запускает `general-purpose` subagent. Целевая среда — fresh Claude Code session (новый transcript). Поведение субагента и главной сессии может различаться: субагент более склонен «выполнить задачу» и начать править. Это занижает качество baseline и может переоценить эффективность `DO NOT` блока. Done criteria тоже говорит «fresh subagent» вместо «fresh session». Если есть возможность запустить изолированную сессию — стоит так и тестировать.

4. **`ollama-precheck.sh` и `token-precheck.sh` не уважают `PREFLIGHT_CURL_BIN`.**
Plan Task 2 Step 3 note (`docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:421-424`) это признаёт. В design decision говорится, что `PREFLIGHT_CURL_BIN` нужен для «oddly-installed curl», но для провайдерских precheck'ов он не работает — там curl берётся с PATH. Это противоречит заявленной цели. Либо пробрасывать переменную в prechecks, либо честно сказать, что для них нужен curl на PATH.

5. **Worst-case время пробы занижено.**
`docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md:287-288` пишет «five providers ≈ 35 s worst case». Но `ollama-precheck.sh` делает 3×2s retry на `/` и ещё 5s на `/api/tags`, т.е. до 11s. Даже без учёта повторов получается больше 35s. Лучше поправить оценку или сделать `ollama-precheck.sh` параметризуемым по таймауту.

6. **`PROBED` accumulator в `preflight-env.sh` хрупок к подстрокам.**
Plan Task 4 (`docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md:716-725`) использует `case "$PROBED" in *"|$PROV="*)`. Благодаря `=`-delimiter и валидации provider id (`[a-z0-9-]+`) ложного совпадения быть не должно, но формат `|$PROV=STATUS|` всё же менее надёжен, чем bash 4 associative array. Проект требует bash 4+, поэтому `declare -A PROBED_STATUS` повысила бы читаемость и устранила риск.

7. **Нет стратегии для повторных probe-запусков.**
Если review-скилл перезапускается в той же сессии, preflight придётся выполнять заново (≈35s). Это не ошибка, но worth noting: кеширование результатов probe внутри сессии не предусмотрено.

---

### Suggestions

1. **Добавить в сгенерированный промпт правило для статуса `config`:** если `config` не `OK`, не вызывать `mesh-design-review`/`mesh-review`, а остановиться и попросить пользователя исправить/создать `config.yaml` в sandbox. Только при `config OK` + доступных reviewerах переходить к review.

2. **Убрать `exit 1` из discovery-блока** или заменить на структурированную строку таблицы (`preflight-env.sh MISSING not installed here`) с `exit 0`, чтобы агент интерпретировал это как verdict, а не как сбой инструмента.

3. **Исправить механизм вызова в Step 15:** заменить «via the Skill tool» на корректное описание invocation slash-команды. Заодно можно исправить и существующую ошибку для `continue-plan-fresh-session`.

4. **Добавить в `DO NOT` / `ENVIRONMENT` блок явный запрет на `git push` и `gh pr create`**, а не только на «push / open PR/MR». В sandbox git remote unreachable, но агент может попытаться запушать локально, если формулировка не конкретна.

5. **Параметризовать `ollama-precheck.sh` по таймауту** (например, через env var `OLLAMA_PRECHECK_TIMEOUT`) и пробрасывать `PREFLIGHT_CURL_BIN` в `token-precheck.sh` / `ollama-precheck.sh`, чтобы соответствовать design claim.

6. **Для RED/GREEN тестов зафиксировать модель/тип субагента** и явно отметить, что результаты — прокси для fresh session. Если есть возможность запускать изолированную Claude Code session, использовать её.

7. **Добавить в промпт footnote о хьюристике `codex`/`gemini`** и пояснить, что в интерактивном UI агент должен помочь пользователю выбрать только OK-варианты.

---

### Questions

1. Как планируется обрабатывать случай, когда `config.yaml` в песочнице валиден, но в нём нет ни `models`, ни `codex`, ни `gemini`, только встроенный `claude`? В этом сценарии `mesh-design-review` запустится и покажет UI только с `claude` — это корректно?

2. В `code-review-fresh-session` git range резолвится через `origin/HEAD` → `master`. Почему fallback chain не включает `main`, который сейчас распространён? Shallow clone в sandbox может не иметь `origin/HEAD`.

3. RED baseline и GREEN планируются на `general-purpose` subagent. Есть ли техническая возможность запускать эти тесты в отдельной Claude Code session (новый transcript), чтобы валидировать именно target behavior?

4. Планируется ли в будущем фильтровать selection UI `mesh-design-review` / `mesh-review` по результатам preflight, или сознательно оставляем ручной cross-reference на операторе?

5. Почему `preflight-env.sh` использует line-based accumulator `PROBED` вместо `declare -A`, если проект требует bash 4+? Есть ли причина, кроме совместимости с coding style других shared-скриптов?

> Примечание executor'а (ollama/kimi): Critical 1 и 2 проверены по коду и подтверждаются; Critical 3 («via the Skill tool» некорректно для command-файлов) — ЛОЖНОЕ СРАБАТЫВАНИЕ, command-файлы вызываются через Skill tool в текущем Claude Code. Concern 5 подтверждён и недооценён (до ~15 s на ollama-провайдера). Question 2 уже отвечен в коде (ext-claude-code-review, iter-2 CONCERN-9).

---

## ext-claude-executor (ollama/minimax)

Понял — это review, а не реализация; task tracking тут излишен. Финализирую обзор.

# Ревью дизайна и плана fresh-session review prompts

## Critical Issues

### 1. Конфликт между решением «fresh session => review» и существующим поведением `continue-plan-fresh-session`

В `skills/mesh-design-review/SKILL.md:785` сейчас оба варианта в Step 15 — "Новая итерация" и "Остановиться и начать работу" — маршрутизируются в `continue-plan-fresh-session` с разными инструкциями. План (Task 8, Step 1) корректно отделяет эти ветки, но само дизайн-решение в `decisions` обосновывает только то, что новая ветка уходит в `design-review-fresh-session`, а вторая остаётся в `continue-plan-fresh-session`. Однако:

- В текущей `mesh-design-review` Step 15 "Новая итерация (fresh session)" на самом деле и есть ветка, которая **запускает ещё одну итерацию ревью в свежей сессии**. То, что план заменяет её на `design-review-fresh-session` — правильно, но описание в Step 15 не обновляет текст самой опции — оно остаётся в виде **description** внутри `AskUserQuestion`, а это значит, что пользователь увидит "Сгенерировать prompt для запуска следующей итерации review в новой сессии" — этот текст останется корректным.
- Однако план не упоминает, что при выборе "Новая итерация" текущее поведение `continue-plan-fresh-session` (которое, согласно его названию, про *продолжение плана*) плохо подходило для запуска review-итерации — то есть старая маршрутизация была *ошибкой*, и мы её молча исправляем. Стоило бы явно зафиксировать в дизайне: "Step 15 'Новая итерация' historically invoked `continue-plan-fresh-session`; this was a UX bug — the prompt it generated was for implementing, not reviewing — and the design fixes it". Без этого контекста ревьюер будущего PR увидит изменение маршрута без обоснования.

### 2. Катастрофический failure mode Task 5: pre-test может вернуть GREEN, но gate не работает на самом деле

Task 5 ("RED baseline and the wording micro-test") обещает установить истину о том, что `DO NOT`-блок связывает поведение сессии. Но сам по себе wording-micro-test — 5 повторений с subagent — даёт очень слабую статистическую гарантию. Хуже того: micro-test запускается **на тех же subagent-инстансах**, что и план, а Task 6 Step 4 запускает ещё один GREEN-тест "на свежем subagent". Это два разных теста, которые оба берут на веру, что subagent честно следует инструкциям.

Конкретная уязвимость: **fresh session, получившая prompt с gate-блоком, всё равно может проигнорировать `## DO NOT` и начать редактировать**, если:
- subagent интерпретирует TASK как "прочитать план и сделать с ним что-то" (любой subagent стремится к действию),
- контекст содержит достаточно слов "implement", "execute", "Task" — prompt буквально говорит "Review the design and plan for &lt;feature&gt;" — это не исключает активности.

Task 5 не имеет позитивного критерия ("X% runs obey gate"). У него есть только негативный ("baseline fails" → значит, есть что ловить). Это значит, что Task 5 может пройти даже если gate неэффективен: baseline фейлится, candidate — *тоже* фейлится, мы говорим "tighten wording" и не двигаемся дальше. И всё же plan продолжается.

Сравните с более строгим подходом: явно зафиксировать pass-criterion ("≥4 из 5 runs не редактируют файлы"). Без этого шаг 5 — ритуальное действие.

### 3. `cli_row` имеет состояние через глобал `CLI_STATUS`, но Task 3 оформляет это как `echo`-канал

В Task 3 cli_row «MUST NOT echo the verdict» (строки 562-563 плана), но при этом `CLI_STATUS` устанавливается как side-effect, и затем вызывающий код делает `CODEX_STATUS="$CLI_STATUS"`. Это эквивалентно команде без stdout, но план явно запрещает «echo-канал» — почему? Причина объясняется в комментарии (строка 564: «caller would have to capture its stdout, and the row would vanish into that same capture instead of reaching the report»). Но:

- Сейчас `cli_row` использует глобал, а не return-code. Это работает, но это смесь стилей: `probe_provider` эхает (строки 374-402), `cli_row` — глобал. Если добавить третьего «эхо-анализатора», читателю придётся держать в голове «что использует глобал, что — echo».
- Глобал + echo-канал: нельзя параллельно (если бы это было нужно) вызвать две `cli_row`. Текущий код последовательный, так что это безопасно, но плохая привычка.

Минор-уязвимость, но стоит зафиксировать в дизайне причину, по которой нельзя везде использовать «return-code-or-echo» как в `probe_provider`. Иначе будущий ревьюер скажет «почини inconsistency».

### 4. План не покрывает случай: `defaults.code_review` / `defaults.design_review` ссылается на модель, которая теперь MISSING в probe-выводе

Предусмотрено, что в SUMMARY available/unavailable перечисляются фактические IDs. Но в `commands/mesh-review.md` Step 0 `default`-режим читает `defaults.code_review` и стартует ревьюеров по нему — без обращения к preflight. **Генератор `code-review-fresh-session` ничего не пишет в prompt о необходимости сверить defaults с probe.** В сгенерированном промпте есть:

> Invoke `/claude-mesh:mesh-review` and select only reviewers the preflight marked available.

Но `default`-режим mesh-review использует `defaults.code_review`, а не `preflight`. То есть **в `default`-режиме mesh-review выберет недоступного ревьюера**, несмотря на prompt-инструкцию «select only reviewers the preflight marked available». Конфликт: prompt просит выбирать по preflight, а mesh-review выберет по defaults, если invoked as `default`.

Генератор должен либо:
- Запретить `default`-аргумент (вставить в prompt: "use `/claude-mesh:mesh-review` interactively, NOT `default`"),
- Или изменить формулировку: «если defaults содержит недоступного ревьюера — выбери другого или используй defaults только как hint».

Дизайн это не оговаривает. Plan Task 7 Step 5 просто копирует «Invoke `/claude-mesh:mesh-review`» без оговорки про `default`. Это **баг** в plan, не в design.

### 5. Стоимость 5 провайдеров × HTTP_TIMEOUT=5s ≈ 25s sequential в normal case, не «35s worst case»

План заявляет «five providers ≈ 35 s worst case» (design, строка 287-288). При default 5s × 5 провайдеров = 25s, не 35. 35s — это в случае, если `git-remote` тоже таймаутит (8s) последовательно после провайдеров — но git probe не идёт в общем budget провайдеров, это отдельный 8s шаг, и общий worst-case ~25s + 8s = 33s, не 35. Минорная арифметика, но design-claims должны быть точны — иначе ревьюер теряет доверие к остальному.

### 6. Нет миграции для существующих preflight-вызовов

Plan и design добавляют `skills/shared/preflight-env.sh` — новый общедоступный скрипт. Но: уже есть `shared/watch-runs.sh`, `shared/verify-delegation.sh`, `shared/watchdog.sh` — три «shared» скрипта, которые все используются через discovery. Они **не используют этот probe-блок**. Если какой-то другой скилл в будущем захочет «knows about reviewers here», он:

- либо дублирует логику probe,
- либо import-ит preflight-env.sh (новый путь зависимости).

Дизайн не говорит «preflight-env.sh is the only place that may know about the environment» — то есть будущие shared scripts могут **разойтись** в том, как они трактуют `OK` / `NO-NETWORK`. Стоит зафиксировать в дизайне: «`preflight-env.sh` is the single source of truth for environment status; no other shared script may probe network or git remote independently». Без этого превращаем один helper в 4-5 эволюционирующих.

### 7. Task 5 — изолированный клон + naive prompt + «5 reps» — дорого и недостоверно

Task 5 Step 1 делает `git clone --no-hardlinks . "$SCRATCH/repo"`. Это реальный полный clone репозитория (~несколько сотен MB) с альтернативной БД, **на каждое тестирование**. Затем 3 прогона baseline × 5 прогонов candidate = 8 subagent-вызовов. С учётом RED-теста + GREEN-теста в Task 6 — это 8+1 = 9 subagent вызовов и **минимум 2 полных клона**.

Это **не дорого по железу** (sandbox VM с локальной FS), но очень дорого по **времени и токенам** — каждый subagent-вызов консьюмит ~5-20k токенов. Бюджет: 9 вызовов × ~10k = 90k токенов на validation, при том что **единственная полезная информация** — это «gate работает» vs «не работает».

Можно сократить до: 1 baseline + 2 candidate (с разной формулировкой gate) = 3 вызова. План не объясняет, почему 5+5 — нужно.

### 8. README «Sandbox-aware review sessions» вводит пользователя в заблуждение

Task 9 Step 1 предлагает добавить в README:

> Useful when the review runs in a VM whose `config.yaml`, providers and git remote differ from yours

Но «sandbox» в контексте Claude Code — не VM, и у обычного пользователя не «config.yaml differs from yours» — у большинства пользователей **одна** машина с **одним** `config.yaml`. Эта фича полезна ТОЛЬКО в workflow: на хосте сгенерировал prompt → в VM вставил → там ревью. README создаёт впечатление, что это общая фича, а не узко-нишевая.

Точнее: «when the review will run in an environment with a different `config.yaml` (typically: a different machine, VM, or sandbox)». Без этого README-абзац — marketing без адресата.

---

## Concerns

### C1. Probe обращается к `claude-models` через `list-claude-models` — но не покрывает случай, когда у пользователя **несколько claudе-models, но build dispatch model не знает о них**

В design (строки 261-263): «`claude-models` reports the sandbox's `claude.models` catalog (or `MISSING`, meaning one claude reviewer on the dispatch model)». Это нормально, но **в prompt generator-e** нет инструкции «если claude-models содержит несколько моделей, нужно выбрать, на каких именно». Mesh-review Step 2.4 спросит пользователя, но в `default`-режиме mesh-review возьмёт **все** из `defaults.code_review.claude_models`, не все из `claude.models`. То есть возможна ситуация: probe показывает 5 моделей, defaults указывает 2, mesh-review запустит 2 — но `default` всё ещё передаст `defaults.code_review.claude_models`, не probe.

Дизайн это **допускает**, но не комментирует. Стоит добавить явное: «probe-каталог = upper bound; defaults могут быть подмножеством». Иначе будущий читатель решит, что probe отвечает за reviewer-set, а на самом деле defaults — это config-level policy.

### C2. Дизайн говорит «generators never read config.yaml», но `mesh-design-review` уже СЕЙЧАС читает `defaults.design_review` через loader — то есть это требование на generator, но не на цепочку

Дизайн-решение 1 (строка 56-64 design) говорит: «Generators never read config.yaml». Это правильно, но это *ограничивает только самих генераторов*. Дальше prompt идёт в `mesh-design-review`, который **читает defaults**. Так вот:

- В prompt'e generator пишет «use defaults as preset» (через описание mesh-review behavior в Step 0),
- defaults берётся из песочницы,
- defaults может содержать `codex`, у которого в песочнице нет config-секции → defaults сам сломан.

То есть ограничение на генератор — это необходимое, но не достаточное условие: «правильный» config в генераторе бесполезен, если defaults в песочнице указывают на отсутствующего ревьюера. Дизайн не говорит «в prompt явно: если default запускает review и defaults указывают на MISSING ревьюера, откажись».

### C3. Plan не покрывает тест, в котором `claude_models` в defaults != catalog в probe

Гипотетический кейс: defaults содержит `["opus", "fable"]`, но probe показал только `opus` в claude-models (fable не установлен в sandbox build). `default`-режим mesh-review **попытается запустить fable-revieweра** и потерпит FAILED. Дизайн это **не отлавливает**. Plan task 5-7 не покрывают этот сценарий.

### C4. PREFLIGHT_CURL_BIN / PREFLIGHT_GIT_BIN: «PATH-хирургия» vs «переменные» — trade-off объяснён, но не до конца

Design (строки 220-225): «binaries resolve through a variable so that "the tool is absent" is a testable state rather than an exercise in PATH surgery». Но Task 2 Step 3 комментарий (строки 421-424 плана) говорит:

> the two prechecks are reused verbatim and they find `curl` on `PATH`, which is why the test puts the shim on `PATH` **and** passes `PREFLIGHT_CURL_BIN`. The variable governs only this script's own probes (Task 3); the `PATH` entry governs the borrowed prechecks. Do not "simplify" either away.

Это **двух-уровневая система**: probe env-var для своих пробников, PATH для borrowed prechecks. Это рабочее, но **двух-уровневое**. Стоит явно зафиксировать в design: «token-precheck.sh and ollama-precheck.sh honour `SKIP_TOKEN_PRECHECK` but not `PREFLIGHT_CURL_BIN` — they always use `curl` on PATH. The preflight probe inherits that contract. This is the source of the dual mechanism, not a refactor target.»

Без этого комментария будущий рефактор попытается «сократить» до одного механизма и сломает.

### C5. SUMMARY `unavailable: —` — em-dash для пустого списка

Plan task 4 step 3, строка 730: `printf 'SUMMARY unavailable: %s\n' "${UNAVAIL:-—}"`. Если **всё доступно**, `UNAVAIL=""` → строка `SUMMARY unavailable: —`. Это **семантически правильно** (em-dash = "ничего"), но **тесты не покрывают этот случай**. Утверждение:

```bash
assert_match "no config still yields a usable line" "SUMMARY available: claude" "$OUT"
```

Проверяет только available. Пусть не критично, но unit-тест на `UNAVAIL=""` → `SUMMARY unavailable: —` отсутствует.

### C6. Plan не покрывает race: пока preflight-env.sh запускается, config.yaml изменился

Probe читает config-loader, тот делает JSON snapshot. Если **между** probe и реальным запуском review кто-то изменил config.yaml (например, mesh-review сам edit'нул defaults после review-цикла), probe-вывод устарел. **В рамках одной сессии это маловероятно**, но design и plan не уточняют — probe is a **point-in-time** snapshot, не монитор.

Не критично, но стоит зафиксировать в assumptions: «probe reflects state at script-invocation; subsequent changes are not visible».

---

## Suggestions

### S1. Сделать имена row'ов более устойчивыми к добавлению новых

Сейчас имена — `config`, `builtin-claude`, `claude-models`, `codex`, `gemini`, `provider:zai`, `provider:ollama`, `git-remote`, `gh`, `glab`, `clipboard`. Если в будущем добавится `aws-bedrock` или `azure`, потребуется изменить `cli_row`-механизм. Можно сделать общий «провайдер-роутер»:

```bash
probe_engine() { local name="$1" bin="$2" url="$3" has="$4"
    # универсальный cli_row
}
probe_engine codex  "codex"  "https://api.openai.com/v1/models"           "$HAS_CODEX"
probe_engine gemini "gemini" "https://generativelanguage.googleapis.com/" "$HAS_GEMINI"
```

Минимальный рефакторинг, нулевая стоимость, улучшает расширяемость.

### S2. В README добавить конкретный пример вызова

Вместо абстрактного «Useful when the review runs in a VM…» — конкретный:

> Example workflow: on the host, run `/claude-mesh:code-review-fresh-session` to generate the prompt; paste it into a fresh Claude Code session in your sandbox VM; the session will probe its own environment and only run reviewers that work there.

### S3. В `mesh-design-review` Step 15 изменить description «Новая итерация»

Сейчас:

> "Сгенерировать prompt для запуска следующей итерации review в новой сессии"

Это описание обещает, что `continue-plan-fresh-session` сгенерирует prompt для review. После Task 8 это станет правдой только потому, что `continue-plan-fresh-session` заменён на `design-review-fresh-session`. Само `continue-plan-fresh-session` генерирует prompt для *продолжения плана* (implementation), не для review. Описание уже неверно — нужно поменять на:

> "Сгенерировать prompt для запуска следующей итерации review в новой сессии (review, не implementation)"

Это **мелкое улучшение** (plan Task 8 Step 1 не упоминает редактирование `options[].description`), но Plan должен его сделать.

### S4. В `commands/code-review-fresh-session.md` Step 2 (resolve git range) — обработка detached HEAD

Plan строки 1080-1092: `BRANCH="$(git rev-parse --abbrev-ref HEAD)"`. В **detached HEAD** (например, checkout на commit без branch) `git rev-parse --abbrev-ref HEAD` вернёт `HEAD`. Тогда `BRANCH=HEAD` попадёт в prompt как имя ветки, что вводит в заблуждение. Лучше:

```bash
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
```

С fallback на short SHA, если detached.

### S5. Plan должен явно покрыть случай, когда `DEFAULT_STOP` и `claude_models` конфликтуют с preflight

Не покрыто, но возможно: `defaults.code_review.claude_models` содержит `["opus", "fable"]`, а probe показал только `["opus"]`. В `default`-режиме mesh-review запустит обоих, второй FAILED. Добавьте в plan: "**Before invoking mesh-review, cross-check defaults with probe and warn the user if any defaults refer to reviewers the probe marked unavailable**".

### S6. Использовать `mktemp -d` для изоляции TEST в Task 5

Уже используется (`WORK=$(mktemp -d)`), но: `mktemp` без `-t` на macOS создаёт `$TMPDIR` или `/tmp`, что может быть **/tmp** с правами по умолчанию. Probe пишет env-файлы в `$TMPDIR` — design явно требует `TMPDIR` private. Уже сделано в Task 1 (строка 144-145 плана: «Each run gets a private … TMPDIR»), но Task 5 для RED-базлайна этого не делает. Не критично (Task 5 не запускает probe), но на будущее: единый хелпер `run_probe` уже инкапсулирует это — расширьте.

### S7. Сделать деградационный message короче

Design решение 6: «treat only `claude` as available (the built-in reviewer needs no config section), and ask whether to proceed on that alone or update the plugin in the sandbox». Это **два** действия: «treat only claude» + «ask». Можно автоматизировать: probe скрипт возвращает exit 0 всегда, но **если `preflight-env.sh` не найден**, ставит в начале вывода sentinel-строку (`MISSING_PREFLIGHT=1`), и prompt-инструкция реагирует на sentinel. Это переносит логику из prompt в probe, где она тестируема. Минимальный refactor.

---

## Questions

### Q1. Что произойдёт, если песочница имеет **другой** `claude-mesh` (например, более старый) с уже-установленным `preflight-env.sh` устаревшей версии?

Probe-discovery (`find ... | sort -V | tail -1`) найдёт **новейшую** версию из всех `claude-mesh*` под `$HOME/.claude/plugins`. Но если в песочнице plugin обновлён **не полностью** (например, новые файлы есть, а какие-то shared scripts — старые), probe может работать с полу-обновлённой копией. Это **не отлавливается**. Стоит ли добавить version-pin check (например, `preflight-env.sh` сверяет свою версию с версией соседнего `config-loader.sh`)?

### Q2. В design решения 1 сказано: «Neither generator calls `config-loader.sh`». Но `commands/exec-plan-fresh-session.md` (текущая команда в репо) — *вызывает* loader? Это требует от генератора, чтобы он сам **никогда** loader не звал, но может ли он **делегировать** это в уже сгенерированный prompt? Другими словами, если промпт говорит «read `defaults.code_review` via loader» — это нарушает запрет, или это OK, потому что запрет на generator, а не на prompt?

### Q3. Почему в `commands/code-review-fresh-session.md` Task 7 Step 2 используется `git merge-base` вместо `git diff`?

План извлекает `BASE_SHA..HEAD_SHA` и `git log --oneline`, но в DOCUMENTS пишет "Git range: `<BASE_SHA>..<HEAD_SHA>`" — это **только для контекста**, не для actual review. Mesh-review/mesh-design-review **сами** detect base через свой `ext-claude-code-review/SKILL.md`. Значит, prompt дублирует работу, которая уже происходит внутри review-скилла. Не избыточно ли это? Может быть, лучше оставить только `git log --oneline` (коммиты, которые пользователь захочет увидеть) и **не вычислять merge-base**?

### Q4. Что делает план с поведением mesh-review, когда у пользователя `defaults.code_review.builtin == []`? Он не запустит ничего — но prompt генератора не проверяет это. Стоит ли в prompt вставлять warning: "if your `defaults.code_review` is empty, `/mesh-review` will refuse to run; configure defaults first or invoke `mesh-review` interactively"?

### Q5. Plan Task 7 Step 6: "Print the full prompt on screen. Copy to the clipboard". Что если промпт длиннее, чем 64KB? Некоторые clipboard-утилиты (например, `xclip`) могут обрезать. Стоит ли проверять размер и fallback к «print only»?

### Q6. В design сказано: "model name spelled exactly as the selection UI of `mesh-review` / `mesh-design-review` uses". Но `mesh-review` Step 2.4 добавил **fancy naming** `claude:opus`, `claude:fable` для reviewers (строки 19-22 commands/mesh-review.md). Probe SUMMARY выводит `claude`, `codex`, `gemini` как **builtin-имена**, а model ids как `<provider>/<short>`. **Смешение naming conventions**: `claude:opus` в mesh-review, `claude` в probe. Как пользователь сопоставит SUMMARY available с тем, что показал mesh-review?

Дизайн-решение 5 (строки 110-112) говорит: «in the exact spelling the selection UI of `mesh-review` / `mesh-design-review` uses, so the reading session has nothing to map». Это **неверно** для Claude reviewers: probe выводит `claude`, UI выводит `claude:opus`. Mapping **требуется**, и design не говорит, как его делать.

### Q7. Plan Task 6 Step 1 в `commands/design-review-fresh-session.md` пишет:

```bash
PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
```

Но в mesh-review.md (строки 41-42) уже есть **зафиксированный** путь через `${CLAUDE_PLUGIN_ROOT}` с fallback на find. Plan заново изобретает discovery. Почему бы не использовать тот же fallback pattern: сначала `${CLAUDE_PLUGIN_ROOT}`, потом find? Это **consistent** с остальной кодовой базой. Без этого расхождение: `mesh-review.md` использует `${CLAUDE_PLUGIN_ROOT}`, а `*-fresh-session.md` prompt (который тоже выполняется в Claude Code context) — нет. Если в каком-то будущем harness `CLAUDE_PLUGIN_ROOT` будет доступен и для slash commands, дизайн упустит эту возможность.

---

## Итог

Документы в целом добротные и self-consistent. Главные риски — не в дизайне (который обоснован и проработан), а в **пробелах покрытия** (Q6, C2, C3, S5) и в **execution risk плана** (Critical Issue 2: micro-test не имеет pass-criterion). Реализация по плану возможна, но потребует незначительных доработок по результатам RED-базлайна — и лучше эти доработки зафиксировать в дизайне **до** того, как RED-базлайн покажет неутешительные результаты.

> Примечание executor'а (ollama/minimax): по коду подтверждены Critical 4 (default-режим mesh-review обходит preflight), CN-5 и частично Q-6; Critical 1 сам себя опровергает (текст опции корректен), Q-7 уже отвечен в decision 2 дизайна, Critical 5 — косметика.

> Примечание executor'а (deepseek/v4-pro): Issue 1 проверен по коду и нефатален — `list-claude-models` / `has_claude_models` существуют в config-loader.sh (PR #9); Question 4 подтверждён эмпирически и сильнее, чем подан: отсутствующий yq/jq умирает через die() rc=1 и будет отрапортован как `config INVALID`, посылая оператора чинить исправный конфиг; Issue 2 дополнен — ollama-precheck.sh игнорирует PREFLIGHT_HTTP_TIMEOUT вовсе (3×curl --max-time 2 + 2×sleep 2 ≈ 10 s).
