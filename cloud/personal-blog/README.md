# Personal Blog (`cloud/personal-blog`)

docker compose stack for the **Ghost 5** blog (`https://blog.vitorx86.dev`) on the OCI Always Free A1 VM
created by [`cloud/infra/envs/oci-blog`](../infra/envs/oci-blog).

> **Migration in progress** ([runbook](../../documentation/migration-runbook.md)): production still runs on
> Cloud Run + Cloud SQL MySQL (`compute-bench`) until the Phase 3 cutover.

The Ghost image (Ghost + `vitorx86-garage` theme + entrypoint) comes from
[`vitorecomp/personal-blog`](https://github.com/vitorecomp/personal-blog), which `deploy_stack.py` checks out
on the VM into `/opt/stacks/personal-blog/app` at the requested ref. Pushes to that repo send
`repository_dispatch: deploy-personal-blog`, which runs [`deploy-blog.yml`](../../.github/workflows/deploy-blog.yml).

| File | Purpose |
| :--- | :--- |
| `compose.yml` | `caddy` (TLS, only service publishing 80/443) → `ghost` (built from `./app`, `GHOST_VERSION` build arg, content on volume `personal-blog_ghost-content`) → `mysql:8.0.46` (tuned for a small VM, binlog off). |
| `Caddyfile` | `{$STACK_DOMAIN}` → `ghost:2368`; `CADDY_TLS=internal` for rehearsals, ACME email after DNS cutover. |
| `.env.example` | Keys for `/opt/stacks/personal-blog/.env` on the VM (mode 0600, never committed, never written by CI). |
| `stack.json` | Metadata for `deploy_stack.py` / `backup_stack.py` (app repo, theme-validation `pre_build`, backup volumes). |
| `cloudbuild.yaml` | Legacy Cloud Run build (removed after the blog cutover). |

```bash
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<blog-ip> --app-ref main --dry-run
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<blog-ip> --app-ref main
ssh deploy@<blog-ip> 'cd /opt/stacks/personal-blog && docker compose ps && docker compose logs --tail 50 ghost'
```
