# infrared-chart

The Helm chart for **Infrared**: an operator/CRD-driven gitops control plane for
agentic change management. One `helm install` on a management cluster brings up
four components; the operator then bootstraps the gitops repo, Argo CD and the
app-of-apps, and from that point Argo CD manages Infrared itself.

| Component | Image | Port | Role |
|---|---|---|---|
| operator | `<image.registry>/infrared-operator` | 8081 (`/healthz`, `/readyz`) | Reconciles `infrared.darkshift.io` resources (Organization, Cluster, GitopsRepo, AgentRole, AgentWorkflow, AgentWorkflowRun, ...) |
| api | `<image.registry>/infrared-api` | 8080 | REST API over those resources |
| ui | `<image.registry>/infrared-ui` | 8080 | Web UI; proxies `/api` and MCP to the services below. Its Service is the primary one, named `infrared` |
| mcp | `<image.registry>/infrared-mcp` | 8080 | MCP server for agents, authenticated to the API with its own token |

Images come from `image.registry` (today darkshift's ECR registry; ask your darkshift contact for pull access), tagged `v0.1.0-alpha.<n>` and pinned by digest. The chart is published as an OCI artifact: `oci://ghcr.io/darkshiftio/charts/infrared`, versioned `0.1.0-alpha.<n>` until 0.1.0 is released.

## Install

```bash
helm install infrared oci://ghcr.io/darkshiftio/charts/infrared \
  --version 0.1.0-alpha.103 --namespace infrared --create-namespace \
  --set managementCluster.name=infrared-mgmt

# The one-time setup token
kubectl -n infrared get secret infrared-setup -o jsonpath='{.data.token}' | base64 -d; echo

# The UI
kubectl -n infrared port-forward svc/infrared 8080:80
# open http://localhost:8080
```

Name the release `infrared`: the UI Service is `{{ include "infrared.fullname" . }}`,
which is exactly `infrared` for that release name, and the gitops template's
`infrared` Application uses release name `infrared` so that adoption lines up.

Private images: create a `kubernetes.io/dockerconfigjson` Secret in the
namespace and pass `--set 'imagePullSecrets[0].name=infrared-pull'`. The first name
is also handed to the operator (`INFRARED_IMAGE_PULL_SECRET`) for the clusters
it bootstraps.

**darkshift's own builds are in ECR.** kpack on darkshift-build pushes every
component to `977456087177.dkr.ecr.us-east-1.amazonaws.com/infrared-<component>`
(darkshift preprod; darkshiftio/gitops). On a cluster whose nodes run the kubelet
ECR credential provider with an instance role allowed to pull (infrared-iac-modules
`aws/k3s-node`, `ecr_access = "pull"`, e.g. infrared-mgmt), point the chart at it
and set **no** pull secret:

```yaml
image:
  registry: 977456087177.dkr.ecr.us-east-1.amazonaws.com
operator:
  image:
    tag: v0.1.0
    digest: sha256:...     # from gitops scripts/release-tag.sh
```

(`ci/ecr-values.yaml` renders exactly this in `make verify`.) Nodes without the
credential provider need a dockerconfigjson Secret holding an ECR token, which
expires after 12 hours; use the credential provider instead.

Pinned images, as a pull request sets them (`repo:tag@sha256:...`):

```yaml
api:
  image:
    tag: v0.1.0
    digest: sha256:...
```

## Generated Secrets

| Secret (namespace = release) | Key | Value | Override | Skip rendering |
|---|---|---|---|---|
| `infrared-setup` | `token` | 32 random characters | `setup.token` | `setup.existingSecret` |
| `infrared-session` | `key` | 64 random characters | `session.key` | `session.existingSecret` |
| `<fullname>-mcp-token` | `token` | 48 random characters | `mcp.token` | `mcp.existingSecret` |
| `infrared-api-tokens` | `mcp` | hex sha256 of the MCP token | (derived) | `mcp.existingSecret` |
| `<fullname>-mcp-access` | `token` | 48 random characters | `mcp.access.token` | `mcp.access.existingSecret` |

The names `infrared-setup`, `infrared-session` and `infrared-api-tokens` are
fixed: the API reads them by name from the release namespace. On `helm install`
and `helm upgrade` each value is generated once and then kept (via `lookup`);
tokens the API adds to `infrared-api-tokens` are preserved across upgrades. Every
generated Secret carries `helm.sh/resource-policy: keep`, so neither uninstalling
nor switching to `existingSecret` deletes a live credential.

**Argo CD adoption.** Argo CD renders charts with `helm template`, where `lookup`
returns nothing, so a chart that relied on `lookup` would regenerate every Secret
on every sync. Once Argo CD adopts the release, the gitops values must carry:

```yaml
setup:   { existingSecret: infrared-setup }
session: { existingSecret: infrared-session }
mcp:     { existingSecret: infrared-mcp-token, access: { existingSecret: infrared-mcp-access } }
```

The gitops template's `infrared` Application (sync wave 40) already sets these
(`mcp.access` from template v0.1.7). An install adopted before 0.1.0-alpha.6 has
no `infrared-mcp-access` Secret yet: create it once (key `token`, 48 random
characters) before the pull request that moves to alpha.6 and adds the value.
With them set, the chart renders no Secret at all and the ones from the first
`helm install` stay in place.

## Extensions

`ui.extensions` adds services the org runs to the UI: each gets a rail item
and a proxy behind Infrared's sign-in. The list is empty by default, and then
the chart renders exactly what it renders without it.

```yaml
ui:
  extensions:
    - id: ledger              # ^[a-z][a-z0-9-]{1,30}$
      title: Ledger
      icon: book              # puzzle (default), book, wallet, receipt, users, key, landmark, scroll
      upstream: ledger.ledger.svc.cluster.local:8080   # FQDN:port
      paths: [v1, ui]         # the default
  extensionsProxySecret:
    existingSecret: infrared-ext-proxy   # key `secret`
```

With extensions set, the chart renders ConfigMap `<fullname>-ui-extensions`
(`extensions.json`, `http.conf`, `server.conf`), mounts it read-only at
`/etc/infrared-ui/extensions/`, sets `INFRARED_EXT_PROXY_SECRET` from the
Secret, and annotates the pods with the ConfigMap's checksum so they roll when
it changes. The UI's nginx then:

- serves `/extensions.json`: `id`, `title`, `icon` and `entry` of each
  extension, nothing else (`[]` without extensions);
- proxies `/ext/<id>/<path>/` to `<upstream>/<path>/` for each declared path,
  once the API's `GET /v1/auth/check` accepts the session cookie. Only a
  GitHub sign-in passes. Its login goes upstream as `X-Infrared-Github`,
  together with `X-Infrared-Proxy-Secret`; the browser's `Cookie` and
  `Authorization` do not, and the upstream's `Set-Cookie` never reaches the
  browser;
- answers 404 for anything else under `/ext/<id>/`, and 502 while an upstream
  is down or does not resolve.

`upstream` is a fully qualified name, because nginx's resolver ignores search
domains. The Secret's value is 32 or more of `A-Z a-z 0-9 _ -` (one trailing
newline is ignored), and the UI refuses to start without one. The UI reads it
only at start, so restart the UI Deployment after rotating it; the extension
checks the same value.

## Upgrading

Before Argo CD adopts Infrared: `helm upgrade infrared oci://ghcr.io/darkshiftio/charts/infrared --version <v> -n infrared --reuse-values`.

**After Argo CD adopts Infrared** (the gitops repo's `registry/clusters/<cluster>/components/infrared.yaml`
Application is Synced/Healthy), do not run `helm upgrade`: Argo CD would revert it.
Upgrade with a pull request in the gitops repo that changes the Application's
`targetRevision` (chart version) and, if needed, the image pins (`tag` + `digest`).

CRDs ship in `crds/`. Helm installs them but never upgrades them; Argo CD applies
them on every sync (the gitops template syncs the `infrared` Application with
`ServerSideApply=true`). On a helm-managed install, upgrade CRDs with
`kubectl apply --server-side -f charts/infrared/crds/` before `helm upgrade`.

## Values

| Key | Default | Description |
|---|---|---|
| `nameOverride` | `""` | Overrides the chart name in resource names |
| `fullnameOverride` | `""` | Overrides the resource name prefix (`infrared` for a release named infrared) |
| `managementCluster.name` | `infrared-mgmt` | Management cluster name (`INFRARED_CLUSTER_NAME`) |
| `externalURL` | `""` | The API's public base URL, ending in `/api` (for example `https://infrared.example.com/api`), if exposed (`INFRARED_EXTERNAL_URL`, api). Usually unnecessary: Infrared works it out from the request |
| `gitops.templateVersion` | `v0.1.9` | infrared-gitops-template tag the API asks the operator to render (`INFRARED_GITOPS_TEMPLATE_VERSION`) |
| `builds.registry` | `""` | Registry prefix kpack builds product images into (`INFRARED_BUILD_REGISTRY`); empty leaves the template's builds component out |
| `image.registry` | `977456087177.dkr.ecr.us-east-1.amazonaws.com` | Registry prefix for every component. During the 0.1 track the chart pins the preprod kpack builds by digest (`<c>.image.tag: main`, `<c>.image.digest`). |
| `image.pullPolicy` | `IfNotPresent` | Pull policy for every component |
| `imagePullSecrets` | `[]` | `[{name: ...}]` on every pod; the first is `INFRARED_IMAGE_PULL_SECRET` |
| `setup.token` / `setup.existingSecret` | `""` | Setup token override / existing Secret (see above) |
| `session.key` / `session.existingSecret` | `""` | Session key override / existing Secret |
| `mcp.token` / `mcp.existingSecret` | `""` | MCP token override / existing Secret |
| `mcp.access.token` / `mcp.access.existingSecret` | `""` | Bearer token MCP clients must send to `/mcp` / existing Secret |
| `observability.metricsURL` | `http://vmsingle-victoria-metrics-k8s-stack.monitoring.svc:8428` | Where the API reads SLO error ratios (`INFRARED_METRICS_URL`); empty reports every SLO as no-data |
| `runner.image.repository` / `.tag` / `.digest` | `infrared-runner`, pinned | The image AgentWorkflowRun agent steps run in (`INFRARED_RUNNER_IMAGE`, operator). Steps run as Jobs in `ir-org-<org>` and need that namespace's Secret `model-provider-anthropic` (key `api-key`). |
| `runner.goToolchainImage` | `golang:1.26@sha256:...` | Image an init container copies a Go toolchain from, so agents can build and test Go repos (`INFRARED_GO_TOOLCHAIN_IMAGE`) |
| `podSecurityContext` | runAsNonRoot, seccomp RuntimeDefault | Pod security for every component |
| `containerSecurityContext` | read-only root fs, drop ALL, no privilege escalation, seccomp RuntimeDefault | Container security for every component |
| `commonLabels` | `{}` | Extra labels on every resource |
| `<c>.image.repository` | `infrared-<c>` | Repository under `image.registry` (`<c>` = operator, api, ui, mcp) |
| `<c>.image.tag` | `""` (appVersion) | Image tag |
| `<c>.image.digest` | `""` | `sha256:...`; renders `repo:tag@digest` |
| `<c>.replicas` | `1` | Replicas (the operator uses leader election, so >1 is safe) |
| `<c>.extraArgs` / `<c>.extraEnv` | `[]` | Extra container args / env |
| `<c>.resources` | small requests, memory limits | Container resources |
| `<c>.serviceAccount.annotations` | `{}` | ServiceAccount annotations |
| `<c>.service.port` | operator 8081, api/mcp 8080, ui 80 | Service port |
| `ui.service.type` | `ClusterIP` | Type of the primary Service |
| `ui.extensions` | `[]` | Extensions in the UI's rail, proxied at `/ext/<id>/<path>/` after sign-in: `id`, `title`, `icon`, `upstream` (FQDN:port), `paths` (default `[v1, ui]`), `entry` (default `/ext/<id>/ui/entry.js`). See "Extensions" |
| `ui.extensionsProxySecret.existingSecret` / `.key` | `""` / `secret` | Secret whose value the UI sends to every extension upstream as `X-Infrared-Proxy-Secret` (`INFRARED_EXT_PROXY_SECRET`); required when `ui.extensions` is set |
| `<c>.podAnnotations`, `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints` | empty | Scheduling |
| `<c>.podSecurityContext` / `<c>.containerSecurityContext` | unset | Per-component override of the shared security contexts |
| `operator.rbac.extraRules` | `[]` | Rules appended to the generated operator ClusterRole |

`values.schema.json` rejects unknown keys and malformed digests.

## RBAC

- **operator**: ClusterRole whose rules are generated from infrared-operator
  `config/rbac/role.yaml` (kubebuilder markers), plus a Role for leader election
  in the release namespace.
- **api**: ClusterRole over every `infrared.darkshift.io` resource and status;
  namespaces get/list/create (organizations live in `ir-org-*` namespaces);
  secrets get/list/create/update/patch. The secrets rule is cluster-wide in this
  skeleton; P2 narrows it to the release namespace and the `ir-org-*` namespaces.
- **ui**, **mcp**: no Kubernetes API access (no token is mounted).

## Keeping the chart in step with the operator

```bash
make sync-operator   # hack/sync-operator.sh [../infrared-operator]
```

copies `config/crd/bases/*.yaml` into `charts/infrared/crds/` and replaces the
rules between the markers in `templates/operator/clusterrole.yaml` with those
from `config/rbac/role.yaml`. Review and commit the diff with the operator
change it came from.

## Development

```bash
make verify     # shell checks, helm lint, helm template (6 value sets), assertions, kubeconform
make template   # render with defaults
```

CI (`.github/workflows/ci.yml`) runs `make verify` on every PR and on `main`.

## Releasing

1. Bump `version` (and `appVersion` if the components moved) in `charts/infrared/Chart.yaml`.
2. Merge, then tag `v<version>` (e.g. `v0.1.0`).
3. `.github/workflows/release.yml` verifies, checks the tag matches the chart
   version, and pushes to `oci://ghcr.io/darkshiftio/charts`.

Component images are not built here: kpack builds them on darkshift-build
(darkshiftio/gitops) and `scripts/release-tag.sh` there produces the pins.

## License

Copyright 2026 darkshift. All rights reserved.
