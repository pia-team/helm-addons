# Dev Profile Validation Scenario: Karpenter + VPA Tuning

**Cluster:** `eks-karpenter-vpa`  
**Profile:** `dev`  
**Date:** 2026-06-16  
**Tester:** automated + Claude Code  

## Goal

Validate the dev-profile tuning changes:

1. Karpenter `NodePool` consolidation delay is `2h` (`consolidateAfter: 2h`, `consolidationPolicy: WhenEmptyOrUnderutilized`).
2. Scale-up is rapid: a pending pod triggers a new `NodeClaim` and a Ready node quickly.
3. VPA `InPlaceOrRecreate` is enabled and the updater is aggressive (`eviction-tolerance=0.25`, `pod-lifetime-update-threshold=1h`, `min-replicas=1`).
4. VPA resizes pods in-place with **0 restarts**.
5. After deleting the load, the Karpenter node is **not** removed before the 2-hour cooldown expires.
6. After the 2-hour cooldown, the underutilized node is consolidated and removed.
7. A second scale-up confirms nodes still come online rapidly after consolidation.

## Pre-conditions

- `kubectl` points at `eks-karpenter-vpa` in `eu-west-1`.
- Dev NodePool manifest applied (`karpenter/manifests/dev/nodepool.yaml`).
- VPA release synced via `helmfile -e eks-karpenter-vpa -l name=vpa sync`.
- `vpa-demo` namespace exists and is labeled:
  - `goldilocks.fairwinds.com/enabled=true`
  - `goldilocks.fairwinds.com/vpa-update-mode=InPlaceOrRecreate`

## Test resources (all from this repo)

- `examples/sample-stateless.yaml` — single-replica Deployment with CPU spikes.
- `examples/sample-stateful.yaml` — single-replica StatefulSet with gp3 PVC + `do-not-disrupt`.
- `examples/load-generator.yaml` — 3-replica CPU stress Deployment (created below for this test).

## Phases

### Phase 0 — Baseline (T+0)

1. Delete any previous workloads in `vpa-demo`:
   ```bash
   kubectl delete -f examples/sample-stateless.yaml --ignore-not-found
   kubectl delete -f examples/sample-stateful.yaml --ignore-not-found
   kubectl delete deployment load-generator -n vpa-demo --ignore-not-found
   kubectl delete vpa load-generator sample-stateless sample-stateful -n vpa-demo --ignore-not-found
   ```
2. Confirm only the bootstrap node is present:
   ```bash
   kubectl get nodes
   kubectl get nodeclaim
   ```
3. Confirm NodePool settings:
   ```bash
   kubectl get nodepool default -o jsonpath='{.spec.disruption}'
   ```
4. Confirm VPA updater args:
   ```bash
   kubectl get deployment -n vpa vpa-updater -o jsonpath='{.spec.template.spec.containers[0].args}'
   ```

**Pass criteria:**
- Exactly 1 managed/bootstrap node.
- `consolidateAfter: 2h`, `consolidationPolicy: WhenEmptyOrUnderutilized`.
- VPA updater has `--eviction-tolerance=0.25`, `--pod-lifetime-update-threshold=1h`, `--min-replicas=1`, `--feature-gates=InPlaceOrRecreate=true`.

### Phase 1 — Rapid scale-up (T+0 to T+5 min)

1. Create `load-generator` Deployment:
   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: load-generator
     namespace: vpa-demo
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: load-generator
     template:
       metadata:
         labels:
           app: load-generator
       spec:
         containers:
           - name: app
             image: polinux/stress
             resources:
               requests:
                 cpu: 200m
                 memory: 64Mi
               limits:
                 cpu: "1"
                 memory: 256Mi
             command:
               - /bin/sh
               - -c
               - |
                 stress --cpu 1 --timeout 600s
   EOF
   ```
2. Watch for pending pods and time how long until:
   - First `NodeClaim` appears.
   - New node becomes `Ready`.
   - All `load-generator` pods are `Running`.

**Pass criteria:**
- `NodeClaim` created within 60 seconds of first pending pod.
- Node `Ready` within 120 seconds of `NodeClaim` creation.
- All 3 pods `Running` and spread/capable of scheduling (bootstrap + Karpenter node).

### Phase 2 — VPA in-place resize (T+5 min to T+15 min)

1. Apply `sample-stateless`:
   ```bash
   kubectl apply -f examples/sample-stateless.yaml
   ```
2. Wait for VPA `RecommendationProvided=True` and then for the pod request to change.
3. Record:
   - Original pod requests.
   - VPA target recommendation.
   - Updated pod requests.
   - Pod restart count.
   - `vpaInPlaceUpdated` annotation.

**Pass criteria:**
- VPA condition `RecommendationProvided=True`.
- Pod CPU/memory request increased (e.g. from `10m` to `1`).
- Pod restart count remains `0`.
- Pod annotated `vpaInPlaceUpdated: "true"`.

### Phase 3 — Consolidation cooldown (T+15 min to T+2h15m)

1. Delete `load-generator`:
   ```bash
   kubectl delete deployment load-generator -n vpa-demo
   ```
2. Keep `sample-stateless` running on the Karpenter node so the node is not empty but is underutilized.
3. Continuously poll `kubectl get nodes` and `kubectl get nodeclaim`.

**Pass criteria:**
- Karpenter node remains present for at least **2 hours** after deletion.
- No `NodeClaim` deletion event before the 2-hour mark.

### Phase 4 — Consolidation completes (after 2h cooldown)

1. Continue polling until the Karpenter node is removed.
2. Record the exact elapsed time from load deletion to node removal.

**Pass criteria:**
- Node removal occurs **at or after** 2 hours.
- Cluster returns to the single bootstrap node.

### Phase 5 — Second rapid scale-up (after consolidation)

1. Re-apply `load-generator`.
2. Time the second scale-up from pending pod to Ready node and Running pods.

**Pass criteria:**
- New `NodeClaim` appears within 60 seconds.
- Node `Ready` within 120 seconds.
- All 3 pods `Running`.

### Phase 6 — Cleanup

1. Delete all test workloads and orphan VPAs:
   ```bash
   kubectl delete -f examples/sample-stateless.yaml --ignore-not-found
   kubectl delete -f examples/sample-stateful.yaml --ignore-not-found
   kubectl delete deployment load-generator -n vpa-demo --ignore-not-found
   kubectl delete vpa load-generator sample-stateless sample-stateful -n vpa-demo --ignore-not-found
   ```
2. Wait for cluster to return to bootstrap footprint.

## Continuous monitoring

A background script records every 60 seconds:

```bash
kubectl get nodes -o wide
kubectl get nodeclaim
kubectl get pods -n vpa-demo -o wide
kubectl get vpa -n vpa-demo
kubectl top nodes 2>/dev/null || true
kubectl get events -n vpa-demo --sort-by='.lastTimestamp' | tail -20
```

Logs are written to `test-reports/dev-karpenter-vpa-tuning-monitor.log`.

## Reporting

After the test, produce `test-reports/dev-karpenter-vpa-tuning-report.md` containing:

1. Executive summary (PASS/FAIL per phase).
2. Cluster baseline.
3. Timeline with timestamps.
4. Per-phase observations and raw command output excerpts.
5. Consolidation elapsed-time measurement.
6. VPA in-place resize evidence.
7. Deviations, if any.
8. Recommendations.
