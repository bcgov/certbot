{{/*
Expand the name of the chart.
*/}}
{{- define "certbot.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "certbot.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "certbot.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "certbot.labels" -}}
helm.sh/chart: {{ include "certbot.chart" . }}
{{ include "certbot.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "certbot.selectorLabels" -}}
app: {{ include "certbot.name" . }}
app.kubernetes.io/name: {{ include "certbot.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "certbot.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "certbot.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- /*
  The artifactory image pull secret to use, retrieved from the provided ArtifactoryServiceAccount
  */}}
{{- define "certbot.artifactoryPullSecret" }}
{{- $artSa := (lookup "artifactory.devops.gov.bc.ca/v1alpha1" "ArtifactoryServiceAccount" .Release.Namespace .Values.artifactoryProxy.artifactoryServiceAccount) }}
{{- if $artSa.spec }}
- name: artifacts-pull-{{ .Values.artifactoryProxy.artifactoryServiceAccount }}-{{ $artSa.spec.current_plate }}
{{- else }}
{{/*
When running helm template, or using --dry-run, lookup returns an empty object
*/}}
- name: image-pull-secret-here
{{- end }}
{{- end }}

{{- /*
  A reuseable job spec, used in both the cron and batch job templates.
  */}}
{{- define "certbot.jobSpec" }}
backoffLimit: 6
activeDeadlineSeconds: 600
parallelism: 1
completions: 1
template:
  metadata:
    labels: {{ include "certbot.labels" . | nindent 6 }}
  spec:
    {{- if .Values.artifactoryProxy.enabled }}
    imagePullSecrets: {{ include "certbot.artifactoryPullSecret" . | nindent 6 }}
    {{- end }}
    containers:
      - name: certbot
        {{- if .Values.artifactoryProxy.enabled }}
        image: "{{ .Values.artifactoryProxy.artifactoryPrefix }}/{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        {{- else }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        {{- end }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        env:
          - name: CERTBOT_DEBUG
            value: {{ .Values.certbot.debug | quote }}
          - name: CERTBOT_DELETE_ACME_ROUTES
            value: {{ .Values.certbot.deleteAcmeRoutes | quote }}
          - name: CERTBOT_DRY_RUN
            value: {{ .Values.certbot.dryRun | quote }}
          - name: CERTBOT_EMAIL
            value: {{ .Values.certbot.email | quote }}
          - name: CERTBOT_SERVER
            {{- if kindIs "string" .Values.certbot.server }}
            value: {{ .Values.certbot.server }}
            {{- else }}
            valueFrom:
              secretKeyRef:
                name: {{ .Values.certbot.server.secretName }}
                key: {{ .Values.certbot.server.secretKey }}
            {{- end }}
          - name: CERTBOT_STAGING
            value: {{ .Values.certbot.staging | quote }}
          - name: CERTBOT_SUBSET
            value: {{ .Values.certbot.subset | quote }}
          - name: CERTBOT_CERT_PER_HOST
            value: {{ .Values.certbot.certPerHost | quote }}
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
        volumeMounts:
          - mountPath: /etc/letsencrypt
            name: certbot-config
    restartPolicy: Never
    serviceAccountName: {{ template "certbot.fullname" . }}
    volumes:
      - name: certbot-config
        persistentVolumeClaim:
          claimName: {{ template "certbot.fullname" . }}
{{- end }}
