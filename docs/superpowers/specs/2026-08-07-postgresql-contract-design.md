# PostgreSQL Tenancy Contract Design

## Goal

Provide production-safe PostgreSQL support for Active Record Tenanted as a
general maintained gem. Both database-per-tenant and schema-per-tenant must be
isolated, discoverable, concurrency-safe, compatible with Rails database tasks,
and tested against a real PostgreSQL server. Consuming applications are
downstream compatibility checks, not design constraints.

## Configuration contract

PostgreSQL strategy selection is explicit through mutually exclusive templates:

- Database tenancy: `database` contains exactly one `%{tenant}` placeholder.
- Schema tenancy: `database` is static and `schema_name_pattern` contains exactly
  one `%{tenant}` placeholder.

A static database without `schema_name_pattern`, both templates at once, or a
pattern without the placeholder is a configuration error. This removes the
unsafe implicit bare-schema behavior while retaining a compact Rails-native
configuration shape.

Tenant names are logical identifiers. Each strategy maps the logical name to a
quoted physical PostgreSQL identifier through its configured template. The
mapping must be reversible for enumeration. Physical identifiers must fit
PostgreSQL's 63-byte identifier limit and may not contain NUL. Schema enumeration
reads PostgreSQL catalog names and applies an anchored Ruby matcher derived from
`schema_name_pattern`; it never uses `LIKE '%'` and never returns `public`,
`information_schema`, `pg_*`, or unrelated application schemas.

## Lifecycle and concurrency

Each PostgreSQL strategy acquires a session-level advisory lock through the
configured maintenance database before checking, creating, migrating, or
destroying a tenant resource. The signed 64-bit lock key is deterministically
derived from the environment, configuration name, strategy, physical resource
template, and logical tenant name. Holding the maintenance connection for the
duration makes the lock process-safe and shared by database and schema workers.

Inside the lock, lifecycle operations re-check existence. Creation and migration
are treated as one readiness transition: an existing resource is migrated
idempotently so a process can recover work left incomplete by a crashed creator.
Failure cleanup only removes a resource proven to have been created by the
current attempt; it never drops a resource another process may own. Concurrent
`create_tenant(..., if_not_exists: true)` callers converge on one ready tenant.

## Rails integration boundaries

The gem does not prepend global PostgreSQL schema behavior. Schema creation uses
Rails' native `create_schema(..., if_not_exists: true)` at the tenanted call
site. Tenant connection configuration supplies a correctly quoted
`schema_search_path`; ordinary PostgreSQL connections retain Rails' untouched
`create_schema` and `schema_search_path=` semantics.

Database tasks use the same locked lifecycle primitives as runtime creation.
On a clean PostgreSQL server:

- `db:create` creates shared/colocated storage without inventing a tenant.
- `db:prepare` and `db:migrate` with `ARTENANT=<name>` create the selected tenant
  resource if absent and migrate it.
- default local/test tenant preparation follows the existing v0.7 policy.
- `db:drop` and tenant destruction terminate only relevant database connections
  or drop only the namespaced schema.

Adapter errors distinguish absence from outages and permission failures; broad
`PG::Error` rescue paths do not convert operational failures into false
non-existence.

## Test and CI contract

Basecamp v0.7's SQLite unit/integration matrix remains unchanged. A required
Rails 8.1 + PostgreSQL 17 job runs targeted tests for both PostgreSQL strategies:

- create, use, enumerate, isolate, and destroy two tenants;
- unrelated/reserved schema exclusion;
- logical names with UUIDs, integers, hyphens, underscores, and suffix-like text;
- two concurrent creators and recovery from an existing incomplete resource;
- clean-server database tasks, schema dump, and schema-cache paths;
- custom maintenance database and primary/named/secondary configurations;
- proof that ordinary PostgreSQL schema APIs retain native Rails behavior.

Rails edge remains informative rather than a publication gate. Integration
fixtures are rooted through one adapter-aware path and render ERB before applying
scenario substitutions.

## Provenance and maintenance

The branch remains based on Basecamp v0.7.0 commit
`f1031b552f98ecc52e9a7856e55820e4609266ce`. Dreamer009/Ben Sullivan's Basecamp
PR #261 commits `7b09a4655d1aea6dd9c51d71b50c9a23481593f1` through
`112e752af16a631b92b426d96e7d208c143b054d` are preserved as source history and
credited in maintenance documentation. Hardening commits intentionally replace
unsafe draft behavior; they do not claim the final contract is an unchanged
copy of the draft.

Humidor IQ is evaluated only after this contract is green. Any application
configuration changes belong to its separate dependency-switch pull request.

## Accepted complexity and exclusions

Advisory locking, reversible physical-name templates, and strategy-specific
lifecycle code are accepted complexity because they enforce isolation and
durability contracts. This work does not adopt v0.8 serialization changes,
add MySQL support, publish a gem artifact, or merge downstream pull requests.
