# `personal-infra` Documentation

Centralized technical documentation for provisioning, operating, and maintaining all infrastructure and deployment pipelines in `personal-infra`.

## Contents

| Document | Description |
| :--- | :--- |
| **[Cloud Architecture](./cloud-architecture.md)** | What runs where: Vercel (static sites), the GCE e2-micro `personal-host` (edge Caddy + Ghost/MySQL), Cloud Run (Taiga) with Neon Postgres, backups, free-tier guardrails. |
| **[VM Provisioning (manual Terraform)](./vm-provisioning.md)** | Prerequisites, plan/review/apply procedure and day-2 operations for `cloud/infra/envs/{gcp-taiga,oci-blog}` (resize, rename, backup keys, OCI capacity retry). |
| **[Pipeline & CI/CD Setup](./pipeline-setup.md)** | CI validation, deploy workflows (images built on runners; blog pulled on the VM over SSH, Taiga to Cloud Run via Workload Identity Federation), GitHub environments, secrets and variables. |
| **[Backup & Restore](./backup-restore.md)** | Daily restic backups of both stacks to `gs://vitorx86-backups`, restore tests and full-restore procedure. |
| **[Workspace Management](./workspace-setup.md)** | Maintaining the GitHub repository inventory (`repo_stats.csv`) and synchronizing local `~/workspace` checkouts. |
| **[Migration Runbook](./migration-runbook.md)** | History: how everything moved off the `compute-bench` GCP stack in November 2026 (completed). |
