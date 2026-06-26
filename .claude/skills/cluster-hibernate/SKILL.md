---
name: cluster-hibernate
description: Scale an EKS + Karpenter cluster down to ZERO worker nodes for cost saving (weekends/overnight), reversibly and WITHOUT editing workloads (ArgoCD-safe). Freezes Karpenter, removes its nodes, and scales all managed nodegroups to 0; records the originals on the NodePool (annotation) and nodegroups (tags) so it is stateless. Reverse with /cluster-wake.
---

Hibernate a whole cluster for cost saving, then wake it later. It is **node-level on purpose**:
it never scales individual Deployments/StatefulSets, so ArgoCD `selfHeal` has nothing to
revert and you do not need any application Git repos. Stateful data on PVCs is preserved.

**Prerequisites**
- `kubectl` context pointing at the TARGET cluster — verify with `kubectl config current-context`
- `aws` CLI with credentials allowed to read/update the cluster's EKS managed nodegroups
- `jq`

Cluster name + region are parsed from the kube-context ARN
(`arn:aws:eks:<region>:<acct>:cluster/<name>`); override with `CLUSTER=` / `REGION=` if your
context is named differently.

**Run**

    bash .claude/skills/cluster-hibernate/hibernate.sh

Steps it performs:
1. Freezes every Karpenter NodePool (`limits → cpu:0, memory:0`), recording the original
   `limits` as the `hibernate.limits` annotation on the NodePool.
2. Relaxes non-`kube-system` PodDisruptionBudgets so node drain can't stall (they are
   controller-managed and recreated automatically on wake).
3. Deletes all NodeClaims → Karpenter terminates its nodes; their pods become Pending.
4. Scales every EKS managed nodegroup to `desiredSize:0` (min:0), recording the original
   `min/max/desired` as `hibernateMin/Max/Desired` tags on the nodegroup.

Result: **zero worker nodes, all pods Pending, ~zero compute cost.** The EKS control plane and
EBS volumes remain (small fixed cost).

Reverse with **/cluster-wake**.
