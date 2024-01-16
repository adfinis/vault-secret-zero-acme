#!/usr/bin/env sh

set -x

tls_dir=/acme.sh/app.dns.podman

# prepare tls directory
mkdir -p $tls_dir

# Create client certificate key for manual CSR requests
#openssl genrsa -out "${tls_dir}/client_auth_key.pem" 4096
# Create client certificate CSR for manual CSR requests
#openssl req -new -key "${tls_dir}/client_auth_key.pem" -config /scripts/request.cfg -out "${tls_dir}/client_auth.csr"

# create acme.sh account
acme.sh --register-account -m my@example.com

# acme.sh request with automatic CSR
acme.sh --server https://vault-server:8200/v1/pki/roles/acme-dns-podman/acme/directory \
  --insecure \
  --standalone --issue -d acme.dns.podman \
  -k 2048

# debug initial call for client certs to initiate trust relationship between vault-agent and vault-server
sleep 3600
