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
appVersion when empty); the digest is empty when the image is not pinned. With
codeIndex.enabled, the code index's too, as code-index: the gitops template runs
it only while that pin is there.
*/}}
{{- define "infrared.imagePins" -}}
{{- $pins := dict }}
{{- range $c := list "operator" "api" "ui" "mcp" "runner" }}
{{- $img := (index $.Values $c).image }}
{{- $_ := set $pins $c (dict "tag" (default $.Chart.AppVersion $img.tag) "digest" (default "" $img.digest)) }}
{{- end }}
{{- if .Values.codeIndex.enabled }}
{{- $ci := .Values.codeIndex.image }}
{{- $_ := set $pins "code-index" (dict "tag" (default "" $ci.tag) "digest" (default "" $ci.digest)) }}
{{- end }}
{{- toJson $pins }}
{{- end }}

{{/*
What codeIndex.enabled needs, checked at every render: an image registry other
than the default, which the operator hands to the gitops template with the
pins (the template names the code index's image by it), and a pin.
*/}}
{{- define "infrared.codeIndexCheck" -}}
{{- if .Values.codeIndex.enabled }}
{{- if not (include "infrared.handedRegistry" .) }}
{{- fail "codeIndex.enabled needs image.registry to name the registry the code index's image is in, such as ghcr.io/darkshiftio: the gitops template names the image by it, and the default registry is never handed on" }}
{{- end }}
{{- if not (or .Values.codeIndex.image.tag .Values.codeIndex.image.digest) }}
{{- fail "codeIndex.enabled needs codeIndex.image.tag or codeIndex.image.digest: a build of darkshiftio/infrared-codeindex" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The backup bucket as JSON (INFRARED_BACKUP): {"bucket", "endpoint", "region"},
and "prefix" when it is set, or empty when none of the three is set. The
operator seeds the Installation's spec.backup.destination from it, and the
restore's modes read it. values.schema.json asks for all three or none, and a
prefix only with them; the operator refuses anything else at start.
*/}}
{{- define "infrared.backup" -}}
{{- $b := .Values.backup }}
{{- if or $b.bucket $b.endpoint $b.region }}
{{- $out := dict "bucket" $b.bucket "endpoint" $b.endpoint "region" $b.region }}
{{- with $b.prefix }}{{ $_ := set $out "prefix" . }}{{ end }}
{{- toJson $out }}
{{- end }}
{{- end }}

{{/*
The gitops template's components the install leaves out, as JSON
(INFRARED_DISABLED_COMPONENTS): components.disabled, and with the stores and a
registry, where the template can run Agent Substrate, substrate-test-actors,
Substrate's test actors, unless substrate.testActors is true. Empty when there
are none, so nothing is handed on.
*/}}
{{- define "infrared.disabledComponents" -}}
{{- $out := .Values.components.disabled | default list }}
{{- if and .Values.stores.enabled .Values.registry.address (not .Values.substrate.testActors) (not (has "substrate-test-actors" $out)) }}
{{- $out = append $out "substrate-test-actors" }}
{{- end }}
{{- if $out }}{{ toJson $out }}{{ end }}
{{- end }}

{{/*
Where the operator, the API and the cluster reach the Gitea this chart runs
(INFRARED_GITEA_URL): its Service, gitea-http, in the release namespace, without
a trailing slash. Gitea's ROOT_URL (gitea.gitea.config.server.ROOT_URL) is the
same with one; `make verify` checks that they agree.
*/}}
{{- define "infrared.giteaURL" -}}
{{- printf "http://%s-http.%s.svc.cluster.local:%d" .Values.gitea.fullnameOverride .Release.Namespace (int .Values.gitea.service.http.port) }}
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

{{/*
The rest of the install's backups as JSON (INFRARED_COPIES), as the
Installation's spec.backup names them: {"schedule", "mirror": {"schedule"},
"retention", "recipients", "postgres": {"archive": true}}, only the fields that
are set; empty when none is, so nothing is handed on. The operator seeds
spec.backup from it, beside the bucket.
*/}}
{{- define "infrared.copies" -}}
{{- $b := .Values.backup }}
{{- $out := dict }}
{{- with $b.schedule }}{{ $_ := set $out "schedule" . }}{{ end }}
{{- with ($b.mirror | default dict).schedule }}{{ $_ := set $out "mirror" (dict "schedule" .) }}{{ end }}
{{- with $b.retention }}{{ $_ := set $out "retention" . }}{{ end }}
{{- with $b.recipients }}{{ $_ := set $out "recipients" . }}{{ end }}
{{- if ($b.postgres | default dict).archive }}{{ $_ := set $out "postgres" (dict "archive" true) }}{{ end }}
{{- if $out }}{{ toJson $out }}{{ end }}
{{- end }}

{{/*
Zot's retention as JSON (INFRARED_REGISTRY_RETENTION): only the fields that are
set; empty when none is.
*/}}
{{- define "infrared.registryRetention" -}}
{{- $r := .Values.registry.retention | default dict }}
{{- $out := dict }}
{{- with $r.untaggedAfter }}{{ $_ := set $out "untaggedAfter" . }}{{ end }}
{{- with $r.keepTags }}{{ $_ := set $out "keepTags" . }}{{ end }}
{{- with $r.keepNewest }}{{ $_ := set $out "keepNewest" (int .) }}{{ end }}
{{- with $r.gcInterval }}{{ $_ := set $out "gcInterval" . }}{{ end }}
{{- with $r.gcDelay }}{{ $_ := set $out "gcDelay" . }}{{ end }}
{{- if $out }}{{ toJson $out }}{{ end }}
{{- end }}

{{/*
A restore as JSON (INFRARED_RESTORE): {"point": "<stamp>"} for that backup,
{"from": "<RFC 3339>"} for the newest complete one at or before that time, or {}
for the newest; empty without restore.enabled. The variable's presence is what
says the install is a restore. It checks what a restore needs, and fails the
render without it.
*/}}
{{- define "infrared.restore" -}}
{{- if .Values.restore.enabled }}
{{- if not .Values.stores.enabled }}
{{- fail "restore.enabled needs stores.enabled: the backups a restore reads are the stores' backups" }}
{{- end }}
{{- if not .Values.backup.bucket }}
{{- fail "restore.enabled needs backup.bucket, backup.endpoint and backup.region: the bucket the backups are in" }}
{{- end }}
{{- if and .Values.gitea.enabled (ne (int .Values.gitea.replicaCount) 0) }}
{{- fail "restore.enabled with gitea.enabled needs --set gitea.replicaCount=0: Gitea starts once the restore has filled its volume" }}
{{- end }}
{{- if and .Values.restore.point .Values.restore.from }}
{{- fail "restore.point and restore.from both name the backup to restore: give one" }}
{{- end }}
{{- if .Values.restore.point }}{{ toJson (dict "point" .Values.restore.point) }}
{{- else if .Values.restore.from }}{{ toJson (dict "from" .Values.restore.from) }}
{{- else }}{{ "{}" }}{{ end }}
{{- end }}
{{- end }}

{{/* The operator's image, which also runs the restore's modes. */}}
{{- define "infrared.operatorImage" -}}
{{- include "infrared.image" (dict "root" . "image" .Values.operator.image) }}
{{- end }}

