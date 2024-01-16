# PKI Demo

This repository holds a docker/podman-compose file for demonstrating the use of Vault
to order TLS certificates for applications from the HashiCorp Vault PKI secrets
engines. This demo shows how to tackle the Secret Zero problem for Vault, this will use the CA from Vault to issue a certificate to a specific DNS name which can be used for authentication.

## Container setup
| Container Name     | Container/host port mapping | Description                                                                                          |
| ------------------ | --------------------------- | ---------------------------------------------------------------------------------------------------- |
| **`acme`**      |                             | The ACME container is used for requesting certificates and logging into vault     |
| **`vault server`** | `8200 -> 8200`              | The HashiCorp Vault dev server is run as a dedicated single-node container                           |
## Quick Walktrough
 the [Quick Guide](step-by-step)

## Usage
To start the containers:
This will start a Vault dev server and a container for ACME 
```bash
podman-compose up -d
```
or
```bash
docker-compose up -d
```
## Basic Vault Provisioning
Setup the configuration on the Vault development server:
Vault server location and credentials
```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=1
export VAULT_TOKEN=root
```

Enable auditing for debugging purposes
```bash
vault audit enable file path=stdout
```

Setup a very basic PKI role for issuing client certificates
https://developer.hashicorp.com/vault/docs/secrets/pki/setup
```bash
vault secrets enable -path=pki pki
```

Ensure cluster-local configuration prerequisites for ACME
https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-caddy#configure-acme
```bash
vault write pki/config/cluster \
   path=https://vault-server:8200/v1/pki \
   aia_path=https://vault-server:8200/v1/pki
```
## Enable ACME on vault
Enable ACME headers
```bash
vault secrets tune \
 -passthrough-request-headers=If-Modified-Since \
 -allowed-response-headers=Last-Modified \
 -allowed-response-headers=Location \
 -allowed-response-headers=Replay-Nonce \
 -allowed-response-headers=Link \
 pki
```

Enable ACME and allow to request clientAuth extended key usage
https://developer.hashicorp.com/vault/api-docs/secret/pki#set-acme-configuration
```bash
vault write pki/config/acme \
 enabled=true \
 allow_role_ext_key_usage=true
```

Create internal CA and role to issue client certitificates in the acme.example.com network
```bash
vault write -format=json pki/root/generate/internal common_name=podman.dns ttl=768h | jq -r '.data.issuing_ca' > ca-cert.pem
```
## Provision cert auth role to enable acme.dns.podman
Make the role issue client certs:
 - https://developer.hashicorp.com/vault/api-docs/secret/pki#client_flag
 - https://developer.hashicorp.com/vault/api-docs/secret/pki#server_flag
 - https://developer.hashicorp.com/vault/api-docs/secret/pki#ext_key_usage

 Deliberately choose low ttl for the certificate (only used for first
 authentication)
```bash
vault write pki/roles/acme-dns-podman allowed_domains=acme.dns.podman allow_subdomains=true allow_bare_domains=true max_ttl=60m ttl=30m \
  client_flag=true \
  server_flag=false \
  ext_key_usage=ClientAuth
```

Setup basic Cert auth role app-example-com to authenticate clients in the example domain
 - https://developer.hashicorp.com/vault/docs/auth/cert
```bash
vault auth enable cert
vault write auth/cert/certs/acme-dns-podman certificate=@ca-cert.pem allowed_common_names="acme.dns.podman" token_ttl=15m token_max_ttl=30m token_period=15m

```

```bash
# Example for a different CN
vault write auth/cert/certs/app-dns-podman certificate=@ca-cert.pem allowed_common_names="app.dns.podman" token_ttl=15m token_max_ttl=30m token_period=15m policies=vault-app
```

```bash
# Globbing for CN 
# https://github.com/gobwas/glob
vault write auth/cert/certs/cluster-a-dns-podman certificate=@ca-cert.pem allowed_common_names="*.cluster-a.dns.podman" token_ttl=15m token_max_ttl=30m token_period=15m policies=vault-cluster-a
```
## Activate KV Secrets Engine and provision secrets and policies
Policy to read and write passwords for path secret/data/acme_demo_a
```bash
echo '
path "kv-v2/data/acme_demo_a/*" {
  capabilities = ["read"]
}
' | vault policy write acme_demo_a_read -
```
Activate kv2 secrets engine and store secrets at 2 different paths
```bash
vault secrets enable kv-v2
vault kv put kv-v2/acme_demo_a/test key=you_should_see_this
vault kv put kv-v2/acme_demo_b/test key=you_cant_see_this
```

## Create Alias and Entity
Read authentication method accessor for alias creation
```bash
vault auth list -format=json | jq -r '.["cert/"].accessor' > acme.txt
```

Create entity with connected policy and store the entitiy_id
```bash
vault write -format=json identity/entity name="acme.dns.podman" policies="acme_demo_a_read" | jq -r ".data.id" > entity_id.txt
```

Create alias with entity_id and auth_accessor
```bash
vault write identity/entity-alias name="acme.dns.podman" canonical_id=$(cat entity_id.txt) mount_accessor=$(cat acme.txt)
```

## ACME Instructions
Use the shell of the acme pod
```bash
podman exec -it acme /bin/sh
```

create acme.sh account
```bash
acme.sh --register-account -m my@example.com
```

acme.sh request with automatic CSR
```bash
acme.sh --server https://vault-server:8200/v1/pki/roles/acme-dns-podman/acme/directory \
  --insecure \
  --standalone --issue -d acme.dns.podman \
  -k 2048
```

Authenticate at Vault and save the token
```bash
    curl \
    --insecure \
    --request POST \
    --cacert /acme.sh/acme.dns.podman/ca.cer \
    --cert /acme.sh/acme.dns.podman/acme.dns.podman.cer \
    --key /acme.sh/acme.dns.podman/acme.dns.podman.key \
    https://vault-server:8200/v1/auth/cert/login | jq -r '.auth.client_token' > token.txt
```
Request secret "acme_demo_a/test" which should work
```bash
curl -k -X GET -H "X-Vault-Token: $(cat token.txt)" https://vault-server:8200/v1/kv-v2/data/acme_demo_a/test
```

Request secret "acme_demo_b/test" which shouldn't work as the policy doesn't allow this
```bash
curl -k -X GET -H "X-Vault-Token: $(cat token.txt)" https://vault-server:8200/v1/kv-v2/data/acme_demo_b/test
```
## Reset

For Podman:
```bash
podman-compose down
podman volume rm pki-demo_tls
```

For Docker:
```bash
docker-compose down
docker volume rm pki-demo_tls
```
