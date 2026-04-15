# cloud-adjacent-pipeline

A reference implementation of dbt Cloud CI behavior using GitHub Actions and Snowflake — no dbt Cloud required.

---

## What This Is

dbt Cloud's CI check jobs give you slim CI out of the box: only run models that changed, defer everything else to production, catch breaking changes before they merge. This repo replicates that behavior with open-source tooling:

- **GitHub Actions** for orchestration
- **Snowflake** as the data warehouse
- **RSA key pair authentication** for secure, credential-free CI connections
- **Per-PR isolated schemas** that are automatically created and dropped
- **A Snowflake-native network policy** that restricts the CI user to GitHub Actions IPs only

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub                                                         │
│                                                                 │
│  PR opened/updated                                              │
│    └── dbt-ci.yml ──────────────────────────────────────────┐  │
│          1. Download prod manifest (from last main run)      │  │
│          2. dbt seed  (CI schema)                            │  │
│          3. dbt build --select state:modified+               │  │
│                       --defer --state ./prod-manifest        │  │
│          Result: PASS → PR can merge / FAIL → PR is blocked  │  │
│                                                              │  │
│  Push to main                                                │  │
│    └── dbt-prod.yml                                          │  │
│          1. dbt seed + build --target prod                   │  │
│          2. Upload manifest.json artifact ◄──────────────────┘  │
│                                                                 │
│  PR closed (merged or abandoned)                                │
│    └── dbt-cleanup.yml                                          │
│          DROP SCHEMA ANALYTICS.DBT_PR_<N>                       │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  Snowflake                                                      │
│                                                                 │
│  ANALYTICS.DBT_PROD        ← production models                  │
│  ANALYTICS.DBT_PR_3        ← PR #3 CI build (ephemeral)         │
│  ANALYTICS.DBT_PR_4        ← PR #4 CI build (ephemeral)         │
│                                                                 │
│  ANALYTICS.OPS             ← infrastructure objects            │
│    refresh_ci_network_policy()   Snowpark procedure             │
│    refresh_ci_network_policy_task  Weekly Task (Sun 06:00 UTC)  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Data Model

```
raw_events (seed)
    └── stg_events  [view]
            └── int_user_event_summary  [ephemeral]
                        └── fct_user_revenue  [incremental table]
```

| Model | Materialization | Description |
|---|---|---|
| `stg_events` | View | Typed and renamed events from the seed source |
| `int_user_event_summary` | Ephemeral | Per-user aggregation of purchase/refund counts and revenue |
| `fct_user_revenue` | Incremental table | One row per user with revenue metrics; incremental on `last_event_at` |

---

## Slim CI in Action

When a PR only touches `int_user_event_summary`, slim CI selects:

```
int_user_event_summary   ← modified
fct_user_revenue         ← downstream (+)
```

`stg_events` and its tests are deferred — they resolve to the prod versions in `ANALYTICS.DBT_PROD`. Only the 2 affected nodes (+ their tests) run, not the full DAG.

---

## Key Design Decisions

**`generate_schema_name` macro** — For any non-prod target, all models build into `target.schema` regardless of model-level `schema:` config. This prevents CI builds from accidentally scattering across multiple schemas.

**`clone_incrementals_for_ci()` on-run-start hook** — Clones incremental tables from their production source before `dbt build` runs. This allows CI to test true incremental logic (not a full refresh) against a realistic data state.

**Separate `dbt seed` step** — Seeds run as a dedicated step before `dbt build` to avoid a race condition where source freshness tests fire before the seed data exists.

**`SNOWFLAKE_CI_DATABASE` secret (optional)** — When set, all CI builds (and schema cleanup) target this database instead of `SNOWFLAKE_DATABASE`. Useful for fully isolating CI activity from the production database.

**Network policy** — `ci_user` is restricted to GitHub Actions IP ranges via `ci_open_policy`. The allowed list is refreshed weekly by a Snowflake Task (`ANALYTICS.OPS.refresh_ci_network_policy_task`) that calls `https://api.github.com/meta` through an external access integration — no GitHub credentials required.

---

## Repository Layout

```
.github/workflows/
  dbt-ci.yml          PR CI check (slim build)
  dbt-prod.yml        Production build + manifest upload
  dbt-cleanup.yml     Drop CI schema on PR close

models/
  staging/            stg_events
  intermediate/       int_user_event_summary (ephemeral)
  marts/              fct_user_revenue (incremental)

macros/
  generate_schema_name.sql      Isolates dev/CI builds to target.schema
  hooks/
    clone_incrementals_for_ci.sql   Clones prod incrementals into CI schema

profiles/
  profiles.yml        check + prod targets (all creds from env vars)

seeds/
  raw_events.csv
```

---

## Setup

See **[CI_SETUP.md](./CI_SETUP.md)** for the full step-by-step guide including key generation, Snowflake user setup, GitHub secrets, and branch protection configuration.
