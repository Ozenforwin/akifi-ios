---
name: feature
description: Полный цикл разработки фичи от PRD до деплоя
---

# /feature — Разработка новой фичи

## Описание
$ARGUMENTS

## Workflow

1. **@product-manager** — напиши PRD для этой фичи, задай уточняющие вопросы
2. **@architect** — создай ADR с архитектурными решениями на основе PRD
3. **@ai-architect** — если фича связана с AI, определи паттерн интеграции
4. **@designer** — определи компоненты дизайн-системы и токены
5. **@team-lead** — декомпозируй на задачи и запусти параллельно:
   - **@backend** (worktree) — API endpoints, бизнес-логика, тесты
   - **@frontend** (worktree) — веб-компоненты, страницы
   - **@ios** (worktree) — iOS экраны
   - **@android** (worktree) — Android экраны
6. **@tester** — тест-план, edge cases, запусти тесты
7. **@reviewer** — code review всех платформ
8. **@devops** — деплой на staging

Сохрани session log в vault: `~/Documents/agent-factory-brain/Sessions/`
