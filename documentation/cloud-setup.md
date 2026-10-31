# Cloud Setup Guide

Step-by-step instructions to provision and configure the Google Cloud infrastructure from scratch using Terraform.

---

## 1. Prerequisites

1. **Google Cloud SDK (`gcloud`)** installed and authenticated:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   gcloud config set project <YOUR_GCP_PROJECT_ID>
   ```
2. **Terraform** (`>= 1.0`) installed locally.
3. **Domain Ownership**: Access to DNS settings for `vitorx86.dev`.

---

## 2. Enable Required GCP APIs

Enable the Google Cloud APIs required by the Load Balancer, Cloud CDN, Cloud Storage, Cloud Build, Artifact Registry, Cloud Run, and Cloud SQL:

```bash
gcloud services enable \
  compute.googleapis.com \
  storage.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  sqladmin.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com
```

---

## 3. Service Account & IAM Permissions

Create a dedicated Service Account for GitHub Actions and Cloud Build deployments (used as `GCP_SA_KEY`):

```bash
export PROJECT_ID="<YOUR_GCP_PROJECT_ID>"
export SA_NAME="personal-infra-deployer"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# 1. Create the service account
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="personal-infra CI/CD & Terraform Deployer"

# 2. Grant required roles for Terraform & Cloud Build
# (Terraform automatically provisions and binds the hardened runtime SAs
# `personal-blog-run` and `taiga-run` using these permissions)
for ROLE in \
  roles/compute.loadBalancerAdmin \
  roles/compute.networkAdmin \
  roles/storage.admin \
  roles/cloudbuild.builds.editor \
  roles/run.admin \
  roles/cloudsql.admin \
  roles/artifactregistry.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/resourcemanager.projectIamAdmin \
  roles/viewer; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}"
done
```

To export a JSON key for GitHub Actions (`GCP_SA_KEY` secret):

```bash
gcloud iam service-accounts keys create /tmp/gcp-sa-key.json \
  --iam-account="${SA_EMAIL}"
# Copy the contents of /tmp/gcp-sa-key.json into GitHub Secret GCP_SA_KEY, then delete the local file:
rm -f /tmp/gcp-sa-key.json
```

---

## 4. Provision Infrastructure with Terraform

Navigate to [`cloud/infra/envs/prod`](../cloud/infra/envs/prod):

```bash
cd cloud/infra/envs/prod
```

1. **Create `terraform.tfvars`** from the example template (`.tfvars` files are gitignored):
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
   Edit `terraform.tfvars`:
   ```hcl
   project_id               = "your-gcp-project-id"
   region                   = "us-central1"
   bucket_name              = "vitorx86-nobuffer-site-prod"
   domain                   = ["www.vitorx86.dev", "vitorx86.dev"]
   portfolio_bucket_name    = "vitorx86-portfolio-prod"
   portfolio_domain         = ["cases.vitorx86.dev", "me.vitorx86.dev"]
   blog_domain              = ["blog.vitorx86.dev"]
   blog_service_name        = "personal-blog"
   blog_ar_repo_name        = "personal-blog"
   blog_db_instance_name    = "personal-blog-mysql"
   blog_db_tier             = "db-f1-micro"
   blog_db_name             = "ghost"
   blog_db_user             = "ghost"
   blog_content_bucket_name = "vitorx86-blog-content-prod"
   ```

2. **Initialize, Validate, and Plan**:
   ```bash
   terraform init
   terraform validate
   terraform plan -out=tfplan
   ```

3. **Apply**:
   ```bash
   terraform apply tfplan
   ```

4. **Retrieve Outputs**:
   ```bash
   terraform output
   ```
   Note the `load_balancer_ip` output value.

---

## 5. DNS Configuration

In your DNS provider for `vitorx86.dev`, point the following `A` records to the `load_balancer_ip` output by Terraform:

| Host / Record | Type | Value |
| :--- | :--- | :--- |
| `@` (`vitorx86.dev`) | `A` | `<load_balancer_ip>` |
| `www` (`www.vitorx86.dev`) | `A` | `<load_balancer_ip>` |
| `cases` (`cases.vitorx86.dev`) | `A` | `<load_balancer_ip>` |
| `me` (`me.vitorx86.dev`) | `A` | `<load_balancer_ip>` |
| `blog` (`blog.vitorx86.dev`) | `A` | `<load_balancer_ip>` |
| `taiga` (`taiga.vitorx86.dev`) | `A` | `<load_balancer_ip>` |

> [!NOTE]
> Google-managed SSL certificates (`nobuffer-site-cert-v2`) require DNS `A` records to resolve to the Load Balancer IP before certificate provisioning transitions from `PROVISIONING` to `ACTIVE` (typically 15–45 minutes after DNS propagation).

---

## 6. Initial Deployment of Workloads

Once Terraform has created the buckets, Artifact Registry repository, Cloud SQL database, and Cloud Run service, deploy each workload from the repository root:

```bash
# 1. Deploy nobuffer-site (www.vitorx86.dev)
python3 cloud/scripts/download_nobuffer_site.py --deploy --bucket <nobuffer_site_bucket_name>

# 2. Deploy personal-portifolio (cases.vitorx86.dev)
python3 cloud/scripts/download_personal_portifolio.py --deploy --bucket <personal_portifolio_bucket_name>

# 3. Deploy personal-blog (blog.vitorx86.dev)
python3 cloud/scripts/download_personal_blog.py --deploy --region us-central1

# 4. Deploy Taiga Project Manager (taiga.vitorx86.dev)
python3 cloud/scripts/deploy_taiga.py --deploy --region us-central1
```

After `personal-blog` is deployed, visit `https://blog.vitorx86.dev/ghost` once to create your Ghost Admin owner account.
