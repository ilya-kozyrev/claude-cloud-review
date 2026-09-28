# cloud-review

**Ревью кода в облачной сессии Claude Code для GitLab, Bitbucket и любого другого git-хостинга.**

*English: a Claude Code plugin that sends one committed branch from any git host to a Claude Code
cloud session for a read-only review, and brings the verdict back as `final.md`. Cloud sessions
natively work with GitHub only; this uploads the branch as a git bundle.*

Облачные сессии Claude Code умеют клонировать и пушить только GitHub. Этот плагин отправляет в облачную
сессию одну закоммиченную ветку из любого репозитория и забирает готовое ревью обратно файлом
`final.md`. Облачная сессия ничего не пушит: это ревьюер, а не исполнитель.

Зачем: облачные сессии расходуют облачный кредит, а не 5-часовой и недельный лимиты плана. Осенью
2026 подписчикам начислили разовый кредит: $100 на Pro и $250 на Max. Забрать его нужно было до
7 октября, сгорает он 5 ноября 2026. Потом облако тратит обычную квоту. У нас ревью MR на ~240 строк
моделью Fable стоило около $2.5, так что $250 — это порядка сотни ревью.

## Установка

Как плагин, из этого репозитория как маркетплейса:

```bash
claude plugin marketplace add ilya-kozyrev/claude-cloud-review
claude plugin install cloud-review@cloud-review
```

Внутри сессии Claude Code то же делают `/plugin marketplace add ilya-kozyrev/claude-cloud-review` и
`/plugin install cloud-review@cloud-review`. Скилл вызывается как `/cloud-review:cloud-review`, или
можно просто попросить «сделай облачное ревью этой ветки».

Вручную, как обычный скилл:

```bash
git clone https://github.com/ilya-kozyrev/claude-cloud-review
mkdir -p ~/.claude/skills
cp -R claude-cloud-review/plugins/cloud-review/skills/cloud-review ~/.claude/skills/
```

Что нужно:
- Claude Code с флагом `--cloud` (проверка: `claude --help | grep -- --cloud`). На macOS скрипт сам
  находит свежий бинарь десктоп-приложения, если `claude` в PATH старый.
- Вход через аккаунт claude.ai: `claude auth login`. С API-ключом облачные сессии не работают.
- `git`, `python3`, `script` — на macOS и Linux они есть из коробки.

## Использование

```bash
S=~/.claude/skills/cloud-review/scripts/cloud-review.sh   # у плагина путь внутри ~/.claude/plugins/cache/…
$S run -C ~/code/myrepo -r my-branch -b review.md -n mr42   # создаёт облачную сессию
$S wait ~/.cache/cloud-review/runs/mr42-<время>             # ждёт готовности и пишет final.md
cat ~/.cache/cloud-review/runs/mr42-<время>/final.md
$S clean ~/.cache/cloud-review/runs/mr42-<время>
```

- Модель по умолчанию — `claude-fable-5-1`. Другую задаёт `-m`, например `-m opus`.
- Бриф пишется по образцу [`examples/review-brief.md`](plugins/cloud-review/skills/cloud-review/examples/review-brief.md).
  Он должен быть самодостаточным: облако видит только репозиторий на этом коммите — без локальных
  путей, трекера, страницы MR и стендов.
- Ревью обычно занимает 3–5 минут.

## Как это устроено

1. `run` делает одноветочный клон нужного коммита без remote в `~/.cache/cloud-review/runs/`.
2. `CCR_FORCE_BUNDLE=1 claude --cloud "<бриф>"` загружает клон бандлом и создаёт облачную сессию.
   `--cloud` работает только интерактивно, поэтому скрипт запускает его через `script(1)` как
   псевдотерминал.
3. Облачная модель делает ревью и заканчивает ответ строкой `CLOUD-REVIEW-DONE`.
4. `fetch` и `wait` вызывают `claude -p --teleport <id>`: teleport копирует облачный транскрипт в
   `~/.claude/projects/`, а скрипт дословно достаёт оттуда последний ответ облачной модели в `final.md`.

## Что скрипт трогает у тебя

- Создаёт `~/.cache/cloud-review/runs/<имя>-<время>/`: клон, бриф, результат, `usage.json` с токенами.
- Добавляет в `~/.claude.json` отметку доверия к папке клона: без неё интерактивный `claude --cloud`
  остановится на вопросе «доверяешь ли папке». `clean` эту отметку удаляет.
- Каждый `fetch` — один короткий локальный ход Haiku, около $0.1 из обычных лимитов.

## Грабли, на которые мы наступили

- `claude --cloud` не сочетается с `-p`: создать сессию можно только интерактивно.
- Загрузка не принимает репозиторий внутри `~/.claude` и git worktree с `extensions.worktreeConfig`.
  Поэтому клон отдельный и лежит в `~/.cache`.
- Доверие к папке не распространяется на подпапки, поэтому оно ставится на каждый прогон отдельно.
- `Agent` с `isolation: "remote"` в нашем десктоп-клиенте в облако не ушёл: он молча выполнился
  локально на лимитах плана. Проверь у себя, прежде чем на это полагаться.
- Качество: на нашем MR оба прогона Fable нашли средний дефект, но пропустили high, который нашёл
  Codex. Используй облачное ревью как второе мнение, а не как единственную проверку.

## Лицензия

MIT
