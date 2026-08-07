# PostgreSQL hardening handoff

Branch: `maintained/postgresql-v0.7`

Basecamp basis: v0.7.0 at `f1031b552f98ecc52e9a7856e55820e4609266ce`.
Dreamer009/Ben Sullivan provenance: Basecamp PR #261, commits `7b09a4655d1aea6dd9c51d71b50c9a23481593f1` through `112e752af16a631b92b426d96e7d208c143b054d`.

## Implemented

- Explicit PostgreSQL database and schema strategies with exactly one `%{tenant}` template.
- Reversible quoted identifier mapping, including parallel-test worker isolation, 63-byte enforcement, and empty/NUL rejection.
- Namespace-safe schema/database enumeration and reserved-schema exclusion.
- Session-level PostgreSQL advisory locking for tenant lifecycle and database tasks.
- Existing-resource migration recovery and cleanup ownership tracking.
- Rails-native schema creation with the unsafe global PostgreSQL patches removed.
- Fresh-server database-task lifecycle for database and schema strategies.
- Adapter-aware PostgreSQL integration fixtures and a required Rails 8.1/PostgreSQL 17 CI job.
- PostgreSQL contract, maintenance basis, and PR #261 provenance documentation.

## Verification completed

- Naming/factory/schema/database/worker tests: 51 runs, 109 assertions, 0 failures.
- PostgreSQL Rails API isolation: 2 runs, 7 assertions, 0 failures (Rails 8.2 edge container); earlier Rails 8.1 run passed 1 run, 5 assertions.
- PostgreSQL advisory locking: 3 runs, 8 assertions, 0 failures.
- Existing-resource recovery/cleanup focused tests: 10 runs, 14 assertions, 0 failures.
- Concurrent creators for both PostgreSQL strategies: 2 runs, 8 assertions, 0 failures.
- Fresh-server task tests before stricter lock checks: 4 runs, 23 assertions, 0 failures.
- Drop locking for both strategies: 2 runs, 14 assertions, 0 failures.
- Colocated create locking: 1 run, 5 assertions, 0 failures.
- Default tenant preparation: 2 runs, 6 assertions, 0 failures.
- Live PostgreSQL 17 enumeration returned only configured tenants and excluded an unrelated schema.
- Scoped RuboCop checks and `git diff --check` passed.

## Remaining before a review-ready PR

- Run the final combined focused PostgreSQL suite after all tracks were integrated.
- Run `ADAPTER=postgresql bin/test-integration` to completion without another test process sharing its PostgreSQL server. The last clean run passed `db:prepare` and entered the first Rails scenario before it was intentionally stopped for this handoff.
- Run the preserved SQLite unit/integration matrix and full RuboCop suite.
- Review the final diff for accidental test artifacts or over-broad cleanup. In particular, PostgreSQL test cleanup must delete only resources created by its own run.
- Open the maintained-fork PR only after those checks. Do not merge without Josh's approval.
- Humidor IQ dependency pinning is a separate downstream task and has not been started.

## Resume workflow

From this repository on `maintained/postgresql-v0.7`:

```sh
git pull --ff-only
docker network create art-v07-test 2>/dev/null || true
docker run --rm --name art-v07-postgres --network art-v07-test \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=test postgres:17
```

In another shell, use the existing `activerecord-tenanted-bundle` volume:

```sh
docker run --rm --network art-v07-test -v "$PWD:/app" -w /app \
  -v activerecord-tenanted-bundle:/usr/local/bundle \
  -e POSTGRES_HOST=art-v07-postgres -e POSTGRES_USERNAME=postgres \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_PORT=5432 ruby:3.4 \
  sh -lc 'bundle install && bin/test-unit'

docker run --rm --network art-v07-test -v "$PWD:/app" -w /app \
  -v activerecord-tenanted-bundle:/usr/local/bundle \
  -e POSTGRES_HOST=art-v07-postgres -e POSTGRES_USERNAME=postgres \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_PORT=5432 ruby:3.4 \
  sh -lc 'ADAPTER=postgresql bin/test-integration'
```

Then run the SQLite integration matrix and RuboCop using the same Ruby container, inspect `git diff`, and open a draft PR against Basecamp's v0.7 maintenance basis.
