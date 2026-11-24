# infrared-chart

The Helm chart for Infrared (`charts/infrared`), published to
`oci://ghcr.io/darkshiftio/charts/infrared` on `v*` tags.

- Vocabulary, exactly: management cluster, workload cluster, cluster template,
  gitops repo, registry (`registry/clusters/<cluster>/`), app-of-apps,
  Application, AppProject, sync wave, Synced/Healthy, gitops catalog, zone,
  promotion, pin (`tag@sha256`), AgentRole/AgentWorkflow/AgentWorkflowRun.
  Never hub/spoke/persona/pipeline.
- `crds/` and the rules between the markers in
  `templates/operator/clusterrole.yaml` are generated: run
  `hack/sync-operator.sh`, never edit them by hand.
- Fixed contract with the API: Secrets `infrared-setup` (token),
  `infrared-session` (key), `infrared-api-tokens` (name -> hex sha256, and
  owner.<name> -> the admin it was minted for) in the release namespace;
  `infrared-platform-tokens` keys `google-client-id` and `google-client-secret`
  (Sign in with Google's client, read at use) and env `INFRARED_SIGN_IN_PASSWORD`
  (`signIn.password.enabled`). The API writes the ConfigMap `infrared-sign-in`
  itself; the chart never renders it. The chart renders the ConfigMap
  `infrared-flags` (`api.flags`, ADR 0058) always, by that fixed name, with
  `data: {}` when none is set; the API only reads it, by name, every 15
  seconds, so it is mounted nowhere and no Deployment carries its checksum. The UI Service is `{{ include "infrared.fullname" . }}`
  (`svc/infrared`), port 80 -> 8080.
- ADR 0042, the API's side: env `INFRARED_DIRECTORY_SERVICE_ACCOUNT`,
  `INFRARED_DIRECTORY_API`, `INFRARED_DIRECTORY_INTERVAL`,
  `INFRARED_DIRECTORY_MAX_AGE` (`api.directory.*`), `INFRARED_CLIENT_ADDRESS_HEADER`
  (`api.clientAddressHeader`), `INFRARED_EDGE_PROOF_SECRET`
  (`api.clientAddressProof.enabled`, the name `<fullname>-edge-proof`, on the
  operator too, which needs the header: the render fails without it) and
  `INFRARED_GITEA_BROWSER_URL` (`gitea.browserURL`), each rendered only when
  set; never
  `INFRARED_DIRECTORY_BASE_URL` or `INFRARED_ALLOW_HTTP_CONNECTORS`, which are
  for tests. The API writes the Secret `infrared-git-connectors` (keys
  `<connector>.client-secret`) and the BreakGlass `root` itself, and the API
  and the operator the Secret `<fullname>-edge-proof` (key `credential`); no
  template renders it. No Secret holds
  the root user's password or its hash: no template names `infrared-admin`.
- ADR 0053, Infrared as the OpenID Connect provider of the install's tools: env
  `INFRARED_OIDC` (`oidc.enabled`) and `INFRARED_OIDC_GRAFANA_URL`
  (`oidc.grafanaURL`, a trailing slash trimmed) for the API and the operator,
  each rendered only when set; the operator never gets
  `INFRARED_GITEA_BROWSER_URL`. `oidc.mcpURL` (trailing slash trimmed) is
  `INFRARED_OIDC_MCP_URL` for the API alone, rendered when set, and
  `INFRARED_MCP_CODE_URL` for infrared-mcp, rendered only with `oidc.enabled`
  too. The API writes the Secrets `infrared-oidc-signing`,
  `infrared-oidc-gitea` (keys `key`, `secret`) and `monitoring/infrared-oidc-grafana`
  itself; no template renders them. Gitea's sign-in is the ConfigMap
  `infrared-gitea-sign-in`, `gitea.gitea.additionalConfigFromEnvs` and the
  post-init step `configure-infrared-sign-in`, which never fails Gitea's start.
- Workspace TODO 668, the support chat (the API's rollout flag `supportChat`):
  env `INFRARED_SUPPORT_CHAT_BASE_URL` (`supportChat.baseUrl`, a trailing
  slash trimmed), `INFRARED_SUPPORT_CHAT_WEBSITE_TOKEN`,
  `INFRARED_SUPPORT_CHAT_INSTALL`, `INFRARED_SUPPORT_CHAT_ORGS`
  (`supportChat.orgs`, comma-separated) and
  `INFRARED_SUPPORT_CHAT_HMAC_KEY_FILE`
  (`/var/run/infrared/support-chat/hmac-key`, from the Secret
  `supportChat.hmacKeySecret.name`, key `.key`, mounted optional and never
  through a subPath) for the API alone, each rendered only when set. The
  install makes that Secret; no template renders it.
- ADR 0066 D1, the network fence: env `INFRARED_NETWORK_POLICIES`
  (`tenancy.networkPolicies.enabled`) on the operator, rendered only when set,
  and `templates/networkpolicy.yaml` (`infrared-fence`, `infrared-api`,
  `infrared-zone-snapshot`) in the release namespace, rendered only then too.
  The API's policy names its callers by the chart's selector labels and the
  template's fixed names (`envoy-gateway-system`, `monitoring`); a new caller
  of the API is a new rule there.
- ADR 0066 D3, the registry by identity and the stores' own security: env
  `INFRARED_REGISTRY_PULLS` (`tenancy.registryPulls.enabled`) and
  `INFRARED_STORES_SECURITY` (`tenancy.storesSecurity.enabled`) on the
  operator, each rendered only when set. The chart renders nothing else for
  them: the operator writes each zone's `zot-pull`, and the gitops template
  closes Zot's reads and secures SeaweedFS.
- ADR 0066 D4, D5, D6 and D10, the rest of the tenancy: env
  `INFRARED_TENANT_PODS` (`tenancy.tenantPods`, JSON `{"placement": ...}`),
  `INFRARED_TENANT_QUOTAS` (`tenancy.quotas`, JSON `{"zones", "builds"}`),
  `INFRARED_ADMISSION_POLICIES`, `INFRARED_DENY_LOGGING` and
  `INFRARED_ARGOCD_RESTRICT_DEFAULT_PROJECT` on the operator, each rendered
  only when set, and `INFRARED_ADMISSION_PLATFORM_NAMESPACES`
  (`tenancy.admissionPolicies.platformNamespaces`, JSON, the install's own
  platform namespaces Argo CD may make) only with the admission policies and
  a non-empty list. The operator parses the JSON strictly, so a key the schema
  takes is a key the operator reads. The chart renders nothing else for them:
  the operator writes the zones' blocks, the quotas and the admission
  policies, and the ClusterRole's rules come from `make sync-operator`.
  `runtimeClassName` in `builds.placement` and `runner.placement` is schema and
  a comment, never a default key, so `INFRARED_BUILD_PLACEMENT` and
  `INFRARED_AGENT_STEP_PLACEMENT` keep their bytes.
- Workspace TODO 473's caps: env `INFRARED_BUILD_CAPS` (`tenancy.buildCaps`,
  JSON `{"deadlineMinutes", "minutesPerOrgPerDay"}`) and
  `INFRARED_TENANT_STORAGE` (`tenancy.tenantStorage`, JSON `{"capGi",
  "minDiskGi"}`) on the operator, each rendered only when enabled. The
  operator refuses to start on a cap it cannot keep, so the schema refuses the
  same first: both build caps zero, or no `capGi`. The chart renders nothing
  else for them.
- ADR 0066 D7 and workspace TODO 461, the operator's side: env
  `INFRARED_RUNNER_PERMISSIONS` (`runner.permissions`, `strict`),
  `INFRARED_RUNNER_EGRESS` (`runner.networkPolicy.egressByName`, JSON
  `{"hosts": [...]}`, which needs `runner.networkPolicy.enabled`: the render
  fails without it) and `INFRARED_MANAGEMENT_EGRESS`
  (`managementCluster.egressAddresses`, comma-separated), each rendered only
  when set. The operator writes the runners' FQDN network policies; the chart
  renders none.
- The incident response's Fix plan, C19's second half, each agent step's
  own keys for its agent and e2e hosts: env `INFRARED_STEP_SECRET_REQUIRED`
  (`runner.stepSecret.required`) on the operator, rendered only when true.
  The operator writes each runner Job's Secret `<run>-<step>-hosts` in the
  org's namespace itself and gives each key to the runner and its one host;
  no template renders it, and the operator's Secret rules already cover it.
- The incident response's Fix plan, C34, each agent step's own MCP
  credential: env `INFRARED_STEP_MCP_CREDENTIALS`
  (`runner.stepMCPCredentials.enabled`) on the operator, rendered only when
  true. The operator writes the Secret `infrared-step-tokens` in the release
  namespace itself (each step token's hex SHA-256 and its record, kind `step`,
  in the shape of `infrared-api-tokens`), and infrared-api reads it from the
  Fix plan's C3 and C7 on; no template renders it, and the operator's and the
  API's Secret rules already cover it.
- The incident response's Fix plan, C15's second half (F28), a role lists
  the MCP tools it uses: env `INFRARED_MCP_TOOLS_LISTED_REQUIRED`
  (`runner.mcpToolsListed.required`) on the operator, rendered only when
  true. The operator puts `mcpToolsListedRequired` in every step's
  `spec.json`, and the runner leaves out a server the role lists none of the
  tools of; the chart renders nothing else for it.
- The incident response's Fix plan, C20, each org's own Gitea user for its
  agent steps: env `INFRARED_GITEA_STEPS_USER` and `INFRARED_GITEA_ADMIN_SECRET`
  (`infrared-gitea-admin`, the API's same Secret) on the operator, rendered
  only when `runner.giteaStepsUser.enabled` and `gitea.enabled`. The operator
  writes each org's Secret `gitea-steps` and the Gitea user and team itself;
  no template renders them.
- infrared-docs-internal ADR 0087, the stores' layout and the media store:
  env `INFRARED_STORES_ORG_LAYOUT` (`stores.orgLayout.enabled`) and
  `INFRARED_STORES_POLICIES` (`stores.policies.enabled`, which needs the
  layout: the render fails without it) on the operator, each rendered only
  when set and with `stores.enabled`; `INFRARED_MEDIA_STORE`
  (`summaryvideo.store`, rendered only when not `volume`, which needs
  `stores.enabled` and `summaryvideo.enabled`) on the operator and the API,
  and on the API `INFRARED_MEDIA_S3_ENDPOINT`, `INFRARED_MEDIA_S3_BUCKET` and
  the keys of the Secret `infrared-media-s3` with it, and the keys of
  `infrared-storage-reader-s3` whenever `stores.enabled`, wherever the media
  are (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, each `optional`), which
  the gitops template copies into the release namespace; no template renders
  them. Under `objectStore` the media volume stays mounted, read-only, and its
  claim kept.
- infrared-docs-internal `docs/home-defense.md` step 5, the metrics' door:
  env `INFRARED_METRICS_AUTH` (`observability.metricsAuth.stage`) and
  `INFRARED_METRICS_TOKEN_AUDIENCE` (`.audience`) on the operator, rendered
  only when the stage is not `off`, and `INFRARED_NODE_EXPORTER_AUTH`
  (`observability.nodeExporterAuth.enabled`) only when on. From `clients` on,
  the API and the operator take `INFRARED_METRICS_URL` from
  `observability.metricsAuth.url` and `INFRARED_METRICS_TOKEN_FILE`
  (`/var/run/secrets/infrared.darkshift.io/metrics/token`), a projected
  ServiceAccount token of the audience (volume `metrics-token`, 3600 s). The
  chart renders nothing else for them: the gitops template makes the door,
  its users and its NetworkPolicies, and the operator mounts the same token
  into the upgrade guard's Job.
- Every new value goes in `values.yaml`, `values.schema.json` and the README
  table. Every behaviour worth keeping gets an assertion in `scripts/verify.sh`.
- Flags (infrared-docs-internal ADR 0058 and 0061) are declared in infrared-api,
  never here: `api.flags` takes any camelCase key, and the API lists a key no
  release declares as unknown and ignores it, so neither a new rollout flag nor
  its retirement changes the chart. What an install opts into elsewhere is a
  value here, off by default: for the operator, runner or code index, rendered
  on the operator only when set, as `stores.singleNode` is
  `INFRARED_STORES_SINGLE_NODE` (until the operator reads flags, ADR 0061
  decision 9); for a new object the chart renders, `<thing>.enabled: false`;
  never `api.flags`. Such a value retires the other way round from a flag: the
  schema refuses an unknown key, so every values file drops it first and the
  schema follows in a later release.
- `make verify` must pass before a PR. Pin every upstream version.
- Never apply from CI; CI only verifies and publishes the chart. AWS work uses
  the `darkshift-preprod` profile only, never the default profile.
- Commits: conventional commits. No AI attribution lines in commits or PRs.
