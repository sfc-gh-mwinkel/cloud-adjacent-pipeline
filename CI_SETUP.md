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

The `clone_incrementals_for_ci()` on-run-start hook fires automatically because the target name is `check`, cloning incremental tables from prod so CI runs true incremental builds rather than full refreshes.

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

## Step 6: Enable Branch Protection (Recommended)

Require the CI check to pass before any PR can be merged:

1. Go to **Settings** → **Branches** → **Add branch protection rule**
2. Branch name pattern: `main`
3. Enable **Require status checks to pass before merging**
4. Search for and add: `dbt build (slim CI)`
5. Enable **Require branches to be up to date before merging**

> **Note:** Branch protection rules on public repos are free. Private repos require GitHub Pro or higher.

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
  ├── dbt build --select state:modified+   ← only changed models + downstream
  │            --defer                     ← use prod for unselected node refs
  │            --state ./prod-manifest     ← comparison state
  │            --target check              ← triggers clone_incrementals_for_ci()
  │
  └── Schema: <layer>_dbt_pr_<PR_NUMBER>    ← isolated per layer, dropped on PR close
```

The `clone_incrementals_for_ci()` on-run-start hook fires automatically when `target.name == check` and clones any incremental tables from their production source into the CI schema before `dbt build` runs — enabling true incremental builds (not full refreshes) in CI.

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
