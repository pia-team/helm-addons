# helm-addons

GitOps repository for installing add-ons (Karpenter, VPA, Goldilocks, …) across EKS clusters using Helmfile.

Each cluster is an **environment**. Adding a new environment file is all that's needed to reproduce the same setup on another cluster.

---

## Repository layout

```
helm-addons/
├── helmfile.yaml.gotmpl              # Root orchestrator — entry point for all installs
├── environments/
│   └── eks-karpenter-vpa.yaml        # Per-cluster values (one file per cluster)
├── profiles/
│   ├── dev.yaml                      # Minimal cost: in-place VPA, aggressive consolidation
│   ├── test.yaml                     # Stability: Initial VPA mode, WhenEmpty consolidation
│   └── prod.yaml                     # HA: recommendation-only VPA, conservative consolidation
├── karpenter/
│   ├── values.yaml.gotmpl            # Chart values template
│   ├── manifests/
│   │   ├── dev/                      # EC2NodeClass + NodePool for dev profile
│   │   ├── test/                     # EC2NodeClass + NodePool for test profile
│   │   └── prod/                     # EC2NodeClass + NodePool for prod profile
│   └── iam/                          # Terraform: controller IRSA, node role, SQS queue
├── vpa/
│   ├── values.yaml.gotmpl            # VPA chart values (Fairwinds)
│   ├── goldilocks-values.yaml.gotmpl # Goldilocks chart values
│   ├── metrics-server-values.yaml    # metrics-server chart values
│   └── manifests/
│       ├── dev/vpa-template.yaml     # Hand-managed VPA CR template (dev fallback)
│       ├── test/vpa-template.yaml    # Hand-managed VPA CR template (test fallback)
│       └── prod/vpa-template.yaml    # Hand-managed VPA CR template (prod fallback)
├── storage/
│   └── manifests/
│       └── gp3-storageclass.yaml     # gp3 WaitForFirstConsumer default StorageClass
└── examples/
    ├── sample-stateless.yaml         # Stateless app for VPA + Karpenter validation
    └── sample-stateful.yaml          # Stateful (PVC) app for zone-safety validation
```

> **Note:** The root file is `helmfile.yaml.gotmpl` (not `helmfile.yaml`). Helmfile v1 requires the
> `.gotmpl` extension on any file that uses Go template expressions (`{{ .Values.* }}`).

---

## Profiles

Each environment file sets a `profile:` key that controls VPA update mode, Karpenter consolidation, and instance families:

| Profile | VPA mode | Karpenter consolidation | Instances | Use case |
|---------|----------|------------------------|-----------|----------|
| `dev` | `InPlaceOrRecreate` | `WhenEmptyOrUnderutilized`, 5 min | t-series | Minimal cost, single replicas, dev environments |
| `test` | `Initial` | `WhenEmpty`, 10 min | t3 + m5 | Stability, no surprise evictions |
| `prod` | `Off` (recommendations only) | `WhenEmpty`, 15 min | m5 + r5 | HA, manual resource tuning |

### How idle scale-down and active scale-up work (dev profile)

```
Evening (traffic drops)
  → VPA lowers CPU/memory requests (slow histogram decay)
  → In-place resize DOWN — no eviction
  → Nodes become underutilized
  → After 5 min (consolidateAfter), Karpenter bins-packs and removes nodes

Morning (traffic returns)
  → VPA raises requests (fast peak percentile)
  → In-place resize UP, or pods become pending if the node cannot accommodate
  → Karpenter provisions a new node immediately (no delay on scale-out)
```

No scheduled downscaler or KEDA is needed. Idle shrink emerges naturally from VPA lowering requests + Karpenter consolidation.

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Terraform | 1.5.7 | https://developer.hashicorp.com/terraform/install |
| Helmfile | 1.x | `brew install helmfile` |
| Helm | 3.14+ | https://helm.sh/docs/intro/install |
| kubectl | 1.29+ | https://kubernetes.io/docs/tasks/tools |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |

Your shell must be authenticated to the target AWS account (`aws sts get-caller-identity` should succeed) and your kubeconfig must point at the target cluster.

---

## Install order

The helmfile `sync` command installs releases in the order they appear in `helmfile.yaml.gotmpl`:

1. **metrics-server** — provides live CPU/memory metrics used by the VPA recommender.
2. **vpa** — installs CRDs + recommender + updater + admission controller; also applies the `gp3` StorageClass via a presync hook.
3. **goldilocks** — watches labeled namespaces and auto-creates one VPA object per Deployment.
4. **karpenter** — dynamic node provisioner; EC2NodeClass + NodePool applied via postsync hook.

Run everything in one command:

```bash
cd helm-addons

# Required for Karpenter (ECR OCI registry; tokens expire after 12 h)
aws ecr-public get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin public.ecr.aws

helmfile -e eks-karpenter-vpa sync
```

---

## Installing Karpenter on a cluster

### Step 1 — Tag private subnets for Karpenter discovery (Terraform)

In `terraform/clusters/<cluster>/main.tf`, pass the discovery tag to the VPC module:

```hcl
module "vpc" {
  ...
  private_subnet_tags = {
    "karpenter.sh/discovery" = "<cluster-name>"
  }
}
```

```bash
cd terraform/clusters/<cluster>
terraform apply -target=module.vpc
```

### Step 2 — Apply the IAM Terraform module

```bash
cd karpenter/iam
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars` (use real OIDC values from `terraform output` in the cluster repo):

```hcl
cluster_name      = "<cluster-name>"
aws_region        = "eu-west-1"
oidc_provider_arn = "arn:aws:iam::<account_id>:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/<oidc_id>"
oidc_provider_url = "https://oidc.eks.eu-west-1.amazonaws.com/id/<oidc_id>"
```

> **Important:** Use the real OIDC values. The IRSA trust policy breaks if the literal placeholders remain.

```bash
terraform init && terraform apply
```

### Step 3 — Fill in the environment file

```bash
cp environments/eks-karpenter-vpa.yaml environments/<cluster>.yaml
```

```yaml
profile: dev                 # dev | test | prod
cluster_name: <cluster-name>
cluster_endpoint: ""         # terraform output cluster_endpoint
aws_region: eu-west-1

karpenter_version: "1.5.0"
karpenter_controller_role_arn: ""       # terraform output karpenter_controller_role_arn
karpenter_interruption_queue_name: ""   # terraform output karpenter_interruption_queue_name
karpenter_node_role_name: ""            # terraform output karpenter_node_role_name
```

### Step 4 — Update the EC2NodeClass for the new cluster

`karpenter/manifests/<profile>/ec2nodeclass.yaml` contains cluster-name references:

```yaml
spec:
  role: <cluster-name>-karpenter-node          # node IAM role

  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <cluster-name>  # must match private_subnet_tags in Terraform

  securityGroupSelectorTerms:
    - tags:
        kubernetes.io/cluster/<cluster-name>: owned

  tags:
    karpenter.sh/discovery: <cluster-name>
```

### Step 5 — Add the environment to `helmfile.yaml.gotmpl`

```yaml
environments:
  eks-karpenter-vpa:
    values:
      - environments/eks-karpenter-vpa.yaml
      - profiles/dev.yaml
  <cluster>:                  # add this block
    values:
      - environments/<cluster>.yaml
      - profiles/<profile>.yaml
```

### Step 6 — Log in to ECR Public and install

```bash
aws ecr-public get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin public.ecr.aws

helmfile -e <cluster> diff   # preview
helmfile -e <cluster> sync   # install
```

### Step 7 — Verify

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl get ec2nodeclass    # READY: True
kubectl get nodepool        # READY: True
```

---

## VPA and Goldilocks

### What gets installed

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| metrics-server | kube-system | Supplies CPU/memory metrics to VPA recommender |
| vpa | vpa | Recommender + Updater + Admission Controller |
| goldilocks | goldilocks | Auto-VPA per Deployment; right-sizing dashboard |

### Enabling VPA on a namespace

Label the namespace to opt it in. Goldilocks creates one VPA object per Deployment and displays recommendations on its dashboard.

```bash
kubectl label namespace <your-ns> goldilocks.fairwinds.com/enabled=true

# Set the update mode for this namespace (optional — inherits profile default if omitted)
# dev  → InPlaceOrRecreate
# test → Initial
# prod → Off
kubectl label namespace <your-ns> goldilocks.fairwinds.com/vpa-update-mode=InPlaceOrRecreate
```

### VPA update modes explained

| Mode | Behaviour | When to use |
|------|-----------|-------------|
| `InPlaceOrRecreate` | Resizes the running container live; evicts only as last resort | Dev: single-replica, cost-optimised |
| `Initial` | Applies recommendations at pod creation only; never evicts running pods | Test: stability first |
| `Off` | Records recommendations, applies nothing | Prod: manual review before changes |

### In-place resize (K8s 1.35 + VPA 1.4+)

`InPlaceOrRecreate` requires:
- Kubernetes >= 1.27 (feature gate `InPlaceOrRecreate` in VPA)
- VPA chart version >= 4.7 (Fairwinds `vpa` chart)
- The cluster this was tested on runs **1.35** — the feature is stable

When in-place resize is used, the pod stays on the same node and AZ. No rescheduling occurs, so PVC-bound pods are always safe.

### Fallback: hand-managed VPA CRs

If a Goldilocks version does not propagate the update mode into its generated VPA objects, copy the template from `vpa/manifests/<profile>/vpa-template.yaml`, fill in the Deployment name and namespace, and apply it manually:

```bash
kubectl apply -f vpa/manifests/dev/vpa-template.yaml
```

The hand-managed CR overrides only the `updateMode`; Goldilocks still shows recommendations in the dashboard.

---

## Storage: gp3 StorageClass and PVC zone safety

A `gp3` StorageClass with `volumeBindingMode: WaitForFirstConsumer` is applied automatically as a presync hook on the `vpa` release.

Key properties:
- **Default class** — claims without an explicit `storageClassName` use `gp3`.
- **WaitForFirstConsumer** — the PVC binds in the same AZ as the pod that claims it. This eliminates volume node-affinity conflicts when pods are rescheduled.
- **gp3 baseline** — 3000 IOPS / 125 MiB/s at no extra charge vs gp2.

### Protecting stateful pods from Karpenter consolidation

Annotate pods that own a PVC with `karpenter.sh/do-not-disrupt: "true"`:

```yaml
metadata:
  annotations:
    karpenter.sh/do-not-disrupt: "true"
```

Karpenter will never voluntarily evict annotated pods. The node they run on is only replaced during a Disruption Budget-aware rolling operation (e.g. node expiry or forced upgrade), not during routine consolidation.

### Verify gp3 is the default StorageClass

```bash
kubectl get sc
# NAME     PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      DEFAULT
# gp2      kubernetes.io/aws-ebs   Delete          Immediate              false
# gp3      ebs.csi.aws.com         Delete          WaitForFirstConsumer   true
```

---

## Sample apps for validation

`examples/` contains two ready-to-use manifests:

| File | Purpose |
|------|---------|
| `sample-stateless.yaml` | Single-replica Deployment with periodic CPU spikes. Observe VPA in-place resize up, then Karpenter scale-out; idle → resize down → Karpenter consolidate. |
| `sample-stateful.yaml` | Single-replica StatefulSet with a gp3 PVC. Confirms in-place resize with no reschedule, no zone conflict, and Karpenter respects the `do-not-disrupt` annotation. |

```bash
# Create and label the namespace
kubectl create namespace vpa-demo
kubectl label namespace vpa-demo goldilocks.fairwinds.com/enabled=true
kubectl label namespace vpa-demo goldilocks.fairwinds.com/vpa-update-mode=InPlaceOrRecreate

# Deploy both sample apps
kubectl apply -f examples/sample-stateless.yaml
kubectl apply -f examples/sample-stateful.yaml

# Watch VPA recommendations (takes ~5 min for the recommender to gather data)
kubectl get vpa -n vpa-demo -w

# Watch Karpenter node activity
kubectl get nodes -w
```

---

## Customising Karpenter

### Change instance types

Edit `karpenter/manifests/<profile>/nodepool.yaml`:

```yaml
- key: node.kubernetes.io/instance-type
  operator: In
  values:
    - t3.large
    - m5.large       # uncomment for general-purpose workloads
    - r5.large       # uncomment for memory-intensive workloads
```

### Allow Spot instances

```yaml
- key: karpenter.sh/capacity-type
  operator: In
  values: ["on-demand", "spot"]
```

### Adjust consolidation delay

```yaml
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 10m    # increase to reduce node churn
```

### Change Karpenter version

Edit `environments/<cluster>.yaml`:

```yaml
karpenter_version: "1.6.0"
```

---

## Applying to another existing cluster

1. Tag private subnets in Terraform (Step 1).
2. Apply the IAM module with the cluster's OIDC values (Step 2).
3. Copy and fill `environments/<cluster>.yaml` (Step 3). Set `profile: dev`, `test`, or `prod`.
4. Copy EC2NodeClass manifests from `karpenter/manifests/<profile>/` and update cluster-name references (Step 4).
5. Add the environment block to `helmfile.yaml.gotmpl` with the matching profile file (Step 5).
6. Log in to ECR Public and run `helmfile -e <cluster> sync` (Step 6).

---

## Uninstalling

```bash
helmfile -e <cluster> destroy

# Remove IAM resources
cd karpenter/iam && terraform destroy
```

---

## Troubleshooting

### `exec: "docker-credential-desktop": executable file not found`

Your `~/.docker/config.json` contains `"credsStore": "desktop"` but Docker Desktop is not running. Remove that entry, then log in to ECR Public (Step 6 above).

### `SubnetSelector did not match any Subnets`

The private subnets are missing the `karpenter.sh/discovery=<cluster-name>` tag. Apply the Terraform change (Step 1).

### `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity`

The IRSA trust policy has placeholder OIDC values. Re-apply the IAM Terraform with the real values from `terraform output`.

### `EC2NodeClass READY: False`

```bash
kubectl describe ec2nodeclass default
```

The `Status.Conditions` section shows exactly which dependency (subnets, security groups, AMI, instance profile) is unresolved.

### VPA pods pending or CrashLoopBackOff

```bash
kubectl get pods -n vpa -w
kubectl logs -n vpa -l app.kubernetes.io/name=vpa-recommender
```

Ensure metrics-server is running first — the recommender will fail to start without it.

### Goldilocks not creating VPA objects

Confirm the namespace has both labels:

```bash
kubectl get namespace vpa-demo --show-labels
# Should include: goldilocks.fairwinds.com/enabled=true
```

If labels are correct but VPAs are not appearing, check the Goldilocks controller logs:

```bash
kubectl logs -n goldilocks -l app.kubernetes.io/name=goldilocks-controller
```
