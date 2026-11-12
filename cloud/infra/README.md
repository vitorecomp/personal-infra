# `cloud/infra`: Terraform

| Root | What | How it is applied |
| :--- | :--- | :--- |
| [`envs/gcp-taiga`](./envs/gcp-taiga) → [`modules/gce-vm`](./modules/gce-vm) | GCE free-tier VM for Taiga + GCS bucket for the blog's backups (`personal-project-514501`) | **By hand** from a workstation: [documentation/vm-provisioning.md](../../documentation/vm-provisioning.md) |
| [`envs/oci-blog`](./envs/oci-blog) → [`modules/oci-vm`](./modules/oci-vm) | OCI Always Free A1 VM for the blog + Object Storage bucket for Taiga's backups (compartment `vitorecomp`) | **By hand**, same runbook |
| [`envs/prod`](./envs/prod) → [`modules/load-balancer`](./modules/load-balancer) | **Legacy** GCP stack (LB, CDN, Cloud Run, Cloud SQL) in `compute-bench` | Frozen; destroyed by hand in Phase 5 of the [migration runbook](../../documentation/migration-runbook.md) |

CI (`ci.yml`) only runs `terraform fmt -check` and `terraform validate` for every root. No workflow plans
or applies, and GitHub holds no cloud credentials for Terraform. State for the VM roots lives in the
versioned bucket `gs://personal-project-514501-tfstate` (prefixes `vms/gcp-taiga`, `vms/oci-blog`).
