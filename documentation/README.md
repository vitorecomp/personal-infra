# `personal-infra` Documentation

Centralized technical documentation for provisioning, operating, and maintaining all infrastructure and deployment pipelines in `personal-infra`.

## Contents

| Document | Description |
| :--- | :--- |
| **[Cloud Architecture](./cloud-architecture.md)** | End-to-end GCP network topology, shared Global HTTPS Load Balancer, Cloud CDN + GCS static sites (`nobuffer-site`, `personal-portifolio`), Cloud Run + Cloud SQL MySQL 8.0 (`personal-blog`), and Nginx reverse-proxy architecture. |
| **[Cloud Setup Guide](./cloud-setup.md)** | Step-by-step guide to bootstrapping a GCP project, enabling required APIs, creating the Terraform/CI Service Account, running Terraform (`cloud/infra/envs/prod`), and configuring DNS. |
| **[Pipeline & CI/CD Setup](./pipeline-setup.md)** | Reference for all GitHub Actions workflows, Google Cloud Build pipelines, cross-repository `repository_dispatch` triggers, required GitHub Secrets/Variables, and local deployment scripts. |
| **[Migration Runbook](./migration-runbook.md)** | Phase-by-phase plan to move off GCP: Vercel for the static sites, Ghost on an OCI A1 VM, Taiga on a GCE e2-micro VM, with cutover checklists, rollback and decommissioning. |
| **[VM Provisioning (manual Terraform)](./vm-provisioning.md)** | Prerequisites, plan/review/apply procedure and day-2 operations for `cloud/infra/envs/{gcp-taiga,oci-blog}`, plus the legacy `prod` destroy. |
| **[Backup & Restore](./backup-restore.md)** | restic backups of each compose stack to the other cloud, restore tests and full-restore procedure. |
| **[Workspace Management](./workspace-setup.md)** | Guide to maintaining the GitHub repository inventory (`repo_stats.csv`) and synchronizing local `~/workspace` checkouts. |
