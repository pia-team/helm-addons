# HPA + VPA Coexistence Analysis for DNext

**Date:** 2026-06-16  
**Scope:** All DNext deployments using the `orbitant/app` Helm chart and the `gitops-eks-smf-dev-orange` environment.  
**Key files referenced:**

- `helm-charts/orbitant/app/templates/hpa.yaml` — HPA template
- `helm-charts/orbitant/app/values.yaml` — HPA defaults (`hpa:` block at lines 150–163)
- `helm-charts/orbitant/app/templates/deployment.yaml` — Deployment resources block (line 297)
- `gitops-eks-smf-dev-orange/dev/manifests/voltran/account/patches/hpa.yaml` — example patch

---

## 1. Requirements and Concerns

The goal is to run **both Horizontal Pod Autoscaler (HPA) and Vertical Pod Autoscaler (VPA) together** on every DNext service in production, with the following behavior:

1. **HPA is always enabled in production.** It starts each Deployment at the `minReplicas` defined in its HPA.
2. **VPA is allowed to resize CPU and memory** of running pods in-place using `InPlaceOrRecreate`.
3. **VPA must never exceed hard container limits**, e.g.:
   ```yaml
   limits:
     cpu: 2000m
     memory: 2000Mi
   ```
4. **VPA should act first.** It should grow per-pod resources up to its own upper cap before HPA adds more pods.
5. **HPA should add pods only when VPA can no longer help.** If load is still high after VPA hits its upper bound, HPA provisions new pods.
6. **HPA should act slower than VPA** so the two controllers do not fight.
7. **When HPA adds pods**, real CPU/memory usage per pod drops, so VPA will want to lower requests again. The system should not enter a scale-up/scale-down loop.
8. **Desired asymmetric VPA behavior:** grow resource requests quickly when load increases, but decrease them slowly when load drops, to maintain stability.

---

## 2. Current State

### 2.1 HPA template in `orbitant/app`

`helm-charts/orbitant/app/templates/hpa.yaml:1-43` renders an `autoscaling/v2` HPA:

```yaml
{{ if .Values.hpa.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "app.fullname" . }}
  minReplicas: {{ .Values.hpa.minReplicas }}
  maxReplicas: {{ .Values.hpa.maxReplicas }}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: {{ .Values.hpa.averageUtilization }}
  behavior:
    scaleDown:
      stabilizationWindowSeconds: {{ .Values.hpa.scaleDown.stabilizationSeconds }}
      policies:
        - type: Pods
          value: {{ .Values.hpa.scaleDown.valuePods }}
          periodSeconds: {{ .Values.hpa.scaleDown.periodSeconds }}
    scaleUp:
      stabilizationWindowSeconds: {{ .Values.hpa.scaleUp.stabilizationSeconds }}
      policies:
        - type: Pods
          value: {{ .Values.hpa.scaleUp.valuePods }}
          periodSeconds: {{ .Values.hpa.scaleUp.periodSeconds }}
        - type: Percent
          value: {{ .Values.hpa.scaleUp.valuePercentage }}
          periodSeconds: {{ .Values.hpa.scaleUp.periodSeconds }}
      selectPolicy: Max
```

### 2.2 HPA defaults

`helm-charts/orbitant/app/values.yaml:150-163`:

```yaml
hpa:
  enabled: false
  minReplicas: 2
  maxReplicas: 6
  averageUtilization: 50
  scaleDown:
    stabilizationSeconds: 300
    periodSeconds: 300
    valuePods: 1
  scaleUp:
    stabilizationSeconds: 30
    periodSeconds: 15
    valuePods: 2
    valuePercentage: 40
```

### 2.3 HPA usage across DNext dev

There are **93 HPA manifests** in `gitops-eks-smf-dev-orange/dev/manifests`:

- **72** are pinned to `minReplicas: 1, maxReplicas: 1` — effectively disabled for scaling. VPA is safe on these because HPA cannot change replica count.
- **21** use `minReplicas: 2, maxReplicas: 6` with CPU utilization target `averageUtilization: 50`. These are the real scaling workloads.
- **All 93** scale on `cpu` with `type: Utilization`.
- **None** currently use memory as an HPA metric.
- **No VPA manifests or templates** exist in either `gitops-eks-smf-dev-orange` or `helm-charts/orbitant` today.

---

## 3. The Conflict

### 3.1 How CPU-utilization HPA works

HPA v2 with `type: Utilization` computes:

```text
CPU utilization % = actual CPU usage / CPU request
```

For example, if a pod uses `200m` CPU and its request is `100m`:

```text
utilization = 200m / 100m = 200%
```

HPA target is 50%, so it scales **up**.

### 3.2 What happens when VPA changes the CPU request

VPA’s job is to change the CPU/memory **request**. Suppose VPA sees the pod needs more CPU and raises the request from `100m` to `400m`. The pod is still using the same `200m` of real CPU, but now:

```text
utilization = 200m / 400m = 50%
```

HPA now sees exactly the target utilization. If VPA raises the request a bit more, utilization drops **below** 50%, and HPA will want to **scale down** pods.

This is the exact opposite of the desired “VPA first, then HPA.”

### 3.3 The feedback loop

| Step | VPA action | HPA sees | HPA action |
|------|-----------|----------|-----------|
| 1 | Load grows | High utilization | Scale up |
| 2 | VPA raises CPU request | Lower utilization | Scale down |
| 3 | Load concentrated on fewer pods | High utilization | Scale up |
| 4 | VPA raises request again | Lower utilization | Scale down |

The controllers chase each other. HPA scale-up stabilization (`30s`) and VPA pod-lifetime thresholds can dampen this, but they cannot eliminate it because the math is wrong.

### 3.4 Memory-only VPA avoids the conflict

If VPA controls only memory and HPA controls only CPU, they watch different resources and do not interfere. This is a safe pattern, but it does not satisfy the requirement to let VPA resize CPU.

---

## 4. Why the Desired Sequence Cannot Be Achieved with `Utilization`

The requirement is:

> “VPA should act first, increase resources to upper limits, and if still not enough, HPA should add new pods.”

With `Utilization`, this is impossible because **raising the request lowers utilization**. HPA interprets a successful VPA resize as *less* need for pods, not more.

The only way to get “VPA grows first, HPA grows second” is to make HPA react to **absolute real usage**, not to a percentage of the request.

---

## 5. VPA Recommender Limitations

There is **no VPA recommender setting that creates “grow fast, shrink slow” behavior** on a per-workload basis. The available knobs are global or indirect:

| Setting | Scope | Effect | Can it make VPA grow fast / shrink slow? |
|---------|-------|--------|------------------------------------------|
| `--cpu-histogram-decay-half-life` | Global recommender flag | How fast old CPU samples are forgotten | No — affects both directions |
| `--memory-histogram-decay-half-life` | Global recommender flag | How fast old memory samples are forgotten | No — affects both directions |
| `pod-lifetime-update-threshold` | Per-VPA | Minimum pod age before updater resizes it | No — delays all updates |
| `eviction-tolerance` | Per-VPA | Node spare capacity required before evicting | Indirectly makes VPA more conservative |
| `minReplicas` | Per-VPA | Skip workloads below this replica count | Safety guard, not speed control |
| `maxAllowed` | Per-VPA | Upper bound for requests/limits | Yes — enforces the hard cap, but does not influence speed |
| `minAllowed` | Per-VPA | Lower bound for requests/limits | Yes — prevents over-shrink |

The VPA recommender is intentionally stable and histogram-based. It does not support asymmetric recommendation speeds.

---

## 6. Recommended Solution

### 6.1 Core idea

Switch HPA from **CPU utilization** to **absolute average usage** (`type: AverageValue`). VPA then controls per-pod CPU/memory requests freely, and HPA adds pods only when real per-pod load exceeds a fixed threshold.

Example HPA metric:

```yaml
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: AverageValue
        averageValue: "800m"   # scale when real CPU per pod > 800m
```

Now the desired sequence works:

1. Pods start at `minReplicas`.
2. Load grows; real usage per pod rises.
3. VPA raises CPU request in-place up to `maxAllowed` (e.g. `1800m`).
4. If real usage is still above `800m` per pod after VPA hits its cap, HPA adds pods.
5. More pods spread the load; real usage per pod drops below `800m`; HPA may scale down only when load truly falls.

### 6.2 Why `AverageValue` preserves the hard limit intent

With current `Utilization: 50`, the HPA target moves whenever VPA changes the request. With `AverageValue: 800m`, the target is fixed to **actual usage**. The container limit (`2000m`) still protects the pod, and VPA’s `maxAllowed` (`1800m`) prevents VPA from pushing requests close enough to the limit that the pod has no burst room.

### 6.3 VPA configuration for the pattern

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: InPlaceOrRecreate
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        controlledResources:
          - cpu
          - memory
        controlledValues: RequestsAndLimits
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: 1800m          # 200m headroom below 2000m limit
          memory: 1800Mi      # 200Mi headroom below 2000Mi limit
```

Key points:

- `controlledValues: RequestsAndLimits` keeps limits proportional to requests, or sets limits explicitly.
- `maxAllowed` is the safety guard that prevents VPA from exceeding the hard container limits.
- `minAllowed` prevents VPA from shrinking resources so much that the pod becomes unstable.

### 6.4 HPA `AverageValue` targets

The HPA target should be a fraction of the VPA `maxAllowed`. A practical starting point is **50% of `maxAllowed` CPU** and, if memory scaling is enabled, **60–70% of `maxAllowed` memory**.

Example for a service with `limits.cpu: 2000m`, `limits.memory: 2000Mi`, and VPA `maxAllowed` set to 90% of limits:

```yaml
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: AverageValue
        averageValue: "900m"   # ~50% of 1800m maxAllowed
  - type: Resource
    resource:
      name: memory
      target:
        type: AverageValue
        averageValue: "1200Mi"  # ~67% of 1800Mi maxAllowed
behavior:
  scaleUp:
    stabilizationWindowSeconds: 30
    policies:
      - type: Pods
        value: 2
        periodSeconds: 15
  scaleDown:
    stabilizationWindowSeconds: 300
    policies:
      - type: Pods
        value: 1
        periodSeconds: 300
```

### 6.5 Memory scaling caution

Memory behaves differently from CPU:

- Processes rarely release memory back to the OS.
- VPA memory recommendations therefore tend to be sticky (mostly upward).
- A memory-based HPA can cause unnecessary scale-outs if applications cache data.

**Recommendation:** Start with **CPU `AverageValue` + VPA for both CPU and memory**. Add memory to HPA only after observing that VPA memory recommendations are stable and the application releases memory under load.

---

## 7. What Should Change in the Helm Chart

### 7.1 `orbitant/app` HPA template

`helm-charts/orbitant/app/templates/hpa.yaml` should support both `Utilization` (current default, for non-VPA services) and `AverageValue` (for VPA-enabled services).

Proposed values schema:

```yaml
hpa:
  enabled: false
  minReplicas: 2
  maxReplicas: 6
  targetType: Utilization   # or AverageValue
  averageUtilization: 50      # used when targetType == Utilization
  averageValue:              # used when targetType == AverageValue
    cpu: "800m"
    memory: "1200Mi"
  metrics:                   # optional override list
  scaleDown:
    stabilizationSeconds: 300
    periodSeconds: 300
    valuePods: 1
  scaleUp:
    stabilizationSeconds: 30
    periodSeconds: 15
    valuePods: 2
    valuePercentage: 40
```

Template logic:

```yaml
{{- if eq .Values.hpa.targetType "AverageValue" }}
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: AverageValue
        averageValue: {{ .Values.hpa.averageValue.cpu }}
  - type: Resource
    resource:
      name: memory
      target:
        type: AverageValue
        averageValue: {{ .Values.hpa.averageValue.memory }}
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

### 7.2 Add VPA template to `orbitant/app`

Add `helm-charts/orbitant/app/templates/vpa.yaml`:

```yaml
{{ if .Values.vpa.enabled }}
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: {{ include "app.fullname" . }}
  labels:
    app.kubernetes.io/name: {{ include "app.name" . }}
    app.kubernetes.io/family: {{ include "app.family" . }}
    helm.sh/chart: {{ include "app.chart" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "app.fullname" . }}
  updatePolicy:
    updateMode: {{ .Values.vpa.updateMode }}
    minReplicas: {{ .Values.vpa.minReplicas }}
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        controlledResources:
          {{- toYaml .Values.vpa.controlledResources | nindent 10 }}
        controlledValues: {{ .Values.vpa.controlledValues }}
        minAllowed:
          {{- toYaml .Values.vpa.minAllowed | nindent 10 }}
        maxAllowed:
          {{- toYaml .Values.vpa.maxAllowed | nindent 10 }}
{{- end }}
```

Proposed defaults in `values.yaml`:

```yaml
vpa:
  enabled: false
  updateMode: InPlaceOrRecreate
  minReplicas: 1
  controlledResources:
    - cpu
    - memory
  controlledValues: RequestsAndLimits
  minAllowed:
    cpu: 100m
    memory: 128Mi
  maxAllowed:
    cpu: 1800m
    memory: 1800Mi
```

### 7.3 Guard: do not allow `hpa.targetType: Utilization` when `vpa.enabled: true`

In the chart, add a validation guard:

```yaml
{{- if and .Values.vpa.enabled (eq .Values.hpa.targetType "Utilization") }}
{{- fail "HPA targetType must be AverageValue when VPA is enabled" }}
{{- end }}
```

This prevents teams from accidentally creating the conflict.

---

## 8. Per-Service Configuration

Not all DNext services have the same resource profile. The chart defaults should be overrideable per service in `gitops-eks-smf-dev-orange`.

Example for a service with known CPU-heavy load:

```yaml
# gitops-eks-smf-dev-orange/dev/manifests/<service>/patches/vpa.yaml
hpa:
  enabled: true
  targetType: AverageValue
  averageValue:
    cpu: "900m"
    memory: "1200Mi"

vpa:
  enabled: true
  maxAllowed:
    cpu: 1800m
    memory: 1800Mi
```

For the 72 services with `minReplicas: 1, maxReplicas: 1`, VPA can also be enabled safely with `InPlaceOrRecreate` because HPA cannot scale. However, `minReplicas: 1` should still be respected by VPA (`vpa.minReplicas: 1`) so the updater acts on single-replica workloads.

---

## 9. Migration Path

1. **Phase 0 — Chart changes**
   - Add `hpa.targetType` and `hpa.averageValue` to `orbitant/app`.
   - Add the VPA template.
   - Add the guard that rejects `vpa.enabled: true` + `hpa.targetType: Utilization`.

2. **Phase 1 — Dev pilot**
   - Pick 3–5 services with `minReplicas: 2` and real traffic.
   - Set `hpa.targetType: AverageValue` and `vpa.enabled: true`.
   - Observe for 1–2 weeks. Look for:
     - Stable pod counts under steady load.
     - No HPA/VPA thrashing.
     - In-place resize with 0 restarts.

3. **Phase 2 — Dev broad rollout**
   - Enable VPA + `AverageValue` HPA on all dev `minReplicas=2` services.
   - Keep `minReplicas=1` services on VPA only or with `AverageValue` HPA if they later need scaling.

4. **Phase 3 — Test / SIT**
   - Apply the same pattern to higher environments.
   - Tune `averageValue` targets if load patterns differ.

5. **Phase 4 — Production**
   - Roll out service-by-service with a runbook:
     - Disable VPA if thrashing occurs.
     - Switch back to `Utilization` only as a fallback if `AverageValue` proves unstable.

---

## 10. Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| HPA `AverageValue` target is wrong for a service | Make it overridable per service; start at 50% of VPA `maxAllowed` CPU and tune |
| VPA memory recommendations keep growing | Set `maxAllowed`; monitor; use `controlledValues: RequestsAndLimits`; consider memory-only HPA later |
| HPA and VPA still thrash | Increase HPA scale-down stabilization; increase VPA `pod-lifetime-update-threshold`; verify `AverageValue` is used |
| Container limits are exceeded | Enforce `maxAllowed` < container limit in the chart or CI policy |
| `AverageValue` unavailable in metrics-server | Ensure metrics-server is running and serving resource metrics (already required by VPA) |
| Single-replica services cannot benefit from HPA | These already have `minReplicas: 1, maxReplicas: 1`; VPA alone gives them right-sizing |

---

## 11. Open Decisions

Before implementation, the following decisions need to be made:

1. **Should HPA also scale on memory `AverageValue`, or only CPU initially?**
   - Recommendation: start with CPU only; add memory after observing VPA behavior.

2. **Should the 72 `minReplicas: 1` services get VPA too?**
   - Recommendation: yes, with `minReplicas: 1` in VPA so the updater acts on single-replica deployments.

3. **Should the chart default to `AverageValue` once VPA is enabled globally?**
   - Recommendation: yes, but keep `Utilization` as an explicit opt-in for legacy/non-VPA services.

4. **Who owns the per-service `averageValue` tuning?**
   - Recommendation: platform team provides defaults; service owners can patch in their GitOps overlays.

5. **What is the acceptable headroom between VPA `maxAllowed` and container `limits`?**
   - Recommendation: default to 10% headroom (e.g. `maxAllowed: 1800m` for `limits: 2000m`).

---

## 12. Conclusion

Running HPA and VPA together for both CPU and memory is achievable, but **only if HPA is configured with `AverageValue` targets**, not CPU utilization percentages. The current `orbitant/app` HPA template uses `Utilization`, which creates a mathematical conflict with VPA.

The required changes are:

1. Add `AverageValue` support to the HPA template.
2. Add a VPA template with `maxAllowed`, `minAllowed`, and `InPlaceOrRecreate`.
3. Guard against enabling VPA with `Utilization`-based HPA.
4. Roll out service-by-service in dev, then higher environments.

This design satisfies all stated requirements:

- HPA starts at `minReplicas`.
- VPA grows resources in-place up to a safe `maxAllowed` below container limits.
- When real per-pod load exceeds the `AverageValue` threshold, HPA adds pods.
- The two controllers measure different things (absolute usage vs. request size), so they do not fight.
