# SecureCloud

A small cloud deployment management platform: users create cloud projects and trigger
deployments for them.

This repository is built in phases. **Phase 1: application + Docker** ✅,
**Phase 2: CI/CD + shift-left security** ✅, **Phase 3: local Kubernetes
deployment** ✅, and **Phase 4: Kubernetes security & policy enforcement** ✅
are complete. Authentication and infrastructure-as-code are intentionally not
part of these phases, nor are runtime detection (Falco) or supply-chain signing
(Cosign).

## Stack

| Layer     | Technology                                              |
| --------- | ------------------------------------------------------- |
| Frontend  | Next.js 16 (App Router), TypeScript                     |
| Backend   | Python 3.12, FastAPI, Pydantic v2, SQLAlchemy 2         |
| Database  | PostgreSQL 16                                           |
| Tests     | pytest, FastAPI `TestClient`                            |
| Security  | ruff, ESLint, Semgrep, Gitleaks, Trivy                  |
| Policy    | Kyverno (admission policies), K8s RBAC least privilege  |
| CI/CD     | GitHub Actions (`.github/workflows/ci.yml`)             |
| Runtime   | Docker Compose **and** Kubernetes (k3d, Phase 3)        |

## Architecture

```
                       docker compose up --build
┌──────────────┐        ┌──────────────────────┐        ┌──────────────────────┐
│   Browser    │───────▶│  frontend  :3000     │        │  db  postgres:16     │
│              │  HTTP  │  Next.js (React UI)  │        │  port 5432 (internal)│
└──────────────┘        └──────────┬───────────┘        └──────────▲───────────┘
                                   │ NEXT_PUBLIC_API_URL          │ SQL
                                   │ (http://localhost:8000)      │
                                   ▼                              │
                        ┌──────────────────────┐                  │
                        │  backend  :8000      │──────────────────┘
                        │  FastAPI + SQLAlchemy│
                        │  /docs (OpenAPI)     │
                        └──────────────────────┘
```

- The browser calls the backend directly at `http://localhost:8000` (CORS is configured
  via `CORS_ORIGINS`).
- The backend connects to PostgreSQL through the `DATABASE_URL` environment variable.
- All three services are wired together by `docker-compose.yml`.

## Requirements

- Docker with Docker Compose v2 (`docker compose version`)

That's it. Python, Node.js, and PostgreSQL are **not** required to run the app.
(They are only needed for the optional local-development and security-check
commands in the sections below.)

## Quick start

```bash
cp .env.example .env
# edit .env and set a real POSTGRES_PASSWORD (URL-safe: letters, digits, _ -)

docker compose up --build
```

Then open:

| What                    | URL                            |
| ----------------------- | ------------------------------ |
| Frontend UI             | http://localhost:3000          |
| Backend API             | http://localhost:8000          |
| Interactive API docs    | http://localhost:8000/docs     |
| Health check            | http://localhost:8000/api/health |
| Database health check   | http://localhost:8000/api/health/db |

Check and stop the stack:

```bash
docker compose ps                # all three services should show (healthy)
docker compose down              # stop, keep database data
docker compose down -v           # stop and delete database data
```

Both images define a `HEALTHCHECK`, so `docker compose ps` reports `(unhealthy)` if
the API or UI stops answering.

## Using the UI

1. Open http://localhost:3000 — the dashboard loads data from the API (watch the
   `API online` badge in the top right).
2. **Users** — add a user (email + name). Duplicates are rejected with `409`.
3. **Projects** — pick an owner from the users you created.
4. **Deployments** — pick a project and an environment (`development`, `staging`,
   `production`) and hit *Deploy*. New deployments start as `pending`.
5. Errors from the API (validation, not found, conflicts) appear as a red banner —
   no page reload needed.

## Configuration

All configuration comes from environment variables — nothing is hardcoded.

| Variable                | Used by   | Default / example              | Purpose                          |
| ----------------------- | --------- | ------------------------------ | -------------------------------- |
| `POSTGRES_USER`         | db, backend | `securecloud`                | PostgreSQL user                  |
| `POSTGRES_PASSWORD`     | db, backend | *(set in `.env`)*            | PostgreSQL password              |
| `POSTGRES_DB`           | db, backend | `securecloud`                | PostgreSQL database name         |
| `DATABASE_URL`          | backend   | set by compose from the above | SQLAlchemy connection URL        |
| `CORS_ORIGINS`          | backend   | `http://localhost:3000`       | Allowed browser origins (comma separated) |
| `ENVIRONMENT`           | backend   | `development`                 | Runtime label                    |
| `NEXT_PUBLIC_API_URL`   | frontend (build time) | `http://localhost:8000` | Backend URL used by the browser  |

`.env` is gitignored. `.env.example` contains placeholders only — never commit real secrets.

## API

| Method | Path                     | Description                       | Errors                     |
| ------ | ------------------------ | --------------------------------- | -------------------------- |
| GET    | `/api/health`            | Liveness                          | –                          |
| GET    | `/api/health/db`         | Database connectivity             | `503` if DB unavailable    |
| POST   | `/api/users`             | Create user                       | `409` duplicate email, `422` validation |
| GET    | `/api/users`             | List users (`?limit=&offset=`)    | –                          |
| POST   | `/api/projects`          | Create project                    | `404` unknown owner, `422` |
| GET    | `/api/projects`          | List projects (`?limit=&offset=`) | –                          |
| GET    | `/api/projects/{id}`     | Get one project                   | `404`                      |
| POST   | `/api/deployments`       | Create deployment                 | `404` unknown project, `422` invalid environment |
| GET    | `/api/deployments`       | List deployments (`?limit=&offset=`) | –                       |
| GET    | `/api/deployments/{id}`  | Get one deployment                | `404`                      |

Example:

```bash
curl -X POST http://localhost:8000/api/users \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "full_name": "Alice"}'

curl -X POST http://localhost:8000/api/projects \
  -H "Content-Type: application/json" \
  -d '{"name": "web-app", "description": "demo", "owner_id": 1}'

curl -X POST http://localhost:8000/api/deployments \
  -H "Content-Type: application/json" \
  -d '{"project_id": 1, "environment": "production"}'
```

Rules enforced by validation:

- `email` must be a valid email address and unique (`409` on duplicate).
- `environment` must be one of `development`, `staging`, `production`.
- A project must reference an existing user; a deployment must reference an existing project.
- A new deployment always starts with status `pending`.

## Database

Tables: `users`, `projects`, `deployments`.

- Schema is created automatically when the backend starts (`Base.metadata.create_all`),
  after a short retry loop that waits for PostgreSQL to become ready.
- Data is persisted in the Docker volume `postgres-data`.
- Migrations (e.g. Alembic) are deferred to a later phase — the schema is stable for Phase 1.

## Security & CI/CD (Phase 2)

On every push to `main` and on every pull request, GitHub Actions runs the
pipeline in `docs/SECURITY-PIPELINE.md` — **every check below must pass**; a
finding fails the workflow (no `continue-on-error` anywhere):

```text
lint  ->  unit-tests  ->  sast  ->  secret-scan  ->  dependency-scan  ->  docker-build  ->  container-scan
ruff + eslint       pytest         semgrep        gitleaks          trivy fs          docker compose    trivy image
```

| Check               | Tool                | Threshold                             |
| ------------------- | ------------------- | ------------------------------------- |
| Lint                | ruff, ESLint        | any finding                          |
| Unit tests          | pytest              | any failure (19 tests)               |
| SAST                | Semgrep `p/ci`      | any finding                          |
| Secret scan         | Gitleaks            | any leak                             |
| Dependency scan     | Trivy fs            | HIGH/CRITICAL with a fix available   |
| Container scan      | Trivy image         | HIGH/CRITICAL with a fix available   |

The full scanner-by-scanner guide, failure criteria, fix instructions, and
local reproduction commands live in [**docs/SECURITY-PIPELINE.md**](docs/SECURITY-PIPELINE.md).

## Running on Kubernetes (Phase 3)

The same application can run as a real Kubernetes workload on your machine with
**k3d** (k3s in Docker): non-root containers, per-workload ServiceAccounts bound
to an empty Role, resource limits, probes, read-only root filesystems, an empty
Secrets boundary, and a Traefik ingress.

```bash
make cluster-up       # or: bash scripts/cluster-up.sh   (create the k3d cluster)
make deploy           # or: bash scripts/deploy.sh       (build images, secrets, apply, rollout)
make verify           # or: bash scripts/verify.sh       (T1-T6 end-to-end checks)
make status           # or: bash scripts/status.sh       (cluster + workload state)
make logs             # or: bash scripts/logs.sh         (tail pod logs)
```

The app then serves at http://localhost:8080. Full manifest walkthrough,
security posture, troubleshooting, and the k3d-vs-kind decision are documented
in [**docs/PHASE-3-KUBERNETES.md**](docs/PHASE-3-KUBERNETES.md).

## Kubernetes security & policy enforcement (Phase 4)

Admission policies from **Kyverno** enforce the cluster baseline secure-by-default:
no root, no privilege escalation, drop all capabilities, resource limits, no
`latest` tags, approved registries, no host networking, and no hostPath. Each
policy ships with a deliberate violating manifest and a compliant one, and is
tested in audit mode then enforced. RBAC is reviewed for least privilege (empty
Role, no `cluster-admin`, no auto-mounted tokens).

```bash
make kyverno            # or: bash scripts/kyverno-install.sh   (install the engine)
make policies-audit     # apply policies in audit mode (measure via PolicyReports)
make policies-enforce   # block violations
make policy-test        # or: bash scripts/policy-test.sh        (bad rejected, good accepted)
make rbac-review        # or: bash scripts/rbac-review.sh        (least privilege)
```

Threat model, per-policy threat/bad-example/policy/expected-result/secure-version
documentation, and the RBAC findings live in
[**docs/PHASE-4-KUBERNETES-SECURITY.md**](docs/PHASE-4-KUBERNETES-SECURITY.md).

## Running without Docker (development)

Backend with SQLite (no PostgreSQL needed for local development — `DATABASE_URL` is
required and simply points at a local file):

```bash
cd app/backend
python -m venv .venv
# Linux/macOS: source .venv/bin/activate
# Windows cmd: .venv\Scripts\activate
pip install -r requirements-dev.txt

# Linux/macOS:
export DATABASE_URL="sqlite:///./securecloud.db"
# Windows cmd:
set DATABASE_URL=sqlite:///./securecloud.db
# Windows PowerShell:
$env:DATABASE_URL="sqlite:///./securecloud.db"

uvicorn app.main:app --reload
```

Frontend:

```bash
cd app/frontend
npm install
npm run dev
```

Frontend runs on http://localhost:3000 and talks to the backend at
`NEXT_PUBLIC_API_URL` (defaults to `http://localhost:8000`).

> Note: the dev servers use the same ports (3000 / 8000) as the Docker stack.
> Run `docker compose stop` first, or use different ports.

## Tests

```bash
cd app/backend
pip install -r requirements-dev.txt
pytest          # 19 tests, < 1s
```

The suite contains **19 tests** running against an in-memory SQLite database. It covers
every endpoint, including validation failures (`422`), not-found cases (`404`), and
duplicate email conflicts (`409`).

## Verification status

Everything documented here has been run and verified locally:

| Check                     | Result                                          |
| ------------------------- | ----------------------------------------------- |
| `docker compose up --build` | all 3 containers `healthy`                   |
| API smoke test            | all endpoints + error codes (404/409/422/503) + CORS |
| Database                  | schema auto-created in PostgreSQL; data verified via `psql`; persists across restarts |
| Backend tests             | 19/19 passed (`pytest`)                         |
| Frontend production build | `next build` clean (TypeScript + compile)       |
| Frontend dev flow         | `npm run dev` serves the dashboard              |
| Backend lint              | `ruff check` + `ruff format --check` clean      |
| Frontend lint             | `eslint .` clean (Next.js core-web-vitals + TS) |
| SAST                      | Semgrep `p/ci`: 0 findings (50 rules, 41 files) |
| Secret scan               | Gitleaks: no leaks (git history + working tree) |
| Dependency scan           | Trivy fs: 0 HIGH/CRITICAL (fixable) over Python manifests + npm lockfile |
| Container scan            | Trivy image: 0 fixable HIGH/CRITICAL on `securecloud-backend` and `securecloud-frontend` |
| Workflow validation       | YAML parses + actionlint clean (+ chain verified) |
| Kubernetes (k3d)          | cluster up; 3 workloads Ready; ingress /api + / serve; backend→PG read/write via Secret DSN (T1–T6) |
| K8s policy (Kyverno)      | 8 policies: audit reports violations; enforce rejects all 8 bad manifests, accepts the compliant one (`make policy-test`) |
| K8s RBAC                  | least privilege confirmed: no ClusterRoleBinding, no cluster-admin, tokens not auto-mounted, sensitive verbs denied (`make rbac-review`) |

## Project structure

```
SecureCloud/
├── docker-compose.yml          # db + backend + frontend
├── .env.example                # configuration template (copy to .env)
├── requirements-tools.txt      # pinned dev/sec tools (keep in sync with ci.yml)
├── Makefile                    # Phase 3/4 helpers: cluster-up/down, deploy, verify, kyverno, policies, rbac-review
├── .github/workflows/ci.yml    # Phase 2 pipeline (7 chained jobs)
├── docs/
│   ├── SECURITY-PIPELINE.md         # scanner guide + local reproduction commands
│   ├── PHASE-3-KUBERNETES.md        # k3d deployment guide + security posture
│   └── PHASE-4-KUBERNETES-SECURITY.md # threat model, policies, RBAC, policy-as-code
├── scripts/                    # shell helpers (lib, cluster-up/down, deploy, status, logs, verify, kyverno-install, policy-test, rbac-review)
├── kubernetes/                 # manifests
│   ├── base/                   # namespaced workloads (Deployments, StatefulSet, Services)
│   ├── rbac/                   # per-workload ServiceAccounts (no token) + empty Role
│   ├── network-policies/       # default-deny + explicit allows (needs a CNI that enforces)
│   ├── ingress/                # Traefik ingress (/api, /)
│   ├── policies/               # Phase 4 Kyverno ClusterPolicies (base=audit, enforce/ overlay)
│   ├── policy-tests/           # bad/ violations + good/ compliant example
│   └── overlays/local/         # kustomize overlay + secretGenerator (secret.env, gitignored)
├── app/
│   ├── backend/
│   │   ├── Dockerfile
│   │   ├── pyproject.toml      # ruff config
│   │   ├── requirements.txt
│   │   ├── requirements-dev.txt
│   │   ├── pytest.ini
│   │   ├── app/
│   │   │   ├── main.py         # app factory, CORS, error handling, schema init
│   │   │   ├── config.py       # settings from environment variables
│   │   │   ├── database.py     # engine + session factory
│   │   │   ├── models.py       # SQLAlchemy models
│   │   │   ├── schemas.py      # Pydantic request/response schemas
│   │   │   ├── deps.py         # DB session dependency
│   │   │   └── routers/        # health, users, projects, deployments
│   │   └── tests/              # pytest suite
│   └── frontend/
│       ├── Dockerfile
│       ├── eslint.config.mjs   # ESLint flat config (core-web-vitals + TS)
│       ├── lib/api.ts          # typed API client
│       └── app/                # Next.js App Router UI
```

## Roadmap

- **Phase 1:** application + Docker + tests ✅
- **Phase 2:** CI/CD + shift-left security pipeline ✅
- **Phase 3:** local Kubernetes deployment (k3d) ✅
- **Phase 4:** Kubernetes security & policy enforcement (Kyverno + RBAC) ✅
- Later phases: authentication, infrastructure-as-code, runtime detection
  (Falco) & supply-chain signing (Cosign) — not implemented yet.
