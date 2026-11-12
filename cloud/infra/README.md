# `cloud/infra`: Terraform

| Root | What | How it is applied |
| :--- | :--- | :--- |
| [`envs/gcp-taiga`](./envs/gcp-taiga) → [`modules/gce-vm`](./modules/gce-vm) | GCE free-tier VM (blog + edge Caddy + backups), Taiga on Cloud Run (Artifact Registry, Secret Manager, media bucket), Workload Identity Federation for CI deploys, and the backup bucket (`personal-project-514501`) | **By hand** from a workstation: [documentation/vm-provisioning.md](../../documentation/vm-provisioning.md) |
| [`envs/oci-blog`](./envs/oci-blog) → [`modules/oci-vm`](./modules/oci-vm) | Spare OCI Always Free A1 VM (compartment `vitorecomp`; capacity retry loop running, not used by any stack yet) | **By hand**, same runbook |

CI (`ci.yml`) only runs `terraform fmt -check` and `terraform validate` for both roots. No workflow plans
or applies, and GitHub holds no cloud keys (CI deploys use Workload Identity Federation). State for the VM roots lives in the
versioned bucket `gs://personal-project-514501-tfstate` (prefixes `vms/gcp-taiga`, `vms/oci-blog`).
