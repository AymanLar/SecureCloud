# SecureCloud - local Kubernetes helper targets.
#
# The actual logic lives in scripts/*.sh; the Makefile just wraps them for
# hosts that ship GNU Make (macOS/Linux). On Windows (Git Bash) run the
# scripts directly, e.g. `bash scripts/cluster-up.sh`.
#
# Targets:
#   cluster-up     create the k3d cluster
#   cluster-down   delete the k3d cluster
#   deploy         build images, generate secrets, apply manifests
#   status         show cluster + workload state
#   logs           tail pod logs; optional SERVICE=<backend|frontend|postgres>
#   verify         run end-to-end connectivity checks
#   kyverno        install the Kyverno admission policy engine
#   policies-audit apply the baseline policies in audit mode
#   policies-enforce apply the baseline policies in enforce mode
#   policy-test    prove every policy (violations rejected, compliant accepted)
#   rbac-review    confirm least-privilege RBAC
#   help           list targets

.PHONY: help cluster-up cluster-down deploy status logs verify kyverno policies-audit policies-enforce policy-test rbac-review

help:
	@echo "SecureCloud local Kubernetes targets:"
	@echo "  make cluster-up       create the k3d cluster"
	@echo "  make cluster-down     delete the k3d cluster"
	@echo "  make deploy           build images, generate secrets, apply manifests"
	@echo "  make status           show cluster + workload state"
	@echo "  make logs             tail pod logs (SERVICE=backend|frontend|postgres)"
	@echo "  make verify           run end-to-end connectivity checks"
	@echo "  make kyverno          install Kyverno (admission policy engine)"
	@echo "  make policies-audit   apply baseline policies in audit mode"
	@echo "  make policies-enforce apply baseline policies in enforce mode"
	@echo "  make policy-test      run the policy violation/compliance tests"
	@echo "  make rbac-review      confirm least-privilege RBAC"

cluster-up:
	bash scripts/cluster-up.sh

cluster-down:
	bash scripts/cluster-down.sh

deploy:
	bash scripts/deploy.sh

status:
	bash scripts/status.sh

logs:
	bash scripts/logs.sh $(if $(SERVICE),$(SERVICE),all)

verify:
	bash scripts/verify.sh

kyverno:
	bash scripts/kyverno-install.sh

policies-audit:
	kubectl apply -k kubernetes/policies

policies-enforce:
	kubectl apply -k kubernetes/policies/enforce

policy-test:
	bash scripts/policy-test.sh

rbac-review:
	bash scripts/rbac-review.sh