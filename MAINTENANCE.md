# PostgreSQL maintenance branch

The `maintained/postgresql-v0.7` branch carries PostgreSQL tenant database and
schema support as a generally maintained gem without adopting the breaking changes released in
Active Record Tenanted v0.8.0.

## Provenance

- Basecamp basis: tag `v0.7.0`, commit
  `f1031b552f98ecc52e9a7856e55820e4609266ce`.
- PostgreSQL source: Basecamp pull request
  [#261](https://github.com/basecamp/activerecord-tenanted/pull/261), authored
  by Ben Sullivan (`Dreamer009`).
- Source range: `7b09a4655d1aea6dd9c51d71b50c9a23481593f1` through
  `112e752af16a631b92b426d96e7d208c143b054d`.

The source commits were cherry-picked in order so their original authorship is
retained. Conflicts were reconciled in favor of Basecamp v0.7.0's dependency,
security, Active Storage, and Rails test-matrix updates. Dreamer's unrelated
MySQL implementation and its broad scenario-tree rewrite were not imported;
the test harness supports the existing v0.7 SQLite scenarios alongside the new
PostgreSQL scenarios.

## Maintenance policy

Keep this branch pinned by commit from consuming applications. Future updates
should rebase or cherry-pick onto an explicitly documented Basecamp release,
retain PostgreSQL-focused tests, and avoid mixing unrelated adapter or product
changes into the compatibility delta.

## PostgreSQL contract

- Database tenancy uses a `database` template containing exactly one `%{tenant}`.
- Schema tenancy uses a static `database` and a `schema_name_pattern` containing exactly one `%{tenant}`.
- Logical tenant names map reversibly to quoted PostgreSQL identifiers. Empty names, NUL, and rendered identifiers over 63 bytes are rejected.
- Schema/database discovery is anchored to the configured template; unrelated and reserved schemas are excluded.
- Tenant creation, readiness recovery, migration, and cleanup hold a session advisory lock. Cleanup removes only resources created by the failing attempt.
- PostgreSQL behavior is implemented at tenanted call sites with Rails-native APIs; the gem does not globally patch PostgreSQL schema statements.
- Database tasks create missing resources on a clean server and use the same lifecycle as runtime tenant creation.
