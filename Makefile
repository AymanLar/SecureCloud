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
#   help           list targets

.PHONY: help cluster-up cluster-down deploy status logs verify

help:
	@echo "SecureCloud local Kubernetes targets:"
	@echo "  make cluster-up      create the k3d cluster"
	@echo "  make cluster-down    delete the k3d cluster"
	@echo "  make deploy          build images, generate secrets, apply manifests"
	@echo "  make status          show cluster + workload state"
	@echo "  make logs            tail pod logs (SERVICE=backend|frontend|postgres)"
	@echo "  make verify          run end-to-end connectivity checks"

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