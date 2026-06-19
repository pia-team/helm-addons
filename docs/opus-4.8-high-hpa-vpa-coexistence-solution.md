# HPA + VPA Coexistence for DNext — Final Practical Solution

**Version:** 1.0
**Date:** 2026-06-19
**Status:** Recommended for implementation
**Companion to:** `hpa-vpa-coexistence-analysis.md`

This document re-evaluates the Recommended Solution (§6), resolves the Open Decisions (§11), and judges the unified-solution research (§12) of the analysis. It then states a single, production-ready plan grounded in the **actual DNext cluster state** (EKS `eks-karpenter-vpa`, Kubernetes `v1.35.5`, VPA `1.4` with `InPlaceOrRecreate` validated, Goldilocks `v4.13.0`, Karpenter `1.5.0`).

---

## 0. TL;DR

Keep the analysis doc's core architecture — it is correct and it is the only one of the three candidate designs that actually satisfies the stated requirement that **VPA resizes CPU and acts first**:

```
HPA  →  CPU only, type: AverageValue  →  replica count
VPA  →  CPU + memory, RequestsOnly    →  per-pod requests (grows first)
Deployment → static CPU/memory limits (platform policy, never moved by VPA)
Guard → reject  vpa.controls(cpu) + hpa.targetType=Utilization
```

Three refinements over the analysis doc, each justified below:

1. **`controlledValues: RequestsOnly`**, not `RequestsAndLimits`. The requirement says limits are hard and static; let VPA move only the scheduling signal (requests) and leave limits as the fixed safety ceiling.
2. **`updateMode: InPlaceOrRecreate` is safe to default to** on this estate — it is already validated on K8s 1.35 with 0 restarts. No need for the conservative `Initial` fallback. Enforce it via a **chart-rendered VPA CR**, because Goldilocks v4.13.0 corrupts the update-mode label.
3. **Asymmetry ("grow fast, shrink slow") lives in HPA `scaleDown.stabilizationWindowSeconds`, not VPA.** §5 of the analysis already proved VPA has no per-workload asymmetric knob; stop trying to get it there.

**On the headline question — is `AverageValue` fine as the chart default even without VPA?** No. Keep `Utilization` as the default; switch a service to `AverageValue` only when VPA controls its CPU. It is *safe* without VPA but it is *worse as a default* (it cannot be a single portable number across 93 differently-sized services, and it goes stale whenever requests change). Full reasoning in §4.

---

## 1. Re-evaluation of the Recommended Solution (§6)

### 1.1 What holds — and why this design, not the dimension-split alternative

The analysis is right on the central point: with `type: Utilization`, raising the CPU request lowers utilization, so HPA reads a successful VPA resize as *less* need for pods. Switching HPA to `AverageValue` (absolute per-pod usage) is the only way to make "VPA grows first, HPA scales out second" actually work. This is sound and stands.

A tempting alternative is the **GKE-style dimension split**: HPA on CPU, VPA on **memory only**. It is genuinely conflict-free by construction. But it must be rejected as the *primary* design here for one reason: **it abandons requirement #4** — "VPA is allowed to resize CPU … grow per-pod requests from the static baseline up to `maxAllowed` before HPA adds more pods." The dimension split deliberately never lets VPA touch CPU, so it does not deliver the behavior DNext asked for. It is a fine *fallback* for any service that proves unstable under shared-CPU mode (see §6.4), but it is not the answer to the requirement as written.

### 1.2 What changes — RequestsOnly over RequestsAndLimits

The analysis uses `controlledValues: RequestsAndLimits`. Reconsider against requirement #3, which fixes hard limits at `cpu: 2000m, memory: 2000Mi` and treats them as a safety ceiling VPA must never exceed.

`RequestsOnly` is the better fit:

- **Requests are scheduling policy; limits are platform policy.** Let VPA move what it is good at (the request, which drives bin-packing and the HPA `AverageValue` math) and leave the limit as a stable, human-owned ceiling.
- **The hard-limit guarantee becomes structural, not arithmetic.** With limits frozen at `2000m`/`2000Mi` and `maxAllowed` at `1800m`/`1800Mi`, a pod always retains ≥10% burst headroom between request and limit, by construction. With `RequestsAndLimits`, VPA scales the limit up too, so the headroom guarantee depends on VPA's proportional-scaling behaving exactly as expected across all 93 services — more surface area for surprises.
- **CPU is compressible (throttle, not death); memory is incompressible (OOMKill).** Keeping the memory *limit* fixed and well above the `maxAllowed` request is the cleanest OOM protection.

### 1.3 What is confirmed by the real cluster

`updateMode: InPlaceOrRecreate` is not a risk to be hedged on this estate — the tuning report validates it on `v1.35.5` with **0 pod restarts**, `eviction-tolerance=0.25`, and `pod-lifetime-update-threshold=1h`. So we default to it directly. The only practical wrinkle is operational, not architectural: **Goldilocks v4.13.0 lowercases the `goldilocks.fairwinds.com/vpa-update-mode` label** (`InPlaceOrRecreate` → `Inplaceorrecreate`), so it cannot be trusted to set the mode. Render the VPA object from the `orbitant/app` chart and keep Goldilocks for the recommendation dashboard only.

---

## 2. Resolution of the Open Decisions (§11)

| # | Open Decision | Resolution | Why |
|---|---------------|------------|-----|
| 1 | HPA on memory too, or CPU only? | **CPU only.** Memory is VPA's exclusive dimension. | Memory is cache-sticky and rarely released; a memory HPA causes spurious scale-outs, and adding replicas does not fix a heap-bound process. Two metrics on one HPA also fight via `selectPolicy`. |
| 2 | VPA on the 72 `min=max=1` services? | **Yes — highest-value, lowest-risk target.** Enable VPA (`InPlaceOrRecreate`, `minReplicas: 1`); HPA stays pinned and cannot conflict. | These cannot scale horizontally, so vertical right-sizing is the *only* efficiency lever, and there is no HPA to oscillate against. This is where VPA pays for itself first. |
| 3 | Default the chart to `AverageValue` once VPA is enabled? | **No.** `Utilization` stays the chart default; `AverageValue` is required (and validated) *only* when VPA controls that service's CPU. | See §4. `AverageValue` cannot be one portable default across differently-sized services and goes stale when requests change. Flip per-service at opt-in, avoiding a fleet-wide big-bang. |
| 4 | Who owns per-service `averageValue` tuning? | **Platform owns the formulas + the guard; service owners own the numbers** via GitOps overlays. | Platform ships `maxAllowed = 0.9 × limit` and `averageValue.cpu = 0.5 × maxAllowed.cpu` as defaults/comments and enforces them in the guard; owners patch their overlay. Matches the existing base/overlay model. |
| 5 | Headroom between `maxAllowed` and limit? | **10% on memory (`0.9 × limit`)**, and also set a **`minAllowed` floor**. CPU headroom is non-critical (compressible). | Memory over-limit = OOMKill, so the gap is a hard floor (consider 15–20% for spiky latency-sensitive services). A `minAllowed` floor stops VPA shrinking a JVM/Node heap below its safe idle size and OOMing on the next burst. |
| 6 | **(added)** In-place resize availability | **`InPlaceOrRecreate` by default** on this estate; expose `updateMode` as a chart value for portability. | The analysis omits the version gate. It is already cleared here (K8s ≥1.33 / 1.35.5, VPA ≥1.4, feature gate on, 0-restart resize validated). Only fall back to `Initial` on a cluster below that bar. |

A note on Decision 5's `minAllowed`: the chart default should match the deployment request floor (`cpu: 20m, memory: 500Mi`) for app pods, but the existing hand-managed prod CR uses a higher floor (`cpu: 50m, memory: 128Mi`) and dev a lower one (`cpu: 10m, memory: 32Mi`). Keep `minAllowed` profile-overridable rather than a single global constant.

---

## 3. Evaluation of §12 — Can a better unified solution be built?

**Verdict: do not build a controller; adopt the unified *behavior* with stock objects.** The analysis reaches the right conclusion; this confirms it and sharpens the cost argument.

| Option | Verdict | Reasoning |
|--------|---------|-----------|
| Custom in-house MDPA controller | **Reject** | A new critical-path controller needing cluster-wide state, a cost model, and safety guards. High build + operational cost for behavior a config split already delivers. Not justified at DNext's scale. |
| Upstream MDPA API | **Not available (2026)** | Still research / SIG discussion, no GA. Watch it; do not block on it. |
| GKE Multidimensional Autoscaler | **Not applicable (EKS, not GKE)** | But note *what it actually does* under the hood: HPA-on-CPU + VPA-on-memory. That informs our fallback (§6.4), not the default. |
| HPA `AverageValue` + VPA(cpu,mem) | **Accept — this is the plan** | The closest production-safe approximation of unified behavior using supported components, exactly as §12.4 argues. |

The single highest-leverage move toward MDPA-like behavior is the one already in the plan: **switch HPA to `AverageValue`.** Everything else is tuning. Spend real engineering effort on **observability** — being able to see when HPA and VPA disagree — not on a bespoke controller.

---

## 4. The headline question: Is `AverageValue` safe as a default *without* VPA?

Short answer: **safe, but not advisable as the default. Keep `Utilization` as the chart default and switch to `AverageValue` only when VPA controls CPU on that service.**

### 4.1 Why it is *safe*

For a pod with a **static** CPU request, the two HPA modes are mathematically equivalent:

```
Utilization 50% with request 100m   ≡   AverageValue 50m
(scale when usage / request > 50%)       (scale when usage > 50m)
```

Without VPA the request never moves, so `AverageValue` scales at exactly the same point as `Utilization`. Nothing breaks. A team that wanted one consistent HPA mode everywhere *could* run `AverageValue` fleet-wide and it would function.

### 4.2 Why it is a *worse default*

Three concrete drawbacks when there is no VPA to justify it:

1. **It cannot be a single portable number.** `Utilization: 50` is one value that fits all 93 services regardless of size — a 200m service and a 2000m service both scale at "50% of their own request." `AverageValue` is an absolute figure (`900m`) that is correct for one resource profile and wrong for every other. As a global default it forces per-service tuning that `Utilization` does not.
2. **It goes stale.** With `Utilization`, if an owner changes the CPU request the absolute scale-out point moves with it automatically and proportionally. With `AverageValue`, the target is decoupled from the request, so any request/limit change silently leaves a stale threshold that must be re-tuned by hand. That decoupling is the whole *point* when VPA is moving the request — and a pure liability when nothing is.
3. **No upside without VPA.** The only reason to ignore the request is that something else (VPA) is rewriting it. With static requests, the request *is* the meaningful sizing signal, and `Utilization`'s request-relative behavior is exactly what you want.

### 4.3 Practical rule

```
hpa.targetType: Utilization   ← default for every service (VPA absent, or VPA memory-only)
hpa.targetType: AverageValue  ← required the moment VPA controls that service's CPU
                                (and enforced by the validation guard)
```

So: do **not** flip the chart-wide default to `AverageValue`. It is a per-service flag that travels with "VPA controls CPU here," not a global standard. This also keeps the 72 single-replica and the 21 CPU-`Utilization` scaling services on their current, well-understood mode until they explicitly opt in.

---

## 5. Concrete configuration

### 5.1 `orbitant/app` HPA — `targetType` switch

```yaml
hpa:
  enabled: true
  targetType: Utilization        # DEFAULT. Set to AverageValue only when VPA controls CPU.
  minReplicas: 2
  maxReplicas: 6
  averageUtilization: 50          # used when targetType == Utilization
  averageValue:                   # used when targetType == AverageValue
    cpu: "900m"                   # 0.5 × vpa.maxAllowed.cpu (1800m)
  scaleUp:
    stabilizationSeconds: 30      # fast: "grow fast"
    periodSeconds: 15
    valuePods: 2
    valuePercentage: 40
  scaleDown:
    stabilizationSeconds: 300     # slow: "shrink slow" lives HERE, not in VPA
    periodSeconds: 300
    valuePods: 1
```

```yaml
{{- if eq .Values.hpa.targetType "AverageValue" }}
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: AverageValue
        averageValue: {{ .Values.hpa.averageValue.cpu }}
{{- else }}
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: {{ .Values.hpa.averageUtilization }}
{{- end }}
```

Note: HPA scales on **CPU only** in both modes (Decision 1). Memory is never an HPA metric.

### 5.2 `orbitant/app` VPA — rendered by the chart (not left to Goldilocks)

```yaml
vpa:
  enabled: false                 # opt-in per service
  updateMode: InPlaceOrRecreate  # validated on this estate; Initial only on clusters < K8s 1.33
  minReplicas: 1                 # 1 for single-replica dev; 2 for prod multi-replica
  controlledResources: [cpu, memory]
  controlledValues: RequestsOnly # limits stay static (platform policy)
  minAllowed:
    cpu: 20m                     # matches deployment request floor (profile-overridable)
    memory: 500Mi
  maxAllowed:
    cpu: 1800m                   # 0.9 × limits.cpu (2000m)
    memory: 1800Mi               # 0.9 × limits.memory (2000Mi)
```

Generated object:

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: {{ include "app.fullname" . }}
spec:
  targetRef: { apiVersion: apps/v1, kind: Deployment, name: {{ include "app.fullname" . }} }
  updatePolicy:
    updateMode: {{ .Values.vpa.updateMode }}
    minReplicas: {{ .Values.vpa.minReplicas }}
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        controlledResources: [cpu, memory]
        controlledValues: RequestsOnly
        minAllowed: { cpu: 20m, memory: 500Mi }
        maxAllowed: { cpu: 1800m, memory: 1800Mi }
```

Render this from the chart so the enforced `updateMode` is correct regardless of the Goldilocks label bug; keep Goldilocks for the recommendation dashboard.

### 5.3 The validation guard — the most important lines in the chart

```yaml
{{- if and .Values.vpa.enabled (has "cpu" .Values.vpa.controlledResources) (eq .Values.hpa.targetType "Utilization") }}
{{- fail "VPA controls CPU while HPA targetType=Utilization — this oscillates. Set hpa.targetType=AverageValue or remove cpu from vpa.controlledResources." }}
{{- end }}
```

Scoped to "VPA controls **cpu**" (not merely "VPA enabled"), so a memory-only VPA can safely coexist with `Utilization` HPA.

### 5.4 Where the asymmetry comes from

§5 of the analysis proved VPA has no per-workload "grow fast / shrink slow" knob (histogram decay is global and symmetric). Own asymmetry at the HPA layer instead:

- **Grow fast** = VPA in-place request bumps + HPA fast scale-up (`stabilizationSeconds: 30`).
- **Shrink slow** = HPA `scaleDown.stabilizationSeconds: 300` + VPA's naturally conservative downward recommendations (helped by `pod-lifetime-update-threshold=1h`, `eviction-tolerance=0.25`).

---

## 6. Rollout plan (grounded in the real cluster)

1. **Phase 0 — Observe.** Run VPA in recommendation-only mode (`updateMode: Off` via Goldilocks dashboards) across all 93 services for 1–2 weeks. Compare `target` / `lowerBound` / `upperBound` against current static requests. Zero behavior change, full data, and it identifies which services have chronically mis-sized requests.
2. **Phase 1 — The 72 single-replica services.** Enable VPA(cpu, mem) in `InPlaceOrRecreate`, `minReplicas: 1`. HPA stays pinned, so no conflict. Highest ROI, validate against Phase-0 data.
3. **Phase 2 — The 21 scaling services.** For each, flip `hpa.targetType: AverageValue`, set `averageValue.cpu = 0.5 × maxAllowed.cpu`, enable VPA(cpu, mem). The guard enforces the pairing. One service at a time; watch replica count for oscillation for 1–2 weeks each.
4. **Phase 3 — Higher environments (test/SIT → prod).** Promote the validated pattern. Use the prod VPA profile (`minReplicas: 2`, higher `minAllowed`), keep the conservative updater settings already in place. Add a `PodDisruptionBudget` to every multi-replica service before enabling eviction-capable modes.
5. **Fallback per service.** If any service oscillates under shared-CPU mode despite `AverageValue`, demote it to the **dimension split** (VPA memory-only + HPA-CPU `Utilization`). It loses vertical CPU right-sizing for that one service but is conflict-free by construction.

---

## 7. Summary — decisions resolved

| # | Decision | Resolution |
|---|----------|------------|
| 1 | HPA on memory? | **No** — CPU only; memory is VPA's. |
| 2 | VPA on 72 single-replica services? | **Yes** — highest ROI, `InPlaceOrRecreate`, `minReplicas: 1`. |
| 3 | `AverageValue` as chart default? | **No** — `Utilization` default; `AverageValue` only when VPA controls CPU. |
| 4 | Threshold ownership? | Platform owns formulas + guard; owners patch numbers in overlays. |
| 5 | Headroom? | **10%** memory floor (`0.9 × limit`) + a `minAllowed` floor; CPU non-critical. |
| 6 | In-place availability? | **`InPlaceOrRecreate` default** (validated on K8s 1.35 / VPA 1.4); `Initial` only below the version gate. |
| — | `controlledValues`? | **`RequestsOnly`** — limits stay static platform policy. |
| §12 | Build a unified controller? | **No** — adopt unified *behavior* with stock HPA `AverageValue` + VPA; invest in observability. |
| Q | `AverageValue` safe without VPA? | **Safe but not advisable as default** — keep `Utilization`; it is portable and self-adjusting, `AverageValue` is not. |

**Bottom line:** The analysis doc's architecture is correct and is the only candidate that honors the "VPA resizes CPU and acts first" requirement. Adopt it with three refinements — `RequestsOnly`, default `InPlaceOrRecreate` (this estate is already on K8s 1.35), and HPA-layer asymmetry — keep `Utilization` as the chart default, and turn on `AverageValue` per service exactly when (and only when) VPA takes over that service's CPU.
