#!/usr/bin/env bash
# Stage the build context (driver, scripts, our config, truststore with the
# lab IDM certificate) and build the image inside the minikube node.
# Usage: rcs/k8s/build.sh     (needs rcs/deploy.sh client run once for the truststore)
set -euo pipefail
cd "$(dirname "$0")/../.."
PROFILE="${MINIKUBE_PROFILE:-rcs}"
TAG="${RCS_IMAGE:-databricks-rcs:dev}"

TRUST=rcs/openicf/security/truststore
keytool_bin="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home/bin/keytool"
"$keytool_bin" -list -alias idm-local -keystore "$TRUST" -storepass changeit >/dev/null 2>&1 \
  || { echo "no IDM cert in $TRUST — run rcs/deploy.sh client first"; exit 1; }

ctx=$(mktemp -d); trap 'rm -rf "$ctx"' EXIT
cp rcs/k8s/Dockerfile rcs/k8s/ConnectorServer.properties rcs/k8s/logback.xml "$ctx/"
cp runtime/openidm/lib/databricks-jdbc-2.7.3.jar "$TRUST" "$ctx/"
mkdir "$ctx/scripts" && cp idm-config/script/*.groovy "$ctx/scripts/"

minikube -p "$PROFILE" image build -t "$TAG" "$ctx"
echo "built $TAG in minikube profile $PROFILE"
