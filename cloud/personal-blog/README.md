# Personal Blog (`cloud/personal-blog`)

Docker Compose stack for the **Ghost 5** blog (`https://$BLOG_DOMAIN`) on the GCE e2-micro VM
(`cloud/infra/envs/gcp-taiga`; Taiga runs on Cloud Run). TLS and routing come from the shared edge proxy
([`cloud/edge`](../edge)); Ghost joins the `edge` network as `blog-ghost` and publishes no ports.

The Ghost image (Ghost + custom theme + entrypoint) is built from
[`vitorecomp/personal-blog`](https://github.com/vitorecomp/personal-blog) on the GitHub runner by
[`deploy-blog.yml`](../../.github/workflows/deploy-blog.yml) (theme validation included) and pushed to
`ghcr.io/vitorecomp/personal-blog`; the deploy job writes the digest-pinned reference and `STACK_DOMAIN` into the VM
`.env` and the VM only pulls it. Pushes to the app repo send `repository_dispatch: deploy-personal-blog`.

| File | Purpose |
| :--- | :--- |
| `compose.yml` | `ghost` (`${GHOST_IMAGE}` from GHCR, heap capped, content on volume `personal-blog_ghost-content`) + local `mysql:8.0.46` (tuned for a shared 1 GB VM, binlog off, private network). |
| `.env.example` | Keys for `/opt/stacks/personal-blog/.env` on the VM (mode 0600, never committed; CI writes `GHOST_IMAGE` and `STACK_DOMAIN`). |
| `stack.json` | Metadata for `deploy_stack.py` / `backup_stack.py` (`domain_env: BLOG_DOMAIN`, `registry: ghcr.io`, `edge_tls_key: BLOG_TLS`, backup). |

The final data of the legacy GCP blog is restored from the saved export
(`gs://$BACKUP_BUCKET/migration/personal-blog/`, see the migration runbook).

```bash
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<vm> --identity-file ~/.ssh/blog_deploy --dry-run
ssh -i ~/.ssh/blog_deploy deploy@<vm> 'cd /opt/stacks/personal-blog && docker compose ps && docker compose logs --tail 50 ghost'
```
