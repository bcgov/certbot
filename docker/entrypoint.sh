#!/bin/bash

: "${CERTBOT_CONFIG_DIR:=/etc/letsencrypt}"
: "${CERTBOT_RENEWAL_DIR:=${CERTBOT_CONFIG_DIR}/renewal}"
: "${CERTBOT_DEPLOY_DIR:=${CERTBOT_CONFIG_DIR}/renewal-hooks/deploy}"
: "${CERTBOT_LOGS_DIR:=/var/log/letsencrypt}"
: "${CERTBOT_WORK_DIR:=/var/lib/letsencrypt}"
: "${CERTBOT_DEBUG:=false}"
: "${CERTBOT_DELETE_ACME_ROUTES:=true}"
: "${CERTBOT_DRY_RUN:=false}"
: "${CERTBOT_RSA_KEY_SIZE:=2048}"
: "${CERTBOT_STAGING:=false}"
: "${CERTBOT_SUBSET:=true}"
: "${CERTBOT_CERT_PER_HOST:=false}"
: "${CERTBOT_COMBINED_CERT_NAME:=openshift-route-certs}"

if [ -z "${CERTBOT_EMAIL}" ]; then
  echo "Missing 'CERTBOT_EMAIL' environment variable"
  exit 1
fi

function deleteAcmeChallengeRoutes() {
  echo "Deleting ACME challenge resources ..."
  oc delete route,svc,networkpolicy -l app=certbot,well-known=acme-challenge
}

function getCertificate() {
  certificateName=${1}
  domainList=${2}

  CERTBOT_ARGS='--no-random-sleep --no-eff-email'
  if [ "${CERTBOT_DRY_RUN}" == "true" ]; then
    CERTBOT_ARGS="${CERTBOT_ARGS} --dry-run"
  fi

  if [ "${CERTBOT_DEBUG}" == "true" ]; then
    CERTBOT_ARGS="${CERTBOT_ARGS} --debug"
  fi

  if [ "${CERTBOT_SUBSET}" == "true" ]; then
    CERTBOT_ARGS="${CERTBOT_ARGS} --allow-subset-of-names"
  fi

  if [ ! -z "$CERTBOT_SERVER" ]; then
    CERTBOT_ARGS="${CERTBOT_ARGS} --server ${CERTBOT_SERVER}"
  fi

  set -x
  # If there is no certificate issued request a new one, otherwise request a renewal.
  if [ ! -f "${CERTBOT_CONFIG_DIR}/live/${certificateName}/cert.pem" ]; then
    certbot --config /tmp/certbot.ini certonly $CERTBOT_ARGS --non-interactive --keep-until-expiring --cert-name ${certificateName} --expand --standalone -d ${domainList}
  else
    certbot --config /tmp/certbot.ini renew $CERTBOT_ARGS --no-random-sleep-on-renew --cert-name ${certificateName}
  fi
  set +x
}

mkdir -p "${CERTBOT_CONFIG_DIR}" "${CERTBOT_WORK_DIR}" "${CERTBOT_LOGS_DIR}" "${CERTBOT_DEPLOY_DIR}"

cat > /tmp/certbot.ini <<EOF
rsa-key-size = ${CERTBOT_RSA_KEY_SIZE}
authenticator = standalone
http-01-port = 8080
https-port = 4443
preferred-challenges = http
agree-tos = true
email = ${CERTBOT_EMAIL}

config-dir = ${CERTBOT_CONFIG_DIR}
work-dir = ${CERTBOT_WORK_DIR}
logs-dir = ${CERTBOT_LOGS_DIR}
EOF

if [ "${CERTBOT_STAGING}" == "true" ]; then
  echo "staging = true" >> /tmp/certbot.ini
fi

cat > ${CERTBOT_DEPLOY_DIR}/set-deployed-flag.sh << EOF
#!/bin/sh
touch ${CERTBOT_WORK_DIR}/deployed
EOF
chmod +x ${CERTBOT_DEPLOY_DIR}/set-deployed-flag.sh

cat > /tmp/certbot-svc.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  creationTimestamp: null
  labels:
    app: certbot
    well-known: acme-challenge
  name: certbot
spec:
  ports:
    - name: http
      port: 8080
      protocol: TCP
      targetPort: 8080
  selector:
    app: certbot
  sessionAffinity: None
  type: ClusterIP
EOF

cat > /tmp/certbot-route.yaml <<'EOF'
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  creationTimestamp: null
  name: certbot-well-known
parameters:
- name: NAME
- name: HOST
objects:
- apiVersion: route.openshift.io/v1
  kind: Route
  metadata:
    annotations:
      haproxy.router.openshift.io/timeout: 5m
    labels:
      app: certbot
      well-known: acme-challenge
    name: ${NAME}
  spec:
    host: ${HOST}
    path: /.well-known/acme-challenge/
    port:
      targetPort: http
    tls:
      insecureEdgeTerminationPolicy: Allow
      termination: edge
    to:
      kind: Service
      name: certbot
      weight: 100
    wildcardPolicy: None
EOF

cat > /tmp/certbot-np.yaml <<'EOF'
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: certbot-allow-ingress
  labels:
    app: certbot
    well-known: acme-challenge
spec:
  podSelector:
    matchLabels:
      app: certbot
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
  policyTypes:
    - Ingress
EOF

# Get a mapping of all managed routes and their hosts
routeMap=$(oc get route -l certbot-managed=true -o=jsonpath='{range .items[*]}{.metadata.name}={.spec.host}{"\n"}{end}')


# Get a mapping of tls secrets and their hosts from all managed ingresses.
# Example:
#   oc -n 4a9599-dev get ingress -l certbot-managed=true -o=jsonpath='{range .items[*]}{range .spec.tls[*]}{.secretName}={.hosts}{"\n"}{end}'
# Result:
#   mediator-credo-tls=["mediator-dev.digitaltrust.gov.bc.ca"]
ingressTlsMap=$(oc get ingress -l certbot-managed=true -o=jsonpath='{range .items[*]}{range .spec.tls[*]}{.secretName}={range .hosts[*]}{.}{" "}{end}{"\n"}{end}{end}')


# Declare and populate a hash table to use as a dictionary for mapping the routes to their hosts.
# - The host name will also be used as the certificate name in the case individual certificates are being requested.
declare -A managedRoutes
for item in ${routeMap}; do
  # Filter out platform routes
  if [[ "${item}" != *apps.silver.devops.gov.bc.ca* ]]; then
    # Use the route's name as the key
    # and the host name as the value
    key=${item%%=*}
    value=${item#*=}
    managedRoutes[${key}]=${value}
  fi
done

# Declare and populate a hash table for mapping ingress TLS secrets to their hosts.
# - The TLS secret name will be used as the certificate name for ingress-managed certificates.
declare -A managedIngressSecrets
while IFS='=' read -r key value; do
  if [ -z "${key}" ] || [ -z "${value}" ]; then
    continue
  fi

  # Normalize and de-duplicate hosts for a given secret.
  ingressHosts=$(echo "${value}" | tr ' ' '\n' | sed '/^$/d' | sort -fu | paste -sd ',' -)
  if [ -z "${ingressHosts}" ]; then
    continue
  fi

  if [ -n "${managedIngressSecrets[${key}]}" ]; then
    mergedHosts=$(printf "%s\n%s\n" "${managedIngressSecrets[${key}]}" "${ingressHosts}" | tr ',' '\n' | sed '/^$/d' | sort -fu | paste -sd ',' -)
    managedIngressSecrets[${key}]="${mergedHosts}"
  else
    managedIngressSecrets[${key}]="${ingressHosts}"
  fi
done <<< "${ingressTlsMap}"

# Generate a list of sorted and unique managed domains (hosts), and a list of sorted and unique routes
allHosts=$(printf "%s\n" "${managedRoutes[@]}" "${managedIngressSecrets[@]}" | tr ',' '\n' | sed '/^$/d' | sort -fu)
echo "${allHosts}" > /tmp/certbot-hosts.txt
cat /tmp/certbot-hosts.txt | paste -sd "," - > /tmp/certbot-hosts.csv
echo "${!managedRoutes[@]}" | tr " " "\n" | sort -fu > /tmp/certbot-routes.txt
echo "${!managedIngressSecrets[@]}" | tr " " "\n" | sort -fu > /tmp/certbot-ingress-secrets.txt

# Track which certificate should be used for each ingress TLS secret.
declare -A ingressSecretCertificates

echo 'CERTBOT_DEBUG =' ${CERTBOT_DEBUG}
# Dump contents of files to help troubleshoot in case of problems
if [ "${CERTBOT_DEBUG}" == "true" ]; then
  echo '*********** full list of detected routes (route=host):'
  for item in ${routeMap}; do
    echo "  ${item}"
  done

  echo '*********** resulting filtered mapping of routes to hosts (certificate names):'
  for route in "${!managedRoutes[@]}"; do
    echo "  ${route}: ${managedRoutes[${route}]}"
  done

  echo '*********** resulting mapping of ingress tls secrets to hosts:'
  for secret in "${!managedIngressSecrets[@]}"; do
    echo "  ${secret}: ${managedIngressSecrets[${secret}]}"
  done

  echo '*********** contents of /tmp/certbot-hosts.csv:'
  cat /tmp/certbot-hosts.csv

  echo '*********** contents of /tmp/certbot-hosts.txt:'
  cat /tmp/certbot-hosts.txt

  echo '*********** contents of /tmp/certbot-routes.txt:'
  cat /tmp/certbot-routes.txt

  echo '*********** contents of /tmp/certbot-ingress-secrets.txt:'
  cat /tmp/certbot-ingress-secrets.txt

  echo '*********** contents of /tmp/certbot-route.yaml:'
  cat /tmp/certbot-route.yaml

  echo '*********** contents of /tmp/certbot-svc.yaml:'
  cat /tmp/certbot-svc.yaml

  echo '*********** contents of /tmp/certbot-np.yaml:'
  cat /tmp/certbot-np.yaml

  echo '*********** contents of /tmp/certbot.ini:'
  cat /tmp/certbot.ini
fi

# Delete well-known/acme-challenge routes
deleteAcmeChallengeRoutes

# Create certbot network policy
oc create -f /tmp/certbot-np.yaml

# Create certbot service
oc create -f /tmp/certbot-svc.yaml

# Create well-known/acme-challenge routes
cat /tmp/certbot-hosts.txt | xargs -n 1 -I {} oc process -f /tmp/certbot-route.yaml -p 'NAME=acme-challenge-{}' -p 'HOST={}' | oc create -f -

# Sleep for 5sec. There was an issue noticed where the pod wasn't able to get a route and was giving 404 error. Not totally certain if this helps.
sleep 5s

rm -f ${CERTBOT_WORK_DIR}/deployed

# Get certificate(s), either combined or individual
if [ "${CERTBOT_CERT_PER_HOST}" == "true" ]; then
  echo "Manage individual certificates for each unique host."
  for certbot_host in $(</tmp/certbot-hosts.txt); do
    getCertificate "${certbot_host}" "${certbot_host}"
  done

  # Ingress TLS secrets may contain multiple hosts. Request one certificate per secret.
  for secret in "${!managedIngressSecrets[@]}"; do
    getCertificate "${secret}" "${managedIngressSecrets[${secret}]}"
    ingressSecretCertificates[${secret}]="${secret}"
  done
else
  echo "Managing a single certificate covering all managed hosts."
  getCertificate "${CERTBOT_COMBINED_CERT_NAME}" "$(</tmp/certbot-hosts.csv)"

  # Re-Map the managed route dictionary so all routes get patched with the combined certificate.
  for route in "${!managedRoutes[@]}"; do
    managedRoutes[${route}]="${CERTBOT_COMBINED_CERT_NAME}"
  done

  for secret in "${!managedIngressSecrets[@]}"; do
    ingressSecretCertificates[${secret}]="${CERTBOT_COMBINED_CERT_NAME}"
  done
fi

if [ -f ${CERTBOT_WORK_DIR}/deployed ]; then
  echo 'New certificate(s) have been issued'
else
  echo 'No new certificate(s) have been issued'
fi

# Patch Routes
for route in "${!managedRoutes[@]}"; do
  certificateName=${managedRoutes[${route}]}

  echo "Updating route/${route} with certificate ${certificateName} ..."
  CERTIFICATE="$(awk '{printf "%s\\n", $0}' ${CERTBOT_CONFIG_DIR}/live/${certificateName}/cert.pem)"
  KEY="$(awk '{printf "%s\\n", $0}' ${CERTBOT_CONFIG_DIR}/live/${certificateName}/privkey.pem)"
  CABUNDLE=$(awk '{printf "%s\\n", $0}' ${CERTBOT_CONFIG_DIR}/live/${certificateName}/fullchain.pem)

  # If any of the cert components is blank, then don't run the patch command
  if [ "${CERTBOT_DRY_RUN}" == "true" ]; then
    echo "Dry Run - the certificate for route/${route} was not patched."
  elif [ "${CERTIFICATE}" == "" ] || [ "${KEY}" == "" ] || [ "${CABUNDLE}" == "" ]; then
    echo "The certificate for route/${route} wasn't created properly so it won't be patched."
  else
    oc patch "route/${route}" -p '{"spec":{"tls":{"certificate":"'"${CERTIFICATE}"'","key":"'"${KEY}"'","caCertificate":"'"${CABUNDLE}"'"}}}'
  fi
done

# Patch or create ingress TLS secrets
for secret in "${!managedIngressSecrets[@]}"; do
  if [ "${CERTBOT_CERT_PER_HOST}" == "true" ]; then
    certificateName=${ingressSecretCertificates[${secret}]}
  else
    certificateName=${CERTBOT_COMBINED_CERT_NAME}
  fi

  echo "Updating secret/${secret} with certificate ${certificateName} for ingress TLS ..."
  TLS_CRT="$(awk '{printf "%s\\n", $0}' ${CERTBOT_CONFIG_DIR}/live/${certificateName}/fullchain.pem)"
  TLS_KEY="$(awk '{printf "%s\\n", $0}' ${CERTBOT_CONFIG_DIR}/live/${certificateName}/privkey.pem)"

  if [ "${CERTBOT_DRY_RUN}" == "true" ]; then
    echo "Dry Run - the certificate for secret/${secret} was not patched."
  elif [ "${TLS_CRT}" == "" ] || [ "${TLS_KEY}" == "" ]; then
    echo "The certificate for secret/${secret} wasn't created properly so it won't be patched."
  else
    if oc get secret "${secret}" > /dev/null 2>&1; then
      oc patch "secret/${secret}" -p '{"type":"kubernetes.io/tls","stringData":{"tls.crt":"'"${TLS_CRT}"'","tls.key":"'"${TLS_KEY}"'"}}'
    else
      echo "secret/${secret} does not exist, creating it as type kubernetes.io/tls ..."
      oc create secret tls "${secret}" --cert="${CERTBOT_CONFIG_DIR}/live/${certificateName}/fullchain.pem" --key="${CERTBOT_CONFIG_DIR}/live/${certificateName}/privkey.pem"
    fi
  fi
done

if [ "${CERTBOT_DEBUG}" == "true" ]; then

  echo '*********** final mapping of routes to hosts (certificate names):'
  for route in "${!managedRoutes[@]}"; do
    echo "  ${route}: ${managedRoutes[${route}]}"
  done

  echo '*********** final mapping of ingress tls secrets to certificate names:'
  for secret in "${!ingressSecretCertificates[@]}"; do
    echo "  ${secret}: ${ingressSecretCertificates[${secret}]}"
  done

  echo "*********** list of all files/folder under ${CERTBOT_CONFIG_DIR}:"
  find ${CERTBOT_CONFIG_DIR}

  echo "*********** list of all files/folder under ${CERTBOT_LOGS_DIR}:"
  find ${CERTBOT_LOGS_DIR}

  echo "*********** list of all files/folder under ${CERTBOT_WORK_DIR}:"
  find ${CERTBOT_WORK_DIR}

  echo "*********** contents of ${CERTBOT_LOGS_DIR}/letsencrypt.log:"
  cat ${CERTBOT_LOGS_DIR}/letsencrypt.log

  for confFile in $(ls ${CERTBOT_RENEWAL_DIR} -1); do
    echo "*********** contents of ${confFile}:"
    cat "${CERTBOT_RENEWAL_DIR}/${confFile}"
  done
fi

if [ "${CERTBOT_DELETE_ACME_ROUTES}" == "true" ]; then
  # Delete well-known/acme-challenge routes
  deleteAcmeChallengeRoutes
else
  echo "ACME challenge resources (services, routes, and network policies) were not deleted, please clean them up manually."
fi
