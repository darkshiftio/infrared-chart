CHART := charts/infrared

.PHONY: verify lint template sync-operator package deps publish
verify: deps ## lint, render and validate the chart
	scripts/verify.sh

lint: deps
	helm lint --strict $(CHART)

template: deps
	helm template infrared $(CHART) -n infrared --include-crds

deps: ## vendor the chart's dependencies (the gitea chart) at Chart.lock's versions, each archive's sha256 checked
	hack/deps.sh

sync-operator: ## copy CRDs and RBAC rules from ../infrared-operator
	hack/sync-operator.sh

package: deps
	mkdir -p dist && helm package $(CHART) -d dist

# Artifact Registry in Google Cloud, private to darkshift (the organization refuses public access):
# helm signs in with the person's gcloud identity, for this push alone.
AR_HOST := us-central1-docker.pkg.dev
AR_CHARTS := oci://$(AR_HOST)/darkshift-preprod/infrared/charts
GCLOUD_CONFIGURATION ?= darkshift-preprod

publish: package ## push the packaged chart to Artifact Registry ($(AR_CHARTS)/infrared); a release tag's job, run by a person while CI cannot
	@cfg=$$(mktemp -d)/config.json; \
	gcloud --configuration=$(GCLOUD_CONFIGURATION) auth print-access-token | helm registry login $(AR_HOST) -u oauth2accesstoken --password-stdin --registry-config $$cfg >/dev/null && \
	for c in dist/infrared-*.tgz; do helm push $$c $(AR_CHARTS) --registry-config $$cfg; done
