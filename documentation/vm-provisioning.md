# VM Provisioning Runbook (manual Terraform)

The two compose VMs are created with Terraform **run by hand from your workstation**. CI only runs
`terraform fmt -check` and `terraform validate`; it never plans or applies, and holds no cloud credentials.

| Root | Cloud | Creates | State (GCS) |
| :--- | :--- | :--- | :--- |
| [`cloud/infra/envs/gcp-taiga`](../cloud/infra/envs/gcp-taiga) | GCP project `personal-project-514501` | `taiga-vpc` + subnet + firewall (22, 80/443, ICMP), static IP `taiga-ip`, **e2-micro** VM `personal-host` (hosts the blog + edge Caddy; builds/deploys Taiga), **Cloud Run** `taiga` + Artifact Registry `taiga` + Secret Manager + bucket `vitorx86-taiga-media` (30 GB pd-standard, Ubuntu 24.04 amd64), SA `taiga-vm`, backup bucket `vitorx86-backups` + SA `stack-backup-writer` | `gs://personal-project-514501-tfstate/vms/gcp-taiga` |
| [`cloud/infra/envs/oci-blog`](../cloud/infra/envs/oci-blog) (spare, not used by any stack yet) | OCI compartment `vitorecomp` | VCN + IGW + route table + security list + public subnet, **A1.Flex 1 OCPU / 6 GB** VM `blog` (50 GB boot, Ubuntu 24.04 aarch64), reserved public IP (+ an empty `taiga-backups` bucket from the old cross-cloud design, removed once the VM exists) | `gs://personal-project-514501-tfstate/vms/oci-blog` |

Both stacks back up with restic to the GCS bucket `vitorx86-backups` ([backup-restore.md](./backup-restore.md)).

**Expected cost:** GCP e2-micro + 30 GB pd-standard are free tier; the in-use static IPv4 is billed
(~US$3.60/month). OCI A1 (≤ 2 OCPU / 12 GB per tenancy), 200 GB block storage and 20 GB object
storage are Always Free in your home region. The backup bucket stays within GCS's 5 GB free tier.

**Safety guards in the code:** `prevent_destroy` on both instances and IPs, GCE `deletion_protection`,
and `ignore_changes` on boot images/metadata so a new Ubuntu release never plans a replacement.
You still review every plan ([§3](#3-every-change-plan-review-apply)).

---

## 1. One-time prerequisites

### 1.1 Tools

```bash
cd ~/workspace/personal/personal-infra
mise trust && mise install          # terraform 1.17.1 + cloud-sql-proxy from mise.toml
terraform version                   # if mise is not activated in your shell: mise exec -- terraform version
```

### 1.2 GCP (`personal-project-514501`)

Billing is currently **disabled** on this project, and every billing account you own is closed.
Link an *open* billing account first (the free tier requires one):

```bash
gcloud billing accounts list --filter=open=true
gcloud billing projects link personal-project-514501 --billing-account=<OPEN_ACCOUNT_ID>

gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com \
  compute.googleapis.com iam.googleapis.com storage.googleapis.com \
  --project personal-project-514501

gcloud auth application-default login   # Terraform uses your ADC; no service-account keys

gcloud storage buckets create gs://personal-project-514501-tfstate \
  --project personal-project-514501 --location us-central1 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://personal-project-514501-tfstate --versioning
```

> Free-tier hours are counted per billing account. Don't run another e2-micro on the same account.

### 1.3 OCI (compartment `vitorecomp`)

1. **Upgrade the tenancy to Pay-As-You-Go** (Billing → Upgrade). Always Free resources stay free, and
   Oracle stops reclaiming idle Always Free instances. Then set a **budget alert of US$1**.
2. **API key:** Console → Profile (top right) → *API keys* → *Add API key* → *Generate key pair* →
   download the private key → *Add*. Copy the shown config snippet into `~/.oci/config`:

   ```bash
   mkdir -p ~/.oci && chmod 700 ~/.oci
   mv ~/Downloads/<key>.pem ~/.oci/oci_api_key.pem && chmod 600 ~/.oci/oci_api_key.pem
   $EDITOR ~/.oci/config   # [DEFAULT] user=..., fingerprint=..., tenancy=..., region=..., key_file=~/.oci/oci_api_key.pem
   ```

3. **Compartment OCID:** Identity & Security → Compartments → `vitorecomp` → copy the OCID.
   If `vitorecomp` is your tenancy's root compartment, use the tenancy OCID.
4. **Limits:** Governance → *Limits, Quotas and Usage*: check that you have A1 OCPUs/memory available in
   your home region and at least one reserved public IP.

### 1.4 SSH keys

```bash
ssh-keygen -t ed25519 -f ~/.ssh/infra_admin   -C "infra admin"      # initial 'ubuntu' admin user (Terraform)
ssh-keygen -t ed25519 -f ~/.ssh/blog_deploy   -C "blog deploy"      # CI/CD 'deploy' user on the blog VM
ssh-keygen -t ed25519 -f ~/.ssh/taiga_deploy  -C "taiga deploy"     # CI/CD 'deploy' user on the Taiga VM
```

### 1.5 Variables

```bash
for env in gcp-taiga oci-blog; do
  cp cloud/infra/envs/$env/terraform.tfvars.example cloud/infra/envs/$env/terraform.tfvars   # gitignored
done
curl -s https://api.ipify.org; echo     # your public IP -> web_source_cidrs = ["<ip>/32"]
```

Fill in `admin_ssh_public_key` (contents of `~/.ssh/infra_admin.pub`), `web_source_cidrs`, and for
OCI `region` (home region), `tenancy_ocid`, `compartment_ocid`.

---

## 2. First apply

Do the blog first (Phase 3 of the [migration runbook](./migration-runbook.md)), then Taiga.

```bash
cd cloud/infra/envs/oci-blog        # or gcp-taiga
terraform init
terraform plan -out tfplan          # review (see §3)
terraform apply tfplan
terraform output                    # public_ip, admin_ssh, backup bucket/repositories
```

Then bootstrap the host ([`cloud/scripts/bootstrap_vm.py`](../cloud/scripts/bootstrap_vm.py)):

```bash
IP=$(terraform output -raw public_ip)
cd ../../../..
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@$IP --identity-file ~/.ssh/infra_admin \
  --provider oracle --deploy-pubkey-file ~/.ssh/blog_deploy.pub --backup-stack personal-blog --dry-run
# repeat without --dry-run, then once more with --check (expect "no drift")
# Taiga: --provider gce --deploy-pubkey-file ~/.ssh/taiga_deploy.pub --swap-gb 3 --backup-stack taiga
```

`bootstrap_vm.py` prints the VM's SSH host-key fingerprint. Compare it with
`ssh-keyscan -t ed25519 $IP | ssh-keygen -lf -` before storing the keyscan output as `DEPLOY_KNOWN_HOSTS`.

**OCI "Out of host capacity"** (common for Always Free A1): Always Free only exists in the home region, and
`sa-saopaulo-1` has a single availability domain, so the fix is retrying until capacity frees up (hours to
days). Leave the retry loop running in a terminal:

```bash
cloud/scripts/tf_apply_retry.sh --env oci-blog              # every 5 min; --interval 600, --max-attempts N
```

It retries only on capacity errors, refuses any plan that deletes or replaces something, stops on any
other error, sends a desktop notification on success and prints the outputs (including `public_ip`).
In regions with several ADs you can also try `availability_domain_index = 1` (or 2).

---

## 3. Every change: plan, review, apply

```bash
cd cloud/infra/envs/<env>
terraform init                      # after provider/module changes
terraform plan -out tfplan
terraform apply tfplan
rm -f tfplan                        # plan files can contain sensitive values (they are gitignored anyway)
```

**Stop and investigate** if a plan shows any of these as `destroy` or `-/+ replace`:
`google_compute_instance`, `google_compute_address`, `oci_core_instance`, `oci_core_public_ip`,
or the backup buckets. `prevent_destroy` makes Terraform error out on them anyway; never remove that
guard to "make the plan pass". In-place updates (`~`) of firewall rules, labels or machine type are expected.

---

## 4. Day-2 operations

| Task | How |
| :--- | :--- |
| **Open 80/443 at DNS cutover** | `web_source_cidrs = ["0.0.0.0/0"]` → plan → apply (in-place firewall/security-list update). Let's Encrypt validates from many IPs, so it must be open to the world. |
| **Taiga VM too small** | `machine_type = "e2-small"` in `gcp-taiga/terraform.tfvars` → plan → apply. In-place stop/start (`allow_stopping_for_update`); the static IP is kept. e2-small is not free tier (~US$13/month). |
| **Blog VM size** | `ocpus` / `memory_in_gbs` (stay ≤ 2 / 12 for Always Free). Flex shape changes are in-place (reboot). |
| **CPU limits (e2-micro)** | The VM sustains only ~25% of its 2 vCPUs. Image builds, migrations and restores are slow and must not overlap (run them one at a time; `deploy_stack.py` deploys are serialized by the `deploy-gcp-vm` concurrency group). If deploys become painful, `machine_type = "e2-small"` is an in-place change. |
| **Rename the VM** | GCE names change only while stopped and Terraform would replace the instance, so: `gcloud compute instances stop <vm>`, `gcloud compute instances set-name <vm> --new-name=<new>`, `gcloud compute instances start <new>`, then set `instance_name` in `envs/gcp-taiga/main.tf`, `terraform state rm module.taiga_vm.google_compute_instance.this` and `terraform import module.taiga_vm.google_compute_instance.this projects/personal-project-514501/zones/us-central1-a/instances/<new>`; the next plan must show no replacement. |
| **Disk snapshots (GCE)** | `enable_snapshots = true` → daily snapshots kept 7 days (billed per GB). restic backups remain the primary safety net. |
| **Rotate the admin key** | Instance metadata keys are ignored after creation on OCI. Edit `~ubuntu/.ssh/authorized_keys` over SSH, or for GCE change `admin_ssh_public_key` (in-place metadata update). Deploy keys are managed by `bootstrap_vm.py`. |
| **Backup credentials (per VM)** | `gcloud storage hmac create $(terraform -chdir=cloud/infra/envs/gcp-taiga output -raw backup_writer_email) --project personal-project-514501` → put the access ID/secret in that VM's `.env` as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. Create one key per VM so either can be revoked on its own (`gcloud storage hmac update <ACCESS_ID> --deactivate`). |
| **Deliberately rebuild a VM** | Restore from restic onto a new VM: comment out `prevent_destroy` *in a dedicated commit*, `terraform apply -replace=module.<vm>.<resource>`, restore `prevent_destroy`, bootstrap, deploy, `backup_stack.py` restore (see [backup-restore.md](./backup-restore.md)). The reserved/static IP is kept, so DNS does not change. |

---

## 5. Hand-off to CI/CD

After the first apply and bootstrap, configure the GitHub Environment for the stack
(`blog-prod` or `taiga-prod`). Details: [pipeline-setup.md](./pipeline-setup.md#5-vm-deploy-workflows-ssh).

```bash
gh secret set DEPLOY_HOST    --env blog-prod --body "$IP"
gh secret set DEPLOY_SSH_KEY --env blog-prod < ~/.ssh/blog_deploy
gh variable set DEPLOY_KNOWN_HOSTS --env blog-prod --body "$(ssh-keyscan -t ed25519 $IP 2>/dev/null)"
gh variable set DEPLOY_USER  --env blog-prod --body deploy
gh variable set BLOG_DEPLOY_ENABLED --body true      # repository-level gate
```

---

## 6. Troubleshooting

| Symptom | Fix |
| :--- | :--- |
| `Error 403: Billing account for project ... is not found` / `billing is disabled` | §1.2: link an open billing account. |
| `<other-account> does not have storage.objects.list access to ... personal-project-514501-tfstate` | Terraform's GCS backend uses Application Default Credentials, which can belong to a different Google account than the `gcloud` CLI. Either `gcloud auth application-default login` with `vitor.ecomp@gmail.com` (+ `gcloud auth application-default set-quota-project personal-project-514501`), or prefix commands with `GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`. `tf_apply_retry.sh` does the latter automatically. |
| `storage: bucket doesn't exist` on `terraform init` | Create the state bucket (§1.2). |
| `Error acquiring the state lock` | Another apply is running, or one crashed: `terraform force-unlock <ID>` only if you are sure. |
| OCI `401 NotAuthenticated` | Wrong `fingerprint`/`key_file` in `~/.oci/config`, or the key was not added to your user. |
| OCI `404 NotAuthorizedOrNotFound` on the compartment | Wrong `compartment_ocid`, or `vitorecomp` is the root (use the tenancy OCID). |
| OCI `500 Out of host capacity` | Different `availability_domain_index`, or retry later. |
| Cannot SSH after apply (OCI) | Security list allows 22 from `ssh_source_cidrs`; Canonical images accept SSH in host iptables by default. Wait ~2 min for cloud-init. |
| Port 80/443 unreachable (OCI) after bootstrap | `web_source_cidrs` must include your IP; `bootstrap_vm.py --check` verifies the host iptables rules. |

---

## 7. Legacy stack (done)

The old `compute-bench` stack (Global LB, Cloud CDN, Cloud Run, Cloud SQL, Cloud Build) was destroyed on
2026-11-12 with Terraform (46 resources), its state removed and its code deleted. Final Cloud SQL exports and
content are kept in `gs://vitorx86-backups/migration/<stack>/` ([migration runbook](./migration-runbook.md)).
