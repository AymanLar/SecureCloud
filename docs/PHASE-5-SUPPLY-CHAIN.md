# Phase 5 — Software Supply-Chain Security

This document explains the SecureCloud software-supply-chain threat model and the
controls that defend it: **SBOM generation**, **container vulnerability scanning**,
**image signing**, and **verification at deploy time**. It covers why each control
exists, how the pipeline enforces them, and how to reproduce every check locally.

Phase 5 scope: **Syft SBOMs** (CycloneDX + SPDX), a **Trivy CRITICAL hard gate**,
**Cosign signing** (keyless in CI, ephemeral key locally) and a **verification
gate wired into deployment**. Runtime detection (Falco) and authentication remain
out of scope.

```
   build          scan           generate         publish        sign            verify / deploy
     │              │               │               │             │                    │
     ▼              ▼               ▼               ▼             ▼                    ▼
 ┌────────┐   ┌──────────┐   ┌────────────┐   ┌─────────┐   ┌──────────┐   ┌────────────────────┐
 │ images │──▶│ Trivy    │──▶│ Syft SBOM  │──▶│ push to │──▶│ Cosign   │──▶│ cosign verify      │
 │        │   │ CRITICAL │   │ CycloneDX  │   │ GHCR    │   │ keyless  │   │ signed -> ACCEPT   │
 └────────┘   │ gate     │   │ + SPDX     │   │         │   │ (OIDC)   │   │ unsigned -> REJECT │
              └──────────┘   └────────────┘   └─────────┘   └──────────┘   └────────────────────┘
```

---

## 1. Why: the supply-chain threat model

Phase 2–4 harden the *code* and the *cluster*. But an attacker rarely needs to
break in if they can make you *run their code willingly*. The realistic ways a
dependency, a build, or a registry becomes the attack path:

| Surface | What an attacker gains | Phase 5 control |
| --- | --- | --- |
| Unknown dependencies | A malicious or vulnerable library runs inside your image | SBOM (know what shipped) |
| Vulnerable base image / OS package | Remote code execution via a known CVE | Trivy CRITICAL gate |
| Tampered image in transit/at rest | Your "secure" build is silently replaced | Cosign signature |
| Unsigned / untrusted image | Anyone can push a same-named image to a reachable registry | Deploy-time verification |
| Compromised CI identity | A forged "trusted" signature | Keyless signing bound to the workflow's OIDC identity |
| Mutable image tags | Rollbacks and provenance both lie | Sign-by-digest |

**The principle behind all of it:** *never run an image you cannot account for and
cannot verify.* An SBOM tells you what is inside; a scan tells you whether it is
safe; a signature tells you it is the bytes your pipeline produced; and the deploy
gate refuses to run anything that fails those checks.

### Signing alone is not security

Worth stating plainly: a signature proves **provenance** (this image came from
*this* pipeline, untampered) — it says nothing about whether the image is
*vulnerable* or *correct*. That is why Phase 5 pairs signing with an SBOM **and**
a CRITICAL vulnerability gate. All three are needed:

- **SBOM** — visibility: what did we ship?
- **Scan** — safety: are there known critical holes in it?
- **Signature** — authenticity: is it really the thing we built?

Signing is the last link, not the whole chain.

---

## 2. What: the three building blocks

### 2.1 SBOM — Software Bill of Materials

An SBOM is a machine-readable inventory of every component in an artifact. We
generate it **from the shipped image** (not from a lockfile) with **Syft**, in the
two standard formats:

| Format | Extension | Why it exists |
| --- | --- | --- |
| **CycloneDX** | `*.cdx.json` | Built for app security; compact; carries vulnerability + dependency edges; understood by most scanners |
| **SPDX** | `*.spdx.json` | ISO/IEC 5962 standard; the format procurement and compliance teams ask for; broader file-level detail |

Generating both is deliberate: CycloneDX for the tooling ecosystem, SPDX for the
standards/compliance ecosystem. They describe the same image.

For SecureCloud the SBOM contains the real runtime dependencies — e.g. the backend
inventory includes `fastapi`, `sqlalchemy` and `psycopg`, and the frontend includes
`next` and `react` — plus their transitive dependencies and the OS packages from
the base image. `scripts/sbom.sh` asserts this (a component count floor **and** a
check for a known application dependency) so an empty or truncated SBOM cannot pass
silently.

### 2.2 Container vulnerability scanning — the CRITICAL gate

`scripts/scan-image.sh` runs **two** Trivy gates per image:

1. `--severity HIGH,CRITICAL --ignore-unfixed` — fails on *addressable* HIGH/CRITICAL
   (a fixed version exists; you should upgrade). Same threshold as the Phase 2
   dependency scan.
2. `--severity CRITICAL` **with no `--ignore-unfixed`** — the *hard gate*. Fails on
   **any** CRITICAL, **including ones with no published fix yet**.

The distinction matters. The first gate keeps the build green on noise (an
unfixable HIGH has nowhere to go), while the second refuses to ship a CRITICAL
regardless of whether a patch exists — because a CRITICAL in a *container image*
that you are about to run in production is a stop-the-line event, not a backlog
item. A CRITICAL that cannot be fixed should be triaged, mitigated, or the base
image replaced — not silently shipped.

### 2.3 Image signing & verification — Cosign

**Cosign** signs an OCI image so anyone can later prove (a) it was produced by a
specific identity and (b) its bytes have not changed. Two modes are supported:

- **Keyless (used in CI).** No private key exists anywhere. GitHub Actions proves
  its identity with an **OIDC token**; Fulcio issues a short-lived certificate bound
  to that identity; the signature and certificate are appended to the **Rekor**
  transparency log and stored with the image in GHCR. The trust anchor is the
  workflow's OIDC identity — `https://github.com/<repo>/.github/workflows/ci.yml@`
  — so *only that exact workflow* can produce a signature that verifies.
- **Key-based (used locally).** For a local registry demo there is no OIDC, so an
  ephemeral key pair is generated into `.supplychain/` (gitignored). The public key
  is the trust anchor. The key is local-only and never committed; `scripts/image-verify.sh`
  prefers it when present and falls back to keyless otherwise.

Verification checks the signature against the configured trust anchor (public key
or OIDC identity + issuer). A missing signature, a wrong signer, or any byte change
to the image all fail verification. This is what makes the "unsigned → rejected,
signed → accepted" demonstration meaningful.

---

## 3. Where: layout

```
SecureCloud/
├── .github/workflows/ci.yml      # sbom, publish, sign, verify, deploy jobs added in Phase 5
├── Makefile                      # Phase 5 targets: sbom, scan-image, sign-images, verify-images,
│                                 #   supply-chain, deploy-verified
├── scripts/
│   ├── lib.sh                    # config: registry, key dir, image refs, cosign_reg_flags(), digest_ref()
│   ├── sbom.sh                   # Syft -> CycloneDX/SPDX, validated
│   ├── scan-image.sh             # two Trivy gates (fixable HIGH/CRITICAL + absolute CRITICAL)
│   ├── image-sign.sh             # Cosign sign (ephemeral local key; CI signs keyless)
│   ├── image-verify.sh           # Cosign verify (key if present, else keyless)
│   └── supply-chain-test.sh      # end-to-end demo: SBOM + scan + sign + signed/unsigned verify
├── .supplychain/                 # gitignored: local cosign key pair (never committed)
└── sbom/                         # gitignored: generated SBOMs (regenerated on demand)
```

Two directories are **deliberately gitignored**: `.supplychain/` (the local signing
key — a private key must never be committed) and `sbom/` (regenerated artifacts).
`git status` therefore stays clean and Gitleaks never sees key material.

---

## 4. Usage

```bash
# 0. tools (CI installs these on the runner; locally put them on PATH)
#    syft (1.54.1), cosign (3.1.3), trivy (0.75.0) - versions pinned in ci.yml env

# 1. generate SBOMs from the built images (CycloneDX + SPDX)
bash scripts/sbom.sh                                   # or: make sbom
SBOM_FORMAT=spdx-json bash scripts/sbom.sh securecloud-backend:3.0.0

# 2. scan images (fails on a CRITICAL)
bash scripts/scan-image.sh                             # or: make scan-image

# 3. run the whole local demonstration
bash scripts/supply-chain-test.sh                      # or: make supply-chain

# 4. sign / verify individually (local ephemeral key)
bash scripts/image-sign.sh                             # or: make sign-images
bash scripts/image-verify.sh                           # or: make verify-images

# 5. deploy only after the signature gate passes
SC_VERIFY_IMAGES=1 bash scripts/deploy.sh              # or: make deploy-verified
```

`supply-chain-test.sh` runs the full loop against a throwaway local registry
(`localhost:5000`): keygen → push → SBOM → scan → sign → **verify signed (must
succeed)** → push an unsigned image → **verify unsigned (must fail)**.

> Note on the ephemeral local key: it is generated with an empty passphrase and
> `scripts/image-sign.sh` exports `COSIGN_PASSWORD` (empty) so cosign decrypts it
> non-interactively. The key lives only in the gitignored `.supplychain/` and is a
> demo convenience — CI never uses a key, it signs keyless.

---

## 5. The controls, one by one

### C1 — Every image ships an SBOM (Syft, CycloneDX + SPDX)

- **Threat** — You cannot defend, patch, or answer a disclosure question about
  components you cannot enumerate. "What's in this image?" becomes a fire drill.
- **Implementation** — `scripts/sbom.sh` runs Syft against the image in both
  formats and validates the result is non-empty, has a meaningful component count,
  and contains a known application dependency.
- **Enforcement** — the CI `sbom` job generates both formats and uploads them as a
  30-day artifact. An empty or malformed SBOM fails the job.

### C2 — A CRITICAL vulnerability stops the pipeline

- **Threat** — A known critical CVE in the base image or a bundled library ships to
  production because the gate only looked at "fixable" issues.
- **Implementation** — `scripts/scan-image.sh` runs the two Trivy gates described
  in §2.2. The hard gate has **no** `--ignore-unfixed`.
- **Enforcement** — the CI `container-scan` job adds the CRITICAL gate on top of
  the existing fixable HIGH/CRITICAL scan; either gate failing fails the job.

### C3 — Images are signed by the CI identity (Cosign, keyless)

- **Threat** — Anyone who can push to a reachable registry (or tamper with one in
  transit) can substitute an image under a trusted name.
- **Implementation** — the CI `sign` job signs the **pushed digests** (not the tags)
  keyless. Signing binds the signature to the workflow's OIDC identity and records
  it in the Rekor transparency log.
- **Ordering note** — the request listed *Sign before Publish*. Cosign stores the
  signature **in the registry next to the image**, so the image must exist there
  first; `publish` therefore precedes `sign`, and the signer signs the exact digest
  that was pushed.

### C4 — Verification is demonstrated both ways

- **Threat** — A verification gate that has never been shown to *reject* anything
  is theatre; you do not know it works.
- **Implementation** — before signing, the `sign` job verifies the just-pushed
  image and **asserts it is rejected** (non-zero exit required). After signing, the
  `verify` job asserts the signed images **are accepted**. Both halves are proven
  on every run.

### C5 — Deployment re-verifies the signature

- **Threat** — A valid signature at build time does not guarantee the image that
  reaches the cluster is the signed one (tag retargeting, tampered registry copy).
- **Implementation** — `scripts/deploy.sh` runs `scripts/image-verify.sh` when
  `SC_VERIFY_IMAGES=1` and aborts before `kubectl apply` on any verification
  failure. The CI `deploy` job does the same as a gate, then applies only if a
  `KUBE_CONFIG` secret is configured.

---

## 6. Test results

All results below are from running the scripts locally on this repository.

### 6.1 SBOM generation (real dependencies present)

```
==> SBOM for securecloud-backend:3.0.0 (cyclonedx-json)  OK: 637 components,  includes 'fastapi'
==> SBOM for securecloud-frontend:3.0.0 (cyclonedx-json) OK: 1115 components, includes 'next'
==> SBOM for securecloud-backend:3.0.0 (spdx-json)       OK: 1296 components, includes 'fastapi'
```

The inventories include the actual runtime stack (`fastapi`, `sqlalchemy`,
`psycopg`, `next`, `react`) plus transitive and OS packages — not a stub.

### 6.2 The CRITICAL gate fails on a vulnerable image

```
$ bash scripts/scan-image.sh                        # our built images
=> container scan clean (no CRITICAL, no fixable HIGH/CRITICAL)   exit=0

$ bash scripts/scan-image.sh postgres:16.15-alpine  # an image with a real CRITICAL
  FAIL: fixable HIGH/CRITICAL found in postgres:16.15-alpine
  FAIL: CRITICAL found in postgres:16.15-alpine - pipeline must stop          exit=1
```

(`rancher/k3s` likewise trips the gate via a CRITICAL in `google.golang.org/grpc`.)
The gate demonstrably stops the line when a CRITICAL is present.

### 6.3 Signed accepted / unsigned rejected

```
==> sign images with Cosign
==> signing localhost:5000/securecloud-backend@sha256:e18e9a7c…
  => PASS: images signed

==> verification of SIGNED images (must succeed)
  OK: localhost:5000/securecloud-backend:3.0.0  signature verified
  OK: localhost:5000/securecloud-frontend:3.0.0 signature verified
  => PASS: trusted, signed images verified

==> verification of UNSIGNED image (must fail)
  REJECTED: localhost:5000/securecloud-unsigned:3.0.0 is unsigned or signed by an untrusted key
  => PASS: unsigned/untrusted image rejected

SUPPLY-CHAIN TESTS PASSED
```

### 6.4 Regression: nothing else broke

| Check | Result |
| --- | --- |
| `bash scripts/verify.sh` (T1–T6) | all passed |
| `bash scripts/policy-test.sh` | 8 bad rejected, good accepted |
| `bash scripts/rbac-review.sh` | least privilege confirmed |
| `actionlint .github/workflows/ci.yml` | clean (shellcheck-enabled) |

---

## 7. CI: the extended pipeline

The full chain in `.github/workflows/ci.yml` (each job `needs` the previous):

```text
lint -> unit-tests -> sast -> secret-scan -> dependency-scan
     -> docker-build -> container-scan -> sbom -> publish -> sign -> verify -> deploy
```

| Job | What it adds in Phase 5 |
| --- | --- |
| `container-scan` | adds the **CRITICAL hard gate** (no `--ignore-unfixed`) |
| `sbom` | Syft → CycloneDX + SPDX, validated, uploaded as an artifact |
| `publish` | pushes images to GHCR and emits the **pushed digests** |
| `sign` | **rejects the unsigned image**, then signs the digests **keyless** |
| `verify` | asserts the **signed images are accepted** |
| `deploy` | re-verifies signatures, then applies manifests if `KUBE_CONFIG` is set |

Scoped permissions: workflow-wide `contents: read`; `publish`/`sign` add
`packages: write`; `sign` adds `id-token: write` **only** for OIDC keyless signing;
`verify`/`deploy` are read-only on packages. No long-lived keys or registry
passwords are stored anywhere.

---

## 8. Limitations & next steps

- **Local-vs-CI digests.** The local demo (`deploy-verified`) verifies the
  registry-published (signed) images while k3d runs locally rebuilt imports; these
  are byte-identical only if builds are reproducible. CI signs the **pushed digest**,
  which is byte-exact, so the guarantee is strongest in CI.
- **Keyless needs a public verifier.** Verifying a keyless CI signature locally
  requires network access to the Rekor transparency log and Fulcio roots; the
  local demo therefore uses the ephemeral key mode, which is self-contained.
- **Signing ≠ patching.** The CRITICAL gate stops known criticals from shipping,
  but it cannot make an unfixable vulnerability disappear — those need base-image
  changes or explicit, documented mitigations (tracked in
  [SECURITY-PIPELINE.md](SECURITY-PIPELINE.md)).
- **Third-party images are scanned only in CI for our built images.** The gate
  covers `securecloud-backend` / `securecloud-frontend`. Pulled base images
  (e.g. `postgres`) inherit their risk from upstream; add them to the scan set if
  you want the same CRITICAL gate on them.
- **SBOMs are generated, not yet continuously monitored.** They are produced and
  retained per build; wiring them to an advisory-monitoring service (e.g. to alert
  when a shipped component gets a new CVE) is a natural next step.
- **Out of scope (future phase):** runtime detection (Falco) and authentication.
  Supply-chain signing complements — but does not replace — admission policy
  (Phase 4) or runtime monitoring.
