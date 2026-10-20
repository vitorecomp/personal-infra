# `personal-infra` Documentation

Centralized technical documentation for provisioning, operating, and maintaining all infrastructure and deployment pipelines in `personal-infra`.

## Contents

| Document | Description |
| :--- | :--- |
| **[Cloud Architecture](./cloud-architecture.md)** | End-to-end GCP network topology, shared Global HTTPS Load Balancer, Cloud CDN + GCS static sites (`nobuffer-site`, `personal-portifolio`), Cloud Run + Cloud SQL MySQL 8.0 (`personal-blog`), and Nginx reverse-proxy architecture. |
| **[Cloud Setup Guide](./cloud-setup.md)** | Step-by-step guide to bootstrapping a GCP project, enabling required APIs, creating the Terraform/CI Service Account, running Terraform (`cloud/infra/envs/prod`), and configuring DNS. |
| **[Pipeline & CI/CD Setup](./pipeline-setup.md)** | Reference for all GitHub Actions workflows, Google Cloud Build pipelines, cross-repository `repository_dispatch` triggers, required GitHub Secrets/Variables, and local deployment scripts. |
| **[Workspace Management](./workspace-setup.md)** | Guide to maintaining the GitHub repository inventory (`repo_stats.csv`) and synchronizing local `~/workspace` checkouts. |
