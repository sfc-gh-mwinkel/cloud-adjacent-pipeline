# CI Setup Guide: GitHub Actions dbt Pipeline

This document covers everything needed to get the GitHub Actions CI pipeline running.

---

## What the Pipeline Does

| Trigger | Workflow | What Happens |
|---|---|---|
| Push to `main` | `dbt-prod.yml` | Runs `dbt seed + build --target prod`, uploads `manifest.json` as a workflow artifact |
| PR opened / updated | `dbt-ci.yml` | Downloads prod manifest, seeds CI schema, runs `dbt build --select state:modified+ --defer` in an isolated per-PR schema |
| PR closed (merged or abandoned) | `dbt-cleanup.yml` | Drops the ephemeral CI schema (`dbt_pr_<N>`) from Snowflake |

The CI job schemas are isolated per PR, namespaced by model layer:

| Layer | CI schema (PR #42) |
|---|---|
| staging | `staging_dbt_pr_42` |
| intermediate | *(ephemeral — no physical schema)* |
| marts | `marts_dbt_pr_42` |
| *(no custom schema)* | `dbt_pr_42` |

When a production manifest is available, CI first runs `dbt clone --full-refresh` for selected incremental models so reruns replace any prior PR clone. The `clone_incrementals_for_ci()` on-run-start hook then removes each model's configured window relative to the clone's maximum watermark so the build runs true incremental logic and rewrites rows.

Configure the trim watermark in the model properties:

```yaml
models:
  - name: fct_user_revenue
    meta:
      ci_trim_timestamp_column: last_event_at
      ci_trim_days: 1  # optional; defaults to vars.ci_trim_days
```

CI forces `on_schema_change: sync_all_columns` for the sample incremental model. Added, removed, and type-changed columns are synchronized on the clone and surfaced as a non-failing GitHub Actions warning, job summary, and same-repository PR comment. A warning means the production deployment should be reviewed for a full refresh because existing rows are not backfilled by schema synchronization. Fork PRs do not receive comments because their `GITHUB_TOKEN` is read-only, but their Actions annotation and summary still render.

The schema-drift reporting macro mirrors dbt-adapters 1.16.3. Review it whenever the pinned dbt dependencies change.

---

## Step 1: Generate a Snowflake RSA Key Pair

Run these commands locally. Keep the private key secure — it will be stored as a GitHub secret.

```bash
# Generate 2048-bit unencrypted RSA key (simplest for CI — no passphrase needed)
openssl genrsa -out snowflake_key.p8 2048
openssl rsa -in snowflake_key.p8 -pubout -out snowflake_key.pub

# View the public key content (needed for Snowflake)
cat snowflake_key.pub
```

> To use an encrypted key (passphrase-protected), replace the first command with:
> `openssl genrsa -aes256 -out snowflake_key.p8 2048`
> Then set `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` in GitHub secrets.

---

## Step 2: Register the Public Key with your Snowflake CI User

In Snowflake, run as ACCOUNTADMIN (or SECURITYADMIN):

```sql
-- Create a dedicated CI user (recommended)
CREATE USER ci_user
    DEFAULT_ROLE    = dbt_ci_role
    DEFAULT_WAREHOUSE = your_warehouse;

-- Assign the public key (paste contents without -----BEGIN/END lines and without newlines)
ALTER USER ci_user SET RSA_PUBLIC_KEY='MIIBIjANBgkq...your_key_content...AQAB';

-- Grant the role appropriate privileges
GRANT ROLE dbt_ci_role TO USER ci_user;
```

---

## Step 3: Add GitHub Repository Secrets

Go to your repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

| Secret Name | Required | Value | Notes |
|---|---|---|---|
| `SNOWFLAKE_ACCOUNT` | ✅ | `orgname-accountname` | Account identifier (no `.snowflakecomputing.com`) |
| `SNOWFLAKE_USER` | ✅ | `ci_user` | The user created above |
| `SNOWFLAKE_PRIVATE_KEY` | ✅ | *(contents of `snowflake_key.p8`)* | Paste the full PEM including `-----BEGIN RSA PRIVATE KEY-----` |
| `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` | ✅ | *(passphrase or leave empty)* | Leave empty if key is unencrypted |
| `SNOWFLAKE_DATABASE` | ✅ | `ANALYTICS` | Default database for prod and CI builds |
| `SNOWFLAKE_CI_DATABASE` | ⬜ optional | `ANALYTICS_CI` | If set, CI builds land here instead of `SNOWFLAKE_DATABASE`. Useful for isolating CI activity from your prod database. Falls back to `SNOWFLAKE_DATABASE` if unset. |
| `SNOWFLAKE_SCHEMA` | ✅ | `dbt_prod` | Production schema (used by `dbt-prod.yml`) |
| `SNOWFLAKE_WAREHOUSE` | ✅ | `TRANSFORM_WH` | Warehouse to use |
| `SNOWFLAKE_ROLE` | ✅ | `dbt_ci_role` | Role to assume (can be empty to use user default) |

---

## Step 4: Verify the `profiles/profiles.yml` is Committed

The `profiles/profiles.yml` file is committed to this repo and used by all dbt commands via `--profiles-dir ./profiles`. It reads all credentials from environment variables — no secrets are hardcoded.

```
profiles/
└── profiles.yml   ← committed, no secrets
```

The `check` target resolves the CI database as:
```
SNOWFLAKE_CI_DATABASE  (if set)
        ↓ fallback
SNOWFLAKE_DATABASE
```

---

## Step 5: Bootstrap the Production Manifest

On first run, there is no production manifest yet, so CI will fall back to a full `dbt build`. To bootstrap:

1. Merge any change to `main` to trigger `dbt-prod.yml`
2. Confirm it uploads the `dbt-prod-manifest` artifact (visible in the Actions run summary)
3. Subsequent PRs will automatically use slim CI

---

## Step 6: Configure Repository Administration

### 6a. Branch Protection Rules

Go to **Settings** → **Branches** → **Add branch protection rule**, pattern: `main`.

#### Required

| Setting | Why |
|---|---|
| **Require status checks to pass** → add `dbt build (slim CI)` | Blocks merges when CI fails |
| **Require branches to be up to date before merging** | Critical for slim CI correctness — see note below |
| **Do not allow bypassing the above settings** (enforce on admins) | Prevents accidental direct pushes from maintainers |

> **Why "up to date" is non-negotiable for slim CI**
>
> Slim CI only tests models that changed *in this PR* (`state:modified+`). Everything else is deferred to the production manifest from the last `main` run. If another PR merges to `main` after your CI check passed, your check is silently stale — it was computed against a manifest that no longer reflects prod. The merged PR's changes were never tested alongside yours.
>
> With **Require branches to be up to date** enabled, GitHub blocks the merge button the moment `main` advances, forcing a rebase that triggers a fresh CI run against the new manifest.

#### Recommended

| Setting | Why |
|---|---|
| **Require a pull request before merging** (1 approval minimum) | Ensures a second set of eyes before code executes against Snowflake — see security note below |
| **Dismiss stale pull request approvals when new commits are pushed** | Prevents approving a PR, then the author pushing new code without re-review |
| **Require conversation resolution before merging** | No unresolved review comments sneak through |
| **Allow squash merging only** (see 6b) | Keeps `main` history clean and linear; avoids merge commits and the empty "retrigger" commits that appear in `git log` |

> **Security note: collaborator write access = Snowflake CI access**
>
> Any collaborator with write access to this repo can push a dbt model or macro that runs arbitrary SQL via `dbt_ci_role` when CI fires. Requiring PR reviews creates a human approval gate before that code executes. Keep your collaborator list tight and treat it as equivalent to granting Snowflake warehouse access.

#### Not needed for this pipeline

| Setting | Notes |
|---|---|
| Require signed commits | Adds friction; not meaningful for automated CI pipelines |
| Require linear history | Redundant if you enforce squash merging in 6b |
| Lock branch | Only for archiving; would block all PRs |

---

### 6b. Merge Strategy

Go to **Settings** → **General** → **Pull Requests**.

Recommended configuration for this pipeline:

| Setting | Recommended | Reason |
|---|---|---|
| **Allow squash merging** | ✅ Enable | Clean single commit per feature on `main` |
| **Allow merge commits** | ❌ Disable | Creates noise in `git log`; empty retrigger commits inflate history |
| **Allow rebase merging** | ❌ Disable | Rewrites commit SHAs; breaks `git bisect` and manifest attribution |
| **Automatically delete head branches** | ✅ Enable | Keeps the branch list clean; CI schemas are dropped on PR close anyway |

> With squash-only merging, the commit message on `main` is the PR title. Write PR titles as imperative sentences (`feat: add total_event_count`) — they become your production change log.

---

### 6c. Fork Pull Request Behavior

For **public repos**, GitHub's `pull_request` trigger (used here) blocks Snowflake secrets from all fork workflows by default. A fork PR will trigger a CI run, but dbt will fail to connect — no Snowflake access is possible from a fork. This is the correct behavior.

The one gap: GitHub requires manual approval only for a contributor's *first* PR from a fork. Subsequent PRs auto-trigger. For a reference/demo repo this is acceptable. For a production pipeline, consider:

- **Settings → Actions → Fork pull request workflows** → *Require approval for all outside collaborators*

This adds a maintainer approval click before any fork PR runs, at the cost of more friction for external contributors.

---

### 6d. Merge Queue (for High-Velocity Repos)

With **Require branches to be up to date** and multiple contributors, a problem emerges: merging PR A invalidates PR B's check, which then needs to rebase and re-run CI before it can merge — and that rerun invalidates PR C, and so on. Only one PR can effectively merge at a time.

GitHub's **Merge Queue** solves this by batching PRs into a virtual merge order, running CI on the projected post-merge state, and committing only if CI passes. This gives the correctness guarantees of strict mode without the serialization friction.

To enable: **Settings** → **Branches** → edit the rule → **Require merge queue**.

> The merge queue is overkill for a small team or solo project. Enable it when you find maintainers frequently rebasing just to unblock each other.

---

### Current State of This Repository

| Protection | Status |
|---|---|
| Required status check: `dbt build (slim CI)` | ✅ Enabled |
| Require branches to be up to date (strict mode) | ✅ Enabled |
| Force pushes to `main` | ✅ Blocked |
| Deleting `main` | ✅ Blocked |
| Required PR reviews | ⬜ Not set (solo repo) |
| Enforce on admins | ⬜ Not set (solo repo) |
| Squash-only merge | ⬜ Not set — see 6b |
| Auto-delete head branches | ⬜ Not set — see 6b |

---

## How Slim CI Works

```
PR pushed
  │
  ├── Download dbt-prod-manifest (manifest.json from last prod run)
  │
  ├── dbt seed --target check
  │     └── loads seed data into the CI schema first (avoids race condition
  │         where source tests run before seeds are present)
  │
  ├── dbt clone --select "state:modified+,config.materialized:incremental"
  │            --state ./prod-manifest
  │            --full-refresh
  │            --target check
  │     └── zero-copy clones selected production incrementals into CI
  │
  ├── dbt build --select state:modified+   ← only changed models + downstream
  │            --defer                     ← use prod for unselected node refs
  │            --state ./prod-manifest     ← comparison state
  │            --target check              ← trims clones, then runs incrementally
  │
  └── Schema: <layer>_dbt_pr_<PR_NUMBER>    ← isolated per layer, dropped on PR close
```

The `clone_incrementals_for_ci()` on-run-start hook fires when `target.name == check` and removes the configured recent window from each clone before the selected models run.

---

## Network Policy

`ci_user` is protected by a Snowflake network policy (`ci_open_policy`) that restricts connections to GitHub Actions IP ranges only. The policy is automatically refreshed every Sunday at 06:00 UTC by a Snowflake Task:

```
ANALYTICS.OPS.refresh_ci_network_policy_task
  └── CALL analytics.ops.refresh_ci_network_policy()
        └── Fetches https://api.github.com/meta → aggregates IPv4 ranges
            → ALTER NETWORK POLICY ci_open_policy SET ALLOWED_IP_LIST = (...)
```

No GitHub credentials or runner minutes are used for policy maintenance — it runs entirely inside Snowflake via an external access integration (`github_meta_api_integration`).

---

## Troubleshooting

**CI fails with "No production manifest" on first run**
Expected — run the prod workflow once by merging to `main`.

**dbt can't connect: `JWT token is invalid`**
The RSA public key in Snowflake doesn't match the private key secret. Re-run Step 2 ensuring you pasted the correct public key.

**Schema not dropped after PR close**
Check the `dbt-cleanup.yml` run in Actions. The cleanup drops all schemas matching `%_dbt_pr_<N>` in the CI database. The CI user needs `DROP SCHEMA` privilege on the CI database (`SNOWFLAKE_CI_DATABASE` if set, otherwise `SNOWFLAKE_DATABASE`).

**CI builds landing in the wrong database**
Verify that `SNOWFLAKE_CI_DATABASE` is set correctly in repository secrets. If the secret is blank or missing, builds fall back to `SNOWFLAKE_DATABASE`.

**`state:modified+` selects nothing**
The manifest comparison uses git-tracked file changes. If you only changed non-model files (e.g. docs, seeds), no models will be selected — this is correct behavior. CI will succeed immediately with 0 models built.

**CI job blocked by network policy**
GitHub periodically expands their IP ranges. If a runner gets an IP not yet in `ci_open_policy`, manually trigger the refresh task:
```sql
EXECUTE TASK analytics.ops.refresh_ci_network_policy_task;
-- or call the procedure directly:
CALL analytics.ops.refresh_ci_network_policy();
```
