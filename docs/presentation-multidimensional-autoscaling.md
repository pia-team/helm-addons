---
marp: true
theme: default
paginate: true
size: 16:9
header: 'Grow Up, Then Out — Multi‑Dimensional Autoscaling'
footer: 'Merih İlgör · 2026'
style: |
  section { font-size: 26px; }
  h1 { color: #1f6feb; }
  h2 { color: #1f6feb; }
  table { font-size: 20px; }
  .small { font-size: 18px; }
  .big { font-size: 40px; font-weight: 700; color:#1f6feb; }
---

<!-- _class: lead -->
# Grow Up, Then Out
## Safe Multi‑Dimensional Autoscaling on Kubernetes
### VPA × HPA × Karpenter — working **together**, not fighting

<br/>

**Merih İlgör** · Platform Engineering · 2026

---

## The autoscaling you're told not to mix

| Axis | Tool | Great at | Blind to |
|---|---|---|---|
| **Vertical** — pod size | **VPA** | right‑sizing requests | volume spikes |
| **Horizontal** — replicas | **HPA** | absorbing traffic | mis‑sized pods |
| **Cluster** — nodes | **Karpenter** | capacity + cost | anything app‑level |

> Use one axis → you leave **cost** *and* **resilience** on the table.
> Combine HPA + VPA naïvely → they **oscillate**. So everyone picks one. ❌

---

## Why naïve HPA + VPA fights

```mermaid
flowchart LR
    A[Load ↑] --> B[VPA raises CPU request]
    B --> C["Utilization = usage / request ↓"]
    C --> D[HPA: 'less load' → drop replica]
    D --> E[Per-pod load ↑]
    E --> B
    style C fill:#ffe0e0,stroke:#c0392b
    style D fill:#ffe0e0,stroke:#c0392b
```

`Utilization` is **relative to the request** — so when VPA moves the request, HPA is reading a moving ruler.

---

<!-- _class: lead -->
# The idea
<span class="big">Grow each pod **vertically** to a fixed ceiling first — then scale **horizontally** — on a node fleet that follows demand.</span>

HPA reads **absolute** CPU, so a VPA resize never looks like "less load."

---

## Three layers, one cooperative system

```mermaid
flowchart TD
    subgraph V["① Vertical · VPA"]
      P1[req 20m] --> P2[req → 1800m] --> P3[limit 2000m fixed]
    end
    subgraph H["② Horizontal · HPA AverageValue"]
      R1[1] --> R2[2] --> R3[3 … max]
    end
    subgraph N["③ Cluster · Karpenter"]
      N1[fit by request] --> N2[add nodes] --> N3[consolidate idle]
    end
    V ==> H ==> N
    N -.demand falls.-> H -.-> V
```

Grow **up** → grow **out** → fleet follows. Reverse on the way down.

---

## The one rule that makes it safe — *the guard*

<span class="big">No workload may have VPA‑on‑CPU **and** HPA `Utilization` at once.</span>

- HPA CPU metric → **`type: AverageValue`** (absolute milli‑cores), never `Utilization`
- `averageValue = 0.5 × maxAllowed.cpu` → scale out after vertical headroom is used
- If an HPA *can't* be `AverageValue` → make that VPA **memory‑only**

✅ Oscillation removed **by construction**, not by luck.

---

## How it behaves over a demand cycle

```mermaid
sequenceDiagram
    participant L as Load
    participant V as VPA
    participant H as HPA
    participant K as Karpenter
    L->>V: usage climbs → grow pod (in-place)
    L->>H: per-pod CPU crosses line → + replicas (fast)
    H->>K: more pods → provision nodes
    Note over L,K: PEAK = right-sized pods × right replicas × right nodes
    L-->>H: load falls → scale in (slow)
    V-->>V: requests decay
    K-->>K: consolidate idle nodes → 💰 reclaimed
```

**Grow fast, shrink slow.**

---

## Safe by configuration (reference values)

| Component | Key setting |
|---|---|
| **HPA** | CPU `AverageValue`, `averageValue = 0.5×maxAllowed.cpu` |
| **VPA** | `InPlaceOrRecreate`, `maxAllowed = 0.9×limit`, limits fixed |
| **Recommender** | `--round-memory-bytes`, tuned histogram decay |
| **Updater** | `feature-gates=InPlaceOrRecreate=true`, lifetime threshold |
| **Karpenter** | `consolidateAfter` dev 10–15m · prod 2h |
| **PDB** | upper envs: `maxUnavailable:1` + `minReplicas≥2` |

---

## Every objection has a configured answer

| Risk | Neutralised by |
|---|---|
| HPA↔VPA oscillation | `AverageValue` (the guard) |
| VPA balloons limits | `RequestsOnly` + fixed limit + `0.9×limit` cap |
| Node thrash | `consolidateAfter` tuning (1m→10m: **48→25** disruptions) |
| Availability on scale‑in | `maxUnavailable:1` PDB + `minReplicas≥2` |
| PDB blocking scale‑down | `maxUnavailable:1`, never `minAvailable:1` |
| OOM / under‑provision | memory `minAllowed` floor, slower mem decay |

---

## One mechanism — three wins

```mermaid
flowchart LR
    MD["Multi-dimensional<br/>elasticity"] --> A[🟢 Availability]
    MD --> S[📈 Scalability]
    MD --> C[💰 Cost]
```

- **Availability** — right‑sized pods + replicas + PDBs → resilient through change
- **Scalability** — scales on per‑pod load **and** request volume **and** node capacity
- **Cost** — no static over‑provisioning; idle nodes consolidated away

---

## Proven on live EKS + Karpenter

<div class="small">

| Signal | Result |
|---|---|
| HPA↔VPA conflict | **None** — replicas monotonic, no flapping |
| Availability @ peak load | **99.4 %** (100 % idle/normal) |
| Consolidation churn | **48 → 25** disruptions; node thrash eliminated |
| Idle node footprint | ~**halved** (7 → ~4) |
| Ordering | VPA grew pods **first**, HPA added replicas **after** |

</div>

Real CPU load, full idle→peak→idle cycle, continuous monitoring.

---

## Operating model

- 🧩 **GitOps‑native** — everything is manifests reconciled by ArgoCD
- 🌍 **Per‑environment policy** — dev = cost (1 replica, no PDB, fast consolidation); upper = availability (`≥2`, PDB, 2h)
- ♻️ **Repeatable** — an enablement agent discovers each project's services (kustomize *or* raw), classifies app vs infra, applies + validates + ships

---

<!-- _class: lead -->
# Takeaway
<span class="big">"Never combine HPA + VPA" was really "never use `Utilization` with VPA‑on‑CPU."</span>

Fix that one decision → **three autoscalers cooperate**: more available, more scalable, measurably cheaper.

---

<!-- _class: lead -->
# Thank you

**Grow Up, Then Out** — Multi‑Dimensional Autoscaling

**Merih İlgör** · Platform Engineering

*Full whitepaper: `whitepaper-multidimensional-autoscaling.md`*
