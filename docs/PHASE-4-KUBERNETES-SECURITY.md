# Phase 4 — Kubernetes Security & Policy Enforcement

This document explains the SecureCloud Kubernetes threat model and the
policy-as-code controls that defend it. It covers the attack surface, least
privilege, admission control and policy as code, then documents every baseline
policy with its threat, a bad example, the policy itself, the expected
admission result and the secure version.

Phase 4 scope: **Kyverno admission policies** plus an **RBAC least-privilege
review**. Supply-chain signing and runtime detection (Falco) are deliberately
out of scope and left for a later phase.

```
        bad deployment                        good deployment
              │                                     │
              ▼                                     ▼
        ┌───────────┐                         ┌───────────┐
        │  Kyverno  │  admission webhook       │  Kyverno  │
        │  policies │  (enforce)               │  policies │
        └─────┬─────┘                          └─────┬─────┘
              │ violate                              │ compliant
              ▼                                      ▼
         REJECTED                               ACCEPTED
```

---

## 1. Why: the Kubernetes attack surface

A cluster concentrates a lot of authority in one place. The realistic ways an
attacker turns a single compromised workload into a bigger problem:

| Surface | What an attacker gains | Baseline control |
| --- | --- | --- |
| Running as root | Root in the container; a kernel/container-runtime bug becomes host escalation | P1 no root |
| Privilege escalation | setuid/file-capability binaries turn an unprivileged process into root | P2 no privilege escalation |
| Retained capabilities | `NET_RAW` spoofing, `SYS_ADMIN` container escapes | P3 drop ALL |
| Missing limits | One pod starves the node (DoS / noisy neighbour) | P4 limits required |
| Mutable image tags | An unrelated push silently changes what runs; rollbacks lie | P5 no `latest` |
| Untrusted registries | Typosquatting / dependency confusion runs attacker code | P6 approved images |
| `hostNetwork` | Reach the kubelet, node services and metadata; bypass NetworkPolicy | P7 no host networking |
| `hostPath` mounts | Control the node / other pods via runtime sockets — the classic escape | P8 no hostPath |
| Over-privileged RBAC | Stolen token could read secrets, create pods, escalate | RBAC review |

**The principle behind all of it:** a workload should be *secure by default*.
The safe configuration should be the one you get without thinking, and the
dangerous configuration should require an explicit, reviewable exception.

## 2. What: admission control and policy as code

**Admission control** is the gate every object passes through *after* it is
submitted and *before* it is persisted. Kubernetes ships two native hooks
(ValidatingAdmissionWebhook, MutatingAdmissionWebhook) but no policies; you
bring an engine. We use **Kyverno**, which registers webhooks and evaluates
your policies against incoming objects.

**Policy as code** means those rules live in Git as YAML, are reviewed like any
other change, are versioned, and are testable in CI. That is what turns a
security guideline in a wiki into a gate that cannot be ignored.

Two modes matter:

- **Audit** — violations are allowed but recorded in `PolicyReport` objects.
  Use it to measure impact before flipping the switch.
- **Enforce** — violations are **blocked** at admission.

This repo implements both: the base is audit-only; the `enforce/` overlay flips
every policy to `Enforce`.

## 3. Where: layout

```
kubernetes/
├── policies/
│   ├── base/            # 8 ClusterPolicies, validationFailureAction: Audit
│   │   ├── disallow-root.yaml                     # P1
│   │   ├── disallow-privilege-escalation.yaml     # P2
│   │   ├── require-drop-capabilities.yaml         # P3
│   │   ├── require-resource-limits.yaml           # P4
│   │   ├── disallow-latest-tag.yaml               # P5
│   │   ├── restrict-image-registries.yaml         # P6
│   │   ├── disallow-host-network.yaml             # P7
│   │   └── disallow-host-path.yaml                # P8
│   ├── enforce/         # overlay: patches all to validationFailureAction: Enforce
│   └── kustomization.yaml
├── policy-tests/
│   ├── bad/             # 8 deliberately violating Deployments
│   └── good/            # 1 fully compliant Deployment
└── rbac/                # ServiceAccounts (no token) + empty Role + bindings
```

## 4. Usage

```bash
# 1. install the policy engine (pinned; server-side apply for the large CRDs)
bash scripts/kyverno-install.sh          # or: make kyverno

# 2. measure first (nothing is blocked)
kubectl apply -k kubernetes/policies      # or: make policies-audit
kubectl -n securecloud get policyreport

# 3. enforce the important controls
kubectl apply -k kubernetes/policies/enforce   # or: make policies-enforce

# 4. prove the policies work
bash scripts/policy-test.sh               # or: make policy-test

# 5. confirm least-privilege RBAC
bash scripts/rbac-review.sh               # or: make rbac-review
```

Policies are **cluster-scoped** but exclude the system namespaces
(`kube-system`, `kube-public`, `kube-node-lease`, `kyverno`) which legitimately
need host access. They cover `Pod` plus (via Kyverno autogen, or explicit rules
for the deny-based policies) `Deployment`, `StatefulSet`, `DaemonSet`, `Job`,
`ReplicaSet`, `ReplicationController` and `CronJob`.

> Note: `clusterpolicies.kyverno.io/v1` is the mature API this phase uses. The
> engine warns it is superseded by the CEL-based `policies.kyverno.io` APIs in
> newer Kyverno releases; the manifests are written to migrate cleanly later.

---

## 5. The policies, one by one

Each entry: **Threat → Bad example → Policy → Expected result → Secure version.**
All bad examples live under `kubernetes/policy-tests/bad/`; the compliant
example is `kubernetes/policy-tests/good/compliant-deployment.yaml`.

### P1 — Containers must not run as root
- **Threat** — A root container makes any kernel or runtime escape far more
  damaging; file ownership in volumes becomes attacker-controlled.
- **Bad example** — `bad/01-run-as-root.yaml` (`runAsNonRoot: false` +
  `runAsUser: 0`).
- **Policy** — `securecloud-disallow-root`: requires
  `spec.securityContext.runAsNonRoot: true` and rejects any container/init
  container that sets `runAsUser: 0` or `runAsNonRoot: false`.
- **Expected result** — `bad deployment → Kyverno → REJECTED`.
- **Secure version** — pod `runAsNonRoot: true` and a non-zero `runAsUser`
  (e.g. `1001`); see the compliant example.

### P2 — Privilege escalation must be disabled
- **Threat** — `allowPrivilegeEscalation: true` lets a process gain more
  privileges than its parent via setuid binaries or file capabilities.
- **Bad example** — `bad/02-privilege-escalation.yaml`
  (`allowPrivilegeEscalation: true`).
- **Policy** — `securecloud-disallow-privilege-escalation`: every container and
  init container must set `securityContext.allowPrivilegeEscalation: false`.
- **Expected result** — `bad deployment → Kyverno → REJECTED`.
- **Secure version** — `allowPrivilegeEscalation: false`.

### P3 — Containers must drop unnecessary capabilities
- **Threat** — Capabilities like `NET_RAW` (ARP/ICMP spoofing) and `SYS_ADMIN`
  (container escape) grant root-like power without full root.
- **Bad example** — `bad/03-capabilities.yaml` (adds `NET_RAW`, drops nothing).
- **Policy** — `securecloud-require-drop-all-capabilities`: capabilities must be
  dropped entirely (`securityContext.capabilities.drop: [ALL]`).
- **Expected result** — `bad deployment → Kyverno → REJECTED`.
- **Secure version** — `capabilities: { drop: [ALL] }`; add back only a specific
  capability a workload genuinely needs, and document why.

### P4 — Containers must have CPU and memory limits
- **Threat** — An unbounded pod can consume a node's CPU/memory, starving other
  workloads (DoS / noisy neighbour).
- **Bad example** — `bad/04-no-resource-limits.yaml` (no `resources`).
- **Policy** — `securecloud-require-resource-limits`: every container and init
  container must declare non-empty `resources.limits.cpu` and
  `resources.limits.memory` (`"?*"` = required, non-empty).
- **Expected result** — `bad deployment → Kyverno → REJECTED`.
- **Secure version** — set `limits` (and ideally matching `requests`).

### P5 — Deployments must not use the "latest" image tag
- **Threat** — A floating tag is non-reproducible: an unrelated push changes
  what runs, rollbacks no longer mean anything, and image pinning is defeated.
- **Bad example** — `bad/05-latest-tag.yaml` (`securecloud-backend:latest`).
- **Policy** — `securecloud-disallow-latest-tag`: images must carry an explicit
  tag that is not `latest` (rule `image: "!*:latest"`) and must not omit the tag
  (rule `image: "*:*"`).
- **Expected result** — `bad deployment → Kyverno → REJECTED`.
- **Secure version** — pin an immutable tag (e.g. `securecloud-backend:3.0.0`);
  digest-pinning (`@sha256:...`) also satisfies the policy.

### P6 — Pods must use approved registries/images
- **Threat** — Pulling arbitrary images widens the supply-chain surface:
  typosquatting and dependency-confusion images execute attacker code.
- **Bad example** — `bad/06-unapproved-registry.yaml` (`nginx:1.27`).
- **Policy** — `securecloud-restrict-image-registries`: images must match one of
  `securecloud-*`, `postgres:*`, `docker.io/library/*`, `ghcr.io/*`.
- **Expected result** — `bad deployment → Kyverno → REJECTED`.
- **Secure version** — use an approved image from the allow-list. This is the
  policy most likely to be tailored per organisation; the allow-list is the one
  block to edit.

### P7 — Host networking must not be enabled
- **Threat** — `hostNetwork: true` shares the node network namespace: reach the
  kubelet and node services, sniff/spoof traffic, and bypass NetworkPolicy.
- **Bad example** — `bad/07-host-network.yaml` (`hostNetwork: true`).
- **Policy** — `securecloud-disallow-host-network`: denies objects whose
  `hostNetwork` resolves to `true` (Pod and explicit controller rules; the
  `|| false` default makes the check null-safe).
- **Expected result** — `bad deployment → Kyverno → REJECTED`.
- **Secure version** — omit `hostNetwork` (defaults to `false`); use a Service
  or Ingress for exposure.

### P8 — Host filesystem mounts must not be allowed unless justified
- **Threat** — A `hostPath` volume exposes node paths; mounting `/var/run`,
  `/proc`, `/sys` or the runtime socket is the classic container escape.
- **Bad example** — `bad/08-host-path.yaml` (mounts node `/etc`).
- **Policy** — `securecloud-disallow-host-path`: denies any object with a
  `hostPath` volume (null-safe `|| []` guard). **Justification path:** a genuine
  need is handled by a narrower mechanism (CSI volume, projected secret) or an
  explicit Kyverno `PolicyException` — never by weakening the policy.
- **Expected result** — `bad deployment → Kyverno → REJECTED`.
- **Secure version** — use `emptyDir`, a PVC, or a CSI volume instead.

---

## 6. RBAC — least privilege review

Findings for the application:

| Item | State | Rationale |
| --- | --- | --- |
| ServiceAccounts | one per workload, never `default` | blast radius contained per workload |
| ClusterRoleBindings | none | the app never needs cluster-scoped permissions |
| ClusterRoles | none bound | avoids any cluster-wide verb |
| Namespaced Role | `securecloud-app`, **empty** | even a leaked token has zero API verbs |
| `automountServiceAccountToken` | **`false`** | pods receive no token at all — the strongest fix |
| `cluster-admin` | not used anywhere related to the app | removes the classic escape hatch |

The app is a plain client/server stack: it does **not** call the Kubernetes API.
Therefore its pods do not need — and now do not receive — a service-account
token. The empty Role binding is retained as defence in depth (if a token ever
were added, it could still do nothing).

`scripts/rbac-review.sh` asserts all of the above and is safe to run as a gate:

```
==> Check 1: no ClusterRoleBinding references a SecureCloud ServiceAccount   OK
==> Check 2: no cluster-admin membership touching SecureCloud                OK
==> Check 3: automountServiceAccountToken is false on every SA               OK
==> Check 4: sensitive verbs must be denied (6 verbs × 3 SAs)              OK
RBAC REVIEW PASSED (least privilege confirmed)
```

---

## 7. Test results

`scripts/policy-test.sh` applies the enforce overlay, then submits every bad and
good manifest with `--dry-run=server` (admission runs; nothing is persisted) and
asserts the outcome:

```
MANIFEST                          EXPECTED   GOT        RESULT
bad/01-run-as-root.yaml           rejected   rejected   PASS
bad/02-privilege-escalation.yaml  rejected   rejected   PASS
bad/03-capabilities.yaml          rejected   rejected   PASS
bad/04-no-resource-limits.yaml    rejected   rejected   PASS
bad/05-latest-tag.yaml            rejected   rejected   PASS
bad/06-unapproved-registry.yaml   rejected   rejected   PASS
bad/07-host-network.yaml          rejected   rejected   PASS
bad/08-host-path.yaml             rejected   rejected   PASS
good/compliant-deployment.yaml    accepted   accepted   PASS
=> ALL POLICY TESTS PASSED
```

In **audit** mode the same bad manifests are accepted and recorded instead, for
example (from `kubectl -n securecloud get policyreport`):

```
Deployment/bad-run-as-root   PASS 14  FAIL 2
Pod/bad-latest-tag-...       PASS 15  FAIL 1
```

The eight violations are visible, nothing is blocked, and enforcement can then
be turned on with confidence. The existing SecureCloud workloads evaluate as
fully compliant (`PASS 16 / FAIL 0`) and continue to pass the Phase 3
end-to-end checks (`T1–T6`) under enforcement.

---

## 8. Limitations & next steps

- `hostPath` denials use `deny` rules because the "no volume may be hostPath"
  shape is not expressible as a plain pattern; autogen is disabled on those two
  policies in favour of explicit controller rules.
- The registry allow-list is illustrative; make it your own registry first.
- Exceptions should be individual Kyverno `PolicyException` objects (reviewable),
  not broad allow rules.
- **Out of scope (future phase):** runtime detection (Falco) and supply-chain
  signing/verification (Cosign), which complement — but do not replace —
  admission policy.
