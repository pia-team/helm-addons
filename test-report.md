# VPA + Karpenter Integration Test Report

**Cluster:** `eks-karpenter-vpa`  
**Region:** `eu-west-1`  
**Kubernetes:** `1.35.5`  
**Profile:** `dev`  
**Date:** 2026-06-16  
**Tester:** automated validation run

---

## 1. Test Scenarios

| ID | Scenario | Goal | Pass criteria |
|----|----------|------|---------------|
| T1 | Addon health | All platform add-ons are running before workloads are deployed | metrics-server, VPA (recommender/updater/admission), Goldilocks dashboard, Karpenter controller, and `gp3` StorageClass are healthy |
| T2 | gp3 StorageClass zone safety | PVCs bind in the pod's AZ | `gp3` is default; `volumeBindingMode: WaitForFirstConsumer`; PV node affinity matches pod zone |
| T3 | Goldilocks namespace labeling | Auto-create VPA objects per workload | Labeling `goldilocks.fairwinds.com/enabled=true` creates VPAs with correct `updateMode` |
| T4 | Goldilocks fallback (hand-managed VPA) | Work around Goldilocks label bug | Direct VPA CRs with `updateMode: InPlaceOrRecreate` are accepted and reconciled |
| T5 | Stateless workload + in-place VPA resize | VPA adjusts CPU/memory without pod restart | Pod restart count stays 0; requests change to match VPA target |
| T6 | Stateful workload + PVC | Stateful pod runs with gp3 volume in same AZ | PVC `Bound`; pod and PV both in `eu-west-1a`; no reschedule on resize |
| T7 | PVC guardrail (`do-not-disrupt`) | Karpenter does not evict PVC-backed pods during consolidation | Node hosting annotated pod is not removed while pod is running |
| T8 | Load scale-out (Karpenter) | Pending pods trigger fast node provisioning | Karpenter creates a `t3.medium` node within seconds of pods going Pending |
| T9 | VPA scale-up under load | VPA recommender raises requests when CPU usage spikes | Recommendations reflect observed load (~650–813m per load-generator pod) |
| T10 | Idle scale-down (Karpenter consolidation) | Extra node removed after workloads drain | NodeClaim count returns to 0; cluster returns to bootstrap node only |

---

## 2. Pre-test Fixes Applied

Before the workload test began, two install issues were resolved:

| Issue | Symptom | Fix |
|-------|---------|-----|
| VPA chart version | `chart "vpa" matching 4.7.3 not found` | Bumped to `4.12.1` (VPA app 1.6.0) in `helmfile.yaml.gotmpl` |
| Goldilocks controller crash | `unknown flag: --vpa-update-mode` | Removed invalid global flag from `goldilocks-values.yaml.gotmpl`; update mode is set per-namespace via labels |

After fixes, `helmfile -e eks-karpenter-vpa sync` deployed all four releases successfully.

---

## 3. Test Story (Chronological)

### 3.1 Baseline — cluster before workloads

At test start the cluster had a single managed bootstrap node:

```
NAME                                       STATUS   AGE     VERSION
ip-10-1-1-165.eu-west-1.compute.internal   Ready    165m    v1.35.5-eks-3385e9b
```

Addon pods were healthy:

| Component | Namespace | Status |
|-----------|-----------|--------|
| metrics-server | kube-system | Running |
| vpa-recommender | vpa | Running |
| vpa-updater | vpa | Running |
| vpa-admission-controller | vpa | Running |
| goldilocks-controller | goldilocks | Running (after fix) |
| goldilocks-dashboard | goldilocks | Running (2 replicas) |
| karpenter | kube-system | Running |

StorageClass `gp3` was the cluster default with `WaitForFirstConsumer` binding mode.

---

### 3.2 T2 — Namespace and workload deployment

**Namespace created:**

```bash
kubectl create namespace vpa-demo
kubectl label namespace vpa-demo goldilocks.fairwinds.com/enabled=true
kubectl label namespace vpa-demo goldilocks.fairwinds.com/vpa-update-mode=InPlaceOrRecreate
```

**Workloads deployed:**

| Resource | Name | Replicas | Initial requests |
|----------|------|----------|------------------|
| Deployment | `sample-stateless` | 1 | cpu: 10m, memory: 32Mi |
| StatefulSet | `sample-stateful` | 1 | cpu: 10m, memory: 32Mi |
| Deployment | `load-generator` | 3 | cpu: 200m, memory: 64Mi |

`sample-stateless` runs a periodic CPU stress loop (`stress --cpu 1 --timeout 30s`, sleep 90s).  
`load-generator` runs sustained CPU load (`stress --cpu 1 --timeout 600s`).  
`sample-stateful` writes random data to a gp3 PVC and carries `karpenter.sh/do-not-disrupt: "true"`.

---

### 3.3 T8 — Karpenter scale-out

Within ~20 seconds of deploying the workloads, 4 pods were Pending (3× load-generator + sample-stateful-0). Karpenter reacted immediately:

```
08:27:00  found provisionable pod(s): vpa-demo/sample-stateful-0
08:27:00  computed new nodeclaim(s): 1
08:27:02  launched nodeclaim default-99wtj  instance-type=t3.medium  zone=eu-west-1a
08:27:23  registered node: ip-10-1-1-128.eu-west-1.compute.internal
08:27:44  initialized nodeclaim default-99wtj
```

**Result:** Karpenter provisioned a `t3.medium` on-demand node in **~8 seconds** from first Pending pod to EC2 launch. Total time to Ready: ~44 seconds.

**Pod placement after scale-out:**

| Pod | Node | IP |
|-----|------|----|
| `load-generator-7c88d7577c-g4zgj` | ip-10-1-1-128 (Karpenter) | 10.1.1.189 |
| `load-generator-7c88d7577c-gmt2l` | ip-10-1-1-128 (Karpenter) | 10.1.1.225 |
| `load-generator-7c88d7577c-tg2qd` | ip-10-1-1-128 (Karpenter) | 10.1.1.145 |
| `sample-stateful-0` | ip-10-1-1-128 (Karpenter) | 10.1.1.30 |
| `sample-stateless-855d778fcd-bm2kg` | ip-10-1-1-165 (managed) | 10.1.1.144 |

---

### 3.4 T2 / T6 — PVC zone safety

PVC `data-sample-stateful-0` bound to volume `pvc-1bc42262-6f3d-480d-923a-4278beff2c15` on StorageClass `gp3`.

PV node affinity:

```json
{
  "required": {
    "nodeSelectorTerms": [{
      "matchExpressions": [{
        "key": "topology.kubernetes.io/zone",
        "operator": "In",
        "values": ["eu-west-1a"]
      }]
    }]
  }
}
```

Pod `sample-stateful-0` ran on `ip-10-1-1-128` in `eu-west-1a` — **same zone as the volume**. No volume node-affinity conflict.

**Result: T2 PASS, T6 PASS**

---

### 3.5 T3 / T4 — Goldilocks label bug and VPA fallback

Goldilocks controller attempted to create VPAs for labeled namespaces but failed:

```
Error creating VPA/goldilocks-sample-stateful:
  spec.updatePolicy.updateMode: Unsupported value: "Inplaceorrecreate"
  supported values: "Off", "Initial", "Recreate", "InPlaceOrRecreate", "Auto"
```

Goldilocks v4.13.0 lowercases the namespace label value (`InPlaceOrRecreate` → `Inplaceorrecreate`), which the VPA API rejects. This is a known Goldilocks bug.

**Mitigation (plan fallback path):** Removed Goldilocks managed labels from `vpa-demo` and applied hand-managed VPA CRs:

```bash
kubectl label namespace vpa-demo goldilocks.fairwinds.com/enabled-
kubectl apply -f vpa-objects.yaml   # sample-stateless, sample-stateful, load-generator
```

All three VPAs created with `updateMode: InPlaceOrRecreate` and `minReplicas: 1`.

**Result: T3 FAIL (Goldilocks bug), T4 PASS (fallback works)**

---

### 3.6 T5 / T9 — VPA recommendations and in-place resize

After ~2 minutes of sustained load, the VPA recommender produced:

| VPA | Container | Lower bound | Target | Upper bound | Uncapped target |
|-----|-----------|-------------|--------|-------------|-----------------|
| `load-generator` | load | 414m CPU | **813m CPU** | 2 CPU | 813m CPU |
| `sample-stateless` | app | 15m CPU | **1 CPU** | 1 CPU | 1101m CPU |
| `sample-stateful` | app | 15m CPU | **15m CPU** | 500m CPU | 15m CPU |

**Live pod CPU usage at peak (metrics-server):**

| Pod | CPU usage |
|-----|-----------|
| load-generator (×3) | 646–668m each |
| sample-stateless | 0m (between stress cycles) |
| sample-stateful | 4m |

**VPA updater applied in-place resize (no pod restarts):**

| Pod | Before (requests) | After (requests) | Restarts |
|-----|-------------------|--------------------|----------|
| `load-generator-tg2qd` | cpu: 200m | cpu: **813m** | 0 |
| `sample-stateless-bm2kg` | cpu: 10m | cpu: **1** | 0 |
| `sample-stateful-0` | cpu: 10m | cpu: **15m** | 0 |

Annotation `vpaInPlaceUpdated: "true"` appeared on `sample-stateful-0`, confirming the updater used in-place resize rather than eviction.

**Node load at peak:**

```
ip-10-1-1-128  CPU: 2001m (103%)   MEMORY: 469Mi (14%)
ip-10-1-1-165  CPU: 86m   (4%)     MEMORY: 972Mi (29%)
```

**Result: T5 PASS, T9 PASS**

---

### 3.7 T7 — `do-not-disrupt` blocks consolidation

At 11:33, `load-generator` Deployment was deleted to simulate end-of-day traffic drop. After 7 minutes of polling, the Karpenter node `ip-10-1-1-128` was **not removed**.

Investigation:

- `sample-stateful-0` was still running on `ip-10-1-1-128`
- Pod annotation: `karpenter.sh/do-not-disrupt: "true"`
- Karpenter disruption controller made no consolidation attempts in logs

This is **correct behavior** — the PVC guardrail prevents Karpenter from evicting stateful pods during consolidation.

**Result: T7 PASS**

---

### 3.8 T10 — Karpenter consolidation after stateful workload removed

At 11:41, `sample-stateful` StatefulSet and its PVC were deleted to free the Karpenter node. After the `consolidateAfter: 5m` window elapsed, Karpenter removed the node.

**Final cluster state:**

```
NAME                                       STATUS   AGE
ip-10-1-1-165.eu-west-1.compute.internal   Ready    3h23m

NodeClaims: (none)
Pods in vpa-demo:
  sample-stateless-855d778fcd-bm2kg  1/1 Running  (on managed node)
```

The Karpenter-provisioned `t3.medium` (`default-99wtj` / `ip-10-1-1-128`) was terminated. Cluster returned to a single bootstrap node.

**Result: T10 PASS**

---

## 4. Results Summary

| ID | Scenario | Result | Notes |
|----|----------|--------|-------|
| T1 | Addon health | **PASS** | All add-ons running after two install fixes |
| T2 | gp3 zone safety | **PASS** | PVC bound in pod's AZ (`eu-west-1a`) |
| T3 | Goldilocks labeling | **FAIL** | Label lowercasing bug in Goldilocks v4.13.0 |
| T4 | Hand-managed VPA fallback | **PASS** | Direct VPA CRs work with `InPlaceOrRecreate` |
| T5 | In-place VPA resize | **PASS** | 0 restarts; `vpaInPlaceUpdated=true` |
| T6 | Stateful + PVC | **PASS** | No zone conflict; in-place resize on stateful pod |
| T7 | do-not-disrupt guardrail | **PASS** | Node not removed while annotated pod ran |
| T8 | Karpenter scale-out | **PASS** | `t3.medium` in ~8s |
| T9 | VPA scale-up under load | **PASS** | Requests raised to match observed CPU |
| T10 | Karpenter consolidation | **PASS** | Extra node removed after workloads drained |

**Overall: 9/10 PASS, 1 FAIL (Goldilocks label bug — mitigated by hand-managed VPA CRs)**

---

## 5. Recommendations

1. **Goldilocks:** Do not rely on `goldilocks.fairwinds.com/vpa-update-mode=InPlaceOrRecreate` until Goldilocks fixes label value casing. Use hand-managed VPA CRs from `vpa/manifests/dev/vpa-template.yaml` for dev workloads.
2. **Stateful workloads:** Always annotate PVC-backed pods with `karpenter.sh/do-not-disrupt: "true"` and use the `gp3` StorageClass (`WaitForFirstConsumer`).
3. **Consolidation timing:** With `consolidateAfter: 5m`, expect ~5–7 minutes from last workload removal to node termination (plus time for `do-not-disrupt` pods to be removed first).
4. **Re-run validation:** To repeat this test:

```bash
cd helm-addons
helmfile -e eks-karpenter-vpa sync
kubectl apply -f examples/sample-stateless.yaml
kubectl apply -f examples/sample-stateful.yaml
kubectl apply -f /path/to/vpa-objects.yaml   # hand-managed VPAs
kubectl apply -f /path/to/load-generator.yaml
```
