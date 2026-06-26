#!/usr/bin/env bash
# cluster-wake — reverse cluster-hibernate: scale EKS managed nodegroups back to their
# original size (from tags), wait for a node, then unfreeze Karpenter (restore NodePool
# limits from the annotation). Pending pods then schedule; ArgoCD restores any relaxed PDBs.
#
# Requires: kubectl (context on target cluster), aws CLI (EKS perms), jq.
# Cluster/region derived from kube-context ARN; override with CLUSTER= / REGION=.
set -uo pipefail
for b in kubectl aws jq; do command -v "$b" >/dev/null || { echo "ERROR: $b is required"; exit 1; }; done
ARN="$(kubectl config current-context)"
REGION="${REGION:-$(printf '%s' "$ARN" | cut -d: -f4)}"
CLUSTER="${CLUSTER:-$(printf '%s' "$ARN" | sed 's|.*/||')}"
[ -n "$CLUSTER" ] && [ -n "$REGION" ] || { echo "ERROR: set CLUSTER= and REGION="; exit 1; }
echo ">> Waking cluster '$CLUSTER' (region $REGION)"

echo "== 1) restore EKS managed nodegroups from hibernate tags =="
for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups[]' --output text 2>/dev/null); do
  arn="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" --query 'nodegroup.nodegroupArn' --output text)"
  tags="$(aws eks list-tags-for-resource --resource-arn "$arn" --region "$REGION" --query 'tags' --output json)"
  mn=$(jq -r '.hibernateMin // empty' <<<"$tags"); mx=$(jq -r '.hibernateMax // empty' <<<"$tags"); ds=$(jq -r '.hibernateDesired // empty' <<<"$tags")
  if [ -n "$ds" ]; then
    aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" --scaling-config minSize=$mn,maxSize=$mx,desiredSize=$ds >/dev/null
    aws eks untag-resource --resource-arn "$arn" --region "$REGION" --tag-keys hibernateMin hibernateMax hibernateDesired >/dev/null
    echo "  $ng: restored min=$mn max=$mx desired=$ds"
  fi
done

echo "== 2) wait for a managed node to become Ready (Karpenter runs there) =="
for i in $(seq 1 40); do
  r=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  echo "  Ready nodes: ${r:-0}"; [ "${r:-0}" -ge 1 ] && break; sleep 15
done

echo "== 3) unfreeze Karpenter NodePools (restore limits from annotation) =="
for np in $(kubectl get nodepools -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  lim="$(kubectl get nodepool "$np" -o jsonpath='{.metadata.annotations.hibernate\.limits}' 2>/dev/null)"
  if [ -n "$lim" ]; then
    kubectl patch nodepool "$np" --type merge -p "{\"spec\":{\"limits\":$lim}}" >/dev/null
    kubectl annotate nodepool "$np" hibernate.limits- >/dev/null 2>&1 || true
    echo "  $np: restored limits $lim"
  fi
done

echo
echo ">> Awake. Karpenter provisioning for Pending pods; ArgoCD re-syncs and restores PDBs."
echo "   Watch: kubectl get nodes,pods -A"
