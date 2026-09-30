#!/usr/bin/env bash
# Replace IDM's self-signed HTTPS certificate (alias openidm-localhost) with a
# lab certificate whose SAN covers every name the RCS may use to reach IDM:
# localhost (RCS on the Mac) and host.minikube.internal (RCS pod). The shipped
# certificate is CN=localhost with no SAN, so a pod's TLS handshake fails.
# Lab only — a real deployment uses a CA-signed certificate.
#
# Usage: idm-config/lab-tls-cert.sh      then restart IDM, and re-run
#        rcs/deploy.sh client (and rcs/k8s/build.sh) so the RCS trusts the new cert.
set -euo pipefail
cd "$(dirname "$0")/.."

SEC=runtime/openidm/security
KS="$SEC/keystore.jceks"
[[ -f "$KS" ]] || { echo "no $KS — is IDM extracted?"; exit 1; }
KT="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home/bin/keytool"
SP=$(cat "$SEC/storepass")

cp "$KS" "$KS.bak-$(date +%Y%m%d%H%M%S)"
"$KT" -delete -alias openidm-localhost -keystore "$KS" -storetype JCEKS -storepass "$SP"
"$KT" -genkeypair -alias openidm-localhost -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=localhost, O=dbx-aic-lab lab" \
  -ext "SAN=dns:localhost,dns:host.minikube.internal,ip:127.0.0.1" \
  -keystore "$KS" -storetype JCEKS -storepass "$SP" -keypass "$SP"
"$KT" -list -v -alias openidm-localhost -keystore "$KS" -storetype JCEKS -storepass "$SP" 2>/dev/null \
  | grep -E 'Owner:|DNSName|IPAddress'
echo "replaced openidm-localhost (backup kept next to the keystore); restart IDM"
