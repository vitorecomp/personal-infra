# Backup & Restore (compose VMs)

Each VM backs up its own stack with [`cloud/scripts/backup_stack.py`](../cloud/scripts/backup_stack.py),
shipped to `/opt/stacks/.ops/` by `deploy_stack.py` and run daily (03:17 UTC ± 15 min) by the
`stack-backup@<stack>.timer` unit that `bootstrap_vm.py` installs.

All stacks write to one GCS bucket, **`gs://vitorx86-backups`** (project `personal-project-514501`,
us-central1, inside the 5 GB free tier), one restic repository per stack. VMs authenticate with HMAC keys
of the `stack-backup-writer` service account (S3-compatible API), one key per VM.

| Stack | VM | What is backed up | restic repository |
| :--- | :--- | :--- | :--- |
| `personal-blog` | GCE e2-micro | `mysqldump` of the local `ghost` MySQL, volume `personal-blog_ghost-content`, `.env` | `s3:https://storage.googleapis.com/vitorx86-backups/personal-blog` |
| `taiga` | GCE e2-micro | `pg_dump -Fc` of the **Neon** `taiga` database (remote, `postgres:15` client), volumes `taiga_media` + `edge_caddy-data`, `.env` | `s3:https://storage.googleapis.com/vitorx86-backups/taiga` |

- restic encrypts everything client-side with `RESTIC_PASSWORD`, which lives in the VM `.env` **and in your
  password manager** (the `.env` copy inside the snapshots is useless without it).
- Retention: 7 daily, 4 weekly, 6 monthly; `restic check` every Sunday.
- The newest 7 dumps also stay on the VM in `/var/backups/stacks/<stack>/` for quick restores.
- The one-off migration exports (final Cloud SQL dumps + content of the old GCP stack) are kept under
  `gs://vitorx86-backups/migration/<stack>/export-<timestamp>/` (outside the restic repositories).
- Optional: set `BACKUP_PING_URL` (e.g. healthchecks.io) in the `.env` to get alerted when a daily run is missed.

## Setup (once per VM)

1. Create an HMAC key for the VM and set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `/opt/stacks/<stack>/.env`
   (`RESTIC_REPOSITORY` and `AWS_DEFAULT_REGION=us-central1` already come from `.env.example`):

   ```bash
   gcloud storage hmac create stack-backup-writer@personal-project-514501.iam.gserviceaccount.com \
     --project personal-project-514501      # prints the access ID and the secret ONCE
   ```
2. Initialise and test:

   ```bash
   ssh deploy@<vm>
   python3 /opt/stacks/.ops/backup_stack.py --stack <stack> --init
   python3 /opt/stacks/.ops/backup_stack.py --stack <stack>
   python3 /opt/stacks/.ops/backup_stack.py --stack <stack> --restore-test
   python3 /opt/stacks/.ops/backup_stack.py --stack <stack> --snapshots
   systemctl list-timers 'stack-backup@*'
   ```

Run `--restore-test` before each cutover and then quarterly.

## Restore

### Database only, from a local dump (fastest)

```bash
cd /opt/stacks/personal-blog
docker compose stop ghost
gunzip -c /var/backups/stacks/personal-blog/personal-blog-db-<ts>.sql.gz \
  | docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot ghost'
docker compose up -d --wait

cd /opt/stacks/taiga
docker compose stop taiga
docker compose exec -T db sh -c 'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-acl' \
  < /var/backups/stacks/taiga/taiga-db-<ts>.dump
docker compose up -d --wait
```

### Full restore from restic (new VM or lost disk)

The old `.env` must be in place **before** the stack starts for the first time: MySQL/Postgres store the
passwords from the first boot inside their data volume, and the dump only matches the old credentials.

1. `terraform apply` (the reserved/static IP is kept) and `bootstrap_vm.py`.
2. On the VM, restore the newest snapshot. `RESTIC_PASSWORD` comes from your password manager; the bucket
   key can be the old one or a freshly created one:

   ```bash
   export RESTIC_REPOSITORY=... RESTIC_PASSWORD=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=...
   docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
     -v /tmp/restore:/restore restic/restic:0.19.1 restore latest --tag <stack> --target /restore
   sudo chown -R deploy:deploy /tmp/restore     # restic runs as root in the container (admin user has sudo)
   install -d -m 750 /opt/stacks/<stack>
   install -m 600 /tmp/restore/backup/env/.env /opt/stacks/<stack>/.env   # update AWS_* if you created a new key
   ```

3. From your workstation: `python3 cloud/scripts/deploy_stack.py --stack <stack> --host deploy@<ip> --skip-seed`
   (no `--init-env`). The stack starts with the old passwords and empty volumes.
4. On the VM, stop the app, copy the volumes back and restore the newest dump from `/tmp/restore/backup/dumps/`:

   ```bash
   cd /opt/stacks/<stack>
   docker compose stop ghost            # or: taiga
   for vol in /tmp/restore/backup/volumes/*; do
     docker run --rm -v "$vol":/src:ro -v "$(basename "$vol")":/dst alpine:3.24.4 sh -c 'cp -a /src/. /dst/'
   done
   # then the database restore commands from the previous section, pointing at /tmp/restore/backup/dumps/<file>
   docker compose up -d --wait
   rm -rf /tmp/restore
   ```
