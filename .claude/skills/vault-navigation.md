# Skill: Vault Navigation

Как эффективно навигировать по Agent Factory Brain vault.

## Иерархия чтения (ВСЕГДА соблюдай порядок)

```
1. Hot/hot.md          ← ПЕРВЫМ (текущий фокус)
2. Hot/current-sprint  ← задачи спринта
3. Hot/blockers        ← блокеры
4. {Section}/_index.md ← карта нужной секции
5. Конкретная заметка  ← детали
```

## Карты содержимого (_index.md)

Каждая папка имеет `_index.md` — это Map of Content (MoC).
Читай MoC перед погружением в конкретные файлы.

| Папка | MoC |
|-------|-----|
| Projects | `Projects/_index.md` |
| Architecture | `Architecture/_index.md` |
| PRD | `PRD/_index.md` |
| Agents | `Agents/_index.md` |
| Knowledge/tech | `Knowledge/tech/_index.md` |
| Knowledge/domain | `Knowledge/domain/_index.md` |
| Knowledge/competitors | `Knowledge/competitors/_index.md` |
| Sprints | `Sprints/_index.md` |
| Issues | `Issues/_index.md` |
| Sessions | `Sessions/_index.md` |

## Поиск контекста

1. **По агенту** → `Agents/{agent-name}.md` → секция "Связи"
2. **По фиче** → `PRD/feature-{name}.md` → секция "Архитектурные решения"
3. **По решению** → `Architecture/ADR/ADR-{NNN}-*.md`
4. **По технологии** → `Knowledge/tech/{technology}.md`
5. **По домену** → `Knowledge/domain/glossary.md`

## При создании новой заметки

1. Выбери правильную папку (см. CLAUDE.md)
2. Используй шаблон из `Templates/`
3. Заполни frontmatter
4. Добавь wikilinks на все связанные сущности
5. Обнови соответствующий `_index.md`
6. Обнови `Hot/hot.md` если это важное изменение
