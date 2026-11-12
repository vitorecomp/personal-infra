# Edge (`cloud/edge`)

Shared Caddy for the GCP VM: terminates TLS for `blog.vitorx86.dev` (proxied to the Ghost container over
the `edge` docker network, alias `blog-ghost`) and `taiga.vitorx86.dev` (proxied to Taiga's Cloud Run URL,
`TAIGA_UPSTREAM` in the edge `.env`, with the Host header Cloud Run expects).

- Per-site TLS mode lives in `/opt/stacks/edge/.env` (`TAIGA_TLS`, `BLOG_TLS`): the ACME email for
  Let's Encrypt, or `internal` while a hostname's DNS does not point at the VM yet.
- Certificates persist in the `edge_caddy-data` volume (included in the Taiga backup job on the VM).
- Deploy: `python3 cloud/scripts/deploy_stack.py --stack edge --host deploy@<vm>` (the app deploy
  workflows run it before deploying their own stack).
