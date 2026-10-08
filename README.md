# SecureCloud

A small cloud deployment management platform: users create cloud projects and trigger
deployments for them.

This repository is built in phases. **This is Phase 1: application + Docker.**
Authentication, CI/CD pipelines, security scanning, and Kubernetes are intentionally
not part of this phase.

## Stack

| Layer     | Technology                                              |
| --------- | ------------------------------------------------------- |
| Frontend  | Next.js 16 (App Router), TypeScript                     |
| Backend   | Python 3.12, FastAPI, Pydantic v2, SQLAlchemy 2         |
| Database  | PostgreSQL 16                                           |
| Tests     | pytest, FastAPI `TestClient`                            |
| Runtime   | Docker Compose (local, $0, open source only)            |

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

## Running without Docker (development)

Backend with SQLite (no PostgreSQL needed for local development — `DATABASE_URL` is
required and simply points at a local file):

```bash
cd backend
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
cd frontend
npm install
npm run dev
```

Frontend runs on http://localhost:3000 and talks to the backend at
`NEXT_PUBLIC_API_URL` (defaults to `http://localhost:8000`).

> Note: the dev servers use the same ports (3000 / 8000) as the Docker stack.
> Run `docker compose stop` first, or use different ports.

## Tests

```bash
cd backend
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

## Project structure

```
SecureCloud/
├── docker-compose.yml          # db + backend + frontend
├── .env.example                # configuration template (copy to .env)
├── backend/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── requirements-dev.txt
│   ├── pytest.ini
│   ├── app/
│   │   ├── main.py             # app factory, CORS, error handling, schema init
│   │   ├── config.py           # settings from environment variables
│   │   ├── database.py         # engine + session factory
│   │   ├── models.py           # SQLAlchemy models
│   │   ├── schemas.py          # Pydantic request/response schemas
│   │   ├── deps.py             # DB session dependency
│   │   └── routers/            # health, users, projects, deployments
│   └── tests/                  # pytest suite
└── frontend/
    ├── Dockerfile
    ├── lib/api.ts              # typed API client
    └── app/                    # Next.js App Router UI
```

## Roadmap

- **Phase 1 (this):** application + Docker + tests ✅
- Later phases: authentication, CI/CD, security scanning, IaC/Kubernetes — not implemented yet.
