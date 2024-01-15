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

# Create internal CA and role to issue client certitificates in the app.example.com network
vault write -format=json pki/root/generate/internal common_name=example.com ttl=768h | jq -r '.data.issuing_ca' > ca-cert.pem
# Make the role issue client certs:
# - https://developer.hashicorp.com/vault/api-docs/secret/pki#client_flag
# - https://developer.hashicorp.com/vault/api-docs/secret/pki#server_flag
# - https://developer.hashicorp.com/vault/api-docs/secret/pki#ext_key_usage
#
# Deliberately choose low ttl for the certificate (only used for first
# authentication, the periodic Token of vault agent auto-auth is used for
# reneweal)
vault write pki/roles/acme-example-com allowed_domains=acme.dns.podman allow_subdomains=true allow_bare_domains=true max_ttl=5m ttl=2m \
  client_flag=true \
  server_flag=false \
  ext_key_usage=ClientAuth

# Create traditional PKI engine without ACME for the final application certificates
#vault secrets enable -path=pki_int pki
#vault write pki/root/generate/internal common_name=example.com ttl=768h

# Setup basic Cert auth role app-example-com to authenticate clients in the example domain
# https://developer.hashicorp.com/vault/docs/auth/cert
vault auth enable cert
vault write auth/cert/certs/acme-example-com certificate=@ca-cert.pem token_ttl=5m token_max_ttl=10m token_period=5m policies=vault-agent 
echo '
path "pki/issue/acme-example-com" {
  capabilities = ["create", "update"]
}
' | vault policy write vault-app -
 
