{{/* Chart name, truncated to fit a DNS label. */}}
{{- define "infrared.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name prefix. A release named `infrared` gives `infrared`, so the UI
Service is `svc/infrared` and the others are `infrared-api`, `infrared-mcp`,
`infrared-operator`.
*/}}
{{- define "infrared.fullname" -}}
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

{{- define "infrared.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels on every resource. */}}
{{- define "infrared.labels" -}}
helm.sh/chart: {{ include "infrared.chart" . }}
app.kubernetes.io/name: {{ include "infrared.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: infrared
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Component labels. Call with (dict "root" $ "component" "api"). */}}
{{- define "infrared.componentLabels" -}}
{{ include "infrared.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* Selector labels. Call with (dict "root" $ "component" "api"). */}}
{{- define "infrared.selectorLabels" -}}
app.kubernetes.io/name: {{ include "infrared.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* Resource name for a component: <fullname>-<component>. */}}
{{- define "infrared.componentName" -}}
{{- printf "%s-%s" (include "infrared.fullname" .root) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Image reference. Call with (dict "root" $ "image" .Values.api.image).
Renders registry/repository:tag, or registry/repository:tag@digest when a
digest is set (a pin).
*/}}
{{- define "infrared.image" -}}
{{- $registry := trimSuffix "/" .root.Values.image.registry }}
{{- $tag := default .root.Chart.AppVersion .image.tag }}
{{- $ref := printf "%s:%s" .image.repository $tag }}
{{- if $registry }}{{ $ref = printf "%s/%s" $registry $ref }}{{ end }}
{{- if .image.digest }}{{ $ref = printf "%s@%s" $ref .image.digest }}{{ end }}
{{- $ref }}
{{- end }}

{{/* The first image pull secret name, or empty. */}}
{{- define "infrared.firstPullSecret" -}}
{{- with .Values.imagePullSecrets }}{{ (first .).name }}{{ end }}
{{- end }}

{{/*
The default image.registry, darkshift's preprod ECR. Every chart version pins its
own builds there, so a cluster on it upgrades its images with the chart version
alone. `make verify` fails if values.yaml's default and this one differ.
*/}}
{{- define "infrared.defaultRegistry" -}}
977456087177.dkr.ecr.us-east-1.amazonaws.com
{{- end }}

{{/*
The registry to hand to the operator (INFRARED_IMAGE_REGISTRY), or empty for the
default registry. Images from any other registry are pinned in the values, and
those pins have to reach the gitops repo's `infrared` Application, or Argo CD
renders the chart's defaults once it adopts the release. The Application then
carries the same registry, so the operator keeps receiving it.
*/}}
{{- define "infrared.handedRegistry" -}}
{{- $registry := trimSuffix "/" .Values.image.registry }}
{{- if and $registry (ne $registry (include "infrared.defaultRegistry" .)) }}{{ $registry }}{{ end }}
{{- end }}

{{/*
Every component's pin as JSON (INFRARED_IMAGES): {"<component>": {"tag", "digest"}}
for operator, api, ui, mcp and runner. The tag is the one the chart renders (the
appVersion when empty); the digest is empty when the image is not pinned.
*/}}
{{- define "infrared.imagePins" -}}
{{- $pins := dict }}
{{- range $c := list "operator" "api" "ui" "mcp" "runner" }}
{{- $img := (index $.Values $c).image }}
{{- $_ := set $pins $c (dict "tag" (default $.Chart.AppVersion $img.tag) "digest" (default "" $img.digest)) }}
{{- end }}
{{- toJson $pins }}
{{- end }}

{{/* Name of the MCP token Secret. */}}
{{- define "infrared.mcpAccessSecret" -}}
{{- default (printf "%s-mcp-access" (include "infrared.fullname" .)) .Values.mcp.access.existingSecret }}
{{- end }}

{{- define "infrared.mcpTokenSecret" -}}
{{- default (printf "%s-mcp-token" (include "infrared.fullname" .)) .Values.mcp.existingSecret }}
{{- end }}

{{/* In-cluster URLs. */}}
{{- define "infrared.apiURL" -}}
{{- printf "http://%s:%d" (include "infrared.componentName" (dict "root" . "component" "api")) (int .Values.api.service.port) }}
{{- end }}
{{- define "infrared.mcpURL" -}}
{{- printf "http://%s:%d" (include "infrared.componentName" (dict "root" . "component" "mcp")) (int .Values.mcp.service.port) }}
{{- end }}

{{/* The UI's extensions ConfigMap: <fullname>-ui-extensions. */}}
{{- define "infrared.uiExtensionsName" -}}
{{- printf "%s-extensions" (include "infrared.componentName" (dict "root" . "component" "ui")) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Pod-level settings shared by every component: pull secrets, security,
scheduling. Call with (dict "root" $ "c" .Values.api "component" "api"); an
optional "volumes" list is added after the shared /tmp volume.
*/}}
{{- define "infrared.podCommon" -}}
serviceAccountName: {{ include "infrared.componentName" (dict "root" .root "component" .component) }}
{{- /* Only the operator and the API talk to the Kubernetes API. */}}
automountServiceAccountToken: {{ has .component (list "operator" "api") }}
{{- with .root.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  {{- toYaml (default .root.Values.podSecurityContext .c.podSecurityContext) | nindent 2 }}
{{- with .c.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .c.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .c.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .c.topologySpreadConstraints }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumes:
  - name: tmp
    emptyDir:
      sizeLimit: 256Mi
  {{- with .volumes }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}

{{/*
Container settings shared by every component. Same call as podCommon; an
optional "volumeMounts" list is added after the /tmp mount.
*/}}
{{- define "infrared.containerCommon" -}}
image: {{ include "infrared.image" (dict "root" .root "image" .c.image) }}
imagePullPolicy: {{ .root.Values.image.pullPolicy }}
securityContext:
  {{- toYaml (default .root.Values.containerSecurityContext .c.containerSecurityContext) | nindent 2 }}
resources:
  {{- toYaml .c.resources | nindent 2 }}
volumeMounts:
  - name: tmp
    mountPath: /tmp
  {{- with .volumeMounts }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}

{{/* HTTP probes. Call with (dict "port" "http"). */}}
{{- define "infrared.probes" -}}
startupProbe:
  httpGet:
    path: /healthz
    port: {{ .port }}
  periodSeconds: 5
  failureThreshold: 30
livenessProbe:
  httpGet:
    path: /healthz
    port: {{ .port }}
  periodSeconds: 20
  timeoutSeconds: 3
readinessProbe:
  httpGet:
    path: /readyz
    port: {{ .port }}
  periodSeconds: 10
  timeoutSeconds: 3
{{- end }}
