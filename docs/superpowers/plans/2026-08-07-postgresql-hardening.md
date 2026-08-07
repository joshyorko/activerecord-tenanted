# PostgreSQL Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Active Record Tenanted's PostgreSQL database and schema strategies safe, deterministic, and production-testable on the Basecamp v0.7.0 line.

**Architecture:** Keep strategy-specific adapters behind the existing adapter factory, introduce shared PostgreSQL naming and advisory-lock primitives, and route runtime creation and Rails database tasks through the same locked lifecycle. Remove global PostgreSQL monkey patches and validate behavior against a real PostgreSQL 17 service.

**Tech Stack:** Ruby 3.4, Rails/Active Record 8.1, PostgreSQL 17, Minitest, GitHub Actions.

## Global Constraints

- Base remains Basecamp v0.7.0 commit `f1031b552f98ecc52e9a7856e55820e4609266ce`.
- Do not adopt Active Record Tenanted v0.8 behavior or Dreamer's unrelated MySQL work.
- Preserve Dreamer009/Ben Sullivan provenance for PR #261 source commits.
- Design the gem generally; Humidor IQ is only a downstream compatibility check.
- No pull request may be merged without Josh's explicit approval.

---

### Task 1: Explicit PostgreSQL strategy and naming contract

**Files:**
- Modify: `lib/active_record/tenanted/database_adapters/postgresql/factory.rb`
- Create: `lib/active_record/tenanted/database_adapters/postgresql/name_template.rb`
- Modify: `lib/active_record/tenanted/database_adapters/postgresql/base.rb`
- Modify: `lib/active_record/tenanted/database_adapters/postgresql/schema.rb`
- Modify: `lib/active_record/tenanted/database_adapters/postgresql/database.rb`
- Test: `test/unit/database_adapters_postgresql_factory_test.rb`
- Create: `test/unit/database_adapters_postgresql_name_template_test.rb`
- Modify: `test/unit/database_adapters_postgresql_schema_test.rb`

**Interfaces:**
- Produces: `NameTemplate.new(pattern, label:)`, `#physical_name(tenant)`, and `#logical_name(physical)`.
- Produces: factory validation requiring exactly one tenant template in `database` or `schema_name_pattern`.

- [ ] Add failing tests for mutually exclusive strategy templates, missing placeholders, byte limits, reversible UUID/integer/hyphen names, and reserved schema exclusion.
- [ ] Run the focused tests and confirm failures describe the missing contract.
- [ ] Implement `NameTemplate` and factory validation with anchored Ruby matching.
- [ ] Update both adapters to use the shared mapping and remove broad `PG::Error` absence handling.
- [ ] Run focused tests and commit the naming contract.

### Task 2: PostgreSQL advisory locking and safe creation lifecycle

**Files:**
- Create: `lib/active_record/tenanted/database_adapters/postgresql/advisory_lock.rb`
- Modify: `lib/active_record/tenanted/database_adapters/postgresql/base.rb`
- Modify: `lib/active_record/tenanted/tenant.rb`
- Create: `test/unit/postgresql_advisory_lock_test.rb`
- Modify: `test/unit/tenant_test.rb`

**Interfaces:**
- Produces: `AdvisoryLock#synchronize(tenant) { ... }` using a held maintenance connection and deterministic signed 64-bit key.
- Consumes: strategy adapter existence/create/drop operations.

- [ ] Add failing two-connection tests proving concurrent creators serialize and failure cleanup never drops a pre-existing resource.
- [ ] Add a failing recovery test for an existing resource whose migrations are incomplete.
- [ ] Implement the advisory lock and make `Tenant#create_tenant` re-check and migrate inside it while tracking current-attempt ownership.
- [ ] Run concurrency and tenant lifecycle tests repeatedly with randomized seeds.
- [ ] Commit the lifecycle hardening.

### Task 3: Remove global PostgreSQL patches

**Files:**
- Modify: `lib/active_record/tenanted/patches.rb`
- Modify: `lib/active_record/tenanted/railtie.rb`
- Modify: `lib/active_record/tenanted/database_adapters/postgresql/schema.rb`
- Modify: `lib/active_record/tenanted/database_configurations/tenant_config.rb`
- Create: `test/unit/postgresql_rails_api_isolation_test.rb`

**Interfaces:**
- Produces: schema creation through Rails' native `create_schema(name, if_not_exists: true)`.
- Preserves: unmodified Rails behavior for ordinary PostgreSQL connections.

- [ ] Add a failing regression test showing ordinary PostgreSQL `create_schema` duplicate/force semantics are untouched.
- [ ] Remove PostgreSQL adapter prepends and move idempotence/quoting to tenanted call sites.
- [ ] Run Rails API isolation plus schema-strategy tests.
- [ ] Commit the patch-boundary correction.

### Task 4: Fresh-server database tasks

**Files:**
- Modify: `lib/active_record/tenanted/database_tasks.rb`
- Modify: `lib/active_record/tenanted/database_adapters/colocated.rb`
- Modify: `test/unit/database_tasks_test.rb`
- Create: `test/integration/postgresql_database_tasks_test.rb`

**Interfaces:**
- Produces: locked create-if-absent and migrate behavior for `ARTENANT` and default local/test tenant preparation.

- [ ] Add clean-PostgreSQL failing tests for create, prepare, migrate, and drop under both strategies.
- [ ] Route tasks through the safe lifecycle without recursive task invocation.
- [ ] Verify interrupted/incomplete resources recover on the next prepare.
- [ ] Commit database-task repairs.

### Task 5: Adapter-aware integration harness and CI gate

**Files:**
- Modify: `bin/test-integration`
- Modify: `test/test_helper.rb`
- Modify: `.github/workflows/ci.yml`
- Modify: `Gemfile.lock`
- Modify: `gemfiles/rails_8_1.gemfile`
- Modify: `gemfiles/rails_edge.gemfile`

**Interfaces:**
- Produces: required Rails 8.1/PostgreSQL 17 verification separate from the preserved SQLite matrix.

- [ ] Fix scenario-root selection and ERB rendering, then prove each strategy fixture loads from its adapter directory.
- [ ] Correct mislabeled/misspelled schema fixtures and add adapter-class guard assertions.
- [ ] Add the required PostgreSQL 17 CI job for focused unit and integration commands.
- [ ] Run RuboCop, SQLite unit/integration tests, PostgreSQL focused tests, and clean-server task tests.
- [ ] Commit the test and CI gate.

### Task 6: Documentation, publication, and downstream pin

**Files:**
- Modify: `GUIDE.md`
- Modify: `README.md`
- Modify: `MAINTENANCE.md`
- Modify downstream: `Gemfile`, `Gemfile.lock`

**Interfaces:**
- Produces: exact maintained fork commit and documented PostgreSQL configuration contract.
- Consumes downstream: only the tested immutable fork commit.

- [ ] Align docs with explicit strategy templates, lifecycle guarantees, limitations, and provenance.
- [ ] Run full fork verification, inspect the diff, commit, push the maintained branch, and open a draft fork PR against a v0.7 maintenance base.
- [ ] Adapt Humidor IQ configuration if required, pin the exact fork commit, and run dependency/tenant-context verification.
- [ ] Commit, push, and open the Humidor IQ draft PR without merging.
- [ ] Report exact commits, test evidence, PR URLs, and residual risks to the coordinator.

## Self-review

- Spec coverage: naming, namespace safety, concurrency, readiness recovery, patch scope, database tasks, both strategies, CI, provenance, publication, and downstream verification are covered.
- Placeholder scan: no deferred implementation decisions remain.
- Interface consistency: strategy adapters consume the shared name template and advisory lock; runtime and task lifecycles consume the same safe adapter operations.
