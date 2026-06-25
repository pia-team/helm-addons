# Voltran HPA + VPA + Karpenter — mini scaling test report

**Date:** 2026-06-25 (run 12:32–13:08, ~36 min)
**Cluster:** eks-karpenter-vpa (dev), ns `dnext`
**Method:** Method 1 — real CPU injected into the actual voltran app pods (`timeout`-bounded busy
loops via `kubectl exec`, ~2 cores/pod, re-stress loop every 60s to catch new HPA replicas).
**Targets:** `dpams`, `dpcms`, `dacms` loaded; other 5 voltran services idle controls.
**Config under test:** HPA CPU `AverageValue 1000m`, min1/max3; VPA `InPlaceOrRecreate`,
`RequestsAndLimits`, minAllowed 20m/500Mi, maxAllowed 2000m/2000Mi. `consolidateAfter=1m` (temp P1).
**Raw data:** `monitor.csv`, `phases.log`, `events.log` (this dir). `prober.log` empty — see Availability.

## TL;DR verdict
- ✅ **No HPA↔VPA conflict.** Replica counts moved **monotonically** (up under load, down on release) —
  zero oscillation — while VPA pushed CPU requests to ~2 cores. The `AverageValue` design works.
- ✅ **Karpenter scales up & down.** Peak demand reached **8 nodes** (from idle 7); released back to **7**.
- ⚠️ **`consolidateAfter=1m` is too aggressive** — 48 disruptions + 32 node relaunches in 34 min,
  node count thrashed 6↔8, pending pods spiked to 8, and the unprotected prober pod was evicted.
- ⚠️ **Availability not captured** (prober evicted during consolidation) — and that eviction is itself a
  signal that consolidation disrupts unprotected pods.

## Node counts (the headline)
| State | Nodes | Notes |
|------|------|------|
| Idle (baseline) | **7** | replicas 1/1/1; VPA targets 23m·561Mi / 49m·641Mi / 23m·600Mi |
| Normal demand | **7** | dpams scaled 1→3, VPA grew dpams CPU 23m→2 cores; fit on existing nodes (no new node) |
| **High demand (peak)** | **8** | +1 net (peak); nodeclaims peaked at 8; **but churned 6↔8** under 1m consolidation |
| Recovered (idle) | **7** | back to baseline within the 13-min ramp-down |

> The phase-end `node-summary.txt` shows `high=6` because consolidation had already packed down by the
> phase boundary; the **true peak during the high phase was 8** (from `monitor.csv`).

## HPA + VPA coexistence (the main goal) — PASS
| Service | Replicas (1→peak) | VPA CPU target (start→peak) | Behavior |
|---|---|---|---|
| dpams | **1 → 3** (held steady at 3) | 23m → **2 cores** | Clean scale-out to max while VPA grew request; no flap |
| dpcms | 1 → 2 | 49m → **1938m** | Scaled to 2, held; VPA tracked load up to ~2 cores |
| dacms | 1 (no scale-out) | 23m → 511m | Per-pod CPU only reached ~0.5 core → below the 1000m threshold (see below) |

**Key proof:** replica counts were monotonic (no up/down flapping) even as VPA continuously changed CPU
requests via in-place resize. This is exactly the oscillation the `Utilization`→`AverageValue` switch was
meant to prevent — confirmed absent.

**Why dacms didn't scale:** t3.medium = **2 physical cores**. When several stressed pods share one node,
node CPU saturates and each pod is throttled to ~1 core — right at the `1000m` HPA threshold. dacms,
co-scheduled with other stressed pods, never cleanly exceeded 1 core. (Not a conflict — a node-sizing/threshold interaction.)

## Karpenter behavior
- **Scale-up:** added a node under demand (7→8) and `launched 32 nodeclaims` over the run.
- **Scale-down/consolidation:** **48 `disrupting node(s)` decisions, all `reason=underutilized`** (43 delete,
  5 replace), 53 node taints. With `consolidateAfter=1m`, Karpenter consolidated **continuously — even
  during the high phase** — repeatedly deleting and relaunching nodes. This caused:
  - node-count thrash (6↔7↔8) and `nodeclaims` churn,
  - **pending-pod spikes up to 8** (pods evicted by consolidation, pending while rescheduling),
  - eviction of the bare prober pod (no controller → not rescheduled).
- PDBs were observed for some stateful svcs (`mongodb-arbiter`, `logstash-logstash-pdb`,
  `elasticsearch-master-pdb`) — good — but **voltran services have no PDBs**.

## Availability — NOT CAPTURED (action item)
The in-cluster prober was a **bare pod**; Karpenter consolidation drained its node and (no controller) it
was not rescheduled, so `prober.log` is empty. Early in the run it returned `200` in ~11ms, but no
full-run success%/latency was recorded. The pending-pod spikes imply transient scheduling delays during
churn that likely *would* have shown availability dips for unprotected services.

## Acceptance criteria
| # | Criterion | Result |
|---|-----------|--------|
| 1 | No HPA/VPA oscillation | ✅ PASS — monotonic replicas, no flap |
| 2 | Karpenter scales up; pending scheduled | ⚠️ PARTIAL — scaled 7→8, but consolidation churn caused pending spikes (≤8) |
| 3 | Scale-down returns to ~idle within 15 min | ✅ PASS — back to 7 |
| 4 | Node counts captured (idle/normal/high/recovered) | ✅ PASS — 7 / 7 / 8(peak) / 7 |
| 5 | Availability ≥ 99% | ❌ NOT MEASURED — prober evicted |
| 6 | Report persisted | ✅ PASS — this file + raw CSV/logs |

## Action items (prioritized)
1. **Raise `consolidateAfter` off 1m.** It thrashes under active load (48 disruptions / 34 min). Use a
   moderate dev value (**5–15m**) and the planned **2h for the team/prod**. Do NOT hand over at 1m.
2. **Add PodDisruptionBudgets to the voltran services** (e.g. `minAvailable: 1` or a %). Without them,
   consolidation/scale-in evicts pods freely → the availability risk seen here (incl. the prober).
3. **Re-run with a fixed prober** (Deployment + PDB or `karpenter.sh/do-not-disrupt`) to actually capture
   availability % and latency through scaling events.
4. **Node sizing vs HPA threshold:** on 2-core t3.medium, packed pods can't exceed `1000m` reliably (dacms).
   Either allow larger instances, spread stressed pods, or revisit `averageValue` so HPA triggers under real load.
5. **Watch VPA RequestsAndLimits memory growth** (dpcms VPA grew strongly) — contributes to node pressure;
   confirm `maxAllowed`/limits headroom is right.

## Conclusion
The **HPA+VPA coexistence design is sound** (no oscillation; VPA grows requests, HPA scales replicas on
absolute CPU). Karpenter does scale up and reclaim. The dominant issue is **operational tuning**:
`consolidateAfter=1m` + **missing PDBs** make scaling *churny and disruptive*, which is the real risk to
address before this pattern is production-ready.
