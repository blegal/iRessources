#!/bin/sh
# Creates, once per Mac, the personal "Local Code Signing" certificate in the login keychain; the apps
# of blegal share it, and the script does nothing if another repository already created it.
# scripts/build-app.sh then signs every build with it, so the signature stays the same from one
# build to the next and macOS keeps the permissions it granted instead of asking again.
#
# The certificate only serves on this Mac: it does not replace an Apple Developer certificate.
# To remove it: Keychain Access › login › My Certificates › "Local Code Signing" › Delete.
set -eu

NAME=${1:-Local Code Signing}
KEYCHAIN=$HOME/Library/Keychains/login.keychain-db

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "The \"$NAME\" certificate already exists."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
# The system LibreSSL: "security import" reads its PKCS#12, not always the one of OpenSSL 3+.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout "pass:$PASS" -out "$WORK/identity.p12"
# -T: codesign may use the key without asking at every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created the \"$NAME\" certificate; scripts/build-app.sh will use it from now on."
echo "On the first launch of the next build, macOS asks for each permission one last time."
