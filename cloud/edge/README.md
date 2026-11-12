# Edge (`cloud/edge`)

Shared Caddy for the GCP VM: terminates TLS for `taiga.vitorx86.dev` and `blog.vitorx86.dev` and
proxies to the app containers over the `edge` docker network. App stacks (`cloud/taiga`,
`cloud/personal-blog`) publish no ports; they join `edge` with a fixed alias (`taiga-app`, `blog-ghost`).

- Per-site TLS mode lives in `/opt/stacks/edge/.env` (`TAIGA_TLS`, `BLOG_TLS`): the ACME email for
  Let's Encrypt, or `internal` while a hostname's DNS does not point at the VM yet.
- Certificates persist in the `edge_caddy-data` volume (backed up with the Taiga stack).
- Deploy: `python3 cloud/scripts/deploy_stack.py --stack edge --host deploy@<vm>` (the app deploy
  workflows run it before deploying their own stack).
