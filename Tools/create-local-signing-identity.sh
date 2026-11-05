#!/bin/zsh
# Explicit, one-time setup for local builds. Never run by build.sh or CI.
set -euo pipefail
identity_name='Sony Menu Local Signing'
existing_identity=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Sony Menu Local Signing"/ {print $2; exit}')
if [[ -n "$existing_identity" ]]; then
  echo "Reusing existing local signing identity: $existing_identity"
  exit 0
fi
keychain_path=$(/usr/bin/security default-keychain -d user | /usr/bin/sed 's/^ *"//; s/"$//')
umask 077
signing_tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sony-menu-signing.XXXXXX")
trap '/bin/rm -f "$signing_tmp/key.pem" "$signing_tmp/cert.pem" "$signing_tmp/identity.p12" "$signing_tmp/openssl.cnf"; /bin/rmdir "$signing_tmp"' EXIT
if /usr/bin/security find-certificate -c "$identity_name" >/dev/null 2>&1; then
  imported_identity=$(/usr/bin/security find-identity -p codesigning | /usr/bin/awk '/"Sony Menu Local Signing"/ {print $2; exit}')
  if [[ -z "$imported_identity" ]]; then
    echo 'The existing certificate has no usable private key. Inspect it in Keychain Access.' >&2
    exit 1
  fi
  # Reuse an existing key; exporting a certificate does not export its key.
  /usr/bin/security find-certificate -c "$identity_name" -p > "$signing_tmp/cert.pem"
else
cat > "$signing_tmp/openssl.cnf" <<'CONFIG'
[req]
distinguished_name=subject
x509_extensions=extensions
prompt=no
[subject]
CN=Sony Menu Local Signing
O=Sony Menu Local Development
[extensions]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
CONFIG
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -config "$signing_tmp/openssl.cnf" -keyout "$signing_tmp/key.pem" \
  -out "$signing_tmp/cert.pem" >/dev/null 2>&1
identity_password=$(/usr/bin/openssl rand -hex 24)
/usr/bin/openssl pkcs12 -export -inkey "$signing_tmp/key.pem" \
  -in "$signing_tmp/cert.pem" -name "$identity_name" \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -passout "pass:$identity_password" -out "$signing_tmp/identity.p12"
# The generated private key is imported into the user's keychain; only codesign
# is added to its allowed applications. No existing key is exported or changed.
/usr/bin/security import "$signing_tmp/identity.p12" -k "$keychain_path" \
  -P "$identity_password" -T /usr/bin/codesign
unset identity_password
fi
# User-level trust is scoped to code signing, not TLS or general system trust.
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign \
  -k "$keychain_path" "$signing_tmp/cert.pem"
/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Sony Menu Local Signing"/ {print "Created local signing identity: " $2}'
