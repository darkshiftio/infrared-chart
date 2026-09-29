CHART := charts/infrared

.PHONY: verify lint template sync-operator package
verify: ## lint, render and validate the chart
	scripts/verify.sh

lint:
	helm lint --strict $(CHART)

template:
	helm template infrared $(CHART) -n infrared --include-crds

sync-operator: ## copy CRDs and RBAC rules from ../infrared-operator
	hack/sync-operator.sh

package:
	mkdir -p dist && helm package $(CHART) -d dist
