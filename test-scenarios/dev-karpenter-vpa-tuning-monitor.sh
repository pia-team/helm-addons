#!/usr/bin/env bash
# Continuous monitor for dev-karpenter-vpa-tuning test
# Writes timestamped snapshots to test-reports/dev-karpenter-vpa-tuning-monitor.log

LOG="test-reports/dev-karpenter-vpa-tuning-monitor.log"
mkdir -p "$(dirname "$LOG")"

snapshot() {
  echo ""
  echo "================================================================================"
  echo "TIMESTAMP: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "================================================================================"
  echo "--- NODES ---"
  kubectl get nodes -o wide 2>&1 || true
  echo "--- NODECLAIMS ---"
  kubectl get nodeclaim 2>&1 || true
  echo "--- PODS vpa-demo ---"
  kubectl get pods -n vpa-demo -o wide 2>&1 || true
  echo "--- VPA vpa-demo ---"
  kubectl get vpa -n vpa-demo 2>&1 || true
  echo "--- TOP NODES ---"
  kubectl top nodes 2>&1 || true
  echo "--- EVENTS vpa-demo (recent) ---"
  kubectl get events -n vpa-demo --sort-by='.lastTimestamp' 2>&1 | tail -20 || true
  echo "--- KARPENTER CONTROLLER LOGS TAIL ---"
  kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=20 2>&1 || true
}

echo "Monitor started at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOG"

while true; do
  snapshot >> "$LOG" 2>&1
  sleep 60
done
