CHART := charts/infrared

.PHONY: verify lint template sync-operator package deps
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
