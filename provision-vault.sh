#!/usr/bin/env sh

set -x

# Provision the Vault server with PKI roles and client certificate auth backend

# Vault server location and credentials
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=1
export VAULT_TOKEN=root

# Enable auditing for debugging purposes
vault audit enable file path=stdout

# Setup a very basic PKI role for issuing client certificates
# https://developer.hashicorp.com/vault/docs/secrets/pki/setup
vault secrets enable -path=pki pki
# Ensure cluster-local configuration prerequisites for ACME
# https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-caddy#configure-acme
vault write pki/config/cluster \
   path=https://vault-server:8200/v1/pki \
   aia_path=https://vault-server:8200/v1/pki
# Enable ACME headers
vault secrets tune \
 -passthrough-request-headers=If-Modified-Since \
 -allowed-response-headers=Last-Modified \
 -allowed-response-headers=Location \
 -allowed-response-headers=Replay-Nonce \
 -allowed-response-headers=Link \
 pki
# Enable ACME and allow to request clientAuth extended key usage
# https://developer.hashicorp.com/vault/api-docs/secret/pki#set-acme-configuration
vault write pki/config/acme \
 enabled=true \
 allow_role_ext_key_usage=true

# Create internal CA and role to issue client certitificates in the acme.podman.dns network
vault write -format=json pki/root/generate/internal common_name=dns.podman ttl=768h | jq -r '.data.issuing_ca' > ca-cert.pem
# Make the role issue client certs:
# - https://developer.hashicorp.com/vault/api-docs/secret/pki#client_flag
# - https://developer.hashicorp.com/vault/api-docs/secret/pki#server_flag
# - https://developer.hashicorp.com/vault/api-docs/secret/pki#ext_key_usage
#
# Deliberately choose low ttl for the certificate (only used for first
# authentication)
vault write pki/roles/dns-podman allowed_domains=acme.dns.podman allow_subdomains=true allow_bare_domains=true max_ttl=60m ttl=30m \
  client_flag=true \
  server_flag=false \
  ext_key_usage=ClientAuth

# Setup basic Cert auth role acme-dns-podman to authenticate clients in the dns.podman domain
# This is an example for pre-provisiong roles to the Client
# https://developer.hashicorp.com/vault/docs/auth/cert
vault auth enable cert
vault write auth/cert/certs/dns-podman certificate=@ca-cert.pem allowed_common_names="*.dns.podman" token_ttl=15m token_max_ttl=30m token_period=15m

# Create policy acme_demo_a
echo '
path "kv-v2/data/acme_demo_a/*" {
  capabilities = ["read"]
}
' | vault policy write acme_demo_a_read -

# Enable kv-v2 secrets engine and store secrets at 2 different paths
vault secrets enable kv-v2
vault kv put kv-v2/acme_demo_a/test key=you_should_see_this
vault kv put kv-v2/acme_demo_b/test key=you_cant_see_this

# Read authentication method accessor for alias creation
vault auth list -format=json | jq -r '.["cert/"].accessor' > acme.txt

# Create entity with connected policy and store the entitiy_id
vault write -format=json identity/entity name="acme.dns.podman" policies="acme_demo_a_read" | jq -r ".data.id" > entity_id.txt

# Create alias with entity_id and auth_accessor
vault write identity/entity-alias name="acme.dns.podman" canonical_id=$(cat entity_id.txt) mount_accessor=$(cat acme.txt)
