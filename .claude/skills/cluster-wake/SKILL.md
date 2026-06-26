---
name: cluster-wake
description: Reverse /cluster-hibernate — scale EKS managed nodegroups back to their original size (from tags), wait for a node, then unfreeze Karpenter (restore NodePool limits from the annotation). Pending pods then schedule and ArgoCD restores any relaxed PDBs.
---

Wake a cluster that was put to sleep with /cluster-hibernate. Stateless — it reads the
originals stored on the cluster (nodegroup `hibernate*` tags and the NodePool
`hibernate.limits` annotation), so it works even if a different teammate ran the hibernate.

**Prerequisites**: same as /cluster-hibernate — `kubectl` context on the TARGET cluster,
`aws` CLI with EKS permissions, `jq`. Override discovery with `CLUSTER=` / `REGION=`.

**Run**

    bash .claude/skills/cluster-wake/wake.sh

Steps:
1. Restores each EKS managed nodegroup to its original `min/max/desired` from the
   `hibernateMin/Max/Desired` tags, then removes those tags.
2. Waits for a node to become `Ready` (Karpenter's controller runs on it).
3. Restores each Karpenter NodePool's `limits` from the `hibernate.limits` annotation, then
   removes the annotation.

Karpenter then provisions nodes for the Pending pods; ArgoCD re-syncs and recreates any PDBs
that hibernation relaxed.
