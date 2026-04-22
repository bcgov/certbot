# Certbot helm chart

A Reusable [Helm](https://helm.sh/) chart for the Certbot docker container.

## Installation

### You are deploying your application with Helm

If you have one application per namespace, it might make sense to have certbot as a dependency of the application, so that SSL certificate issuance is done when the application is installed, thanks to the `manualRun: true` option.

1. Add certbot as a dependency in your `Chart.yaml`

```yaml
dependencies:
  - name: certbot
    version: 0.1.0
    repository: https://bcdevops.github.io/certbot
```

In your application's `values.yaml`, you can then override the Certbot chart settings, e.g.:

```yaml
certbot:
  image:
    tag: 1.0.0
    pullPolicy: IfNotPresent
  certbot:
    email: your.email@gov.bc.ca
```

2. Update your application (don't forget to update your helm dependencies with `helm dep up`)

### You are not deploying your application with Helm

If this is your first time using helm, check out the [quickstart guide](https://helm.sh/docs/intro/quickstart/). The steps below are similar to the one from the quickstart guide, but specifically for this chart

`$ helm repo add certbot https://bcdevops.github.io/certbot`

Once the repo is added, you can check the available charts with:

```
$ helm search repo certbot
NAME                CHART VERSION   APP VERSION
certbot/certbot     0.1.0           1.0.0
```

Then, install an instance of the chart with:

```
$ helm install -n my-namespace my-certbot certbot/certbot --set certbot.email=your.email@gov.bc.ca

NAME: my-certbot
LAST DEPLOYED: Mon Feb 28 15:38:32 2022
NAMESPACE: my-namespace
STATUS: deployed
REVISION: 1
```

You can use the `--set` or `--values` option to change the default configuration.

## Deletion

`helm -n my-namespace delete my-certbot`

## Configuration and default behaviour

You can find an exhaustive list of the configurable settings in `values.yaml`.

## Helm-managed routes and ingresses with Certbot

If you are using Helm to deploy your application, you likely create the routes via helm as well. Certbot will inject the `tls` settings in your route after Helm creates it, so you need to ensure that Helm does not overwrite the changes that Certbot made next time it updates your route (unless you change the host and actually need to issue a new certificate).
The example below uses Helm's `lookup` function to retrieve the certificates and key from the route before recreating the template.

```yaml
{{- $route := (lookup "route.openshift.io/v1" "Route" .Release.Namespace "your-route" ) }}
{{- $certificate := "" }}
{{- $key := "" }}
{{- $caCertificate := "" }}
{{- if $route }}
{{- $certificate = $route.spec.tls.certificate }}
{{- $key = $route.spec.tls.key }}
{{- $caCertificate = $route.spec.tls.caCertificate }}
{{- end -}}

apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: your-route
  labels: {{ include "your-chart.labels" . | nindent 4 }}
    certbot-managed: "true"

spec:
  host: your-host.gov.bc.ca
  port:
    targetPort: your-port
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    {{- if $route }}
    certificate: {{ $certificate | quote }}
    key: {{ $key | quote }}
    caCertificate: {{ $caCertificate | quote }}
    {{- end }}
  to:
    kind: Service
    name: your-service
    weight: 100
  wildcardPolicy: None
```

For Kubernetes `Ingress` resources, Certbot updates the TLS `Secret` referenced by each managed `spec.tls[*].secretName` entry rather than modifying the `Ingress` object itself. If you manage those secrets with Helm, ensure your chart preserves the secret contents or excludes those TLS secrets from regular reconciliation so Helm does not overwrite certificates issued by Certbot.

## Artifactory Usage

If you want to use Artifactory's local caching to download the docker image, you can set `artifactoryProxy.enabled: true` and provide the name of your `ArtifactoryServiceAccount` with `artifactoryProxy.artifactoryServiceAccount`. The chart will then add your artifactory pull secret to the job's `imagePullSecrets`.

## Usage with Entrust

When issuing certificate using the Entrust ACME server, you may want to keep the server URL in a Secret. The `certbot.server` supports this by allowing either a string, or the following object:

```yaml
certbot:
  server:
    secretName: your-acme-server-secret
    secretKey: acme-server-url
```
