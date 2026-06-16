# helm-addons

GitOps repository for installing add-ons (Karpenter, VPA, …) across EKS clusters.

Each cluster is an **environment**. Adding a new environment file is all that's needed to reproduce the same setup on another cluster.

---

## Repository layout

```
helm-addons/
├── helmfile.yaml.gotmpl            # Root orchestrator — entry point for all installs
├── environments/
│   └── eks-karpenter-vpa.yaml      # Per-cluster values (one file per cluster)
├── karpenter/
│   ├── values.yaml.gotmpl          # Chart values template (reads from environment file)
│   ├── manifests/
│   │   ├── ec2nodeclass.yaml       # Defines how Karpenter launches EC2 nodes
│   │   └── nodepool.yaml           # Defines scheduling constraints and limits
│   └── iam/
│       ├── main.tf                 # IAM: controller role (IRSA), node role, SQS queue
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       ├── backend.tf
│       └── example.tfvars
└── vpa/                            # Vertical Pod Autoscaler (coming soon)
```

> **Note:** The root file is `helmfile.yaml.gotmpl` (not `helmfile.yaml`). Helmfile v1 requires the
> `.gotmpl` extension on any file that uses Go template expressions (`{{ .Values.* }}`).

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Terraform | 1.5.7 | https://developer.hashicorp.com/terraform/install |
| Helmfile | 1.x | `brew install helmfile` |
| Helm | 3.14+ | https://helm.sh/docs/intro/install |
| kubectl | 1.29+ | https://kubernetes.io/docs/tasks/tools |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |

Your shell must be authenticated to the target AWS account (`aws sts get-caller-identity` should succeed) and your kubeconfig must point at the target cluster before running Helmfile commands.

---

## Installing Karpenter on a cluster

### Step 1 — Tag private subnets for Karpenter discovery (Terraform)

Karpenter discovers subnets by tag. The cluster's private subnets must carry the tag
`karpenter.sh/discovery=<cluster-name>`. Do this in the cluster's Terraform before running Helmfile.

In `terraform/clusters/<cluster>/main.tf`, pass the tag to the vpc module:

```hcl
module "vpc" {
  ...
  private_subnet_tags = {
    "karpenter.sh/discovery" = "<cluster-name>"
  }
}
```

Then apply:

```bash
cd terraform/clusters/<cluster>
terraform apply -target=module.vpc
```

This is already done for `eks-karpenter-vpa`. Repeat for every new cluster.

### Step 2 — Apply the IAM Terraform module

This creates the Karpenter controller IAM role (IRSA), the node IAM role, the SQS interruption
queue, and the EventBridge rules. Run once per cluster.

```bash
cd karpenter/iam
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars` with real values (replace the placeholders):

```hcl
cluster_name      = "<cluster-name>"
aws_region        = "eu-west-1"

# Get these from the cluster Terraform repo:
#   cd terraform/clusters/<cluster>
#   terraform output oidc_provider_arn
#   terraform output oidc_provider_url
oidc_provider_arn = "arn:aws:iam::<account_id>:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/<oidc_id>"
oidc_provider_url = "https://oidc.eks.eu-west-1.amazonaws.com/id/<oidc_id>"
```

> **Important:** Use the real OIDC values — not the example placeholders. The IRSA trust policy
> will not work if the literal strings `<account_id>` or `<oidc_id>` remain.

```bash
terraform init
terraform apply
```

Note the outputs — you need them in the next steps:

```bash
terraform output karpenter_controller_role_arn
terraform output karpenter_node_role_name
terraform output karpenter_interruption_queue_name
```

### Step 3 — Fill in the environment file

Copy the example and fill in all fields:

```bash
cp environments/eks-karpenter-vpa.yaml environments/<cluster>.yaml
```

```yaml
cluster_name: <cluster-name>
cluster_endpoint: ""     # terraform output cluster_endpoint  (from cluster TF repo)
aws_region: eu-west-1

karpenter_version: "1.5.0"

karpenter_controller_role_arn: ""    # terraform output karpenter_controller_role_arn
karpenter_interruption_queue_name: "" # terraform output karpenter_interruption_queue_name
karpenter_node_role_name: ""         # terraform output karpenter_node_role_name
```

### Step 4 — Update the manifests for the new cluster

`karpenter/manifests/ec2nodeclass.yaml` contains three cluster-name references that must match:

```yaml
spec:
  role: <cluster-name>-karpenter-node          # node IAM role name

  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <cluster-name>  # must match private_subnet_tags in Terraform

  securityGroupSelectorTerms:
    - tags:
        kubernetes.io/cluster/<cluster-name>: owned

  tags:
    karpenter.sh/discovery: <cluster-name>
```

### Step 5 — Log in to the ECR public registry

Karpenter's chart is hosted on ECR Public. Helm requires a valid login token before it can pull
the chart. ECR Public tokens expire after 12 hours so repeat this at the start of each session:

```bash
aws ecr-public get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin public.ecr.aws
```

> **Note:** ECR Public login always uses `us-east-1` regardless of your cluster's region.

### Step 6 — Add the environment to `helmfile.yaml.gotmpl`

```yaml
environments:
  eks-karpenter-vpa:
    values:
      - environments/eks-karpenter-vpa.yaml
  <cluster>:                    # add this block for the new cluster
    values:
      - environments/<cluster>.yaml
```

### Step 7 — Install

```bash
# From the repo root
cd helm-addons

# Preview what will change
helmfile -e <cluster> diff

# Install / upgrade
helmfile -e <cluster> sync
```

Helmfile will:
1. Apply the Karpenter CRDs
2. Install the Karpenter Helm chart into `kube-system`
3. Apply `karpenter/manifests/` (EC2NodeClass + NodePool)

### Step 8 — Verify

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl get ec2nodeclass    # should show READY: True
kubectl get nodepool        # should show READY: True
```

---

## Customising Karpenter

### Change the Karpenter version

Edit `environments/<cluster>.yaml`:

```yaml
karpenter_version: "1.6.0"
```

Then re-run `helmfile -e <cluster> sync`.

### Change instance types

Edit `karpenter/manifests/nodepool.yaml` under `spec.template.spec.requirements`:

```yaml
- key: node.kubernetes.io/instance-type
  operator: In
  values:
    - t3.large
    - t3.xlarge
    - m5.large       # uncomment m-series for general-purpose workloads
    - r5.large       # uncomment r-series for memory-intensive workloads
```

### Allow Spot instances

In `nodepool.yaml`, add `"spot"` to the capacity-type requirement:

```yaml
- key: karpenter.sh/capacity-type
  operator: In
  values: ["on-demand", "spot"]
```

The SQS interruption queue is already wired up — Karpenter will gracefully drain Spot nodes
before they are reclaimed.

### Change consolidation behaviour

```yaml
disruption:
  consolidationPolicy: WhenEmpty          # only remove completely empty nodes
  # or
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 5m                    # wait longer before bin-packing
```

### Increase / decrease scaling limits

```yaml
limits:
  cpu: "200"        # raise for production
  memory: 800Gi
```

### Use a different AMI family

In `ec2nodeclass.yaml`, update `amiSelectorTerms`:

```yaml
amiSelectorTerms:
  - alias: al2023@latest        # Amazon Linux 2023 (default)
  # - alias: bottlerocket@latest
  # - alias: al2@latest
```

> Karpenter v1.x uses `amiSelectorTerms` with an alias. The old `amiFamily:` field was removed.

### HA replicas (single-node vs multi-node clusters)

The default is `replicas: 1` in `karpenter/values.yaml.gotmpl`. Karpenter's Helm chart deploys
with pod anti-affinity, so running 2 replicas requires at least 2 managed nodes. Increase once
a second bootstrap node is available:

```yaml
replicas: 2
```

---

## Applying to another existing cluster

1. Tag the cluster's private subnets in Terraform (Step 1 above).
2. Apply the IAM module with the new cluster's OIDC values (Step 2).
3. Copy and fill `environments/<other-cluster>.yaml` (Step 3).
4. Update cluster-name references in `ec2nodeclass.yaml` (Step 4) — or maintain a separate
   manifest per cluster under `karpenter/manifests/<cluster>/`.
5. Add the environment block to `helmfile.yaml.gotmpl` (Step 6).
6. Log in to ECR Public (Step 5) and run `helmfile -e <other-cluster> sync`.

---

## Uninstalling

```bash
# Remove the Helm release and CRD resources
helmfile -e <cluster> destroy

# Remove the IAM resources
cd karpenter/iam && terraform destroy
```

---

## Troubleshooting

### `exec: "docker-credential-desktop": executable file not found`

Your `~/.docker/config.json` has `"credsStore": "desktop"` but Docker Desktop is not installed
or not running. Remove that line from the config, then log in to ECR Public (Step 5 above).

### `SubnetSelector did not match any Subnets`

The private subnets are missing the `karpenter.sh/discovery=<cluster-name>` tag. Go back to
Step 1 and apply the Terraform change.

### `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity`

The IRSA trust policy on the controller role has wrong OIDC values (often the literal example
placeholders were left in `terraform.tfvars`). Re-apply the IAM Terraform with the real OIDC
ARN and URL from `terraform output`.

### `EC2NodeClass READY: False`

Run `kubectl describe ec2nodeclass default` and check the `Status.Conditions` section — it shows
exactly which dependency (subnets, security groups, AMI, instance profile) is unresolved.

---

## VPA (coming soon)

The `vpa/` directory is a placeholder. Once Karpenter is validated on `eks-karpenter-vpa`, the
Vertical Pod Autoscaler will be added here following the same environment-based pattern.
