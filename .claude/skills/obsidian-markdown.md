# Skill: Obsidian Markdown

Правила работы с Obsidian-специфичным Markdown.

## Wikilinks
- Внутренние ссылки: `[[note-name]]`
- С алиасом: `[[note-name|отображаемый текст]]`
- На заголовок: `[[note-name#heading]]`
- На блок: `[[note-name#^block-id]]`

## Embeds
- Вставка заметки: `![[note-name]]`
- Вставка секции: `![[note-name#heading]]`
- Вставка изображения: `![[image.png]]`

## Callouts
```markdown
> [!note] Заголовок
> Содержимое

> [!tip] Заголовок
> [!warning] Заголовок
> [!danger] Заголовок
> [!info] Заголовок
> [!question] Заголовок
> [!example] Заголовок
> [!success] Заголовок
> [!failure] Заголовок
```

Сворачиваемые:
```markdown
> [!note]- Свёрнутый по умолчанию
> Содержимое

> [!note]+ Развёрнутый по умолчанию
> Содержимое
```

## Frontmatter (YAML)
```yaml
---
key: value
list: [item1, item2]
---
```

## Mermaid-диаграммы
````markdown
```mermaid
graph TB
    A --> B
```
````

## Dataview запросы
````markdown
```dataview
TABLE status, date
FROM "Architecture/ADR"
WHERE status = "proposed"
SORT date DESC
```
````

## Tags
- В тексте: `#tag-name`
- В frontmatter: `tags: [tag1, tag2]`
- Вложенные: `#parent/child`

## Чеклисты
```markdown
- [ ] Не выполнено
- [x] Выполнено
- [/] В процессе (Dataview)
- [-] Отменено (Dataview)
```
