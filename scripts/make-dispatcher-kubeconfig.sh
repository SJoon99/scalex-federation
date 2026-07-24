#!/usr/bin/env bash
# Create a least-privilege kubeconfig for the child-CI dispatcher runner.
#
# Run this ON THE CLUSTER (node4, where you have admin kubectl to tower).
# It provisions an identity that can ONLY create/read PipelineRuns in tower-ci,
# then emits a base64 kubeconfig for the child repo's GitHub secret
# TOWER_CI_KUBECONFIG (e.g. BellTigerLee/sample-poc).
set -euo pipefail
NS=tower-ci
SA=ci-dispatcher

kubectl -n "$NS" create serviceaccount "$SA" --dry-run=client -o yaml | kubectl apply -f -

# Least-privilege Role: create/read PipelineRuns + read logs for status. NOTHING else.
cat <<'YAML' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-dispatcher
  namespace: tower-ci
rules:
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns"]
    verbs: ["create", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
YAML

kubectl -n "$NS" create rolebinding ci-dispatcher \
  --role=ci-dispatcher --serviceaccount="$NS:$SA" \
  --dry-run=client -o yaml | kubectl apply -f -

# POC: long-lived SA token Secret (k8s >=1.24 no longer auto-creates one).
# For production prefer `kubectl create token` on a short cron instead.
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SA}-token
  namespace: ${NS}
  annotations:
    kubernetes.io/service-account.name: ${SA}
type: kubernetes.io/service-account-token
YAML
sleep 2

APISERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA="$(kubectl -n "$NS" get secret "${SA}-token" -o jsonpath='{.data.ca\.crt}')"
TOKEN="$(kubectl -n "$NS" get secret "${SA}-token" -o jsonpath='{.data.token}' | base64 -d)"

cat > /tmp/dispatcher.kubeconfig <<YAML
apiVersion: v1
kind: Config
clusters:
  - name: tower
    cluster:
      server: ${APISERVER}
      certificate-authority-data: ${CA}
contexts:
  - name: dispatcher
    context: { cluster: tower, namespace: ${NS}, user: dispatcher }
current-context: dispatcher
users:
  - name: dispatcher
    user: { token: ${TOKEN} }
YAML

echo "API server the runner must reach: ${APISERVER}"
echo "---- base64 for GitHub secret TOWER_CI_KUBECONFIG ----"
base64 -w0 /tmp/dispatcher.kubeconfig
echo
