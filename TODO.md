# Project Roadmap & TODO

Planned work only. Bugs not fixed yet live in `KNOWN_BUGS.md`; fixed bugs and finished work in `FIXED_ISSUES.md`. Mark an item `[x]` only when it is implemented **and** covered by tests, then move it
to `FIXED_ISSUES.md`.

## 🧭 Principles

1. **Simple and clear.** A user who knows nothing about SQL declares a model and calls methods.
2. **Model-driven.** Keys, schema, filters come from the model. Composite keys are convenient, and a fully custom key is possible.
3. **Raw escape hatch.** Experienced users / complex logic → raw SQL API, no models required.
4. **Smart engine, optionally simple.** Weighted queue, stats, aging, batching — but FIFO must stay available.
5. **Hint and continue.** Misconfiguration with a sane fallback → warning + `hint` + keep working.
6. **Never crash the host app.** Errors reach the user only through the returned Future/Stream as typed `Fluent*Exception` with a `hint`. Nothing escapes from timers, streams or background work.
7. **No destructive self-healing.** Dropping columns/tables/files happens only on explicit request.

## Order of work

1. **First: fix, complete, optimize** what exists — known bugs, the analyzer / optimizer, the model-level features that
   replace raw SQL, the API simplification, quality & infrastructure.
2. **Then the rest** — bigger features, code generation, DevTools extension, encryption add-on.

## Guiding direction (from the user)

- **Models and methods instead of raw SQL.** Every common need gets a model-level API; `rawQuery` / `execute` stay as
  the escape hatch, not the normal path. Each new feature is checked against "can a user without SQL do this?".
- **Simple calls.** Existing calls are simplified where possible; new ones start simple (one obvious way, sane
  defaults, options only when needed).
- **Database analyzer / optimizer:** the library watches schema, queries and usage, and wherever something is not
  optimal suggests a fix with copy-paste-ready code.
- **Documentation for AI assistants** (`llms.txt`, `doc/ai/`, skills) stays in step with the API.

## Before 2.0

- [ ] CI: analyze + tests + coverage.
- [ ] Guide (`doc/*.md`, written 2026-10-26): review it together and extend with screenshots / diagrams if needed.
- [ ] API reference (`dart doc`) and architecture notes.
- [ ] Before publishing: both packages depend on `fluent_sqflite` by path and say `publish_to: none`; switch to
      `fluent_sqflite: 2.0.0` (test package: the exact version, it uses internals) and publish after the library.
- [ ] Release: versions `2.0.0-dev.N` → `2.0.0` (library + both packages), the CHANGELOG heading "2.0.0-dev.N" (merged) →
      "2.0.0" with a short summary on top.
- [ ] `example/` app to exercise the library on devices (decided: later).

## Device checks

- [ ] Run `FluentBenchmark.run()` / `runScenarios` on a real Android and iOS device; tune the defaults
      (`readConnections`, slicing and isolate thresholds).
- [ ] Measure on a real device whether the analyzer thresholds give false positives.
- [ ] Measure the tuner levers on real devices (gain of auto indexes, memory restore, refresh-rate budget).
- [ ] FTS4 path: the FFI SQLite of the tests has no FTS4 — check on an Android device.

## Features (later releases)

- [ ] Search follow-ups: `search(columns:)`, highlight / snippets, per-column weights, read-only groups (FTS state is
      only set by schema sync; they search with `LIKE`).
- [ ] Backup / restore (`VACUUM INTO`).
- [ ] Encryption (SQLCipher) — decided: an add-on package `fluent_sqflite_cipher` (sqflite cannot encrypt, SQLCipher is
      another native plugin adding a few MB, so it must not be forced on everyone). The core gets a pluggable database
      factory; usage is one parameter `FluentGroup(encryption: FluentEncryption(password))`; without the add-on →
      warning + hint "add fluent_sqflite_cipher". The add-on also migrates an existing plain database to encrypted.
- [ ] Code generation — decided: optional only. A separate dev package `fluent_sqflite_generator` (`@FluentModel()` +
      build_runner → buildJson / fromCacheJson / provider boilerplate, also the boilerplate of found relations). The
      core stays plain Dart, manual models stay the first-class way. Build it once the API is stable.
- [ ] Flutter DevTools extension — decided: a "fluent_sqflite" tab shipped in the package (`extension/devtools/`,
      `devtools_extensions`). The app registers service extensions in debug / profile only (nothing in release); the tab
      shows tables + schema, engine queue / `engineStats()`, cost model (slowest queries), all current hints with
      copy-paste code, and read-only queries. No setup for users (DevTools asks once to enable it).
- [ ] Tuner: read pool resizing at run time (today: decided at start from the cores).
- [ ] Tuner, not done on purpose: settings that only apply to a new database file (`auto_vacuum`, page size) or are
      stored for the next start — risky; revisit with device data. Battery / thermal hook (`FluentDb.reportDeviceState`).
- [ ] Migration check script for Mac and Windows: run by hand or in CI, it checks the migrations when a project moves to a
      new version of the library (schema changes, `FluentDbMigration` hashes and bodies) and reports what needs attention.
- [ ] Pre-launch check script: one command that checks that everything is right before the app starts. It runs all
      checks at once, prints every warning together, and for each one says how to fix it (idea only, not built yet).
- [ ] A query counter for users (N+1 guards) in `fluent_sqflite_test`, through an own hook instead of
      `sqflite_common/src`
