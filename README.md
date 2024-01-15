# PKI Demo

This repository holds a docker/podman-compose file for demonstrating the use of Vault
to order TLS certificates for applications from the HashiCorp Vault PKI secrets
engines.

## Container setup
| Container Name     | Container/host port mapping | Description                                                                                          |
| ------------------ | --------------------------- | ---------------------------------------------------------------------------------------------------- |
| **`app`**          | `8443 -> 4433`              | The Nginx container in this setup represents the end-consumer, the application                       |
| **`certbot`**      |                             | The application (Nginx) communicates with HashiCorp Vault server API through a certbot container     |
| **`vault server`** | `8200 -> 8200`              | The HashiCorp Vault dev server is run as a dedicated single-node container                           |
## Quick Walktrough
 the [Quick Guide](step-by-step)

## Usage
To start the containers:
```bash
podman-compose up -d
```
or
```bash
docker-compose up -d
```

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
vault write -format=json pki/root/generate/internal common_name=example.com ttl=768h | jq -r '.data.issuing_ca' > ca-cert.pem
```

Make the role issue client certs:
 - https://developer.hashicorp.com/vault/api-docs/secret/pki#client_flag
 - https://developer.hashicorp.com/vault/api-docs/secret/pki#server_flag
 - https://developer.hashicorp.com/vault/api-docs/secret/pki#ext_key_usage

 Deliberately choose low ttl for the certificate (only used for first
 authentication, the periodic Token of vault agent auto-auth is used for
 reneweal)
```bash
vault write pki/roles/app-example-com allowed_domains=acme.dns.podman allow_subdomains=true allow_bare_domains=true max_ttl=5m ttl=2m \
  client_flag=true \
  server_flag=false \
  ext_key_usage=ClientAuth
```

Setup basic Cert auth role app-example-com to authenticate clients in the example domain
 - https://developer.hashicorp.com/vault/docs/auth/cert
```bash
vault auth enable cert
vault write auth/cert/certs/acme-example-com certificate=@ca-cert.pem token_ttl=5m token_max_ttl=10m token_period=5m policies=vault-agent 
echo '
path "pki/issue/acme-example-com" {
  capabilities = ["create", "update"]
}
' | vault policy write vault-app -
```

## ACME
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
acme.sh --server https://vault-server:8200/v1/pki/roles/acme-example-com/acme/directory \
  --insecure \
  --standalone --issue -d acme.dns.podman \
  -k 2048
```

Authenticate at Vault
```bash
curl \
  --insecure \
  --request POST \
  --cacert /acme.sh/acme.dns.podman/ca.cer \
  --cert /acme.sh/acme.dns.podman/acme.dns.podman.cer \
  --key /acme.sh/acme.dns.podman/acme.dns.podman.key \
  https://vault-server:8200/v1/auth/cert/login
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
