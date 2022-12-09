#!/bin/bash

set -xe

helm repo add nginx-stable https://helm.nginx.com/stable
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add hashicorp https://helm.releases.hashicorp.com


helm install consul hashicorp/consul --values consul/helm-consul-values.yml
sleep 1m

helm install vault hashicorp/vault --values vault/helm-vault-values.yml
sleep 1m

# kubectl port-forward vault-0 8200:8200
# http://localhost:8200/ui

kubectl exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > cluster-keys.json

# cat cluster-keys.json | jq -r ".unseal_keys_b64[]"

VAULT_UNSEAL_KEY=$(cat cluster-keys.json | jq -r ".unseal_keys_b64[]")

# Unseal vault in all cluster members
for i in 0 1 2
  do
    kubectl exec vault-$i -- vault operator unseal  $VAULT_UNSEAL_KEY
done

sleep 2

kubectl exec vault-0 -- sh -c "\
        vault login $(cat cluster-keys.json | jq -r '.root_token') && \
        vault secrets enable -path=secret kv-v2 && \
        vault kv put secret/webapp/config daniel='password1' robin='password2'"


kubectl exec vault-0 -- sh -c "vault auth enable kubernetes"

kubectl exec vault-0 -- sh -c "vault write auth/kubernetes/config \
        kubernetes_host=\"https://$KUBERNETES_PORT_443_TCP_ADDR:443\" "

kubectl exec vault-0 -- sh -c "vault policy write webapp - <<EOF
path \"secret/data/webapp/\" {
  capabilities = [\"read\"]
}
EOF"

kubectl exec vault-0 -- sh -c "vault write auth/kubernetes/role/webapp \
      bound_service_account_names=vault-webapp \
      bound_service_account_namespaces=default \
      policies=webapp \
      ttl=24h"

kubectl create serviceaccount vault-webapp


helm install nginx  --values nginx/values.yml


helm install postgresql bitnami/postgresql-ha
