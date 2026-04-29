# Project: Multi-Platform Application

## Overview
Multi-platform application ecosystem with shared backend and platform-specific frontends.

## Architecture (DDD — Domain-Driven Design)
```
project/
├── backend/                    # PHP/Laravel (DDD)
│   ├── src/
│   │   ├── Domain/             # Entities, Value Objects, Aggregates, Domain Events
│   │   ├── Application/        # Use Cases, DTOs, Command/Query Handlers (CQRS)
│   │   ├── Infrastructure/     # Repositories, External Services, Persistence
│   │   └── Interfaces/         # Controllers, API Resources, Middleware
│   ├── tests/
│   │   ├── Unit/
│   │   ├── Integration/
│   │   └── Feature/
│   ├── routes/api.php
│   └── composer.json
├── web/                        # Next.js + React
│   ├── src/
│   │   ├── app/                # App Router (Next.js 14+)
│   │   ├── components/         # Shared React components
│   │   ├── hooks/              # Custom hooks
│   │   ├── lib/                # API client, utils
│   │   ├── stores/             # State management (Zustand/Redux)
│   │   └── types/              # TypeScript types
│   ├── tests/
│   └── package.json
├── ios/                        # SwiftUI
│   ├── Sources/
│   │   ├── App/
│   │   ├── Features/           # Feature modules (MVVM)
│   │   ├── Core/               # Networking, Storage, DI
│   │   ├── DesignSystem/       # UI components, tokens
│   │   └── Models/             # Shared models
│   ├── Tests/
│   └── Package.swift
├── android/                    # Kotlin
│   ├── app/src/main/kotlin/
│   │   ├── features/           # Feature modules (MVVM)
│   │   ├── core/               # DI, networking, storage
│   │   ├── designsystem/       # UI components, Material3
│   │   └── models/             # Shared models
│   ├── app/src/test/
│   └── build.gradle.kts
├── shared/                     # Shared specs, API contracts
│   ├── api-spec/               # OpenAPI specs
│   ├── design-tokens/          # Cross-platform design tokens
│   └── docs/                   # Architecture Decision Records
└── infra/                      # CI/CD, Docker, IaC
    ├── docker/
    ├── .github/workflows/
    ├── terraform/ (or pulumi/)
    └── scripts/
```

## Tech Stack
- **Backend:** PHP 8.3+, Laravel 11+, DDD, CQRS, PostgreSQL, Redis
- **Web:** Next.js 14+ (App Router), React 18+, TypeScript, Tailwind CSS
- **iOS:** SwiftUI, Swift 5.9+, Swift Package Manager, Combine/async-await
- **Android:** Kotlin, Jetpack Compose, Material3, Hilt, Coroutines
- **Infra:** Docker, GitHub Actions, Terraform, Nginx

## Conventions
- Backend API: RESTful, versioned (/api/v1/), JSON:API format
- All code in English, comments in English
- Git: Conventional Commits (feat:, fix:, chore:, docs:, refactor:, test:)
- Branch naming: feature/TASK-123-short-description, fix/TASK-456-bug-name
- PR required for all merges to main/develop
- Tests required: unit (80%+ coverage), integration for critical paths

## Commands
- Backend: `cd backend && php artisan test` / `composer analyse` (PHPStan)
- Web: `cd web && npm test` / `npm run lint` / `npm run build`
- iOS: `cd ios && swift test`
- Android: `cd android && ./gradlew test`
- All: `docker compose up -d` for local environment

## Deployment
- **Railway** — основная платформа для простых/средних проектов (auto-deploy из GitHub)
- **Hetzner** — production-grade инфраструктура (Terraform + Docker + SSH)
- **Supabase** — база данных и аутентификация
- **Figma** — дизайн-система (MCP подключен)

## Knowledge Base (Obsidian Brain)
Vault: `~/Documents/agent-factory-brain/`
- Агенты читают `Hot/hot.md` первым для контекста
- ADR хранятся в `Architecture/ADR/`
- PRD в `PRD/`
- Session logs в `Sessions/`
- Используй wikilinks `[[]]` для связей в заметках

## Agent Team
12 агентов доступны через `@agent-name` в Claude Code:
- @product-manager, @team-lead, @architect, @ai-architect (Opus)
- @backend, @ios, @android, @reviewer (Opus)
- @frontend, @tester, @devops, @designer (Sonnet)

## Rules
- NEVER modify database migrations that are already deployed
- ALWAYS create new migrations for schema changes
- NEVER commit secrets, .env files, or API keys
- ALWAYS use dependency injection, never instantiate services directly
- Follow DDD: business logic belongs in Domain layer, not Controllers
- Use Value Objects for complex domain concepts
- API changes require OpenAPI spec update first (spec-first approach)

## iOS release rule — never push a closed train

Before pushing iOS changes that may trigger TestFlight upload, sanity-check that `MARKETING_VERSION` in `project.yml` is NOT a version that's already approved or in review on App Store Connect. The `ios-release` workflow has a pre-flight guard that aborts on a closed train, but a stale `project.yml` still wastes 5 minutes of CI minutes before the guard fires.

Rule of thumb: after any successful App Store submission, the FIRST commit to `main` should bump `MARKETING_VERSION` (1.3.0 → 1.3.1). The auto-bumper in `codemagic.yaml` will then march forward from there.

Full release walk-through (push triggers, tag triggers, what to do when something fails): `.claude/research/release-process.md`. Skill `codemagic-ios-cicd` (lessons 13-15) covers the fix history.

## Self-testing rule — data-layer bugs

Whenever a fix concerns what the user sees (balances, analytics, AI answers,
budget numbers, transaction amounts), **verify the real data in Supabase
before reporting "fixed"**. Unit tests run against fixtures; fixtures can't
catch legacy rows written by a previous client / TMA / broken write-path.

Mandatory check flow:
1. `supabase db query --linked --output table "SELECT ... FROM transactions WHERE ..."`
   to see the actual row (`amount`, `amount_native`, `currency`, `foreign_*`,
   `fx_rate`, `account_id`) — not just what the Swift model computes from it.
2. JOIN against `accounts` to verify `t.currency == a.currency` and
   `amount_native` is in that currency's minor units. A mismatch means a
   legacy row that the Swift read-path can't rescue — needs SQL reconciliation.
3. When in doubt, run an UPDATE against a snapshot in `backup_YYYYMMDD` schema
   first, then the production rows.

Tooling available in this environment:
- `supabase db query --linked` — direct SQL to the linked project (prod).
- `xcodebuild test -scheme AkifiIOS -only-testing:AkifiIOSTests/<Suite>` — Swift tests.
- `xcodebuild build` — iOS compile.
- `xcrun simctl` — simulator automation for UI smoke tests.
- `bash Scripts/lint-amount-usage.sh` — ADR-001 guardrail.
- `supabase functions deploy <name> --project-ref fnvwfrkixjqdifitlifr` — edge functions.
- Claude-in-Chrome MCP — browser automation for web UI.

Do NOT report a bug as fixed without at least one of these verifications
against the real data path. Saying "tests pass" while the user's screen
still shows the bug is worse than saying "tests pass, but I can't verify
against your data — please check".
