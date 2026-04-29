---
name: review
description: Полный code review текущих изменений
---

# /review — Code Review

Проведи полный code review текущих изменений.

## Шаги

1. Посмотри `git diff` и `git log` чтобы понять что изменилось
2. Вызови **@reviewer** для проверки по 8 линзам:
   - Correctness, Security, Performance, Quality
   - Architecture, Testing, Error Handling, Accessibility
3. Для каждого найденного issue укажи severity: Blocker 🔴 / Critical 🟠 / Warning 🟡 / Suggestion 🟢
4. Если есть Blocker или Critical — предложи конкретный fix

## Контекст
$ARGUMENTS
