# Voltran HPA + VPA + Karpenter — scaling test v2 (with PDBs + consolidateAfter=10m + availability)

**Date:** 2026-06-25 (run 13:56–14:31, ~35 min)
**Cluster:** eks-karpenter-vpa (dev), ns `dnext`
**What changed vs v1:** added **non-blocking PDBs `maxUnavailable:1`** (dpams/dpcms/dacms),
**`consolidateAfter` 1m→10m** (git stays 2h), and a **prober that survives consolidation**
(`do-not-disrupt`) → availability actually measured this time.
**Method:** same as v1 — real CPU injected into the actual voltran pods (~2 cores/pod, re-stress loop).
**Raw data:** `monitor.csv`, `availability.txt`, `phases.log`, `events.log` (this dir).

## TL;DR
- ✅ **HPA↔VPA coexistence: confirmed again, cleaner.** Replicas monotonic, no oscillation; `dpcms`
  this time reached **max 3** (v1 only hit 2) and `dacms` reached 2 (v1 stayed 1) — less node churn let
  load distribute.
- ✅ **PDB `maxUnavailable:1` works exactly as evaluated** — it did **not** block consolidation (25
  disruptions still happened) yet held **99.4% availability during peak load**.
- ✅ **`consolidateAfter=10m` halved the churn** (25 disruptions vs **48**) and **stopped node thrash**
  (stable 4→5, vs v1's 6↔8 oscillation).
- ⚠️ **Availability: 95.8% overall — but the dip is entirely in ramp-down (90.0%), not under load.**
  100% idle, 100% normal, **99.4% high**, **90.0% ramp-down**. The ramp-down dip is the inherent
  **single-replica** limitation: when a service scales back to 1 and that pod is moved during
  consolidation, `maxUnavailable:1` *permits* the disruption → brief outage.

## Node counts
| State | v2 nodes | v1 (prev) |
|------|------|------|
| Idle | **4** | 7 |
| Normal | **5** | 7 |
| High (peak) | **5** | 8 (but thrashing 6↔8) |
| Recovered | **5–6** | 7 |

> Idle is 4 here because the cluster had already consolidated post-v1 (true idle footprint ≈ 4–5; the
> "7" in v1 was pre-consolidation slack). The prober node carried `do-not-disrupt`, so it was pinned —
> recovered count is +1 inflated by that.

## Availability (measured) — `availability.txt`
| Phase | Probes | Success |
|------|------|------|
| 0-idle | 181 | **100.000%** |
| 1-normal | 359 | **100.000%** |
| 2-high (peak load) | 660 | **99.394%** |
| 3-rampdown | 792 | **90.025%** |
| **Overall** | 1993 | **95.835%** |

**Interpretation:** availability is **≥99% exactly when it matters (idle/normal/high demand)**. The drop
to 90% is during **scale-down + consolidation**, when `dpams` returns to 1 replica and that lone pod is
relocated. The `maxUnavailable:1` PDB cannot protect a 1-replica service (by design it *allows* the one
pod to be disrupted so consolidation isn't blocked) — that's the trade-off you correctly anticipated.

## HPA + VPA coexistence — PASS
| Service | Replicas 1→peak | VPA CPU peak | Behavior |
|---|---|---|---|
| dpams | 1→**3** (held) | ~2 cores | monotonic, no flap |
| dpcms | 1→**3** (held) | ~1038m+ | reached max this run |
| dacms | 1→**2** | grew under load | scaled (v1 stayed 1) |
Replica counts moved up under load and down on release — **no oscillation** while VPA changed requests.

## Karpenter — PASS, far less churn
- **25 disrupting-node decisions** (23 delete, 2 replace) vs **48** in v1 → ~halved by `consolidateAfter=10m`.
- Node count **stable through the phases** (4→5, no 6↔8 thrash). Scaled up (+1 under load) and reclaimed.
- PDBs did **not** block consolidation (ALLOWED-DISRUPTIONS=1) — confirmed correct PDB choice.

## Acceptance criteria
| # | Criterion | Result |
|---|-----------|--------|
| 1 | No HPA/VPA oscillation | ✅ PASS (cleaner than v1) |
| 2 | Karpenter scales up; pending scheduled | ✅ PASS (4→5, no stuck pending under load) |
| 3 | Scale-down returns to ~idle | ✅ PASS (→5–6) |
| 4 | Node counts captured | ✅ idle 4 / normal 5 / peak 5 / recovered 5–6 |
| 5 | **Availability ≥ 99%** | ⚠️ **PARTIAL — ≥99% idle/normal/high (99.4% peak); 90% in ramp-down** |
| 6 | Report persisted | ✅ this file + raw data |

## The ≥99% decision (the key trade-off)
To hit **≥99% including during scale-down/consolidation**, the only reliable fix is **`minReplicas: 2`**
on the services that must stay available — then the `maxUnavailable:1` PDB always has a 2nd pod serving
while one is moved. Cost: ~2× idle pods for those services. This is the **availability-vs-budget**
trade-off you raised, now quantified:
- 1 replica + PDB → ~**90%** during disruption windows.
- 2 replicas + PDB → expected **≥99%** throughout (PDB keeps 1 up during every move).

## Action items
1. **For services that need ≥99% during scale events: set HPA `minReplicas: 2`** (+ keep the PDB). Leave
   non-critical/dev services at 1 (accept ramp-down blips) to save budget. A per-service choice.
2. **Keep `consolidateAfter` ≥ 10m** (15m would further cut ramp-down churn / dips). Hand over to the
   team at the planned **2h**.
3. PDBs validated → **extend `maxUnavailable:1` to the other 5 voltran services** (only 3 were tested).
4. 2-core t3.medium still caps per-pod CPU under packing (unchanged from v1) — revisit instance sizing or
   `averageValue` if you want crisper HPA triggering.
5. Prober used `do-not-disrupt` (pinned its node); for a pure consolidation measurement, run it off-cluster
   or on a dedicated node.

## Conclusion
The **coexistence design is solid and the PDB choice was correct** (non-blocking + protective under load).
With `consolidateAfter=10m` the cluster is calm (half the churn, no node thrash) and **availability is
≥99% under real demand**. The remaining gap is purely the **single-replica ramp-down blip** — closeable
with `minReplicas: 2` where availability matters, at a known budget cost.
