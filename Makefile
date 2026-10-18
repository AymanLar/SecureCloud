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
#   sbom           generate a CycloneDX/SPDX SBOM from the built images
#   scan-image     Trivy scan (fails on CRITICAL)
#   sign-images    sign images with Cosign (local key pair)
#   verify-images  verify image signatures
#   supply-chain   end-to-end sign/verify demonstration (SBOM + scan + sign)
#   deploy-verified  deploy only if image signatures verify
#   help           list targets

.PHONY: help cluster-up cluster-down deploy status logs verify kyverno policies-audit policies-enforce policy-test rbac-review sbom scan-image sign-images verify-images supply-chain deploy-verified

help:
	@echo "SecureCloud local Kubernetes targets:"
	@echo "  make cluster-up       create the k3d cluster"
	@echo "  make cluster-down     delete the k3d cluster"
	@echo "  make deploy           build images, generate secrets, apply manifests"
	@echo "  make deploy-verified  as deploy, but refuse to roll out unsigned images"
	@echo "  make status           show cluster + workload state"
	@echo "  make logs             tail pod logs (SERVICE=backend|frontend|postgres)"
	@echo "  make verify           run end-to-end connectivity checks"
	@echo "  make kyverno          install Kyverno (admission policy engine)"
	@echo "  make policies-audit   apply baseline policies in audit mode"
	@echo "  make policies-enforce apply baseline policies in enforce mode"
	@echo "  make policy-test      run the policy violation/compliance tests"
	@echo "  make rbac-review      confirm least-privilege RBAC"
	@echo "  make sbom             generate SBOM (CycloneDX/SPDX) from built images"
	@echo "  make scan-image       Trivy container scan (fails on CRITICAL)"
	@echo "  make sign-images      sign images with Cosign"
	@echo "  make verify-images    verify image signatures"
	@echo "  make supply-chain     full sign/verify demonstration (SBOM + scan + sign)"

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

sbom:
	bash scripts/sbom.sh

scan-image:
	bash scripts/scan-image.sh

sign-images:
	bash scripts/image-sign.sh

verify-images:
	bash scripts/image-verify.sh

supply-chain:
	bash scripts/supply-chain-test.sh

deploy-verified:
	SC_VERIFY_IMAGES=1 bash scripts/deploy.sh