# Migration Runbook: Legacy GCP Stack → Vercel + Compose VMs

> **Completed 2026-11-12. Kept as generic architecture history.** Final state: static sites on Vercel; the blog on the
> GCE e2-micro `personal-host` (Ghost + local MySQL behind the edge Caddy); Taiga on Cloud Run with Neon Postgres 15;
> DNS on Cloudflare. The legacy `<legacy-gcp-project>` stack was destroyed (46 resources) and `migrate_gcp_data.py`
> deleted; its final exports/archives live in `gs://$BACKUP_BUCKET/migration/`. Current docs:
> [cloud-architecture.md](./cloud-architecture.md), [vm-provisioning.md](./vm-provisioning.md),
> [pipeline-setup.md](./pipeline-setup.md).

Moved workloads off the legacy `<legacy-gcp-project>` GCP stack (Global LB + CDN, GCS static sites, Cloud Run,
Cloud SQL, Cloud Build) to:

| Workload | Target | Domains | Data |
| :--- | :--- | :--- | :--- |
| `nobuffer-site` | Vercel (Git integration) | `example.com`, `www.example.com` | none |
| `personal-portifolio` | Vercel (Git integration) | `me.example.com`, `cases.example.com` | none |
| `personal-blog` (Ghost 5.130) | GCE e2-micro VM + local MySQL, [`cloud/personal-blog`](../cloud/personal-blog) | `blog.example.com` | MySQL `ghost` + `blog-content-<legacy-project>` |
| `taiga` (back 6.10.2 / front 6.10.3) | Cloud Run + Neon Postgres 15, [`cloud/taiga`](../cloud/taiga) | `taiga.example.com` | Postgres `taiga` + `taiga-content-<legacy-project>` |

DNS records lived in a Cloud DNS zone in `<dns-gcp-project>` before moving to Cloudflare.
Rollback for every step was pointing the record back at the legacy Load Balancer IP (`203.0.113.10`) until Phase 5.

Order: **Phase 0 → (Phase 1 ∥ Phase 2) → Phase 3 → Phase 4 → Phase 5.**

---

## Phase 0: Freeze and prepare

- [ ] **Disable the old pipelines** (they must not run while files change underneath them):

  ```bash
  gh workflow disable terraform-cloud.yml
  gh workflow disable build-blog.yml
  gh workflow disable build-taiga.yml
  ```

- [ ] Create GitHub Environments `blog-prod` and `taiga-prod` (Settings → Environments, deployment
  branches: `main` only) and set temporary gates `BLOG_DEPLOY_ENABLED=false`, `TAIGA_DEPLOY_ENABLED=false`:

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
  # -> ~/.local/state/personal-infra/migrations/<stack>/archive-<ts>/ and gs://<legacy-project>_cloudbuild/sql-archive/
  ```

- [ ] Keep an encrypted copy of the legacy state:
  `terraform -chdir=cloud/infra/envs/prod state pull | gpg -c > ~/prod-state-$(date +%F).json.gpg`.

## Phase 1: Tooling

Terraform roots (`cloud/infra/envs/{gcp-taiga,oci-blog}`), stacks (`cloud/{personal-blog,taiga}/compose.yml`),
`bootstrap_vm.py`, `deploy_stack.py`, `backup_stack.py`, `migrate_gcp_data.py`, `deploy-{blog,taiga}.yml`
and CI validation.

External PRs:

- [ ] `vitorecomp/personal-blog`: pin Ghost (`ARG GHOST_VERSION=5.130.6` + `FROM docker.io/library/ghost:${GHOST_VERSION}-alpine`).
- [ ] `nobuffer-site` / `personal-portifolio`: `vercel.json` (Phase 2 settings) and lockfile cleanup.

## Phase 2: Static sites to Vercel (parallel with Phase 1)

**Done 2026-11-12.** DNS moved to Cloudflare (DNS-only records pointing at Vercel); Let's Encrypt certificates issued
by Vercel; the GCS pipeline (`build-website.yml`, `build-portfolio.yml`, Cloud Build files, download scripts) was removed.

| | `nobuffer-site` | `personal-portifolio` |
| :--- | :--- | :--- |
| Production branch | `master` | `main` |
| Framework preset | Other | Next.js |
| Install command | `npm ci` | `pnpm install --frozen-lockfile` (+ env `ENABLE_EXPERIMENTAL_COREPACK=1`) |
| Build command | `npm run build` | `pnpm run build:export` |
| Output directory | `build` | default (or `out` with preset *Other* + `"trailingSlash": true`) |
| Node.js | 22.x | 24.x |

## Phase 3: Blog to the GCP VM

**Change of plan (2026-11-12):** the blog runs on the same GCE e2-micro as the edge proxy (Ghost + a small local MySQL),
behind the shared edge Caddy (`cloud/edge`). Taiga's Postgres moved to Neon to free the memory MySQL needs.

**Restore the saved export**

```bash
mkdir -p ~/.local/state/personal-infra/migrations/personal-blog
gcloud storage rsync --recursive "gs://$BACKUP_BUCKET/migration/personal-blog/export-20261112T053347Z" \
  ~/.local/state/personal-infra/migrations/personal-blog/export-20261112T053347Z

EXPORT=~/.local/state/personal-infra/migrations/personal-blog/export-20261112T053347Z
python3 cloud/scripts/migrate_gcp_data.py import --stack personal-blog --host deploy@$IP \
  --identity-file ~/.ssh/blog_deploy --local-export $EXPORT --confirm-overwrite
python3 cloud/scripts/migrate_gcp_data.py verify --stack personal-blog --host deploy@$IP \
  --identity-file ~/.ssh/blog_deploy --offline --local-export $EXPORT
curl -sk --resolve blog.example.com:443:$IP https://blog.example.com/ghost/api/admin/site/ | head -c 300
BLOG_ADMIN_EMAIL=admin@example.com BLOG_ADMIN_PASSWORD=... python3 cloud/scripts/seed_ghost_admin.py --connect-ip $IP --insecure
ssh deploy@$IP 'python3 /opt/stacks/.ops/backup_stack.py --stack personal-blog && python3 /opt/stacks/.ops/backup_stack.py --stack personal-blog --restore-test'
```

**Cutover** (T = DNS change)

| When | Who | Action |
| :--- | :--- | :--- |
| T−1 day | you | `blog` record TTL → 60 |
| T−15 min | you | Content freeze (no edits in Ghost admin on the old site) |
| T−10 min | either | Restore the saved export and verify parity |
| T−5 min | you | `web_source_cidrs = ["0.0.0.0/0"]` → plan → apply |
| T0 | you | DNS: `blog` A → `$IP` |
| T+1 min | either | Once DNS resolves `$IP` (`dig +short blog.example.com`), switch Caddy TLS from `internal` to `$ACME_EMAIL` in `/opt/stacks/edge/.env` and restart `caddy` |
| T+5 min | either | `deploy_stack.py --stack personal-blog ...` passes with strict TLS |
| T+1 day | either | Verify `systemctl list-timers 'stack-backup@*'`; TTL back to 300 |

**Rollback:** while the legacy stack existed, `blog` A record → `203.0.113.10`. After Phase 5, the saved export is the fallback.

## Phase 4: Taiga to GCE & Neon / Cloud Run

1. `terraform apply` in `envs/gcp-taiga`. Bootstrap with
   `--provider gce --swap-gb 3 --backup-stack taiga --deploy-pubkey-file ~/.ssh/taiga_deploy.pub`.
2. Rehearsal:
   `curl -sk --resolve taiga.example.com:443:$IP https://taiga.example.com/api/v1/project-templates`,
   `TAIGA_ADMIN_PASSWORD=... python3 cloud/scripts/seed_taiga_admin.py --connect-ip $IP --insecure`.
3. Taiga's Postgres moved to **Neon** (managed Postgres **15**, AWS us-east-2) because Taiga 6.10 requires Postgres ≤ 15.
4. Taiga's app runtime moved to **Cloud Run** (free tier: 1 vCPU / 512 MiB, 0..1 instances, request-based CPU) deployed
   from GitHub Actions via Workload Identity Federation (`deploy-taiga.yml`). Uploads live in `gs://$TAIGA_MEDIA_BUCKET`;
   the edge Caddy proxies `$TAIGA_DOMAIN` to `$TAIGA_UPSTREAM`.

## Phase 5: Decommission `<legacy-gcp-project>`

1. Final archives exported to `gs://$BACKUP_BUCKET/migration/`.
2. Destroyed the legacy Terraform state (46 resources) and cleaned up old service accounts and variables:

   ```bash
   gcloud storage rm -r "gs://<legacy-project>_cloudbuild/terraform/state/personal-infra-prod/"
   gcloud iam service-accounts delete "personal-infra-deployer@<legacy-project>.iam.gserviceaccount.com" --project "<legacy-project>"
   gh secret delete GCP_SA_KEY
   ```

## Known risks & mitigations

| Risk | Mitigation |
| :--- | :--- |
| Old pipelines redeploy Cloud Run during migration | Workflows disabled (Phase 0) + push triggers removed |
| Manual apply replaces a VM holding data | `prevent_destroy`, `deletion_protection`, `ignore_changes`, plan review ([vm-provisioning §3](./vm-provisioning.md#3-every-change-plan-review-apply)) |
| e2-micro (1 GB) memory pressure | 3 GB swap, Taiga moved to Cloud Run + Neon, tuned MySQL |
| Oracle reclaims an idle Always Free VM | PAYG upgrade, restic backups in GCS, external uptime check |
| ACME failures / rate limits at cutover | `tls internal` rehearsal, Caddy restart after DNS flip, persistent `caddy-data` volume |
