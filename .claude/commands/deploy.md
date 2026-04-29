---
name: deploy
description: Деплой на staging или production
---

# /deploy — Деплой

## Окружение
$ARGUMENTS

## Чеклист перед деплоем (вызови @devops)

1. [ ] Все тесты проходят (`/test-all`)
2. [ ] Code review пройден (`/review`)
3. [ ] Миграции безопасны (нет breaking changes)
4. [ ] Переменные окружения обновлены
5. [ ] Health check endpoint работает

## Railway (по умолчанию)
```bash
# Автоматически из GitHub push
git push origin main
```

## Hetzner (production)
```bash
# Создать тег для деплоя
git tag v$(date +%Y.%m.%d)
git push --tags
# GitHub Actions запустит deploy pipeline
```

После деплоя:
- Проверь health endpoint
- Проверь логи на ошибки
- Обнови `Hot/hot.md` в vault
