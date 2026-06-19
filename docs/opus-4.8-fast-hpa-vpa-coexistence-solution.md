# HPA + VPA Coexistence for DNext — Proposed Final Solution

> Companion to `hpa-vpa-coexistence-analysis.md`. The analysis defines the problem,
> the CPU-`Utilization` math conflict, the current DNext state, and a candidate
> architecture. This document **evaluates the Open Decisions (§11) and the Unified-Solution
> research (§12)** and proposes a single, practical, production-ready plan.

---

## 0. TL;DR — The Recommendation in One Page

**Adopt a resource-dimension split as the default, conflict-free model:**

| Dimension | Controller | What it does |
|-----------|-----------|--------------|
| **Replicas** (horizontal) | **HPA on CPU** | Scales pod count on CPU. Default `AverageValue`, fall back to `Utilization` only for legacy/non-VPA services. |
| **Memory** (vertical) | **VPA on memory only** | Right-sizes memory request/limit in place. `controlledResources: [memory]`. |
| **CPU request right-sizing** (vertical) | **VPA off by default; opt-in per service** | Only enabled for the minority of workloads with chronically wrong CPU requests, and only in the `AverageValue` HPA mode. |

This is the **GKE "Multidimensional Pod Autoscaler" pattern reproduced with stock upstream objects** — no custom controller, no feature gate required for the baseline, and it removes the math conflict by construction rather than by careful threshold tuning.

For the subset of services that genuinely need vertical CPU right-sizing, layer on the analysis doc's **`AverageValue`-on-CPU** approach as an explicit, guarded opt-in (Tier 2 below). It is sound, but it keeps two controllers on one dimension and therefore needs the alignment and version guarantees this document specifies.

---

## 1. Why "split by dimension" beats "both controllers on CPU"

The analysis doc's core fix — switch HPA from `Utilization` to `AverageValue` — is correct and necessary, but it solves the *symptom* (the request-relative percentage inverts) while leaving the *structure* intact: VPA still moves the CPU request and HPA still scales on CPU.

```
Analysis doc (Tier 2):     VPA(cpu,mem)  ──┐
                                            ├── both observe CPU usage
                           HPA(cpu)      ──┘   → decoupled by AverageValue,
                                               but still coupled in reality

This proposal (Tier 1):    VPA(mem) ──── memory dimension
                           HPA(cpu) ──── cpu dimension     → orthogonal, cannot conflict
```

With `AverageValue`, HPA reads *absolute* per-pod CPU (e.g. `900m`), so a VPA CPU-request change no longer flips the signal. Good. But two failure modes remain:

1. **Limit-driven throttling feedback.** If VPA raises the CPU *limit* (it does, with `controlledValues: RequestsAndLimits`), a pod can absorb more CPU per replica before HPA's absolute threshold trips — shifting the effective scale-out point in ways that are hard to reason about across 93 services.
2. **In-place resize churn under load.** Exactly when load is climbing (HPA wants to add pods) VPA is also rewriting CPU on the running pods. Even in-place, this competes for the same scaling event window.

Splitting dimensions removes both. **Memory is the dimension VPA is genuinely good at** (slow-moving, per-pod, no horizontal equivalent — you cannot "add replicas" to fix a memory-hungry process). **CPU is the dimension HPA is genuinely good at** (elastic, burst-y, horizontally shardable). Assigning each controller the dimension it suits is why GKE productized exactly this split.

> `★ Why this matters: HPA and VPA were never designed to share a metric. The upstream
> VPA README explicitly warns against running both on CPU or memory simultaneously. The
> AverageValue trick is a community-known escape hatch, not a blessing to share the
> dimension freely. Dimension-split needs no such warning.`

---

## 2. Evaluation of the Open Decisions (§11)

Each decision is resolved with a concrete, defaulted answer plus rationale. "Defaulted" means: this is the chart/platform default; service owners may override in their GitOps overlay.

### Decision 1 — Memory scaling scope (does HPA target memory too?)

**Resolution: No. HPA scales on CPU only. Memory is VPA's exclusive dimension.**

The doc's instinct ("start CPU-only, add memory later") is right, but in the dimension-split model the question disappears: memory horizontal scaling is almost always the wrong tool (a leaking or heap-bound process is not fixed by more replicas, and per-replica memory is non-additive for caches). Let VPA own memory vertically. This also sidesteps the genuinely nasty *two* metrics on HPA (`max` of CPU and memory targets fighting each other).

### Decision 2 — Single-replica workloads (the 72 `minReplicas:1,maxReplicas:1` services)

**Resolution: Enable VPA on all 72, in `InPlaceOrRecreate` mode where the cluster supports it, `Initial` mode where it does not. Keep HPA effectively pinned (`min=max=1`) — or remove HPA from them entirely.**

These 72 services are the **highest-value, lowest-risk VPA target** in the whole estate: they cannot scale horizontally, so right-sizing requests vertically is the *only* efficiency lever available, and there is no HPA to conflict with. This is where VPA pays for itself first.

- Respect `minReplicas: 1` in the VPA (`updatePolicy.minReplicas: 1`) so VPA will still act on a single-replica deployment.
- Without in-place resize available, `Auto`/`Recreate` would evict the lone pod (downtime). Use `Initial` (set requests only at pod creation) as the safe floor, or `InPlaceOrRecreate` once on K8s ≥1.33 (see Decision 6).
- Pair with a `PodDisruptionBudget` only if you move beyond a single replica.

### Decision 3 — Chart defaults (`AverageValue` vs `Utilization` as default)

**Resolution: `Utilization` stays the chart default for backward compatibility; `AverageValue` is required (and validated) whenever VPA also controls CPU on that service.**

In the dimension-split model VPA does **not** touch CPU, so `Utilization` is perfectly safe and remains the simplest, most portable HPA mode — keep it as the default. Flip the default to `AverageValue` only for a service the day it opts into Tier-2 CPU right-sizing. This avoids a fleet-wide behavioral change and a risky big-bang migration across the 21 scaling services.

Implement as a `targetType` switch (see §4), with a hard validation guard: `vpa.cpu.enabled && hpa.targetType == Utilization` ⇒ **reject** (this is the exact misconfiguration that causes oscillation).

### Decision 4 — Per-service ownership of thresholds

**Resolution: Platform team owns the chart defaults and the *formulas*; service owners own the *numbers* via GitOps overlays.**

Concretely, the platform team ships and maintains:
- the relationship rules (`maxAllowed = 0.9 × limit`, `hpa.averageValue.cpu = 0.5 × maxAllowed.cpu`),
- the validation guard, and
- sane defaults derived from the chart baseline.

Service owners patch `vpa.maxAllowed`, `hpa.averageValue`, and `hpa.maxReplicas` in their overlay when their workload profile justifies it. This matches the existing base/overlay GitOps model and keeps the platform team out of per-service tuning loops. Encode the formulas as comments and as the validation guard so overlays that break the relationship are rejected in CI, not at runtime.

### Decision 5 — Safety headroom between VPA upper bound and container limit

**Resolution: Default 10% headroom on memory (`maxAllowed = 0.9 × limit`); for CPU, headroom is less critical because CPU is compressible.**

- **Memory** is incompressible — exceeding the limit = OOMKill. The 10% gap (`maxAllowed.memory: 1800Mi` vs `limit: 2000Mi`) is the right *floor*; consider 15–20% for latency-sensitive services with spiky allocation.
- **CPU** is compressible — hitting the limit causes throttling, not death. The 10% gap is fine but not safety-critical. In dimension-split, VPA doesn't move CPU at all, so the relevant CPU ceiling is purely the static `limits.cpu: 2000m`.
- **Critical addition the doc misses:** also constrain VPA from the **bottom**. Set `minAllowed.memory` at or above the application's real idle floor (the `500Mi` baseline is a reasonable start) so VPA doesn't shrink a JVM/Node heap below its safe minimum during quiet periods and then OOM on the next request burst.

### Decision 6 (NEW — the analysis doc omits it) — In-place resize availability

**Resolution: Make `updateMode` cluster-capability-driven, not hardcoded.**

The proposed `updateMode: InPlaceOrRecreate` requires **VPA ≥ 1.4 *and* Kubernetes ≥ 1.33 with the `InPlacePodVerticalScaling` feature (Beta, on by default in 1.33)**. On EKS this is a concrete version gate. If the cluster is below 1.33, VPA silently degrades to evict-and-recreate, which:
- breaks the stated "resize in place" requirement, and
- causes rolling pod disruption — unacceptable for the 72 single-replica services.

Therefore:
- Add a chart value `vpa.updateMode` with documented allowed values and a **default of `Initial`** (safest: never evicts running pods; only sets requests at creation).
- Promote to `InPlaceOrRecreate` per-environment once the EKS control plane and node pools are confirmed on ≥1.33 and the VPA admission/updater images are ≥1.4.
- Gate the cluster-wide rollout of `Auto`/`InPlaceOrRecreate` behind a `PodDisruptionBudget` for every multi-replica service.

---

## 3. Evaluation of §12 — "Can a Better Unified Solution Be Built?"

**Short answer: A unified *controller* is not worth building. A unified *behavior* already exists and should be adopted.**

| Option | Verdict | Reasoning |
|--------|---------|-----------|
| **Custom MDPA controller** (write your own multi-dimensional loop) | **Reject** | High engineering + operational cost, a new critical-path controller to maintain, and it duplicates work the autoscaling SIG and GKE have already done. DNext gains nothing a config split doesn't give. |
| **Upstream MDPA API** | **Not available** | The doc is correct: as of 2026 there is no GA upstream multidimensional autoscaler API/controller. Watch the autoscaling SIG, but do not block on it. |
| **GKE Multidimensional Autoscaling** (managed) | **Not applicable** | DNext runs on **EKS**, not GKE. But note *what GKE actually does*: HPA on CPU + VPA on memory. That is the dimension-split — reproducible on EKS with two stock objects. |
| **HPA `AverageValue` + VPA on CPU&memory** (the analysis doc's plan) | **Accept as Tier-2 opt-in** | Valid approximation of unified behavior using upstream components, exactly as the doc argues. Keep it for workloads needing vertical CPU right-sizing, with the alignment + version guards below. |
| **Dimension split: HPA-CPU + VPA-memory** (this proposal's Tier 1) | **Accept as default** | The most practical "unified solution available today." Conflict-free by construction, no custom code, no feature gate for the baseline. |

**Conclusion for §12:** The best unified solution that can be *built* today is not a new controller — it is the disciplined composition of the two existing controllers along orthogonal dimensions, with the `AverageValue` shared-CPU mode as a guarded exception. Reserve real engineering effort for *observability* (so you can see when VPA and HPA disagree) rather than for a bespoke controller.

---

## 4. Concrete Implementation

### 4.1 Tier 1 (default) — HPA on CPU, VPA on memory

`values.yaml` additions:

```yaml
hpa:
  enabled: true
  targetType: Utilization        # default; AverageValue only when CPU is VPA-controlled
  minReplicas: 2
  maxReplicas: 6
  averageUtilization: 50         # used when targetType: Utilization
  averageValue:                  # used when targetType: AverageValue
    cpu: "900m"
  scaleDown:
    stabilizationSeconds: 300    # "grow fast, shrink slow" lives HERE, not in VPA

vpa:
  enabled: true
  updateMode: Initial            # Initial | InPlaceOrRecreate | Auto | Off (see Decision 6)
  minReplicas: 1
  controlledResources: [memory]  # Tier 1: memory only
  minAllowed:
    memory: 500Mi
  maxAllowed:
    memory: 1800Mi               # 0.9 × limits.memory (2000Mi)
```

Generated VPA (memory-only):

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata: { name: <svc> }
spec:
  targetRef: { apiVersion: apps/v1, kind: Deployment, name: <svc> }
  updatePolicy:
    updateMode: Initial
    minReplicas: 1
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        controlledResources: [memory]
        controlledValues: RequestsAndLimits
        minAllowed: { memory: 500Mi }
        maxAllowed: { memory: 1800Mi }
```

### 4.2 Tier 2 (opt-in) — VPA also right-sizes CPU

Only for services flagged by an owner; flips two things and triggers the guard:

```yaml
hpa:
  targetType: AverageValue       # REQUIRED in Tier 2 — Utilization is rejected
  averageValue:
    cpu: "900m"                  # 0.5 × vpa.maxAllowed.cpu
vpa:
  controlledResources: [cpu, memory]
  minAllowed: { cpu: 20m, memory: 500Mi }
  maxAllowed: { cpu: 1800m, memory: 1800Mi }   # 0.9 × limits
```

### 4.3 The validation guard (the most important 4 lines in the chart)

```yaml
{{- if and .Values.vpa.enabled (has "cpu" .Values.vpa.controlledResources) (eq .Values.hpa.targetType "Utilization") }}
{{- fail "VPA controls CPU while HPA uses targetType=Utilization — this oscillates. Set hpa.targetType=AverageValue or remove cpu from vpa.controlledResources." }}
{{- end }}
```

### 4.4 Where "grow fast, shrink slow" actually comes from

The doc correctly notes VPA has no asymmetric per-workload knob (the histogram decay half-lives are global and symmetric). In this design:
- **Grow fast** = HPA scale-up (default, fast) + VPA in-place memory bumps.
- **Shrink slow** = HPA `scaleDown.stabilizationSeconds: 300` + VPA's naturally conservative downward recommendations.

Do **not** try to make VPA asymmetric. Own asymmetry at the HPA layer.

---

## 5. Rollout Plan

1. **Phase 0 — Observability first.** Deploy VPA recommender in `updateMode: Off` (recommendation-only) across all 93 services. Collect 1–2 weeks of `target`/`lowerBound`/`upperBound` recommendations vs current static requests. No behavior change, full data.
2. **Phase 1 — The 72 single-replica services.** Enable Tier-1 memory VPA in `Initial` mode (no eviction risk). Highest ROI, zero HPA conflict. Validate request right-sizing against Phase-0 data.
3. **Phase 2 — The 21 scaling services.** Keep HPA `Utilization` on CPU; add Tier-1 memory VPA. Confirm no replica-count regression.
4. **Phase 3 — Cluster capability upgrade.** Confirm EKS ≥1.33 + VPA ≥1.4, then promote `updateMode` to `InPlaceOrRecreate` where in-place memory resize is wanted. Add PDBs.
5. **Phase 4 — Tier-2 opt-ins.** For the few services with chronically mis-sized CPU requests (identified from Phase-0 data), flip to `AverageValue` + `controlledResources:[cpu,memory]`, one service at a time, watching for oscillation.

---

## 6. Summary Table — Decisions Resolved

| # | Open Decision | Resolution |
|---|---------------|------------|
| 1 | HPA target memory? | **No** — CPU only; memory is VPA's. |
| 2 | VPA on 72 single-replica svcs? | **Yes** — highest ROI, `Initial`→`InPlaceOrRecreate`, respect `minReplicas:1`. |
| 3 | `AverageValue` as default? | **No** — `Utilization` default; `AverageValue` required only for Tier-2 CPU-VPA services. |
| 4 | Threshold ownership? | Platform owns formulas + guard; owners patch numbers in overlays. |
| 5 | Headroom? | **10%** memory floor (`0.9×limit`); add a `minAllowed` floor; CPU headroom non-critical (compressible). |
| 6 | (new) In-place availability? | `updateMode` capability-driven; default `Initial`; promote to `InPlaceOrRecreate` only on K8s≥1.33 + VPA≥1.4. |
| §12 | Build unified controller? | **No** — adopt dimension-split (GKE-MDPA behavior, stock objects); keep `AverageValue` shared-CPU as guarded opt-in. |
```