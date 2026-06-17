# HPA + VPA Coexistence Solution for DNext

**Version:** 1.0
**Date:** 2026-06-17
**Status:** Approved Architecture Recommendation

---

# 1. Purpose

This document defines the recommended production architecture for running Horizontal Pod Autoscaler (HPA) and Vertical Pod Autoscaler (VPA) together across DNext workloads.

The solution must satisfy the following goals:

* HPA remains enabled for all scalable production services.
* VPA automatically right-sizes CPU and memory requests.
* HPA and VPA must not create scaling feedback loops.
* Vertical scaling should be preferred before horizontal scaling whenever possible.
* Resource requests must remain within defined safety boundaries.
* The solution must be implementable using standard Kubernetes components.
* No custom autoscaler implementation should be required.

---

# 2. Problem Statement

Traditional HPA configuration uses:

```yaml
target:
  type: Utilization
```

CPU utilization is calculated as:

```text
CPU Utilization = Actual CPU Usage / CPU Request
```

VPA changes CPU requests.

Therefore:

* VPA increases CPU request
* HPA sees lower utilization
* HPA scales down
* Load increases again
* HPA scales up

This creates an inherent mathematical conflict.

As a result:

```text
HPA(Utilization) + VPA(CPU)
```

is not a production-safe architecture.

---

# 3. Approved Architecture

The approved DNext architecture is:

```text
                +----------------+
                |      HPA       |
                | CPU AverageVal |
                +--------+-------+
                         |
                         v
                    Replica Count

                         +

                +----------------+
                |      VPA       |
                | CPU Requests   |
                | Memory Requests|
                +--------+-------+
                         |
                         v
                   Pod Resources
```

Responsibilities:

| Component  | Responsibility  |
| ---------- | --------------- |
| HPA        | Pod count       |
| VPA        | CPU requests    |
| VPA        | Memory requests |
| Deployment | CPU limits      |
| Deployment | Memory limits   |

---

# 4. Final Design Decisions

## Decision 1

HPA SHALL use:

```yaml
type: AverageValue
```

when VPA is enabled.

HPA SHALL NOT use:

```yaml
type: Utilization
```

together with VPA.

---

## Decision 2

HPA SHALL scale on CPU only.

Approved:

```yaml
metrics:
- resource:
    name: cpu
```

Not approved:

```yaml
metrics:
- resource:
    name: memory
```

Reason:

* Memory usage is often cache-driven.
* Memory rarely decreases quickly.
* Memory-based HPA frequently causes unnecessary scale-outs.

Memory scaling is delegated entirely to VPA.

---

## Decision 3

VPA SHALL control:

```yaml
cpu
memory
```

requests.

VPA SHALL NOT control limits.

Approved:

```yaml
controlledValues: RequestsOnly
```

Not approved:

```yaml
controlledValues: RequestsAndLimits
```

Reason:

* Requests are scheduling policy.
* Limits are platform policy.
* Limits should remain stable and predictable.

---

## Decision 4

Container limits remain static.

Example:

```yaml
resources:
  requests:
    cpu: 20m
    memory: 500Mi

  limits:
    cpu: 2000m
    memory: 2000Mi
```

Limits remain owned by service configuration and platform standards.

---

# 5. VPA Configuration

Default VPA configuration:

```yaml
vpa:
  enabled: true

  updateMode: InPlaceOrRecreate

  controlledResources:
    - cpu
    - memory

  controlledValues: RequestsOnly

  minAllowed:
    cpu: 20m
    memory: 500Mi

  maxAllowed:
    cpu: 1800m
    memory: 1800Mi
```

---

# 6. Resource Boundaries

The following rule applies:

```text
VPA maxAllowed = 90% of container limit
```

Example:

| Limit | VPA maxAllowed |
| ----- | -------------- |
| 1000m | 900m           |
| 2000m | 1800m          |
| 4000m | 3600m          |

Memory follows the same rule.

This preserves burst headroom and prevents VPA from consuming the full container limit.

---

# 7. HPA Target Calculation

The HPA target SHALL NOT be hardcoded globally.

Instead:

```text
HPA CPU Target
=
50% of VPA maxAllowed CPU
```

Examples:

| VPA maxAllowed | HPA Target |
| -------------- | ---------- |
| 500m           | 250m       |
| 1000m          | 500m       |
| 1800m          | 900m       |
| 3600m          | 1800m      |

This creates a consistent scaling model across all services.

---

# 8. HPA Configuration

Example:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler

spec:

  minReplicas: 2
  maxReplicas: 6

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: AverageValue
          averageValue: "900m"

  behavior:

    scaleUp:
      stabilizationWindowSeconds: 30

      policies:
        - type: Pods
          value: 2
          periodSeconds: 15

        - type: Percent
          value: 40
          periodSeconds: 15

      selectPolicy: Max

    scaleDown:
      stabilizationWindowSeconds: 300

      policies:
        - type: Pods
          value: 1
          periodSeconds: 300
```

---

# 9. Scaling Behavior

Desired behavior:

## Low Load

```text
Pods = minReplicas
VPA requests near minAllowed
```

---

## Increasing Load

```text
CPU usage increases
```

VPA raises CPU requests.

No new pods are created yet.

---

## Sustained High Load

VPA approaches:

```text
maxAllowed
```

If actual CPU usage remains above the HPA AverageValue target:

```text
HPA scales out
```

New pods are added.

---

## Falling Load

CPU usage decreases.

HPA waits for:

```text
scaleDown stabilization window
```

before reducing replicas.

VPA gradually lowers requests.

This minimizes oscillation.

---

# 10. Single Replica Services

Current inventory includes services configured as:

```yaml
minReplicas: 1
maxReplicas: 1
```

These services SHALL receive VPA.

Benefits:

* Automatic right-sizing
* Lower resource waste
* Automatic memory growth
* Automatic CPU growth

HPA remains effectively disabled.

---

# 11. Helm Chart Requirements

The Orbitant App Helm chart SHALL support:

## HPA

```yaml
hpa:
  enabled: true

  targetType:
    Utilization
    AverageValue
```

---

## VPA

```yaml
vpa:
  enabled: true
```

---

# 12. Mandatory Validation

The chart SHALL reject:

```yaml
vpa:
  enabled: true

hpa:
  targetType: Utilization
```

Validation:

```yaml
{{- if and .Values.vpa.enabled (eq .Values.hpa.targetType "Utilization") }}
{{- fail "VPA requires HPA targetType=AverageValue" }}
{{- end }}
```

This rule is mandatory.

---

# 13. MDPA Evaluation

A Multi-Dimensional Pod Autoscaler (MDPA) would theoretically provide the ideal solution because it manages:

* replica count
* CPU requests
* memory requests

within a single decision loop.

However:

* No production-ready upstream MDPA exists.
* Kubernetes does not currently provide a supported implementation.
* Building a custom autoscaler would introduce significant operational complexity.

Therefore:

```text
Custom MDPA implementation is NOT approved.
```

The approved DNext strategy is:

```text
HPA(AverageValue)
+
VPA(RequestsOnly)
```

---

# 14. Migration Plan

## Phase 1

Implement:

* VPA template
* AverageValue support
* Validation guard

---

## Phase 2

Pilot:

* 3–5 services
* Real traffic
* Dev environment

Observe:

* VPA recommendations
* HPA scaling
* Restart count
* Resource utilization

---

## Phase 3

Roll out to all scalable services.

---

## Phase 4

Enable VPA on fixed-replica services.

---

## Phase 5

Production rollout.

---

# 15. Final Recommendation

The approved DNext autoscaling architecture is:

```text
HPA:
  CPU AverageValue
  Controls Replica Count

VPA:
  CPU Requests
  Memory Requests

Deployment:
  Static Limits

Guard:
  Reject Utilization + VPA
```

This architecture:

* Eliminates HPA/VPA feedback loops.
* Preserves vertical-first scaling behavior.
* Keeps horizontal scaling available when required.
* Requires no custom autoscaler.
* Uses only supported Kubernetes components.
* Provides the lowest operational risk for DNext production environments.
