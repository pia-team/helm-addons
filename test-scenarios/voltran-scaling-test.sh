#!/usr/bin/env bash
# Mini HPA+VPA+Karpenter scaling test for voltran services (Method 1: real CPU injected
# into the actual app pods via exec busy-loops; a re-stress loop keeps new HPA replicas hot).
# Phases: idle -> normal -> high -> rampdown. Monitors node/pod counts, HPA/VPA, availability.
# Outputs CSV/logs under helm-addons/test-reports/. Burners self-expire (timeout 75s) as a safety.
NS=dnext
SVCS_HIGH="dnext-dpams-party-mgmt-srvc dnext-dpcms-product-catalog-mgmt-srvc dnext-dacms-account-mgmt-srvc"
SVCS_NORMAL="dnext-dpams-party-mgmt-srvc"
LIVENESS="http://dnext-dpams-party-mgmt-srvc.dnext.svc.cluster.local:80/api/partyManagement/v4/actuator/health/liveness"
PROBER_POD="voltran-prober"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$(cd "$(dirname "$0")/.." && pwd)/test-reports/voltran-scaling-$TS"
mkdir -p "$OUT"
CSV="$OUT/monitor.csv"; PHASES="$OUT/phases.log"; EVENTS="$OUT/events.log"; PROBELOG="$OUT/prober.log"
echo "$OUT"   # print output dir so caller knows where results land

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$PHASES"; }
setphase(){ echo "$1" > "$OUT/.phase"; log "=== PHASE $1 ==="; }

# CSV header
hdr="ts,phase,nodes,nodeclaims,pods_total,pods_pending,pods_notready"
for s in $SVCS_HIGH; do hdr="$hdr,${s##*-}_rep,${s##*-}_vcpu,${s##*-}_vmem"; done
echo "$hdr" > "$CSV"
echo "init" > "$OUT/.phase"

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

snap_events(){
  { echo "### $(date +%H:%M:%S) phase=$(cat "$OUT/.phase")";
    kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -iE "scaled|FailedScheduling|disrupt|Killing|OOM|Provisioned|nominated|Multi-Attach" | tail -20;
    kubectl -n kube-system logs deploy/karpenter --tail=60 2>/dev/null | grep -iE "disrupt|created nodeclaim|consolidat|launched" | tail -10;
  } >> "$EVENTS" 2>&1
}

stress(){ # $1=burner-duration ; rest=services ; 2 cores/pod
  local dur=$1; shift s p c
  for s in "$@"; do
    for p in $(kubectl get pods -n $NS -l app.kubernetes.io/name=$s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      for c in 1 2; do
        kubectl exec "$p" -n $NS -c "$s" -- timeout -s KILL "$dur" sh -c 'while :; do :; done' >/dev/null 2>&1 &
      done
    done
  done
}

# background monitor
touch "$OUT/.run"
( while [ -f "$OUT/.run" ]; do sample; sleep 15; done ) & MONPID=$!

# in-cluster availability prober
PROBE_CMD='while true; do curl -s -o /dev/null -w "%{http_code} %{time_total}\n" --max-time 3 '"$LIVENESS"'; sleep 2; done'
kubectl run $PROBER_POD -n $NS --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -c "$PROBE_CMD" >/dev/null 2>&1
kubectl wait --for=condition=Ready pod/$PROBER_POD -n $NS --timeout=60s >/dev/null 2>&1

teardown(){ log "TEARDOWN"; rm -f "$OUT/.run"; kill $MONPID 2>/dev/null; kubectl logs $PROBER_POD -n $NS >"$PROBELOG" 2>/dev/null; kubectl delete pod $PROBER_POD -n $NS --force --grace-period=0 >/dev/null 2>&1; log "outputs in $OUT"; }
trap teardown EXIT

# ===== PHASES =====
setphase "0-idle"; snap_events; sleep 180; snap_events
N_IDLE=$(kubectl get nodes --no-headers 2>/dev/null|wc -l|tr -d ' '); log "N_idle=$N_IDLE"

setphase "1-normal"; END=$(( $(date +%s) + 360 ))
while [ $(date +%s) -lt $END ]; do stress 75 $SVCS_NORMAL; sleep 60; done
snap_events; N_NORMAL=$(kubectl get nodes --no-headers 2>/dev/null|wc -l|tr -d ' '); log "N_normal=$N_NORMAL"

setphase "2-high"; END=$(( $(date +%s) + 720 ))
while [ $(date +%s) -lt $END ]; do stress 75 $SVCS_HIGH; sleep 60; done
snap_events; N_HIGH=$(kubectl get nodes --no-headers 2>/dev/null|wc -l|tr -d ' '); log "N_high=$N_HIGH"

setphase "3-rampdown"; log "stop stress; observe HPA scale-in + Karpenter consolidation"
for i in $(seq 1 13); do snap_events; sleep 60; done
N_REC=$(kubectl get nodes --no-headers 2>/dev/null|wc -l|tr -d ' '); log "N_recovered=$N_REC"

log "SUMMARY nodes: idle=$N_IDLE normal=$N_NORMAL high=$N_HIGH recovered=$N_REC"
echo "idle=$N_IDLE normal=$N_NORMAL high=$N_HIGH recovered=$N_REC" > "$OUT/node-summary.txt"
