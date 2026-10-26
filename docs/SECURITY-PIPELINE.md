# Security Pipeline — CI/CD & Shift-Left Security

This document describes how SecureCloud scans its own code, dependencies, and
built containers, why the pipeline fails when it does, and how to reproduce
every check locally before pushing.

The pipeline is a single GitHub Actions workflow:

```text
lint  ->  unit-tests  ->  sast  ->  secret-scan  ->  dependency-scan  ->  docker-build  ->  container-scan
ruff + eslint         pytest       semgrep        gitleaks          trivy fs          docker compose    trivy image
                                                                                                       + CRITICAL gate
        ->  sbom  ->  publish  ->  sign  ->  verify  ->  deploy
         syft        ghcr push   cosign    cosign      cosign verify
         (SBOM)      (digests)   keyless   (signed OK) (gate) + apply
```

Every job runs only after the previous one succeeds (`needs` chain), so a
finding anywhere above stops the pipeline. There is no `continue-on-error`;
a security finding fails the workflow. The workflow lives in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml). All tool versions
are pinned there and in the local manifests, so CI and local checks agree.

Stages 1–7 are the shift-left security pipeline (Phases 1–2). The supply-chain
stages (Phase 5) — the CRITICAL gate, SBOM, signing, verification and the deploy
gate — are documented in
[PHASE-5-SUPPLY-CHAIN.md](PHASE-5-SUPPLY-CHAIN.md) and summarised in §1.7 below.

---

## 1. What each check detects and when it fails

### 1.1 `lint` — ruff (backend) + ESLint (frontend)

| Tool | Scope | Detects |
| --- | --- | --- |
| ruff (`check` + `format`) | `app/backend` | Unused imports, common bugs, blind `except`, mutable default arguments passed to FastAPI dependency calls, style drift |
| ESLint (flat config) | `app/frontend` | Next.js rules (`core-web-vitals` + TypeScript), React hooks violations (e.g. `set-state-in-effect`), unreachable/unsafe patterns |

Fails when: any lint error is reported (ruff `check`/`format --check`, `eslint .` exit 1).

How to fix: read the rule message, fix the code, don't disable rules. If a
rule is genuinely wrong for this codebase, change the config explicitly and
say why in the diff — there are currently no disabled rules.

### 1.2 `unit-tests` — pytest

| Tool | Scope | Detects |
| --- | --- | --- |
| pytest | `app/backend` | Regression in the API: health, users, projects, deployments (19 tests) |

Fails when: any test fails or errors. SQLite in-memory database is used so the
suite runs without PostgreSQL.

### 1.3 `sast` — Semgrep

| Tool | Scope | Detects |
| --- | --- | --- |
| Semgrep (`p/ci` ruleset, `--error`) | `app/backend` (Python) + `app/frontend` (TS/TSX) | Injection, hardcoded credentials, insecure use of crypto, dangerous deserialization, SSRF, SQLi, unsafe regex, etc. |

Fails when: Semgrep reports any finding (`--error`). The `p/ci` ruleset is the
same one played back on every scan; no rules are silenced.

How to fix: read the finding at `file:line`, understand the rule, change the
code so the pattern no longer matches. Re-run the local command below until it
reports `0 findings`.

### 1.4 `secret-scan` — Gitleaks

| Tool | Scope | Detects |
| --- | --- | --- |
| Gitleaks (`detect --source . --redact`) | full repository and git history | Committed secrets: AWS keys, GitHub tokens, private keys, generic high-entropy secrets, connection strings, etc. |

Fails when: Gitleaks reports any leak (`--exit-code 1`).

How to fix:
1. Rotate the leaked secret (treat it as compromised, even if removed now).
2. Remove the secret from history (`git filter-repo`, BFG, or history rewrite).
3. Add a comment/`.gitignore`/allow-list only when it is a true positive that
   must stay (e.g. test fixtures); document it.
4. Verify with the local command.

### 1.5 `dependency-scan` — Trivy fs

| Tool | Scope | Detects |
| --- | --- | --- |
| Trivy fs (`--scanners vuln`) | Python manifests (`app/backend/requirements*.txt`, `requirements-tools.txt`) and `app/frontend/package-lock.json` | Known CVEs in third-party libraries (both OS-independent language deps) |

Fails when: **addressing** (fix available) vulnerabilities with severity
**HIGH or CRITICAL** are found (`--severity HIGH,CRITICAL --ignore-unfixed
--exit-code 1`).

Threshold rationale: unfixed vulnerabilities (no patched version exists yet)
are reported but do not fail the build; there is nothing to upgrade to.
HIGH/CRITICAL gating matches industry-standard tooling defaults and keeps the
pipeline green on real findings rather than unusable on noise. This is a
deliberate policy, not an excuse to ignore — every vulnerability Trivy prints
should be reviewed and its fix logged, even when it doesn't fail the build
(see "Known limitations").

How to fix: bump the pinned version in the relevant manifest to the fixed
version, re-run the checks, and keep the pinned file — pinning `==` is what
makes Trivy able to resolve the exact installed version.

Staging note: Trivy auto-detects files named exactly `requirements.txt`. The
dev and tooling manifests are staged under neutral directory names for the
second scan so they are not skipped (see the workflow's *Stage dev and tools
manifests* step).

### 1.6 `docker-build` + `container-scan` — Trivy image

| Tool | Scope | Detects |
| --- | --- | --- |
| Trivy image (`--scanners vuln`) | `securecloud-backend` and `securecloud-frontend` images | OS package CVEs (Debian/Alpine), Python packages as shipped in the image, Node packages in the image, configs |

Fails when: addressing HIGH/CRITICAL vulns are found, same thresholds as fs.

How to fix: rebuild and rescan. For base-image problems, bump the base image
tag or trim build-only tooling; this project already drops the base image's
bundled `npm` from the frontend runtime stage to remove its (unpatched)
npm-tooling CVEs, and prunes devDependencies (`npm prune --omit=dev`) so
build-only tooling (ESLint, TypeScript, `eslint-config-next` and its transitive
deps) never ships in the image at all.

### 1.7 Supply-chain stages (Phase 5)

| Job | Tool | Fails when |
| --- | --- | --- |
| `container-scan` (CRITICAL gate) | Trivy image | **any** CRITICAL is found, including ones with no published fix (no `--ignore-unfixed`) |
| `sbom` | Syft | the SBOM is empty, truncated, or missing a known application dependency |
| `sign` (pre-check) | Cosign | the just-pushed image **verifies** — an unsigned image must be rejected |
| `verify` | Cosign | a signed image **fails** verification — a trusted signature must be accepted |
| `deploy` | Cosign | the image signature does not verify before anything is applied |

The CRITICAL gate is stricter than the two existing image scans (which only gate
*fixable* HIGH/CRITICAL). It exists because a CRITICAL in a container you are about
to run is a stop-the-line event regardless of whether a patch exists yet. Signing is
**keyless** (GitHub OIDC → Fulcio → Rekor); no private key or registry password is
ever stored. Full model, threat table, and local reproduction are in
[PHASE-5-SUPPLY-CHAIN.md](PHASE-5-SUPPLY-CHAIN.md).

---

## 2. Reproduce every check locally

The CI workflow and these commands are the same checks. Versions that matter
are pinned in `requirements-tools.txt` and in the `env` block of
`.github/workflows/ci.yml`.

### 2.1 Backend: ruff + pytest (`app/backend/.venv`)

```bash
cd app/backend
.venv/Scripts/python -m venv .venv                      # once: python -m venv .venv
.venv/Scripts/python -m pip install -r requirements-dev.txt -r ../../requirements-tools.txt
.venv/Scripts/ruff format --check .                     # exit 1 on any diff
.venv/Scripts/ruff check .                              # exit 1 on any finding
.venv/Scripts/python -m pytest                          # 19 passed
```

### 2.2 Frontend: ESLint (`app/frontend`)

```bash
cd app/frontend
npm ci
npm run lint                                            # exit 1 on any finding
```

### 2.3 Semgrep (SAST)

```bash
.venv/Scripts/semgrep scan --config p/ci --error --metrics off \
    --exclude .venv --exclude node_modules --exclude .next --exclude .git \
    app/backend app/frontend
```

### 2.4 Gitleaks (secret scan)

Install (pinned, checksum-verified — see 2.6):

```bash
gitleaks detect --source . --redact --exit-code 1 --verbose
```

### 2.5 Trivy (dependency + container scan)

```bash
# dependency scan — auto-detected manifests
trivy fs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
    --exit-code 1 --skip-dirs node_modules --skip-dirs .next --skip-dirs .git .

# dependency scan — dev + tools manifests (staged like CI)
mkdir -p deps-scan/extra deps-scan/tools
grep -v '^-r ' app/backend/requirements-dev.txt > deps-scan/extra/requirements.txt
cp requirements-tools.txt deps-scan/tools/requirements.txt
trivy fs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
    --exit-code 1 deps-scan

# container scan (build first)
docker compose build backend frontend
trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 securecloud-backend
trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 securecloud-frontend
```

### 2.6 Install Gitleaks / Trivy binaries (Windows example)

Both are released as binaries. Download the pinned version, verify the SHA-256
checksum against the release's signed checksum file, then extract. CI does the
same steps on Linux.

```bash
# Gitleaks (pin to the version in the workflow env)
curl -sSL -o gitleaks.zip \
  "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip"
curl -sSL -o gitleaks_checksums.txt \
  "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_checksums.txt"
grep "windows_x64.zip" gitleaks_checksums.txt > gitleaks.sum
sha256sum -c gitleaks.sum
unzip -o gitleaks.zip -d gitleaks

# Trivy (pin to the version in the workflow env)
curl -sSL -o trivy.zip \
  "https://github.com/aquasecurity/trivy/releases/download/v0.75.0/trivy_0.75.0_windows-64bit.zip"
curl -sSL -o trivy_checksums.txt \
  "https://github.com/aquasecurity/trivy/releases/download/v0.75.0/trivy_0.75.0_checksums.txt"
grep "windows-64bit.zip" trivy_checksums.txt > trivy.sum
sha256sum -c trivy.sum
unzip -o trivy.zip -d trivy
```

On Linux (as used in CI), substitute `_linux_x64.tar.gz` / `_Linux-64bit.tar.gz`
and `tar -xzf` instead of unzip.

### 2.7 Supply-chain checks (Syft + Cosign)

Install the pinned binaries the same way as above (checksum-verified), put them on
`PATH`, then run the scripts — the exact commands CI runs:

```bash
# Syft (pin to SYFT_VERSION in the workflow env) -> SBOM, both formats
SBOM_FORMAT=cyclonedx-json bash scripts/sbom.sh securecloud-backend:3.0.0
SBOM_FORMAT=spdx-json      bash scripts/sbom.sh securecloud-backend:3.0.0

# Trivy CRITICAL gate (fails on any CRITICAL, including unfixed)
bash scripts/scan-image.sh securecloud-backend:3.0.0

# Full signed/unsigned demonstration against a local registry
bash scripts/supply-chain-test.sh

# Individual sign / verify (local ephemeral key)
bash scripts/image-sign.sh
bash scripts/image-verify.sh

# Deploy only after the signature gate passes
SC_VERIFY_IMAGES=1 bash scripts/deploy.sh
```

---

## 3. Known limitations and tracked risk

These are the vulnerabilities the pipeline reports but does not fail on, and
the reasons — documented so they stay visible rather than silently ignored.

- **`braces` (< 3.0.3 fix pending upstream) — dev-only npm tooling.** npm
  `audit` reports 5 HIGH for `braces` as a transitive dependency of the ESLint
  toolchain (through `micromatch` → `fast-glob` → `@next/eslint-plugin-next`).
  `braces@3.0.3` (the newest release) is already installed and is itself still
  flagged; there is no patched release or advisory fix, and `npm audit fix --force`
  would only "fix" it by downgrading `eslint-config-next` to v14 (breaking).
  These packages are build-time dev dependencies only, are never bundled into
  the container images, and are not reachable from any shipped runtime code.
  Trivy reports them as `fixed` (GHSA/npm advisory) but excludes them with
  `--ignore-unfixed` since no fix exists. Status: tracked, revisit on upstream
  patch.
- **Trivy requires `requirements.txt`-named manifests.** Non-`requirements.txt`
  files (e.g. `requirements-dev.txt`, `requirements-tools.txt`) are not
  auto-detected, and Trivy's heuristic also skips requirement files under
  directories whose names suggest dev/test tooling. The workflow stages those
  manifests under neutral names for an explicit second scan so they are always
  covered.
- **Base image npm-tooling CVEs.** The `node:22-alpine` base image bundles
  `npm`, whose vendored packages carry unfixed HIGH CVEs. The runtime stage
  removes bundled npm entirely (the app runs `next start`, not npm), so CI
  does not scan it.

## 4. Pipeline hygiene

- **Least privilege:** workflow-wide `permissions: contents: read`; no secrets
  are stored. Only the jobs that need them request extra scope — `publish`/`sign`
  add `packages: write`, `sign` adds `id-token: write` **solely** for keyless OIDC
  signing, and `verify`/`deploy` add `packages: read`.
- **Pinned actions:** every GitHub Action is pinned by commit SHA with a `# vN`
  tag comment. Update by re-resolving the tag and checking the diff.
- **Pinned tools:** `requirements-tools.txt` and the workflow `env` block pin
  ruff, semgrep, gitleaks, trivy, syft, and cosign. Keep the two in sync; there
  is a comment in each file reminding you.
- **No committed keys:** the only signing key material (the local ephemeral Cosign
  key) lives in the gitignored `.supplychain/` directory; CI signing is keyless.
- **No `continue-on-error`:** every check above must pass for the pipeline to
  go green. `workflow_dispatch` allows manual re-runs.