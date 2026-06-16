# VPA + Goldilocks + Karpenter Integration Test Report

**Cluster:** `eks-karpenter-vpa`  
**Region:** `eu-west-1`  
**Kubernetes:** `v1.35.5-eks-3385e9b`  
**Profile:** `dev` (`InPlaceOrRecreate` VPA, `WhenEmptyOrUnderutilized` consolidation, `consolidateAfter: 5m`)  
**Date:** 2026-06-16

---

## 1. Test Scenarios

### 1.1 Addon Health

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1.1.1 | **metrics-server** installed and serving | Pod `Running` in `kube-system`; `kubectl top nodes` returns CPU/memory |
| 1.1.2 | **VPA** (Fairwinds chart) installed | Recommender, updater, admission-controller pods `Running` in `vpa` namespace |
| 1.1.3 | **Goldilocks** installed | Controller + dashboard pods `Running` in `goldilocks` namespace |
| 1.1.4 | **Karpenter** installed | Controller pod `Running` in `kube-system`; `EC2NodeClass` and `NodePool` `READY=True` |
| 1.1.5 | **gp3 StorageClass** applied | `gp3` exists, `DEFAULT=true`, `volumeBindingMode=WaitForFirstConsumer`, provisioner `ebs.csi.aws.com` |

### 1.2 Namespace Labeling / VPA Object Creation

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1.2.1 | Create `vpa-demo` namespace with Goldilocks labels | `goldilocks.fairwinds.com/enabled=true` and `goldilocks.fairwinds.com/vpa-update-mode=InPlaceOrRecreate` |
| 1.2.2 | Goldilocks auto-creates VPA per workload | One `VerticalPodAutoscaler` CR per Deployment/StatefulSet appears in `vpa-demo` |
| 1.2.3 | VPA `updateMode` is `InPlaceOrRecreate` | `kubectl get vpa -o yaml` shows `updatePolicy.updateMode: InPlaceOrRecreate` |

### 1.3 Stateless Workload + VPA In-Place Resize

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1.3.1 | Deploy `sample-stateless` (polinux/stress, 10m CPU request) | Pod schedules and runs periodic 30s CPU spikes |
| 1.3.2 | VPA recommender gathers usage | `RecommendationProvided` condition becomes `True` within ~5 min |
| 1.3.3 | VPA updater raises requests in-place | Pod CPU request increases toward target (e.g. 10m → 1 CPU) with **0 restarts** |
| 1.3.4 | In-place resize annotation | Pod annotated `vpaInPlaceUpdated: "true"` |

### 1.4 Stateful Workload + PVC Zone Safety + do-not-disrupt

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1.4.1 | Deploy `sample-stateful` StatefulSet with gp3 PVC | PVC `data-sample-stateful-0` binds to `Bound` |
| 1.4.2 | PVC zone matches pod zone | PV node affinity pins volume to same AZ as pod (e.g. `eu-west-1a`) |
| 1.4.3 | `karpenter.sh/do-not-disrupt: "true"` on pod | Annotation present on `sample-stateful-0` |
| 1.4.4 | VPA in-place resize on stateful pod | CPU/memory requests adjusted with **0 restarts**, pod stays on same node |
| 1.4.5 | Karpenter does not evict protected pod | Node hosting stateful pod is **not** consolidated while pod is running |

### 1.5 Load Generator Scale-Out (Karpenter Provisions Node)

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1.5.1 | Deploy `load-generator` (3 replicas, 200m CPU request, 1 CPU stress each) | Some pods go `Pending` when bootstrap node is full |
| 1.5.2 | Karpenter provisions a new node | `NodeClaim` created; node joins `Ready` within seconds |
| 1.5.3 | Pending pods schedule on new node | All load-generator pods reach `Running` |
| 1.5.4 | Instance type matches NodePool | Provisioned node is `t3.medium` (cheapest allowed type) |

### 1.6 Idle Scale-Down / Karpenter Consolidation

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1.6.1 | Delete load-generator | Cluster CPU drops; Karpenter node becomes underutilized |
| 1.6.2 | `do-not-disrupt` blocks consolidation | Karpenter node **retained** while `sample-stateful-0` still runs on it |
| 1.6.3 | Delete stateful workload | StatefulSet + PVC removed; Karpenter node has no protected pods |
| 1.6.4 | Karpenter consolidates empty node | After `consolidateAfter` (5m), `NodeClaim` deleted and extra node removed |
| 1.6.5 | Cluster returns to bootstrap footprint | Only managed/bootstrap node remains |

### 1.7 Goldilocks Label Bug + Hand-Managed VPA Fallback

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1.7.1 | Goldilocks reads namespace `vpa-update-mode` label | Controller reconciles labeled namespace |
| 1.7.2 | Label value lowercasing bug | Goldilocks emits `Inplaceorrecreate` (invalid) instead of `InPlaceOrRecreate` |
| 1.7.3 | Fallback: remove Goldilocks labels from namespace | `goldilocks.fairwinds.com/enabled` and `vpa-update-mode` labels removed |
| 1.7.4 | Fallback: apply hand-managed VPA CRs | VPAs created from `vpa/manifests/dev/vpa-template.yaml` pattern with correct `updateMode` |
| 1.7.5 | Updater acts on hand-managed VPAs | `RecommendationProvided=True`, resource requests adjusted in-place |

---

## 2. Chronological Test Story

### Phase 0 — Helmfile sync and addon install

**Command:** `helmfile -e eks-karpenter-vpa sync`

**Initial failure — VPA chart version:**
- Helmfile referenced VPA chart `4.7.3`, which does not exist in `fairwinds-stable` (`4.7.2` jumps to `4.8.0`).
- **Fix:** Bumped to `4.12.1` (VPA app version 1.6.0, full `InPlaceOrRecreate` support).
- Re-ran sync; all four releases deployed.

**Installed releases:**

| Release | Namespace | Chart | App version |
|---------|-----------|-------|-------------|
| metrics-server | kube-system | 3.12.2 | 0.7.2 |
| vpa | vpa | 4.12.1 | 1.6.0 |
| goldilocks | goldilocks | 9.0.1 | v4.13.0 |
| karpenter | kube-system | 1.5.0 | 1.5.0 |

**gp3 StorageClass** created via VPA presync hook:
```
storageclass.storage.k8s.io/gp3 created
```
Verified: `gp3` is default, `WaitForFirstConsumer`, provisioner `ebs.csi.aws.com`.

**VPA pods (all Running):**
- `vpa-recommender-56bb5797d5-6nkcq`
- `vpa-updater-7f8c558bfc-qwgq9`
- `vpa-admission-controller-596f478985-7hf92`

**metrics-server:** `metrics-server-8476dffb6d-brtxq` Running; `kubectl top nodes` succeeded.

---

### Phase 1 — Goldilocks controller crash (fixed)

**Observation:** `goldilocks-controller` entered `CrashLoopBackOff`.

**Root cause:** `goldilocks-values.yaml.gotmpl` set an invalid global flag:
```yaml
controller.flags.vpa-update-mode: "InPlaceOrRecreate"
```
Goldilocks v4.13.0 does not support `--vpa-update-mode`; update mode is set **per namespace via labels**.

**Fix:** Removed the `controller.flags.vpa-update-mode` block. Redeployed with `helmfile -e eks-karpenter-vpa -l name=goldilocks sync`.

**Result:** Controller `goldilocks-controller-5cbc44bfc8-mqfbg` Running (0 restarts).

---

### Phase 2 — Namespace and workload deployment

**Namespace created and labeled:**
```bash
kubectl create namespace vpa-demo
kubectl label namespace vpa-demo goldilocks.fairwinds.com/enabled=true
kubectl label namespace vpa-demo goldilocks.fairwinds.com/vpa-update-mode=InPlaceOrRecreate
```

**Workloads applied:**

| Resource | Name | Replicas | Initial CPU request | Notes |
|----------|------|----------|---------------------|-------|
| Deployment | `sample-stateless` | 1 | 10m | `polinux/stress`, 30s CPU spike / 90s sleep loop |
| StatefulSet | `sample-stateful` | 1 | 10m | `busybox`, gp3 PVC, `karpenter.sh/do-not-disrupt: "true"` |
| Deployment | `load-generator` | 3 | 200m each | `stress --cpu 1 --timeout 600s` per pod |

**Bootstrap node before scale-out:** `ip-10-1-1-165.eu-west-1.compute.internal` (managed node group, `eu-west-1a`).

---

### Phase 3 — Karpenter scale-out

**Trigger:** 3× `load-generator` pods (600m requested CPU total) + sample apps exceeded bootstrap node capacity; pods went `Pending`.

**Karpenter response (~8 seconds):**
- `NodeClaim` `default-99wtj` created
- Node `ip-10-1-1-128.eu-west-1.compute.internal` joined (`Ready`)
- Instance type: **t3.medium** (on-demand)
- Zone: **eu-west-1a**

**Pod placement after scheduling:**
- `load-generator-*` pods → Karpenter node `ip-10-1-1-128`
- `sample-stateful-0` → Karpenter node `ip-10-1-1-128`
- `sample-stateless-*` → managed node `ip-10-1-1-165`

**Cluster nodes:** 2 (managed + Karpenter-provisioned).

---

### Phase 4 — PVC zone safety

**PVC:** `data-sample-stateful-0` (gp3, 1Gi) → `Bound`

**Zone verification:**
- Pod `sample-stateful-0` scheduled on `ip-10-1-1-128`
- Node zone: `eu-west-1a`
- PV node affinity: `topology.kubernetes.io/zone In [eu-west-1a]`

**Result:** `WaitForFirstConsumer` binding ensured PVC and pod share the same AZ. No cross-zone volume conflict.

---

### Phase 5 — Goldilocks label bug and VPA fallback

**Observation:** Goldilocks controller logs showed VPA creation failures:
```
Unsupported value: "Inplaceorrecreate"
```
Goldilocks lowercased the namespace label `InPlaceOrRecreate` → `Inplaceorrecreate`, which the VPA API rejects.

**Mitigation:**
1. Removed Goldilocks labels from `vpa-demo`:
   ```bash
   kubectl label namespace vpa-demo goldilocks.fairwinds.com/enabled-
   kubectl label namespace vpa-demo goldilocks.fairwinds.com/vpa-update-mode-
   ```
2. Applied hand-managed VPA CRs for `sample-stateless`, `sample-stateful`, and `load-generator` with explicit `updateMode: InPlaceOrRecreate`.

**Result:** Three VPAs created; `sample-stateless` immediately showed `RecommendationProvided=True`.

---

### Phase 6 — VPA recommendations and in-place resize

**After ~2 minutes of sustained load**, recommender produced targets:

| VPA | Workload | Original request | VPA target | Applied request |
|-----|----------|------------------|------------|-----------------|
| `load-generator` | Deployment (3 pods) | 200m CPU, 64Mi | **813m** CPU | Pod `load-generator-7c88d7577c-tg2qd` → 813m; others still 200m (rolling) |
| `sample-stateless` | Deployment | 10m CPU, 32Mi | **1 CPU**, 100Mi | **1 CPU**, 100Mi |
| `sample-stateful` | StatefulSet | 10m CPU, 32Mi | **15m** CPU, 100Mi | **15m**, 100Mi |

**Node load at peak:** Karpenter node at **103% CPU** (`kubectl top nodes`).

**In-place resize evidence:**
- **Restart count: 0** on all pods in `vpa-demo`
- `sample-stateful-0` annotation: `vpaInPlaceUpdated: "true"`
- `sample-stateless-855d778fcd-bm2kg` annotation: `vpaInPlaceUpdated: "true"` (confirmed at report time)
- No `EvictedByVPA` events

**Current `sample-stateless` pod (post-test):**
- Requests: `cpu: 1`, `memory: 100Mi`
- Limits: `cpu: 100` (display quirk), `memory: 800Mi`
- `vpaInPlaceUpdated: "true"`

---

### Phase 7 — Load removal and consolidation (blocked)

**Action:** Deleted `load-generator` Deployment.

**Expected:** Karpenter consolidates underutilized `ip-10-1-1-128` after 5 minutes.

**Observed (7-minute poll):** Node **not** removed.

**Root cause:** `sample-stateful-0` remained on `ip-10-1-1-128` with:
```yaml
karpenter.sh/do-not-disrupt: "true"
```
Karpenter correctly refused to evict the protected pod. Consolidation blocked — **expected behavior**.

**Pod placement at this point:**
- `ip-10-1-1-128`: `sample-stateful-0` only
- `ip-10-1-1-165`: `sample-stateless-*`

---

### Phase 8 — Stateful teardown and successful consolidation

**Action:**
```bash
kubectl delete statefulset sample-stateful -n vpa-demo
kubectl delete pvc data-sample-stateful-0 -n vpa-demo
```

**Result:** Karpenter node became empty of protected workloads. After `consolidateAfter` elapsed, Karpenter removed the extra node.

---

### Phase 9 — Final cluster state (verified at report time)

```text
$ kubectl get nodes
NAME                                       STATUS   AGE
ip-10-1-1-165.eu-west-1.compute.internal   Ready    3h23m

$ kubectl get nodeclaim
No resources found

$ kubectl get pods -n vpa-demo
NAME                                READY   STATUS    RESTARTS   NODE
sample-stateless-855d778fcd-bm2kg   1/1     Running   0          ip-10-1-1-165

$ kubectl get nodepool
NAME      NODECLASS   NODES   READY
default   default     0       True
```

**Consolidation verdict:** **PASS** — Karpenter node `ip-10-1-1-128` (t3.medium, NodeClaim `default-99wtj`) was removed after the stateful workload and PVC were deleted. Cluster returned to a single managed/bootstrap node.

**Remaining artifacts:**
- `sample-stateless` Deployment and VPA still active
- Orphan VPAs `load-generator` and `sample-stateful` remain (targets deleted; `PROVIDED=False`)

---

## 3. Summary

| Area | Result |
|------|--------|
| Addon health | **PASS** — all components Running |
| gp3 / zone safety | **PASS** — PVC bound in `eu-west-1a` matching pod |
| VPA in-place resize | **PASS** — 0 restarts, `vpaInPlaceUpdated=true` |
| Karpenter scale-out | **PASS** — t3.medium in ~8s |
| do-not-disrupt guard | **PASS** — blocked consolidation while stateful pod ran |
| Karpenter consolidation | **PASS** — extra node removed after stateful deleted |
| Goldilocks auto-VPA | **FAIL** — `InPlaceOrRecreate` lowercasing bug; workaround via hand-managed VPAs |

### Fixes applied during test

1. VPA chart `4.7.3` → `4.12.1` (chart version did not exist)
2. Removed invalid Goldilocks `--vpa-update-mode` controller flag
3. Removed Goldilocks namespace labels; applied hand-managed VPA CRs with correct `InPlaceOrRecreate` casing

### Recommended follow-ups

- Track [Goldilocks issue](https://github.com/FairwindsOps/goldilocks) for `InPlaceOrRecreate` label casing fix
- Clean up orphan VPAs: `kubectl delete vpa load-generator sample-stateful -n vpa-demo`
- Re-run consolidation test with only stateless workloads to validate faster scale-down without `do-not-disrupt` blocker
