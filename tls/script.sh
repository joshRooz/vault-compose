#!/usr/bin/env bash
set -euo pipefail

create_root_ca_conf() {
  local cnf_file="${1:=./root-ca.cnf}"
  local path="${2:=./root-ca}"

  cat - <<-EOF > "$cnf_file"
	[default]
	name               = dev-root-ca
	default_ca         = ca_default
	
	[ca_dn]
	organizationName   = Vault Compose
	commonName         = Self-Signed Root CA
	
	[ca_default]
	home               = $path
	database           = \$home/db/index
	serial             = \$home/db/serial
	crl_dir            = \$home/crl
	new_certs_dir      = \$home/certs
	RANDFILE           = \$home/private/random
	private_key        = \$home/\$name-key.pem
	certificate        = \$home/\$name.pem
	copy_extensions    = none
	default_days       = 90
	default_md         = sha256
	policy             = policy_c_o_match
	
	[policy_c_o_match]
	countryName            = optional
	stateOrProvinceName    = optional
	organizationName       = match
	organizationalUnitName = optional
	commonName             = supplied
	emailAddress           = optional

	[req]
	default_bits       = 4096
	default_md         = sha256
	prompt             = no
	distinguished_name = ca_dn
	req_extensions     = ca_ext
	
	[ca_ext]
	basicConstraints       = critical, CA:true
	keyUsage               = critical,cRLSign,keyCertSign
	subjectKeyIdentifier   = hash
	
	[sub_ca_ext]
	authorityKeyIdentifier = keyid:always
	basicConstraints       = critical,CA:true,pathlen:0
	extendedKeyUsage       = clientAuth,serverAuth
	keyUsage               = critical,cRLSign,keyCertSign
	subjectKeyIdentifier   = hash
	EOF

  mkdir -p $path/{certs,db,crl}
  openssl rand -hex 16 > "$path/db/serial"
  touch $path/db/index
}

create_signing_ca_confg() {
  local cluster="${1:=dummy}"
  local cnf_file="${2:=./${cluster}-signing-ca.cnf}"
  local path="${3:=./${cluster}-signing-ca}"

  # Create ICA configuration file
  cat - <<-EOF > "$cnf_file"
	[default]
	name               = signing-ca
	default_ca         = ca_default
	
	[ca_dn]
	organizationName   = Vault Compose
	commonName         = Signing CA - ${cluster}
	
	[ca_default]
	home               = ./${cluster}/signing-ca
	database           = \$home/db/index
	serial             = \$home/db/serial
	crl_dir            = \$home/crl
	new_certs_dir      = \$home/certs
	RANDFILE           = \$home/private/random
	private_key        = \$home/\$name-key.pem
	certificate        = \$home/\$name.pem
	copy_extensions    = copy
	default_days       = 60
	default_md         = sha256
	policy             = policy_c_o_match
	
	[policy_c_o_match]
	countryName            = optional
	stateOrProvinceName    = optional
	organizationName       = supplied
	organizationalUnitName = optional
	commonName             = supplied
	emailAddress           = optional
	
	[req]
	default_bits       = 2048
	default_md         = sha256
	prompt             = no
	distinguished_name = ca_dn
	
	[server_ext]
	authorityKeyIdentifier = keyid:always
	basicConstraints       = critical,CA:false
	extendedKeyUsage       = clientAuth,serverAuth
	keyUsage               = critical,digitalSignature,keyEncipherment
	subjectKeyIdentifier   = hash
	
	[client_ext]
	authorityKeyIdentifier = keyid:always
	basicConstraints       = critical,CA:false
	extendedKeyUsage       = clientAuth
	keyUsage               = critical,digitalSignature
	subjectKeyIdentifier   = hash
	EOF

  mkdir -p $path/{certs,db,crl}
  openssl rand -hex 16 > "$path/db/serial"
  touch $path/db/index
}


## Create CA key and 90-day cert
root_config=root-ca.cnf ; root_path=./root-ca

test -d $root_path || mkdir -p $root_path
create_root_ca_conf $root_config $root_path
openssl req -new \
  -config $root_config \
  -extensions ca_ext \
  -x509 \
  -days 90 \
  -nodes \
  -out $root_path/dev-root-ca.pem \
  -keyout $root_path/dev-root-ca-key.pem


for cluster in usca usny usil ustx; do
  # Create Int CA and 60-day cert
  sub_config=signing-ca.cnf
	sub_path=$cluster/signing-ca

  test -d $sub_path || mkdir -p $sub_path
  create_signing_ca_confg $cluster $sub_config $sub_path
  openssl req -new \
    -config $sub_config \
    -nodes \
    -out "$sub_path/signing-ca.csr" \
    -keyout "$sub_path/signing-ca-key.pem"
  
  openssl ca -batch \
    -config $root_config \
    -extensions sub_ca_ext \
    -days 60 \
    -in "$sub_path/signing-ca.csr" \
    -out "$sub_path/signing-ca.pem" \
    -notext
  
  # Create and issue 30-day server cert
  # -addext "subjectAltName=DNS:read.vault.$cluster.example.internal,DNS:vault.$cluster.example.internal,DNS:vault.server.$cluster.example.internal,DNS:vault-$cluster-X" \
  openssl req -new \
    -config $sub_config \
    -nodes \
    -subj "/O=Vault Compose/CN=vault.server.$cluster.example.internal" \
    -addext "subjectAltName=DNS:read.lb-$cluster-1,DNS:lb-$cluster-1,DNS:vault.server.$cluster.example.internal,DNS:*" \
    -out "$cluster/cert.csr" \
    -keyout "$cluster/key.pem"
  
  openssl ca -batch \
    -config $sub_config \
    -extensions server_ext \
    -days 30 \
    -in "$cluster/cert.csr" \
    -out "$cluster/cert.pem" \
    -notext
  
  # Create bundle and copy CA into volume that will be mounted to the server instances
  cat "$cluster/cert.pem" "$sub_path/signing-ca.pem" > "$cluster/bundle.pem"
  
  # Verify certificate chain
  openssl verify -CAfile $root_path/dev-root-ca.pem -untrusted $cluster/bundle.pem $cluster/cert.pem
done
