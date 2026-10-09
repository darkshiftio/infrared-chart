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

{{/* The first image pull secret name: registry-token with the registry token, else imagePullSecrets[0]'s, or empty. */}}
{{- define "infrared.firstPullSecret" -}}
{{- if .Values.registryToken.gcpServiceAccount }}registry-token
{{- else }}{{ with .Values.imagePullSecrets }}{{ (first .).name }}{{ end }}
{{- end }}
{{- end }}

{{/*
The default image.registry, darkshift's Artifact Registry in Google Cloud (darkshift-preprod,
us-central1, repository infrared) since 0.1.0-alpha.146; ECR before. Every chart version pins its
own builds there, so a cluster on it upgrades its images with the chart version
alone. `make verify` fails if values.yaml's default and this one differ.
*/}}
{{- define "infrared.defaultRegistry" -}}
us-central1-docker.pkg.dev/darkshift-preprod/infrared
{{- end }}

{{/*
The registry to hand to the operator (INFRARED_IMAGE_REGISTRY), or empty for the
default registry. Images from any other registry are pinned in the values, and
those pins have to reach the gitops repo's `infrared` Application, or Argo CD
renders the chart's defaults once it adopts the release. The Application then
carries the same registry, so the operator keeps receiving it. With the code
index on, the default registry is handed too: the gitops template names the code
index's image by it (<registry>/infrared-codeindex), and has no default of its own.
*/}}
{{- define "infrared.handedRegistry" -}}
{{- $registry := trimSuffix "/" .Values.image.registry }}
{{- if and $registry (or .Values.codeIndex.enabled (ne $registry (include "infrared.defaultRegistry" .))) }}{{ $registry }}{{ end }}
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
The backup bucket's provider, as the operator derives it from the endpoint's
host: linode for *.linodeobjects.com, gcs for storage.googleapis.com (Google
Cloud Storage, reached by the identity of whatever runs: the Jobs'
ServiceAccounts, granted the bucket's role outside Infrared, and no key), s3
for any other host, and empty with no bucket. The chart mounts the bucket's key
only for a provider that takes one, and refuses a key given with gcs.
*/}}
{{- define "infrared.backupProvider" -}}
{{- $b := .Values.backup }}
{{- if or $b.bucket $b.endpoint $b.region }}
{{- $host := regexReplaceAll "^https?://([^/:?#]+).*$" (lower $b.endpoint) "${1}" }}
{{- if hasSuffix ".linodeobjects.com" $host }}linode{{ else if eq $host "storage.googleapis.com" }}gcs{{ else }}s3{{ end }}
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
{{- if ($b.postgres | default dict).archive }}
{{- if eq (include "infrared.backupProvider" .) "gcs" }}
{{- fail "backup.postgres.archive is not offered with Google Cloud Storage yet: Barman writes its WAL archive through S3 with a key, which gcs has none of" }}
{{- end }}
{{- $_ := set $out "postgres" (dict "archive" true) }}{{ end }}
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


{{/*
The registry token's registry host: registryToken.registry, or image.registry's
host. Empty while registryToken.gcpServiceAccount is.
*/}}
{{- define "infrared.registryTokenHost" -}}
{{- if .Values.registryToken.gcpServiceAccount }}
{{- default (first (splitList "/" .Values.image.registry)) .Values.registryToken.registry }}
{{- end }}
{{- end }}

{{/*
The registry token for the operator (INFRARED_REGISTRY_TOKEN), as JSON:
{"gcpServiceAccount", "registry"}. Empty while registryToken.gcpServiceAccount is.
*/}}
{{- define "infrared.registryToken" -}}
{{- with .Values.registryToken.gcpServiceAccount }}
{{- toJson (dict "gcpServiceAccount" . "registry" (include "infrared.registryTokenHost" $)) }}
{{- end }}
{{- end }}

{{/*
What the registry token needs: it is the install's pull secret, so no other is
named, and the images and the chart's repository are on its registry host.
*/}}
{{- define "infrared.registryTokenCheck" -}}
{{- if .Values.registryToken.gcpServiceAccount }}
{{- $host := include "infrared.registryTokenHost" . }}
{{- if or .Values.imagePullSecrets .Values.imageCredentials.username .Values.imageCredentials.password }}
{{- fail "registryToken.gcpServiceAccount makes the Secret registry-token the install's pull secret: leave imagePullSecrets and imageCredentials empty" }}
{{- end }}
{{- if ne (first (splitList "/" .Values.image.registry)) $host }}
{{- fail (printf "registryToken is for %s, but image.registry is on %s: Substrate's images come from <image.registry>/substrate with the token" $host (first (splitList "/" .Values.image.registry))) }}
{{- end }}
{{- if ne (first (splitList "/" .Values.gitops.chartRepository)) $host }}
{{- fail (printf "registryToken is for %s, but gitops.chartRepository is on %s: Argo CD pulls the chart with the token" $host (first (splitList "/" .Values.gitops.chartRepository))) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The registry token's Job: fetch the bound Google service account's access token
from the GKE metadata server and write it to the Secret registry-token, created
or replaced (never applied, which would keep the token in an annotation).
Nothing prints the token. Call with the root context.
*/}}
{{- define "infrared.registryTokenJob" -}}
backoffLimit: 4
activeDeadlineSeconds: 300
template:
  metadata:
    labels:
      {{- include "infrared.selectorLabels" (dict "root" . "component" "registry-token") | nindent 6 }}
  spec:
    serviceAccountName: registry-token
    restartPolicy: OnFailure
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      runAsGroup: 65534
      seccompProfile:
        type: RuntimeDefault
    containers:
      - name: token
        image: {{ .Values.registryToken.image | quote }}
        env:
          - name: HOME
            value: /tmp
          - name: NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
          - name: GCP_SERVICE_ACCOUNT
            value: {{ .Values.registryToken.gcpServiceAccount | quote }}
          - name: REGISTRY
            value: {{ include "infrared.registryTokenHost" . | quote }}
          - name: SECRET
            value: registry-token
        command:
          - /bin/sh
          - -ec
          - |
            umask 077
            md=http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default
            get() { curl -sSf --retry 10 --retry-delay 3 --retry-connrefused -m 10 -H 'Metadata-Flavor: Google' "$@"; }
            # Workload Identity: the metadata server answers as the Google
            # service account bound to this ServiceAccount, or refuses.
            email="$(get "$md/email")"
            if [ "$email" != "$GCP_SERVICE_ACCOUNT" ]; then
              echo "the metadata server answers as '$email', not $GCP_SERVICE_ACCOUNT: grant it roles/iam.workloadIdentityUser for $NAMESPACE/registry-token, on a node pool with GKE_METADATA" >&2
              exit 1
            fi
            # The token, into memory; from there into the Secret's manifest.
            get "$md/token" -o /work/token.json
            if ! jq -n --rawfile t /work/token.json --arg host "$REGISTRY" --arg name "$SECRET" --arg ns "$NAMESPACE" '
                ($t | fromjson | .access_token) as $tok
                | if ($tok | type) != "string" or $tok == "" then error("no access_token") else . end
                | {apiVersion: "v1", kind: "Secret", type: "kubernetes.io/dockerconfigjson",
                   metadata: {name: $name, namespace: $ns,
                     labels: {"app.kubernetes.io/name": "infrared", "app.kubernetes.io/part-of": "infrared",
                              "app.kubernetes.io/component": "registry-token"}},
                   stringData: {".dockerconfigjson": ({auths: {($host): {username: "oauth2accesstoken", password: $tok,
                     auth: ("oauth2accesstoken:" + $tok | @base64)}}} | tojson)}}' >/work/secret.json 2>/dev/null; then
              echo "the metadata server's answer holds no access token" >&2
              exit 1
            fi
            expires="$(jq -r '.expires_in // "?"' /work/token.json)"
            if kubectl get secret "$SECRET" -o name >/dev/null 2>&1; then
              kubectl replace -f /work/secret.json >/dev/null
              done=replaced
            else
              kubectl create -f /work/secret.json >/dev/null
              done=created
            fi
            echo "$NAMESPACE/$SECRET $done: $email's token for $REGISTRY, good for ${expires}s"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 128Mi
        volumeMounts:
          - name: work
            mountPath: /work
          - name: tmp
            mountPath: /tmp
    volumes:
      - name: work
        emptyDir:
          medium: Memory
          sizeLimit: 1Mi
      - name: tmp
        emptyDir:
          sizeLimit: 64Mi
{{- end }}
