# Migration Runbook: GCP → Vercel + compose VMs

Moves everything off the `compute-bench` GCP stack (Global LB + CDN, GCS static sites, Cloud Run,
Cloud SQL, Cloud Build) to:

| Workload | Target | Domains | Data |
| :--- | :--- | :--- | :--- |
| `nobuffer-site` | Vercel (Git integration) | `vitorx86.dev`, `www.vitorx86.dev` | none |
| `personal-portifolio` | Vercel (Git integration) | `me.vitorx86.dev`, `cases.vitorx86.dev` | none |
| `personal-blog` (Ghost 5.130) | GCE e2-micro VM (same as Taiga) + local MySQL, [`cloud/personal-blog`](../cloud/personal-blog) | `blog.vitorx86.dev` | MySQL `ghost` + `blog-content-compute-bench` |
| `taiga` (back 6.10.2 / front 6.10.3) | GCE e2-micro VM, database on Neon Postgres 15, [`cloud/taiga`](../cloud/taiga) | `taiga.vitorx86.dev` | Postgres `taiga` + `taiga-content-compute-bench` |

DNS records live in Cloud DNS zone `vitorx86-dev` in project **`study-deploys`** and are changed **by hand**.
Rollback for every step is "point the record back at the old LB IP `34.110.226.37`" until Phase 5.

Order: **Phase 0 → (Phase 1 ∥ Phase 2) → Phase 3 → Phase 4 → Phase 5.**

---

## Phase 0: Freeze and prepare

- [ ] **Disable the old pipelines** (they must not run while files change underneath them):

  ```bash
  gh workflow disable terraform-cloud.yml   # until the PR that deletes it is merged
  gh workflow disable build-blog.yml
  gh workflow disable build-taiga.yml
  ```

  The migration PR also deletes `terraform-cloud.yml` and removes the `push:` triggers from
  `build-blog.yml`/`build-taiga.yml`, so merging it cannot redeploy Cloud Run even if you skip this.
- [ ] Create GitHub Environments `blog-prod` and `taiga-prod` (Settings → Environments, deployment
  branches: `main` only) and set the gates `BLOG_DEPLOY_ENABLED=false`, `TAIGA_DEPLOY_ENABLED=false`:

  ```bash
  gh api -X PUT repos/vitorecomp/personal-infra/environments/blog-prod \
    -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
  gh api -X POST repos/vitorecomp/personal-infra/environments/blog-prod/deployment-branch-policies -f name=main
  # repeat for taiga-prod
  gh variable set BLOG_DEPLOY_ENABLED --body false
  gh variable set TAIGA_DEPLOY_ENABLED --body false
  ```
- [ ] GCP billing + OCI API key: [vm-provisioning.md §1](./vm-provisioning.md#1-one-time-prerequisites).
- [ ] **Baseline archive** (server-side Cloud SQL export + content buckets, no VM needed):

  ```bash
  python3 cloud/scripts/migrate_gcp_data.py archive --stack personal-blog --dry-run
  python3 cloud/scripts/migrate_gcp_data.py archive --stack personal-blog
  python3 cloud/scripts/migrate_gcp_data.py archive --stack taiga
  # -> ~/.local/state/personal-infra/migrations/<stack>/archive-<ts>/ and gs://compute-bench_cloudbuild/sql-archive/
  ```

  The first run grants the Cloud SQL instance service account `objectAdmin` on the archive bucket.
- [ ] Keep an encrypted copy of the legacy state (it contains DB passwords):
  `terraform -chdir=cloud/infra/envs/prod state pull | gpg -c > ~/prod-state-$(date +%F).json.gpg`.

## Phase 1: Tooling (this PR)

Terraform roots (`cloud/infra/envs/{gcp-taiga,oci-blog}`), stacks (`cloud/{personal-blog,taiga}/compose.yml`),
`bootstrap_vm.py`, `deploy_stack.py`, `backup_stack.py`, `migrate_gcp_data.py`, `deploy-{blog,taiga}.yml`
(gated off) and CI validation.

External PRs:

- [ ] `vitorecomp/personal-blog`: pin Ghost. In `Dockerfile` use
  `ARG GHOST_VERSION=5.130.6` + `FROM docker.io/library/ghost:${GHOST_VERSION}-alpine`
  (`compose.yml` already passes the `GHOST_VERSION` build arg).
- [ ] `nobuffer-site` / `personal-portifolio`: `vercel.json` (Phase 2 settings) and, for the portfolio,
  remove the stray `package-lock.json` (it also has `pnpm-lock.yaml` + `packageManager`).

## Phase 2: Static sites to Vercel (parallel with Phase 1)

**Done 2026-11-12.** DNS moved to Cloudflare (DNS only records pointing at Vercel); Let's Encrypt certificates issued
by Vercel; the GCS pipeline (`build-website.yml`, `build-portfolio.yml`, Cloud Build files, download scripts) was removed.

| | `nobuffer-site` | `personal-portifolio` |
| :--- | :--- | :--- |
| Production branch | `master` | `main` |
| Framework preset | Other | Next.js |
| Install command | `npm ci` | `pnpm install --frozen-lockfile` (+ env `ENABLE_EXPERIMENTAL_COREPACK=1`) |
| Build command | `npm run build` | `pnpm run build:export` |
| Output directory | `build` | default (or `out` with preset *Other* + `"trailingSlash": true`) |
| Node.js | 22.x | 24.x |

1. Import both repos in Vercel and check the `*.vercel.app` previews.
2. Add the domains to the projects (they show "Invalid configuration" until DNS changes; that's expected).
3. Lower the TTL of the records you're moving to 60s, at least one old TTL (300s) ahead.
4. Flip `me` and `cases` first: delete their A records, add `CNAME` to the target Vercel shows.
   Check the pages and certificates. Then flip the apex `A` record and `www` (`CNAME`).
5. `gh workflow disable build-website.yml build-portfolio.yml`. Delete `.github/workflows/trigger-deploy.yml`
   and the `PERSONAL_INFRA_TOKEN` secret in both app repos.
6. Follow-up PR: delete `build-website.yml`, `build-portfolio.yml`, `cloud/nobuffer-site/cloudbuild.yaml`,
   `cloud/personal-portifolio/`, `download_nobuffer_site.py`, `download_personal_portifolio.py` and their
   `ci.yml` dry-run lines.

## Phase 3: Blog to the GCP VM

**Change of plan (2026-11-12):** the blog runs on the same GCE e2-micro as Taiga (Ghost + a small local MySQL),
behind the shared edge Caddy (`cloud/edge`). Taiga's Postgres moved to Neon to free the memory MySQL needs.
The Oracle A1 VM is still being acquired by the capacity retry loop but no stack depends on it.
The original Oracle steps below stay for reference; for the GCP VM, skip the Terraform/bootstrap part,
deploy with `--identity-file ~/.ssh/blog_deploy`, and switch `BLOG_TLS` in `/opt/stacks/edge/.env` at cutover.

**Build-out**

1. [vm-provisioning.md §2](./vm-provisioning.md#2-first-apply): `terraform apply` in `envs/oci-blog`, then
   `bootstrap_vm.py --provider oracle ...` (dry-run → apply → `--check` shows no drift).
2. First deploy, creating the VM `.env` (secrets are generated on the VM):

   ```bash
   python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@$IP \
     --identity-file ~/.ssh/blog_deploy --init-env
   ```

   The generated `.env` starts with `CADDY_TLS=internal` (Caddy's local CA), so no Let's Encrypt
   attempts happen while DNS still points at GCP; the health check runs without certificate verification.

   Keep 80/443 restricted to your IP (`web_source_cidrs`) until cutover: a fresh, unclaimed Ghost must not be public.
3. Backups: create the HMAC key ([vm-provisioning.md §4](./vm-provisioning.md#4-day-2-operations)), put it in the VM
   `.env`, then on the VM: `python3 /opt/stacks/.ops/backup_stack.py --stack personal-blog --init`.
   Save `RESTIC_PASSWORD` from the VM `.env` in your password manager.
4. CI: set the `blog-prod` secrets/variables ([vm-provisioning.md §5](./vm-provisioning.md#5-hand-off-to-cicd)),
   `gh variable set BLOG_DEPLOY_ENABLED --body true`, run *Deploy the Personal Blog (Oracle VM)* manually.

**Restore the saved export** (the old Cloud SQL/GCS blog may already be deleted)

The final blog data was exported on 2026-11-12 (`export-20261112T053347Z`: MySQL dump + content, restore-tested
in MySQL 8.0.46 with identical row counts). It lives in `~/.local/state/personal-infra/migrations/personal-blog/`
and in `gs://vitorx86-backups/migration/personal-blog/`. If the local copy is gone, download it first:

```bash
mkdir -p ~/.local/state/personal-infra/migrations/personal-blog
gcloud storage rsync --recursive gs://vitorx86-backups/migration/personal-blog/export-20261112T053347Z \
  ~/.local/state/personal-infra/migrations/personal-blog/export-20261112T053347Z
```

```bash
EXPORT=~/.local/state/personal-infra/migrations/personal-blog/export-20261112T053347Z
python3 cloud/scripts/migrate_gcp_data.py import --stack personal-blog --host deploy@$IP \
  --identity-file ~/.ssh/blog_deploy --local-export $EXPORT --confirm-overwrite
python3 cloud/scripts/migrate_gcp_data.py verify --stack personal-blog --host deploy@$IP \
  --identity-file ~/.ssh/blog_deploy --offline --local-export $EXPORT    # row/file counts vs the export manifest
curl -sk --resolve blog.vitorx86.dev:443:$IP https://blog.vitorx86.dev/ghost/api/admin/site/ | head -c 300   # "version":"5.130"
curl -sk --resolve blog.vitorx86.dev:443:$IP -o /dev/null -w '%{http_code}\n' https://blog.vitorx86.dev/rss/
BLOG_ADMIN_EMAIL=... BLOG_ADMIN_PASSWORD=... python3 cloud/scripts/seed_ghost_admin.py --connect-ip $IP --insecure
ssh deploy@$IP 'python3 /opt/stacks/.ops/backup_stack.py --stack personal-blog && python3 /opt/stacks/.ops/backup_stack.py --stack personal-blog --restore-test'
```

`.dev` is HSTS-preloaded, so a browser won't let you click past the rehearsal certificate. Use curl, or
trust Caddy's local root (`docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt .`) in a
throwaway browser profile with an `/etc/hosts` entry.

**Cutover** (T = DNS change)

| When | Who | Action |
| :--- | :--- | :--- |
| T−1 day | you | `blog` record TTL → 60 |
| T−15 min | you | Content freeze (no edits in Ghost admin on the old site) |
| T−10 min | either | Data: restore the saved export (above) if not done yet; `verify --offline` must show parity. (If the old Cloud SQL still exists and the blog changed since 2026-11-12, run `migrate_gcp_data.py all --stack personal-blog ... --confirm-overwrite` instead.) |
| T−5 min | you | `web_source_cidrs = ["0.0.0.0/0"]` in `oci-blog` → plan → apply |
| T0 | you | Cloud DNS: `blog` A → `$IP` |
| T+1 min | either | Once the authoritative answer shows `$IP` (`dig +short blog.vitorx86.dev @ns-cloud-a1.googledomains.com`, or without dig: `curl -s 'https://dns.google/resolve?name=blog.vitorx86.dev&type=A'`), switch Caddy to Let's Encrypt on the VM: `cd /opt/stacks/personal-blog && sed -i 's/^CADDY_TLS=.*/CADDY_TLS=vitor.ecomp@gmail.com/' .env && docker compose up -d caddy`, then watch `docker compose logs -f caddy` for "certificate obtained successfully" (switching only after DNS points here avoids failed ACME validations, which Let's Encrypt rate-limits) |
| T+5 min | either | `deploy_stack.py --stack personal-blog ...` passes with strict TLS; browser login to `/ghost` |
| T+10 min | either | Push a theme change (or `workflow_dispatch`) in `personal-blog` and see it deploy via SSH |
| T+1 day | either | `systemctl list-timers 'stack-backup@*'` ran; `journalctl -u stack-backup@personal-blog`; TTL back to 300 |

**Rollback:** while the old stack exists, blog A record → `34.110.226.37` (Cloud Run + Cloud SQL were never modified). After Phase 5, the saved export is the fallback. Anything written on
the VM after cutover must be reverse-synced (`mysqldump` on the VM → import via cloud-sql-proxy) or accepted as lost.

**Follow-up PR:** delete `build-blog.yml`, `cloud/personal-blog/cloudbuild.yaml`, `download_personal_blog.py`
and their `ci.yml` lines.

## Phase 4: Taiga to GCE

Same flow as Phase 3, with these differences:

1. `terraform apply` in `envs/gcp-taiga`. Bootstrap with
   `--provider gce --swap-gb 3 --backup-stack taiga --deploy-pubkey-file ~/.ssh/taiga_deploy.pub`.
2. **Before the first deploy:** create the `.env`, then copy the Cloud Run secrets into it
   (`TAIGA_SECRET_KEY` signs sessions, auth tokens and attachment URLs; `TAIGA_ADMIN_*` keeps the same admin login):

   ```bash
   python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@$IP --identity-file ~/.ssh/taiga_deploy --init-env || true
   python3 cloud/scripts/migrate_gcp_data.py copy-secrets --stack taiga --host deploy@$IP --identity-file ~/.ssh/taiga_deploy
   python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@$IP --identity-file ~/.ssh/taiga_deploy
   ```

   The first `deploy_stack.py` stops at the preflight until the secrets are copied; that's expected.
3. The first image build on an e2-micro is slow (10–20 min). If memory is unworkable, set
   `machine_type = "e2-small"` and apply (in-place).
4. Rehearsal: `migrate_gcp_data.py all --stack taiga ...`, then
   `curl -sk --resolve taiga.vitorx86.dev:443:$IP https://taiga.vitorx86.dev/api/v1/project-templates`,
   `TAIGA_ADMIN_PASSWORD=... python3 cloud/scripts/seed_taiga_admin.py --connect-ip $IP --insecure`,
   open one attachment URL, `verify` shows parity.
5. Cutover: same table as Phase 3 (`taiga` record, `gcp-taiga` `web_source_cidrs`).
   Afterwards: `python3 workspace/scripts/taiga_cli.py projects list` and
   `python3 workspace/scripts/enroll_taiga_projects.py --dry-run` work against the VM.
6. Follow-up PR: delete `build-taiga.yml`, `cloud/taiga/cloudbuild.yaml`, `deploy_taiga.py`; switch
   `_resolve_password_from_cloud_run()` in `taiga_cli.py`/`enroll_taiga_projects.py` to env-only; update `ci.yml`.

## Taiga database on Neon (2026-11-12)

Taiga's data moved from the VM's local Postgres to **Neon** (managed Postgres **15**, AWS us-east-2, ~24 ms
from the VM) to free memory for the blog's MySQL on the same e2-micro. Exact row counts matched after the move.

- Taiga 6.10 needs Postgres **≤ 15**: its `json_object_delete_keys(json json, ...)` function is a syntax error on
  16+ (`json` became a keyword), so the Neon project must stay on 15.
- Connection settings live in `/opt/stacks/taiga/.env` (`TAIGA_DB_*`, direct endpoint, not `-pooler`) and in the
  `taiga-prod` GitHub environment, from which `deploy-taiga.yml` syncs them (`deploy_stack.py --sync-env`).
  Taiga's settings read `POSTGRES_SSLMODE` (default `disable`), so the compose file sets it to `require`.
- The container health check never touches the database, so Neon's compute can scale to zero (free plan:
  100 CU-hours/month per project).
- Backups dump Neon remotely with a `postgres:15` client (`backup_stack.py`, `mode: remote`).
- The old local Postgres volume `taiga_postgres-data` is kept on the VM for rollback; delete it once Neon has
  run a while (`docker volume rm taiga_postgres-data`).

## Taiga on Cloud Run (2026-11-12)

The e2-micro could not hold Ghost + MySQL + Taiga without swapping, so the Taiga **app** moved to Cloud Run
(free tier: 1 vCPU / 512 MiB, 0..1 instances, request-based CPU) while the VM keeps the blog and the edge Caddy.
Resources come from `cloud/infra/envs/gcp-taiga`; `deploy_stack.py --stack taiga` runs
`cloud/taiga/deploy-cloudrun.sh` on the VM (build, migrations against Neon, Secret Manager sync, revision rollout)
with the VM's service account. Uploads live in `gs://vitorx86-taiga-media`; the edge Caddy proxies
`taiga.vitorx86.dev` to the `run.app` URL (`TAIGA_UPSTREAM`). Optional later: a Cloud Run domain mapping
(needs domain verification) would take Taiga's traffic off the VM's 1 GB/month free egress.

## Phase 5: Decommission `compute-bench`

Prerequisites: Taiga is live on its VM, `vitorx86.dev`/`www`/`me`/`cases` resolve to Vercel, and the final exports
of both apps are in `gs://vitorx86-backups/migration/` (done 2026-11-12 for both). The blog no longer needs the old
stack: Phase 3 restores it from the saved export. Then:

1. Final archives: `migrate_gcp_data.py archive --stack personal-blog` and `--stack taiga`.
2. Destroy the legacy Terraform state: [vm-provisioning.md §7](./vm-provisioning.md#7-decommission-the-legacy-compute-bench-stack-phase-5).
3. Clean up:

   ```bash
   gcloud storage rm -r gs://compute-bench_cloudbuild/terraform/state/personal-infra-prod/
   gcloud iam service-accounts delete personal-infra-deployer@compute-bench.iam.gserviceaccount.com --project compute-bench
   gh secret delete GCP_SA_KEY
   for v in GCP_PROJECT_ID GCP_REGION GCS_BUCKET_NAME GCS_PORTFOLIO_BUCKET_NAME GCS_BLOG_CONTENT_BUCKET_NAME \
            GCS_TAIGA_CONTENT_BUCKET_NAME GAR_BLOG_REPO GAR_TAIGA_REPO CLOUD_RUN_BLOG_SERVICE CLOUD_RUN_TAIGA_SERVICE \
            BLOG_RUNTIME_SA TAIGA_RUNTIME_SA BLOG_DB_INSTANCE_NAME BLOG_DB_TIER BLOG_DB_NAME BLOG_DB_USER \
            TAIGA_DB_INSTANCE_NAME TAIGA_DB_TIER TAIGA_DB_NAME TAIGA_DB_USER NOBUFFER_DOMAINS PORTFOLIO_DOMAINS \
            BLOG_DOMAINS TAIGA_DOMAINS BLOG_URL TAIGA_URL TAIGA_DOMAIN; do gh variable delete "$v" 2>/dev/null; done
   ```

   Keep `METRICS_TOKEN`. Don't delete the `compute-bench` or `study-deploys` projects: they host unrelated workloads and the DNS zone.
4. Final PR: delete `cloud/infra/envs/prod`, `cloud/infra/modules/load-balancer`, the `prod` entry of the
   `terraform-validate` matrix, `migrate_gcp_data.py` and its `ci.yml` lines; refresh the docs.

## Known risks

| Risk | Mitigation |
| :--- | :--- |
| Old pipelines redeploy Cloud Run during the migration | Workflows disabled (Phase 0) + push triggers removed in the migration PR |
| A manual apply replaces a VM holding data | `prevent_destroy`, `deletion_protection`, `ignore_changes`, plan review ([vm-provisioning §3](./vm-provisioning.md#3-every-change-plan-review-apply)) |
| e2-micro (1 GB) too small for Taiga + Postgres | 3 GB swap, 1 gunicorn worker, tuned Postgres; `machine_type = "e2-small"` in place |
| A1 capacity / halved Always Free limits | 1 OCPU / 6 GB; `availability_domain_index`; PAYG |
| Oracle reclaims an idle Always Free VM | PAYG upgrade, restic backups in GCS (off Oracle), external uptime check |
| ACME failures / rate limits at cutover | `tls internal` rehearsal, Caddy restart after the flip, persistent `caddy-data` volume |
| `TAIGA_SECRET_KEY` mismatch logs everyone out | `migrate_gcp_data.py copy-secrets` before Taiga's first boot |
| Deleting unrelated GCP resources | Only `terraform destroy` on the legacy state; never delete projects or zones |
