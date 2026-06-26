#!/usr/bin/env bash
# cluster-hibernate — scale an EKS + Karpenter cluster down to ZERO worker nodes for cost
# saving (weekends/overnight), reversibly, without editing any workloads (so ArgoCD selfHeal
# has nothing to revert and no app Git repos are needed). Reverse with cluster-wake.
#
# STATELESS: original Karpenter NodePool limits are stored as the `hibernate.limits`
# annotation on each NodePool; each managed nodegroup's original size is stored as
# hibernateMin/Max/Desired tags on the nodegroup. Any teammate can run cluster-wake later.
#
# Requires: kubectl (context on target cluster), aws CLI (EKS perms), jq.
# Cluster/region are derived from the kube-context ARN; override with CLUSTER= / REGION=.
set -uo pipefail
for b in kubectl aws jq; do command -v "$b" >/dev/null || { echo "ERROR: $b is required"; exit 1; }; done
ARN="$(kubectl config current-context)"
REGION="${REGION:-$(printf '%s' "$ARN" | cut -d: -f4)}"
CLUSTER="${CLUSTER:-$(printf '%s' "$ARN" | sed 's|.*/||')}"
[ -n "$CLUSTER" ] && [ -n "$REGION" ] || { echo "ERROR: set CLUSTER= and REGION= (could not parse from context '$ARN')"; exit 1; }
echo ">> Hibernating cluster '$CLUSTER' (region $REGION)"

echo "== 1) freeze Karpenter NodePools (record original limits on the NodePool) =="
for np in $(kubectl get nodepools -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  if [ -z "$(kubectl get nodepool "$np" -o jsonpath='{.metadata.annotations.hibernate\.limits}' 2>/dev/null)" ]; then
    orig="$(kubectl get nodepool "$np" -o jsonpath='{.spec.limits}' 2>/dev/null)"; [ -n "$orig" ] || orig='{}'
    kubectl annotate nodepool "$np" "hibernate.limits=$orig" --overwrite >/dev/null
    echo "  $np: recorded original limits $orig"
  fi
  kubectl patch nodepool "$np" --type merge -p '{"spec":{"limits":{"cpu":"0","memory":"0"}}}' >/dev/null && echo "  $np: frozen (limits 0/0)"
done

echo "== 2) relax non-kube-system PDBs (else node drain stalls; controllers restore on wake) =="
kubectl get pdb -A -o json 2>/dev/null | jq -r '.items[]|select(.metadata.namespace!="kube-system")|"\(.metadata.namespace) \(.metadata.name)"' \
| while read -r ns nm; do kubectl -n "$ns" delete pdb "$nm" --ignore-not-found >/dev/null && echo "  removed pdb $ns/$nm"; done

echo "== 3) remove all Karpenter nodes (pods become Pending) =="
kubectl delete nodeclaims --all --wait=false 2>/dev/null || echo "  (no NodeClaims / Karpenter CRD absent)"

echo "== 4) scale all EKS managed nodegroups to 0 (store original size as tags) =="
for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups[]' --output text 2>/dev/null); do
  arn="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" --query 'nodegroup.nodegroupArn' --output text)"
  cfg="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" --query 'nodegroup.scalingConfig' --output json)"
  mn=$(jq -r .minSize <<<"$cfg"); mx=$(jq -r .maxSize <<<"$cfg"); ds=$(jq -r .desiredSize <<<"$cfg")
  tagged="$(aws eks list-tags-for-resource --resource-arn "$arn" --region "$REGION" --query 'tags.hibernateDesired' --output text 2>/dev/null)"
  if [ "$tagged" = "None" ] || [ -z "$tagged" ]; then
    aws eks tag-resource --resource-arn "$arn" --region "$REGION" --tags hibernateMin=$mn,hibernateMax=$mx,hibernateDesired=$ds >/dev/null
    echo "  $ng: tagged original min=$mn max=$mx desired=$ds"
  fi
  aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" --scaling-config minSize=0,maxSize=$mx,desiredSize=0 >/dev/null && echo "  $ng: scaling -> 0"
done

echo
echo ">> Hibernated. All worker nodes draining to zero. Wake with: cluster-wake"
