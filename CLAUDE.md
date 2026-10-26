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
  (`api.clientAddressHeader`) and `INFRARED_GITEA_BROWSER_URL`
  (`gitea.browserURL`), each rendered only when set; never
  `INFRARED_DIRECTORY_BASE_URL` or `INFRARED_ALLOW_HTTP_CONNECTORS`, which are
  for tests. The API writes the Secret `infrared-git-connectors` (keys
  `<connector>.client-secret`) and the BreakGlass `root` itself. No Secret holds
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
- Every new value goes in `values.yaml`, `values.schema.json` and the README
  table. Every behaviour worth keeping gets an assertion in `scripts/verify.sh`.
- `make verify` must pass before a PR. Pin every upstream version.
- Never apply from CI; CI only verifies and publishes the chart. AWS work uses
  the `darkshift-preprod` profile only, never the default profile.
- Commits: conventional commits. No AI attribution lines in commits or PRs.
