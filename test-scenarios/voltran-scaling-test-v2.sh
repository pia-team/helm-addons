#!/usr/bin/env bash
# v2 voltran HPA+VPA+Karpenter scaling test.
# Changes vs v1: non-blocking PDBs (maxUnavailable:1) already applied; consolidateAfter=10m;
# availability prober is a Deployment PINNED TO THE MANAGED NODE (survives Karpenter
# consolidation) with timestamped probes; per-phase availability computed at the end.
NS=dnext
SVCS_HIGH="dnext-dpams-party-mgmt-srvc dnext-dpcms-product-catalog-mgmt-srvc dnext-dacms-account-mgmt-srvc"
SVCS_NORMAL="dnext-dpams-party-mgmt-srvc"
LIVENESS="http://dnext-dpams-party-mgmt-srvc.dnext.svc.cluster.local:80/api/partyManagement/v4/actuator/health/liveness"
PROBER="voltran-prober"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$(cd "$(dirname "$0")/.." && pwd)/test-reports/voltran-scaling-$TS"
mkdir -p "$OUT"
CSV="$OUT/monitor.csv"; PHASES="$OUT/phases.log"; EVENTS="$OUT/events.log"; PROBELOG="$OUT/prober.log"; PEPOCH="$OUT/phase-epochs.txt"; AVAIL="$OUT/availability.txt"
echo "$OUT"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$PHASES"; }
setphase(){ echo "$1" > "$OUT/.phase"; echo "$1 $(date +%s)" >> "$PEPOCH"; log "=== PHASE $1 ==="; }

hdr="ts,phase,nodes,nodeclaims,pods_total,pods_pending,pods_notready"
for s in $SVCS_HIGH; do l=$(echo "$s"|cut -d- -f2); hdr="$hdr,${l}_rep,${l}_vcpu,${l}_vmem"; done
echo "$hdr" > "$CSV"; echo "init" > "$OUT/.phase"

sample(){
  local ts ph nodes ncl pt pp pn rep vc vm row s
  ts=$(date +%s); ph=$(cat "$OUT/.phase" 2>/dev/null)
  nodes=$(kubectl get nodes --no-headers 2>/dev/null|wc -l|tr -d ' ')
  ncl=$(kubectl get nodeclaims --no-headers 2>/dev/null|wc -l|tr -d ' ')
  pt=$(kubectl get pods -n $NS --no-headers 2>/dev/null|wc -l|tr -d ' ')
  pp=$(kubectl get pods -n $NS --field-selector status.phase=Pending --no-headers 2>/dev/null|wc -l|tr -d ' ')
  pn=$(kubectl get pods -n $NS --no-headers 2>/dev/null|grep -vcE ' (Running|Completed) ')
  row="$ts,$ph,$nodes,$ncl,$pt,$pp,$pn"
  for s in $SVCS_HIGH; do
    rep=$(kubectl get hpa $s -n $NS -o jsonpath='{.status.currentReplicas}' 2>/dev/null)
    vc=$(kubectl get vpa $s -n $NS -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}' 2>/dev/null)
    vm=$(kubectl get vpa $s -n $NS -o jsonpath='{.status.recommendation.containerRecommendations[0].target.memory}' 2>/dev/null)
    row="$row,${rep:-?},${vc:-?},${vm:-?}"
  done
  echo "$row" >> "$CSV"
}
snap_events(){ { echo "### $(date +%H:%M:%S) phase=$(cat "$OUT/.phase")";
  kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -iE "scaled|FailedScheduling|disrupt|Killing|OOM|Provisioned|nominated|evict" | tail -20;
  kubectl -n kube-system logs deploy/karpenter --tail=60 2>/dev/null | grep -iE "disrupt|created nodeclaim|consolidat|launched" | tail -10; } >> "$EVENTS" 2>&1; }
stress(){ local dur=$1; shift; local s p c
  for s in "$@"; do for p in $(kubectl get pods -n $NS -l app.kubernetes.io/name=$s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    for c in 1 2; do kubectl exec "$p" -n $NS -c "$s" -- timeout -s KILL "$dur" sh -c 'while :; do :; done' >/dev/null 2>&1 & done
  done; done; }

compute_avail(){
  if [ ! -s "$PROBELOG" ]; then echo "NO PROBER DATA (prober produced no logs)" > "$AVAIL"; return; fi
  awk 'NF>=2{t++; if($2==200)ok++} END{if(t)printf "OVERALL: probes=%d ok(200)=%d success=%.3f%%\n", t, ok, ok*100/t; else print "no parsable probes"}' "$PROBELOG" > "$AVAIL"
  echo "per-phase:" >> "$AVAIL"
  while read ph start; do
    next=$(awk -v p="$ph" 'f{print $2; exit} $1==p{f=1}' "$PEPOCH"); next=${next:-9999999999}
    awk -v s="$start" -v e="$next" -v ph="$ph" 'NF>=2 && $1>=s && $1<e {t++; if($2==200)ok++} END{if(t)printf "  %-12s probes=%d ok=%d success=%.3f%%\n", ph, t, ok, ok*100/t}' "$PROBELOG" >> "$AVAIL"
  done < "$PEPOCH"
}

touch "$OUT/.run"; ( while [ -f "$OUT/.run" ]; do sample; sleep 15; done ) & MONPID=$!

# prober Deployment pinned to the managed (non-Karpenter) node so it survives consolidation
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata: { name: $PROBER, namespace: $NS }
spec:
  replicas: 1
  selector: { matchLabels: { app: $PROBER } }
  template:
    metadata: { labels: { app: $PROBER } }
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - { key: eks.amazonaws.com/nodegroup, operator: Exists }
      containers:
      - name: prober
        image: curlimages/curl:8.10.1
        command: ["sh","-c"]
        args:
        - |
          while true; do
            c=\$(curl -s -o /dev/null -w "%{http_code} %{time_total}" --max-time 3 "$LIVENESS")
            echo "\$(date +%s) \$c"
            sleep 1
          done
EOF
kubectl rollout status deploy/$PROBER -n $NS --timeout=90s >/dev/null 2>&1

teardown(){ log TEARDOWN; rm -f "$OUT/.run"; kill $MONPID 2>/dev/null; kubectl logs deploy/$PROBER -n $NS --tail=1000000 >"$PROBELOG" 2>/dev/null; compute_avail; kubectl delete deploy/$PROBER -n $NS --wait=false >/dev/null 2>&1; log "outputs in $OUT"; }
trap teardown EXIT

setphase "0-idle"; snap_events; sleep 180; snap_events; N_IDLE=$(kubectl get nodes --no-headers 2>/dev/null|wc -l|tr -d ' '); log "N_idle=$N_IDLE"
setphase "1-normal"; END=$(( $(date +%s)+360 )); while [ $(date +%s) -lt $END ]; do stress 75 $SVCS_NORMAL; sleep 60; done; snap_events; N_NORMAL=$(kubectl get nodes --no-headers 2>/dev/null|wc -l|tr -d ' '); log "N_normal=$N_NORMAL"
setphase "2-high"; END=$(( $(date +%s)+720 )); while [ $(date +%s) -lt $END ]; do stress 75 $SVCS_HIGH; sleep 60; done; snap_events; N_HIGH=$(kubectl get nodes --no-headers 2>/dev/null|wc -l|tr -d ' '); log "N_high=$N_HIGH"
setphase "3-rampdown"; for i in $(seq 1 13); do snap_events; sleep 60; done; N_REC=$(kubectl get nodes --no-headers 2>/dev/null|wc -l|tr -d ' '); log "N_recovered=$N_REC"
PEAK=$(awk -F, '$2=="2-high"&&$3>m{m=$3}END{print m+0}' "$CSV")
log "SUMMARY nodes idle=$N_IDLE normal=$N_NORMAL high_end=$N_HIGH peak=$PEAK recovered=$N_REC"
echo "idle=$N_IDLE normal=$N_NORMAL high_end=$N_HIGH peak_high=$PEAK recovered=$N_REC" > "$OUT/node-summary.txt"
