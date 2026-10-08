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
namespace, or let the chart render it from `imageCredentials` ("Secrets from
values"), and pass `--set 'imagePullSecrets[0].name=infrared-pull'`. The first name
is also handed to the operator (`INFRARED_IMAGE_PULL_SECRET`) for the clusters
it bootstraps, and for runner Jobs: the operator copies the Secret into each
org namespace and sets it on every Job, so the runner image pulls with it too.

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

**Clusters outside AWS pull from ghcr.** They cannot reach that ECR registry, so
every component, the runner included, comes from `ghcr.io/darkshiftio` pinned by
digest, with one read-only dockerconfigjson Secret for all of them:

```yaml
image:
  registry: ghcr.io/darkshiftio
imagePullSecrets:
  - name: ghcr-pull        # kubernetes.io/dockerconfigjson, in the release namespace
operator:
  image:
    tag: one-install-1a2b3c4
    digest: sha256:...     # from the image workflow's run summary
runner:
  image:
    tag: one-install-1a2b3c4
    digest: sha256:...
# api, ui and mcp the same way
```

(`ci/ghcr-values.yaml` renders exactly this in `make verify`.) The registry and
the digests have to reach the gitops repo's `infrared` values too, or Argo CD
renders the defaults again once it adopts the release. So for any registry other
than the default, the chart hands the registry and every component's pin to the
operator (`INFRARED_IMAGE_REGISTRY`, and `INFRARED_IMAGES` as JSON:
`{"operator": {"tag": "...", "digest": "sha256:..."}, "api": ..., "ui": ...,
"mcp": ..., "runner": ...}`), and the operator hands them to the gitops template,
which writes them into the `infrared` Application. The Application then carries
the same registry, so the operator keeps receiving them after adoption. On the
default registry neither is set, and the chart version's own pins apply.

The pull Secret itself can come from values, so a fresh install needs nothing
made by hand; see "Secrets from values".

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
| `infrared-gitea-admin`, only with `gitea.enabled` | `username`, `password`, `email` | `gitea.gitea.admin.username` and `.email`, and 32 random characters | (none) | `giteaAdmin.existingSecret` |

The names `infrared-setup`, `infrared-session` and `infrared-api-tokens` are
fixed: the API reads them by name from the release namespace. On `helm install`
and `helm upgrade` each value is generated once and then kept (via `lookup`);
tokens the API adds to `infrared-api-tokens`, and the `owner.<name>` key it writes
beside each with the admin the token was minted for, are preserved across upgrades. Every
generated Secret carries `helm.sh/resource-policy: keep`, so neither uninstalling
nor switching to `existingSecret` deletes a live credential.

infrared-mcp gets its two tokens both ways. `<fullname>-mcp-token` and
`<fullname>-mcp-access`, or the `existingSecret` each names, are mounted
read-only at `/var/run/infrared/api-token/token` (`INFRARED_API_TOKEN_FILE`) and
`/var/run/infrared/mcp-access/token` (`INFRARED_MCP_TOKEN_FILE`), and infrared-mcp
`640546c` and later reads each file again at every use, in place of its variable.
A new value counts within the kubelet's sync period, about a minute, with no
restart: a rotation, and a restore, which writes the saved tokens back after
`helm install` has started the pod. The same Secrets also set
`INFRARED_API_TOKEN` and `INFRARED_MCP_TOKEN`, as before, for an image from
before the files, mid-roll, pinned by an older Application or after a rollback:
it reads those, keeps the tokens it started with until it restarts, and still
asks for a token on `/mcp`.

**Argo CD adoption.** Argo CD renders charts with `helm template`, where `lookup`
returns nothing, so a chart that relied on `lookup` would regenerate every Secret
on every sync. Once Argo CD adopts the release, the gitops values must carry:

```yaml
setup:   { existingSecret: infrared-setup }
session: { existingSecret: infrared-session }
mcp:     { existingSecret: infrared-mcp-token, access: { existingSecret: infrared-mcp-access } }
giteaAdmin: { existingSecret: infrared-gitea-admin }   # with gitea.enabled
```

The gitops template's `infrared` Application (sync wave 40) already sets these
(`mcp.access` from template v0.1.7). An install adopted before 0.1.0-alpha.6 has
no `infrared-mcp-access` Secret yet: create it once (key `token`, 48 random
characters) before the pull request that moves to alpha.6 and adds the value.
With them set, the chart renders no Secret at all and the ones from the first
`helm install` stay in place.

## Secrets from values

Two Secrets that a person used to make by hand before `helm install` can come from
values. Each is rendered only when its value is set, so by default the chart
renders neither. Pass the values with `--set-file`, so they are never written into
a values file; the chart trims surrounding whitespace, such as a file's final
newline.

| Secret (namespace = release) | Type, key | From | Read by |
|---|---|---|---|
| The name in `imagePullSecrets[0]` | `kubernetes.io/dockerconfigjson`, `.dockerconfigjson`: one entry for `imageCredentials.registry` (default `ghcr.io`) | `imageCredentials.username` and `imageCredentials.password`, both or neither. Neither: the Secret must already exist, as before | The kubelet for every pod; the operator for Argo CD's chart repository Secret and for runner Jobs, which it copies the Secret to |
| `infrared-platform-tokens` | `Opaque`: `cloudflare-api-token`, `backup-access-key-id` and `backup-secret-access-key`, a key for each token set; with `codeIndex.enabled`, also the code index's five keys (see "The code index") | `platformTokens.cloudflareApiToken`; `platformTokens.backupAccessKeyId` and `platformTokens.backupSecretAccessKey`, both or neither; the code index's record (`codeIndex.knowledge`) and GitHub App (`platformTokens.codeIndexGithubAppId`, `.codeIndexGithubAppInstallationId` and `.codeIndexGithubAppPrivateKey`, all three or none); `platformTokens.existingSecret: infrared-platform-tokens` when it already exists | The gitops template's External Secrets component: the ClusterSecretStore `infrared-platform` reads this Secret, and an ExternalSecret copies each token to the namespace that uses it |

```bash
helm install infrared oci://ghcr.io/darkshiftio/charts/infrared --version <version> \
  -n infrared --create-namespace -f values.yaml \
  --set-file imageCredentials.password="$HOME/path/to/registry-token" \
  --set-file platformTokens.cloudflareApiToken="$HOME/path/to/cloudflare-token" \
  --set-file platformTokens.backupAccessKeyId="$HOME/path/to/backup-key-id" \
  --set-file platformTokens.backupSecretAccessKey="$HOME/path/to/backup-key-secret"
```

with `imagePullSecrets: [{name: ghcr-pull}]` and `imageCredentials.username` in
`values.yaml`. Write `$HOME`, not `~`: the shell does not expand a `~` after
`=` in these arguments. A token kept elsewhere, such as in SSM, goes in on a
pipe, so it is never in a file: `--set-file key=<(command that prints it)`.
Both Secrets carry `helm.sh/resource-policy: keep`. After Argo CD adopts the
release it renders the chart without these values, so it renders neither
Secret, and the ones from the install stay in place.

Pass the backup bucket's key at install only. Once Infrared runs, a platform
admin may set a new key in Settings, Backups, which Infrared writes into the
same two keys of `infrared-platform-tokens`; a later plain `helm upgrade` that
passes `platformTokens.backupAccessKeyId` and `.backupSecretAccessKey` again
overwrites that key with the one from the files.

## The Installation's edge and previews

The operator writes `installation.edge` and `installation.previews` to the
Installation when it starts (`INFRARED_EDGE`, and `INFRARED_PREVIEWS` as JSON), each
only while the Installation's field is empty, and never overwrites one. So a
fresh install needs no patch afterwards, and a person's later change stands. Both
are empty by default, and then the chart renders exactly what it rendered before.

```yaml
installation:
  edge: gateway                      # or traefik; empty means traefik
  previews:
    domain: preview.example.com      # zone z answers at https://<z>.preview.example.com
    signInURL: https://infrared.example.com
```

## The stores, the backup bucket and the components left out

Three settings the operator hands to the gitops template, which installs what
they name. All are empty by default, and then the chart renders exactly what it
rendered before.

```yaml
stores:
  enabled: true                      # INFRARED_STORES: one Postgres and one object store in the cluster
backup:                              # INFRARED_BACKUP, as JSON: all three, or none
  bucket: example-backup
  endpoint: https://s3.example.com
  region: us-east-1                  # the region S3 requests are signed for
  prefix: ""                         # empty: managementCluster.name
components:
  disabled: [infisical]              # INFRARED_DISABLED_COMPONENTS, as JSON
```

The bucket's key is two tokens, `platformTokens.backupAccessKeyId` and
`platformTokens.backupSecretAccessKey`, passed with `--set-file` (see "Secrets
from values"). The operator refuses to start on a malformed value and says
why. After Argo CD adopts the release, the gitops repo's `infrared` Application
has to carry the three settings, or the operator stops receiving them. The
bucket also seeds the Installation's `spec.backup.destination` (see "Backups").

A bucket in Google Cloud Storage takes no key: `backup.endpoint` is
`https://storage.googleapis.com`, `backup.region` the bucket's location (such
as `us-central1`), and whatever reaches the bucket does so as its own
identity, granted the bucket's role outside Infrared (Workload Identity on
GKE): the ServiceAccounts `infrared-backup`, `infrared-restore` and
`infrared-gitea-restore`, the operator's and the API's, all in the release
namespace. The chart then mounts no key in the restore Jobs, refuses
`platformTokens.backupAccessKeyId` and `.backupSecretAccessKey`, and refuses
`backup.postgres.archive`, which Barman writes through S3 with a key. The
operator seeds the destination as provider `gcs` with credentials of kind
`serviceAccount`.

### Substrate's test actors

With the stores and a registry, the gitops template can run Agent Substrate
(when the operator's preflight says the cluster can host it). Its two test
actors, `counter-v1` and `sandbox-v1`, exist only for the template's counter
test and fence check, and `sandbox-v1` runs any command it is sent. So they are
off by default: with `stores.enabled` and `registry.address`, the chart adds
`substrate-test-actors` to the components it hands the operator
(`INFRARED_DISABLED_COMPONENTS`), and the template leaves them out. Turn them
on for those checks with:

```yaml
substrate:
  testActors: true                   # the template makes counter-v1 and sandbox-v1
```

The gitops repo's `infrared` Application carries `substrate.testActors: true`
once the template sees them on, so adoption keeps them.

## The code index

```yaml
codeIndex:
  enabled: true                      # INFRARED_IMAGES gains code-index: the gitops template runs the code index
  knowledge:                         # its record, which the install writes into infrared-platform-tokens
    url: https://github.com/example-org/knowledge.git
    ref: main                        # empty: main
  image:                             # the chart's own pin by default
    tag: one-install-<short sha>     # a build of darkshiftio/infrared-codeindex
    digest: sha256:...
```

Infrared's code index: Zoekt and the code service, behind infrared-api's code
endpoints. The chart renders nothing of it. On, it hands the code index's image
to the operator among Infrared's own (`INFRARED_IMAGES`, key `code-index`), and
the gitops template runs it in the namespace `code-index`, at
`http://code-index.code-index.svc:8080`, which only infrared-api's pods reach.
The template names the image `<image.registry>/infrared-codeindex`, so the
code index needs an `image.registry` other than the default, which is the one
the operator is handed (`ghcr.io/darkshiftio`, where the image is published),
and a tag or a digest: the chart refuses to render without either. Off, the
default, changes nothing.

Its record and its credential come from the install, through the platform's
tokens, so a fresh install or a restore brings the code index up with both and
no step by hand. With `codeIndex.enabled`, `infrared-platform-tokens` holds five
keys more, which the gitops template copies into the namespace `code-index`
through the ClusterSecretStore `infrared-platform`:

| Key | From | Copied to |
|---|---|---|
| `code-index-knowledge-url`, `code-index-knowledge-ref` | `codeIndex.knowledge.url` and `.ref` (empty: `main`): the knowledge repository the code index reads its manifest of repositories and its repo cards from | Secret `code-index-settings`, keys `knowledge-url` and `knowledge-ref` |
| `code-index-github-app-id`, `code-index-github-app-installation-id`, `code-index-github-app-private-key` | `platformTokens.codeIndexGithubAppId`, `.codeIndexGithubAppInstallationId` and `.codeIndexGithubAppPrivateKey`: a GitHub App whose installation may read the private repositories, from which the code index mints read-only installation tokens | Secret `code-index-credentials`, keys `github-app-id`, `github-app-installation-id` and `github-app-private-key` |

The App's three go together, need `codeIndex.enabled`, and are passed with
`--set-file` (the IDs also with `--set-string`); from SSM, on a pipe:

```bash
ssm() { aws ssm get-parameter --profile <profile> --name "$1" --with-decryption --query Parameter.Value --output text; }
helm install ... \
  --set-file platformTokens.codeIndexGithubAppId=<(ssm /path/to/app-id) \
  --set-file platformTokens.codeIndexGithubAppInstallationId=<(ssm /path/to/installation-id) \
  --set-file platformTokens.codeIndexGithubAppPrivateKey=<(ssm /path/to/private-key)
```

Without an App the three keys are written empty, and the code index reads
public repositories only, so a private knowledge repository is out of its reach
too. Wherever the
chart renders the Secret with the code index on, it refuses a missing
`codeIndex.knowledge.url`; the record alone, with no token, renders it too. With
`platformTokens.existingSecret`, the Secret made by hand holds the five keys,
the App's three empty for none.

The chart writes the record and the App only at the install. Once Argo CD
adopts the release, the gitops repo's `infrared` Application carries `codeIndex`
and `platformTokens.existingSecret: infrared-platform-tokens`, so Argo CD's
render never makes the Secret again, even with the record in the org's values
file. A later change to the record or the App goes into the Secret, as a
token's does: External Secrets copies it within the hour, and the code index
reads its record again every hour and its credential at every use.

## The install's own registry

```yaml
registry:
  address: 10.43.0.50:5000           # INFRARED_REGISTRY, operator and API: host and port, no scheme
```

The registry inside the cluster (Zot), as builds and nodes reach it. The
operator then keeps a registry user, rule and push credential per
organization, builds each organization's Products as its own builder, lets a
step whose AgentRole may publish push under `<org>/<product>`, and hands the
address to the gitops template, which runs the registry. Empty, the default,
renders nothing and changes nothing. As with the stores, the gitops repo's
`infrared` Application has to carry it once Argo CD adopts the release.

## Backups

Each backup is one artifact, `<prefix>/backups/<stamp>.irbackup`, encrypted with
age to every recipient, with a clear manifest `<stamp>.json` beside it, written
straight to the backup bucket outside the cluster: Infrared's own objects,
Gitea's dump and a dump of each consumer database of the platform's Postgres.
The setting is the Installation's `spec.backup`, which a platform admin changes
in Infrared (Settings, Backups); the chart's `backup` values only seed it, once,
while it is empty. Every field is empty by default, which keeps its default, so
an install that sets nothing renders what it rendered before; with no recipient
no backup is made. Schedules are UTC and retentions whole days.

```yaml
backup:
  bucket: example-backup             # with endpoint and region, as above: INFRARED_BACKUP
  prefix: ""                         # the path in the bucket; empty: managementCluster.name
  schedule: "5 * * * *"              # a backup; the rest is INFRARED_COPIES
  mirror: {schedule: "17 * * * *"}   # the buckets' mirror, which the gitops template runs
  retention: 7d                      # each backup, and what the mirror replaced
  recipients: [age1...]              # public keys only; empty makes no backup
  postgres: {archive: false}         # Barman's WAL archive besides the dumps; off
registry:
  retention: {untaggedAfter: 24h, keepTags: ["^v[0-9]"], keepNewest: 10, gcInterval: 1h, gcDelay: 1h}
```

The chart hands them to the operator as JSON in the Installation's own shape:
`INFRARED_BACKUP` the bucket (`{"bucket", "endpoint", "region"}`, and `"prefix"`
when set), `INFRARED_COPIES` the rest (`{"schedule", "mirror": {"schedule"},
"retention", "recipients", "postgres": {"archive"}}`, each only when set). The
gitops template carries them in its `infrared` Application under `backup`, so
they survive Argo CD's adoption, and `registry.retention`
(`INFRARED_REGISTRY_RETENTION`) the same way.

The chart renders no CronJob. The operator writes the backup's,
`infrared-backup`, from `spec.backup`, and runs a backup on request; its Jobs,
`infrared-backup-<stamp>`, export Infrared's objects as the ServiceAccount
`infrared-backup`, which the chart renders always, because the destination and
the recipients can be set in Infrared after the install. It may read and
nothing more. The bucket's key stays in `infrared-platform-tokens`. Any one
recipient's private key opens a backup; it is never a value: see "Restore at
install".

## Restore at install

An install restores itself from one of the backup bucket's backups, made by an
install of the same name, before anything acts on them. The person who holds the age key
makes its Secret first, then installs with the usual values:

```bash
kubectl create namespace infrared
kubectl -n infrared create secret generic infrared-backup-identity \
  --from-file=identity="$HOME/path/to/age-identity"
helm install infrared oci://ghcr.io/darkshiftio/charts/infrared --version <version> \
  -n infrared -f values.yaml <the usual --set-file tokens> \
  --set restore.enabled=true --set gitea.replicaCount=0   # [--set restore.point=20261006T010500Z | --set restore.from=2026-10-03T05:00:00Z]
```

The identity is a Secret, never a value: Helm keeps every value in its release
record, which outlives the restore. `restore.enabled` needs `stores.enabled` and a
backup bucket, and with Gitea `gitea.replicaCount=0`: the chart refuses the install
without them. `restore.point` names one backup by its stamp (what `ir restore
--backup-artifact` passes); `restore.from` takes the newest complete backup at or
before a time; neither, the newest; never both. It then renders:

| What | Name | Does |
|---|---|---|
| `INFRARED_RESTORE` (`{"point": ...}`, `{"from": ...}` or `{}`) | the operator, the API | the operator starts no controller and the API no setup wizard and no run until the restore allows |
| Job | `infrared-restore`, ServiceAccount, ClusterRole and ClusterRoleBinding of the same name | the operator's `restore` mode: picks the backup, writes the ConfigMap `infrared-restore` (phase `Planned`), waits for Gitea's restore, starts Gitea, restores Infrared's objects (phase `ObjectsRestored`), then the platform's Postgres (below) and marks `postgres` in the ConfigMap `stores/restore-stores` |
| Its sidecar `postgres` | a native sidecar of the same pod (an init container with `restartPolicy: Always`), from `restore.postgresImage` | waits for the restore container to decrypt each consumer database's dump into the memory-backed emptyDir `postgres-restore` (`/restore/postgres`: `<database>.dump`, a `.pgpass` and then `ready`, whose first line is `point <stamp>` and each later line `<database> <role>`), then restores each into the empty Postgres at `postgres-rw.stores.svc` as that database's role, `pg_restore --no-owner --role=<role>`, in one transaction with a note on the database, and writes `done` (or `failed`, with the reason). A database that holds tables and no note of this restore is refused; one with the note is left as it is, so a retry restores nothing twice. The pod's outcome is the restore container's exit code alone |
| Job (with Gitea) | `infrared-gitea-restore`, ServiceAccount, Role and RoleBinding of the same name | the operator's `gitea-restore` mode: fills Gitea's empty volume from the Gitea dump the plan names, as Gitea's user, reading the plan alone |

The operator finishes the restore (phase `Complete`) once the gitops template has
brought the stores back, and then deletes the Secret `infrared-backup-identity`,
both Jobs and both bindings, so no restore right outlives it. The ClusterRole and
the ServiceAccounts stay, inert. Argo CD's render carries no `restore`, so it
renders none of this.

## Gitea

`gitea.enabled: true` runs Gitea in the release namespace as the forge for the
install's orgs: the chart's one dependency, the gitea chart 12.7.0 with Gitea
1.27.3 (`docker.gitea.com/gitea:1.27.3-rootless`, by digest). It is off by
default, and then the chart renders exactly what it rendered before. Everything
under `gitea:` but `enabled` is the gitea chart's own values, preset for one pod:

| What | Preset |
|---|---|
| Names | Deployment `gitea`, Service `gitea-http` (ClusterIP, port 3000), claim `gitea-shared-storage` |
| Pod | One, replaced with `Recreate`; non-root, no privilege escalation, every capability dropped |
| Data | SQLite, the repositories and the LevelDB queue on one ReadWriteOnce volume of `gitea.persistence.storageClass` (the cluster's default when empty) and `gitea.persistence.size` (10Gi); an in-memory cache and sessions |
| Access | No Ingress and no SSH; sign-in required to see anything, no self-registration, basic auth on (the API mints tokens with it); `ROOT_URL` `http://gitea-http.infrared.svc.cluster.local:3000/` |
| Off | The gitea chart's PostgreSQL, PostgreSQL HA, Valkey, Valkey cluster and test pod |

With it on, the operator and the API get `INFRARED_GITEA_URL`,
`http://gitea-http.<release namespace>.svc.cluster.local:3000`, and the API
`INFRARED_GITEA_ADMIN_SECRET: infrared-gitea-admin`. Gitea's site admin is that
Secret (see "Generated Secrets"): the chart generates it once, Gitea creates the
admin from it and resets the admin's password to it at every start, and the API
reads it at the setup wizard's forge step to make an org's bot user. Installed in
a namespace other than `infrared`, set `gitea.gitea.config.server.ROOT_URL` and
`.DOMAIN` to match.

```yaml
gitea:
  enabled: true
  persistence:
    storageClass: linode-block-storage-retain   # on Linode: the volume outlives its claim
    size: 10Gi
```

**The volume.** The claim carries `helm.sh/resource-policy: keep` and
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`: neither uninstalling,
turning Gitea off nor deleting the Application deletes it, and with a Retain class
the volume outlives even the claim. Deleting it is a person's decision.

**After Argo CD adopts the release** the gitops template's `infrared`
Application carries `gitea.enabled`, `giteaAdmin.existingSecret` and, on Linode,
the volume's class, so Argo CD renders every object of Gitea's exactly as the
install did (`make verify` compares them) and never a new admin password. It does
not carry the size: a size other than 10Gi goes in the gitops repo's
`registry/clusters/<cluster>/values/infrared.yaml` as well, or Argo CD would try
to shrink the claim, which Kubernetes refuses.

The gitea chart is not committed: `make deps` (`hack/deps.sh`) vendors it into
`charts/infrared/charts/` with `helm dependency build`, at the version in
`Chart.lock`, and checks the archive's sha256. `make verify`, `lint`,
`template` and `package` run it, and so does the publish workflow.

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
| `installation.edge` | `""` | `traefik` or `gateway`; empty means traefik. The operator writes it to the Installation's `spec.edge` while that is empty (`INFRARED_EDGE`). See "The Installation's edge and previews" |
| `installation.previews` | `{}` | `domain` and `signInURL` (both required when set), optional `ingressHost`, `ingressIP`, `managedRoots`, `cloudflareTokenSecret`. The operator writes it to the Installation's `spec.previews` while that is empty (`INFRARED_PREVIEWS`, JSON) |
| `gitops.templateVersion` | `7be814b9…` (feat/one-artifact-per-backup) | infrared-gitops-template tag, or a full 40-character commit SHA, the API asks the operator to render (`INFRARED_GITOPS_TEMPLATE_VERSION`) |
| `builds.registry` | `""` | Registry prefix kpack builds product images into (`INFRARED_BUILD_REGISTRY`); empty leaves the template's builds component out |
| `registry.address` | `""` | The install's own registry, host and port with no scheme (`INFRARED_REGISTRY`, operator and API). See "The install's own registry" |
| `registry.retention.untaggedAfter` / `.keepTags` / `.keepNewest` / `.gcInterval` / `.gcDelay` | `""` / `[]` / `0` / `""` / `""` | Zot's retention and garbage collection (`INFRARED_REGISTRY_RETENTION`, operator, JSON); each empty one keeps the gitops template's: `24h`, `["^v[0-9]"]`, `10`, `1h`, `1h`. See "Backups" |
| `backup.recipients` | `[]` | age recipients (`age1...`, public keys) each backup is encrypted to; empty makes no backup. Seeds `spec.backup` (`INFRARED_COPIES`). See "Backups" |
| `backup.prefix` | `""` | The path everything is kept under in the backup bucket, with the bucket only; empty: `managementCluster.name` (`INFRARED_BACKUP`). See "Backups" |
| `backup.schedule` / `.mirror.schedule` | `""` / `""` | A backup, by the operator's CronJob `infrared-backup`, and the buckets' mirror to the backup bucket: five cron fields, UTC; empty: `5 * * * *`, `17 * * * *` (`INFRARED_COPIES`) |
| `backup.retention` | `""` | How long each backup, and what the mirror replaced or deleted, is kept, whole days; empty: `7d` (`INFRARED_COPIES`) |
| `backup.postgres.archive` | `false` | Barman's WAL archive of the platform's Postgres in the backup bucket, besides the dump in each backup (`INFRARED_COPIES`) |
| `restore.enabled` / `.from` / `.point` | `false` / `""` / `""` | Restore this install from the backup bucket at install (`INFRARED_RESTORE`, operator and API): the backup `point` names by its stamp, or the newest complete one at or before `from` (RFC 3339, UTC), or the newest when both are empty; never both. See "Restore at install" |
| `restore.postgresImage` | the gitops template's Postgres image, `ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:...` | The restore Job's Postgres sidecar, which restores each consumer database's dump with `pg_restore`: the image the template's Postgres Cluster runs, `name:tag@sha256:digest`, so `pg_restore` and the server share a major; change the two together. See "Restore at install" |
| `stores.enabled` | `false` | The gitops template installs the platform's stores, one Postgres and one object store (`INFRARED_STORES`, operator). See "The stores, the backup bucket and the components left out" |
| `backup.bucket` / `.endpoint` / `.region` | `""` | The bucket outside the cluster the backups and the stores' mirror go to: its name, its S3 endpoint (`https://` and a host; `https://storage.googleapis.com` for Google Cloud Storage, reached keyless as the Jobs' ServiceAccounts) and the region requests are signed for (for Google Cloud Storage, the bucket's location). All three or none (`INFRARED_BACKUP`, operator, JSON) |
| `components.disabled` | `[]` | The gitops template's components the install leaves out, by name, e.g. `[infisical]` (`INFRARED_DISABLED_COMPONENTS`, operator, JSON) |
| `codeIndex.enabled` | `false` | Infrared's code index, which the gitops template runs in the namespace `code-index`: its image is handed to the operator among Infrared's own (`INFRARED_IMAGES`, `code-index`). Needs an `image.registry` other than the default, and a pin. See "The code index" |
| `codeIndex.knowledge.url` / `.ref` | `""` / `""` | The code index's record: the knowledge repository's URL (`https://` or `http://`) and the branch, tag or commit to read it at (empty: `main`). With `codeIndex.enabled`, written into `infrared-platform-tokens` at the install, and required wherever the chart renders that Secret. See "The code index" |
| `codeIndex.image.tag` / `.digest` | `one-install-34162bc` / `sha256:ef9dfab5…` | The image `<image.registry>/infrared-codeindex`: a `one-install-<short sha>` build of darkshiftio/infrared-codeindex, and its `sha256:` digest |
| `substrate.testActors` | `false` | Agent Substrate's test actors, `counter-v1` and `sandbox-v1`, for the gitops template's counter test and fence check. Off, with `stores.enabled` and `registry.address`, adds `substrate-test-actors` to `INFRARED_DISABLED_COMPONENTS`. See "Substrate's test actors" |
| `image.registry` | `977456087177.dkr.ecr.us-east-1.amazonaws.com` | Registry prefix for every component. During the 0.1 track the chart pins the preprod kpack builds by digest (`<c>.image.tag: main`, `<c>.image.digest`). Any other registry is handed to the operator with every pin (`INFRARED_IMAGE_REGISTRY`, `INFRARED_IMAGES`) for the gitops template |
| `image.pullPolicy` | `IfNotPresent` | Pull policy for every component |
| `imagePullSecrets` | `[]` | `[{name: ...}]` on every pod; the first is `INFRARED_IMAGE_PULL_SECRET`, which the operator also copies into each org namespace and sets on every runner Job |
| `imageCredentials.registry` / `.username` / `.password` | `ghcr.io` / `""` / `""` | With a username and password, the chart renders the Secret named by `imagePullSecrets[0]` (see "Secrets from values"). Pass the password with `--set-file` |
| `platformTokens.cloudflareApiToken` / `.existingSecret` | `""` | Token rendered into Secret `infrared-platform-tokens`, key `cloudflare-api-token`; or `infrared-platform-tokens` when it already exists. Pass the token with `--set-file` |
| `platformTokens.backupAccessKeyId` / `.backupSecretAccessKey` | `""` | The backup bucket's key, both or neither, rendered into `infrared-platform-tokens`, keys `backup-access-key-id` and `backup-secret-access-key`; refused with Google Cloud Storage, which takes none. Pass them with `--set-file` |
| `platformTokens.codeIndexGithubAppId` / `.codeIndexGithubAppInstallationId` / `.codeIndexGithubAppPrivateKey` | `""` | The code index's GitHub App, all three or none and only with `codeIndex.enabled`: its ID and its installation's (numbers) and its private key (PEM), rendered into `infrared-platform-tokens`, keys `code-index-github-app-id`, `-installation-id` and `-private-key`; empty for none. Pass them with `--set-file` |
| `gitea.enabled` | `false` | Run Gitea, the chart's gitea dependency, and hand its address to the operator and the API (`INFRARED_GITEA_URL`) and its admin Secret to the API (`INFRARED_GITEA_ADMIN_SECRET`). See "Gitea" |
| `gitea.persistence.storageClass` / `.size` | `""` / `10Gi` | StorageClass and size of Gitea's volume; empty uses the cluster's default class |
| `gitea.*` | one pod, SQLite, no Ingress or SSH | The gitea chart's own values, preset as "Gitea" describes. `gitea.fullnameOverride` (`gitea`) and `gitea.gitea.admin.existingSecret` (`infrared-gitea-admin`) are fixed |
| `giteaAdmin.existingSecret` | `""` | `infrared-gitea-admin` when it already exists, as under Argo CD; the chart then renders none |
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
| `<c>.image.digest` | `""` | `sha256:...`; renders `repo:tag@digest`. The operator's image is also handed to it (`INFRARED_OPERATOR_IMAGE`), which the backup CronJob runs |
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
  `config/rbac/role.yaml` (kubebuilder markers), the backup CronJob's among
  them, plus a Role for leader election in the release namespace.
- **api**: ClusterRole over every `infrared.darkshift.io` resource and status;
  zones' Ingresses get/list and, on a Gateway edge, their HTTPRoutes get (a
  zone's links); Deployments, StatefulSets, CronJobs and CloudNativePG
  Clusters and Backups get/list (the platform by layer: Infrared's own
  Deployments, Gitea, Argo CD's controller and repo server, the stores'
  Postgres and its backups, the CronJob that copies the buckets and the
  operator's backup CronJob); namespaces get/list/create (organizations live in `ir-org-*` namespaces);
  secrets get/list/create/update/patch. The secrets rule is cluster-wide in this
  skeleton; P2 narrows it to the release namespace and the `ir-org-*` namespaces.
- **ui**, **mcp**: no Kubernetes API access (no token is mounted).
- **infrared-backup** (always): the ServiceAccount the operator's backup Jobs
  run as, and a ClusterRole that may get and list every `infrared.darkshift.io`
  resource, namespaces, Secrets and ConfigMaps, and nothing else.
- **infrared-restore** (with `restore.enabled`; with Google Cloud Storage the
  identity that reads the bucket, as `infrared-gitea-restore` is for its Job):
  ClusterRole that may get, list,
  watch, create, update and patch every `infrared.darkshift.io` resource,
  namespaces, Secrets and ConfigMaps, create events, and, by name, scale the
  Deployment `gitea` and read the Job `infrared-gitea-restore`; it deletes
  nothing. Every right is in the one ClusterRoleBinding `infrared-restore`,
  which the operator deletes when the restore is complete.
  **infrared-gitea-restore**: a Role that may get the ConfigMap
  `infrared-restore`, and nothing else.

## Keeping the chart in step with the operator

```bash
make sync-operator   # hack/sync-operator.sh [../infrared-operator]
INFRARED_OPERATOR_DIR=<another checkout> make sync-operator   # e.g. a branch's worktree
hack/sync-operator.sh <dir>   # an exported tree: git -C ../infrared-operator archive <commit> config | tar -x -C <dir>
```

copies `config/crd/bases/*.yaml` into `charts/infrared/crds/` and replaces the
rules between the markers in `templates/operator/clusterrole.yaml` with those
from `config/rbac/role.yaml`. Review and commit the diff with the operator
change it came from.

## Development

```bash
make deps       # vendor the gitea chart at Chart.lock's version, its sha256 checked
make verify     # make deps, shell checks, helm lint, helm template (13 value sets), assertions, kubeconform
make template   # render with defaults
scripts/compare-render.sh origin/main                  # this tree's renders against another ref's, CRDs aside
scripts/compare-render.sh origin/main --include-crds   # ...and the CRDs
```

CI (`.github/workflows/ci.yml`) runs `make verify` on every PR and on `main`.

## Releasing

1. Bump `version` (and `appVersion` if the components moved) in `charts/infrared/Chart.yaml`.
   A release that takes a new gitops template sets `gitops.templateVersion` to
   that template's tag in the same change, so the template is tagged first. The
   default always names a released tag, never a commit.
2. Merge, then tag `v<version>` (e.g. `v0.1.0`).
3. `.github/workflows/release.yml` verifies, checks the tag matches the chart
   version, and pushes to `oci://ghcr.io/darkshiftio/charts`.

Component images are not built here: kpack builds them on darkshift-build
(darkshiftio/gitops) and `scripts/release-tag.sh` there produces the pins.

### Pre-releases from a branch

`.github/workflows/publish-prerelease.yml` publishes the chart of a branch,
on demand, as `<version>.oneinstall.<run number>`: for `0.1.0-alpha.92` in
`Chart.yaml`, run 7 publishes `0.1.0-alpha.92.oneinstall.7`. Semver puts that
above `0.1.0-alpha.92` and below the next release, so successive runs sort
upward, a cluster whose gitops repo pins the base version or an older one moves
up to it, and no pre-release ever outranks a later release for `--devel`. It
never pushes a tag, so `release.yml` never fires. Install it by its exact
version:

```bash
gh workflow run publish-prerelease.yml -R darkshiftio/infrared-chart --ref <branch>
helm template infrared oci://ghcr.io/darkshiftio/charts/infrared --version 0.1.0-alpha.92.oneinstall.7 -n infrared
```

## License

Copyright 2026 darkshift. All rights reserved.
