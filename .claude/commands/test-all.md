---
name: test-all
description: Запуск тестов на всех платформах
---

# /test-all — Тесты на всех платформах

Запусти тесты на всех платформах параллельно:

```bash
# Backend
cd backend && php artisan test --parallel 2>&1 | tail -20

# Web
cd web && npm test 2>&1 | tail -20

# iOS
cd ios && swift test 2>&1 | tail -20

# Android
cd android && ./gradlew test 2>&1 | tail -20
```

Выведи сводку: ✅ / ❌ для каждой платформы.
Если есть ошибки — вызови **@tester** для анализа.
