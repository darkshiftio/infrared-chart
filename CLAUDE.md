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
  `infrared-session` (key), `infrared-api-tokens` (name -> hex sha256) in the
  release namespace. The UI Service is `{{ include "infrared.fullname" . }}`
  (`svc/infrared`), port 80 -> 8080.
- Every new value goes in `values.yaml`, `values.schema.json` and the README
  table. Every behaviour worth keeping gets an assertion in `scripts/verify.sh`.
- `make verify` must pass before a PR. Pin every upstream version.
- Never apply from CI; CI only verifies and publishes the chart. AWS work uses
  the `darkshift-preprod` profile only, never the default profile.
- Commits: conventional commits. No AI attribution lines in commits or PRs.
