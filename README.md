# helm-addons

GitOps repository for installing add-ons (Karpenter, VPA, …) across EKS clusters.

Each cluster is an **environment**. Adding a new environment file is all that's needed to reproduce the same setup on another cluster.

---

## Repository layout

```
helm-addons/
├── helmfile.yaml                   # Root orchestrator — entry point for all installs
├── environments/
│   └── eks-karpenter-vpa.yaml      # Per-cluster values (one file per cluster)
├── karpenter/
│   ├── helmfile.yaml               # Karpenter Helm release definition
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

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Terraform | 1.5.7 | https://developer.hashicorp.com/terraform/install |
| Helmfile | 0.167+ | https://helmfile.readthedocs.io |
| Helm | 3.14+ | https://helm.sh/docs/intro/install |
| kubectl | 1.29+ | https://kubernetes.io/docs/tasks/tools |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |

Your shell must be authenticated to the target AWS account (`aws sts get-caller-identity` should succeed) and your kubeconfig must point at the target cluster before running Helmfile commands.

---

## Installing Karpenter on a cluster

### Step 1 — Apply the IAM Terraform module

This creates the Karpenter controller IAM role (IRSA), the node IAM role, the SQS interruption queue, and the EventBridge rules. It only needs to run once per cluster.

```bash
cd karpenter/iam

# Copy the example and fill in the OIDC values
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
cluster_name      = "eks-karpenter-vpa"
aws_region        = "eu-west-1"

# Get these from the cluster Terraform repo:
#   cd ../../../terraform/clusters/eks-karpenter-vpa
#   terraform output oidc_provider_arn
#   terraform output oidc_provider_url
oidc_provider_arn = "arn:aws:iam::<account_id>:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/<oidc_id>"
oidc_provider_url = "https://oidc.eks.eu-west-1.amazonaws.com/id/<oidc_id>"
```

```bash
terraform init
terraform apply
```

Note the three outputs — you will need them in the next step:

```bash
terraform output karpenter_controller_role_arn
terraform output karpenter_node_role_name
terraform output karpenter_interruption_queue_name
```

### Step 2 — Fill in the environment file

Open `environments/eks-karpenter-vpa.yaml` and set the four empty fields:

```yaml
cluster_endpoint:              # terraform output cluster_endpoint  (from cluster TF repo)
karpenter_controller_role_arn: # terraform output karpenter_controller_role_arn  (from step 1)
karpenter_interruption_queue_name: # terraform output karpenter_interruption_queue_name
karpenter_node_role_name:      # terraform output karpenter_node_role_name
```

### Step 3 — Update the manifests with the node role name

Open `karpenter/manifests/ec2nodeclass.yaml` and set `spec.role` to the node role name from step 1:

```yaml
spec:
  role: eks-karpenter-vpa-karpenter-node   # replace if you used a custom name
```

### Step 4 — Install

```bash
# From the repo root — always run helmfile from here
cd helm-addons

# Preview what will change
helmfile -e eks-karpenter-vpa diff

# Install / upgrade
helmfile -e eks-karpenter-vpa sync
```

Helmfile will:
1. Apply the Karpenter CRDs
2. Install the Karpenter Helm chart into `kube-system`
3. Apply `karpenter/manifests/` (EC2NodeClass + NodePool)

### Step 5 — Verify

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl get ec2nodeclass
kubectl get nodepool
```

---

## Customising Karpenter

### Change the Kubernetes version or Karpenter version

Edit `environments/<cluster>.yaml`:

```yaml
karpenter_version: "1.6.0"   # bump to a newer release
```

Then re-run `helmfile -e <cluster> sync`.

### Change instance types

Edit `karpenter/manifests/nodepool.yaml` under `spec.template.spec.requirements`:

```yaml
- key: node.kubernetes.io/instance-type
  operator: In
  values:
    - m5.large
    - m5.xlarge
    - m5.2xlarge
    - c5.xlarge      # add compute-optimised instances
```

### Allow Spot instances

In `nodepool.yaml`, add `"spot"` to the capacity-type requirement:

```yaml
- key: karpenter.sh/capacity-type
  operator: In
  values: ["on-demand", "spot"]
```

The SQS interruption queue is already wired up — Karpenter will gracefully drain Spot nodes before they are reclaimed.

### Change consolidation behaviour

In `nodepool.yaml`:

```yaml
disruption:
  consolidationPolicy: WhenEmpty          # only remove completely empty nodes
  # or
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 5m                    # wait longer before bin-packing
```

### Increase / decrease scaling limits

In `nodepool.yaml`:

```yaml
limits:
  cpu: "200"        # raise the cap for production
  memory: 800Gi
```

### Use a different AMI family

In `ec2nodeclass.yaml`:

```yaml
spec:
  amiFamily: Bottlerocket   # AL2023 (default) | AL2 | Bottlerocket | Windows2022
```

---

## Applying to another existing cluster

1. **Create the environment file:**

   ```bash
   cp environments/eks-karpenter-vpa.yaml environments/<other-cluster>.yaml
   ```

   Fill in the cluster-specific values.

2. **Run the IAM module for the new cluster:**

   ```bash
   cd karpenter/iam
   # edit terraform.tfvars with the new cluster's values
   terraform workspace new <other-cluster>   # optional — use workspaces or a separate tfvars
   terraform apply
   ```

3. **Add the environment to `helmfile.yaml`:**

   ```yaml
   environments:
     eks-karpenter-vpa:
       values:
         - environments/eks-karpenter-vpa.yaml
     <other-cluster>:                        # add this block
       values:
         - environments/<other-cluster>.yaml
   ```

4. **Install:**

   ```bash
   helmfile -e <other-cluster> sync
   ```

---

## Uninstalling

```bash
# Remove the Helm release and manifests
helmfile -e <cluster> destroy

# Remove the IAM resources
cd karpenter/iam && terraform destroy
```

---

## VPA (coming soon)

The `vpa/` directory is a placeholder. Once Karpenter is validated on `eks-karpenter-vpa`, the Vertical Pod Autoscaler will be added here following the same environment-based pattern.
