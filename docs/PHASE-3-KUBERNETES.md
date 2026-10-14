# Phase 3 — Local Kubernetes Deployment (k3d)

This document describes how SecureCloud runs as a full Kubernetes workload on
a developer machine with **k3d** (k3s inside Docker). It covers the directory
layout, what every manifest enforces, the command flow, and how the end-to-end
checks are structured.

Phase 3 scope: a production-shaped deployment of the existing application on a
local cluster. Observability and admission policies (Kyverno/Falco/Cosign/
Prometheus) are intentionally out of scope and left for a later phase.

```text
                  kernel: Windows (Git Bash) + Docker Desktop
┌──────────────────────────────────────────────────────────────────┐
│                        k3d cluster "securecloud"                 │
│                                                                  │
│   localhost:8080 ──▶ loadbalancer ──▶ Traefik (ingress)          │
│                                       ├─── /api ──▶ backend svc  │
│   localhost:8443 ─▶ loadbalancer ──▶   └─── / ───▶ frontend svc  │
│                                                                  │
│   ┌─────────────┐   ┌─────────────┐   ┌───────────────────────┐  │
│   │  frontend   │──▶│   backend   │──▶│       postgres        │  │
│   │  Next.js    │   │  FastAPI    │   │  StatefulSet + PVC    │  │
│   │  :3000      │   │  :8000      │   │  :5432  (local-path)  │  │
│   └─────────────┘   └─────────────┘   └───────────────────────┘  │
│   (SA + no caps)    (SA + RO fs)      (SA + non-root PGDATA)     │
└──────────────────────────────────────────────────────────────────┘
   \___ NetworkPolicies present but not enforced by flannel (see below)
```

## Why k3d

| Option | Decision |
| --- | --- |
| **k3d** | chosen — single command creates a k3s cluster in Docker; Traefik ingress and the `local-path` storage class come preinstalled; host ports are wired through the load balancer with one flag |
| kind | not chosen — requires a separate ingress controller + port-forwarding for a comparable setup |

Everything runs as normal Kubernetes objects (`Deployment`, `StatefulSet`,
`Service`, `Ingress`, ...) so the manifests are portable to any real cluster.

## Requirements

- Docker Desktop (or any Docker engine) — `docker version`
- `kubectl` (v1.36, kustomize v5.8.1 built in — any recent version works)
- `k3d` v5.x on PATH
- `openssl` (used to generate the database password on first deploy)

On a fresh machine, in one block:

```bash
k3d version                          # install k3d first (see k3d.io)
kubectl version --client             # k8s object definitions are conservative (< v1.29 API)

export PATH="/path/to/k3d:$PATH"     # Windows/Git Bash example for a local binary
```

## Quick start

```bash
# 1. create the cluster (idempotent, re-running is a no-op)
make cluster-up                      # or: bash scripts/cluster-up.sh
#    -> cluster "securecloud" + context k3d-securecloud

# 2. build images, generate secrets (once), apply manifests, wait for rollouts
make deploy                          # or: bash scripts/deploy.sh

# 3. verify from the outside and from inside the cluster
make verify                          # or: bash scripts/verify.sh
make status                          # or: bash scripts/status.sh

# tidy up later
make logs SERVICE=backend            # tail pod logs
make cluster-down                    # delete cluster + PVCs
```

The app is served at **http://localhost:8080** after `make deploy`
(K3D_HTTP_PORT, default 8080; HTTPS at localhost:8443 with an untrusted cert).

## Command reference

| Command | What it does |
| --- | --- |
| `make cluster-up` / `scripts/cluster-up.sh` | create the k3d cluster (0 extra agents, ports `8080:80` and `8443:443` on the load balancer), wait for Ready nodes |
| `make deploy` / `scripts/deploy.sh` | generate `secret.env` if missing → build & import the two images → `kubectl apply -k kubernetes/overlays/local` → wait for both Deployments and the StatefulSet to roll out |
| `make status` / `scripts/status.sh` | nodes, workloads, services/ingress/config/secret/SA/NP/PVC, image versions in use |
| `make logs` / `scripts/logs.sh [backend\|frontend\|postgres]` | tail pod logs |
| `make verify` / `scripts/verify.sh` | the T1–T6 end-to-end checks (below) |
| `make cluster-down` / `scripts/cluster-down.sh` | delete the cluster and all data |

Environment: `K3D_CLUSTER_NAME`, `K3D_HTTP_PORT`, `K3D_HTTPS_PORT`, `NAMESPACE`,
`SC_VERSION` (all defaulted in `scripts/lib.sh`). On hosts without `make`, run
the `scripts/*.sh` files directly.

## Directory layout

```
kubernetes/
├── base/                 # workload manifests, environment-agnostic
│   ├── namespace.yaml
│   ├── configmap.yaml            # POSTGRES_USER, POSTGRES_DB (non-secret)
│   ├── backend-deployment.yaml
│   ├── backend-service.yaml
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml
│   ├── postgres-statefulset.yaml # + volumeClaimTemplate (PVC on local-path)
│   ├── postgres-service.yaml     # headless (clusterIP: None) for DNS per pod
│   └── kustomization.yaml
├── rbac/                 # service accounts + a deliberately empty Role
├── network-policies/     # zero-trust intent (default-deny + explicit allows)
├── ingress/              # hostless Traefik ingress (/api and /)
└── overlays/local/       # environment overlay: namespace + secretGenerator
    └── secret.env        # NOT COMMITTED, generated by scripts/deploy.sh
```

## Security posture of the manifests

| Control | Where |
| --- | --- |
| Run as non-root, fixed uid/gid | backend & postgres `999`, frontend `1001` (`runAsNonRoot: true` at pod level) |
| No privilege escalation | `allowPrivilegeEscalation: false` on every container |
| No Linux capabilities | `capabilities.drop: [ALL]` |
| Read-only root fs | backend (`readOnlyRootFilesystem: true` + emptyDir `/tmp`); frontend has an emptyDir `/tmp` for Next.js cache |
| Least-privilege identity | one ServiceAccount per workload, bound to an **empty** Role → workloads cannot call the Kubernetes API |
| Secrets | no passwords in source; `secretGenerator` turns `secret.env` into an Opaque Secret (`securecloud-app-<hash>`), referenced by `secretKeyRef` with keys `DATABASE_URL` / `POSTGRES_PASSWORD` (both containers in the postgres/backend pods never see each other's secret) |
| Immutable image tags | `securecloud-backend:3.0.0`, `securecloud-frontend:3.0.0`, `postgres:16.15-alpine` — no `latest` |
| Resource bounds | requests + limits on every container (backend/frontend 256Mi, postgres 1Gi) |
| Health checks | startup + readiness + liveness; backend readiness hits `/api/health/db` so it only serves traffic when the database is reachable |
| Sandboxing | `seccompProfile: RuntimeDefault` on every pod |

### PostgreSQL: non-root init (the interesting bit)

The official `postgres` image declares `VOLUME /var/lib/postgresql/data`
(owned by uid 70 in the image). Running the container as a non-root user has
two traps this repo solves:

1. Mounting the PVC directly at `/var/lib/postgresql/data` leaves the directory
   owned by `root` (fsGroup only changes the *group*), and `initdb` refuses to
   `chmod` a directory it does not own.
2. Mounting the PVC at the parent and leaving the default `PGDATA` hits the
   image's built-in `data` directory, which sits on a throwaway runtime volume
   and is owned by uid 70, not the container's user.

The StatefulSet therefore mounts the PVC at `/var/lib/postgresql` and sets
`PGDATA=/var/lib/postgresql/pgdata`: the `postgres` user creates that subdir
itself inside the PVC (so initdb can own and `chmod` it) and the data persists
on real storage. An emptyDir on `/var/run/postgresql` gives the server a
writable socket directory.

### NetworkPolicies — declared, not (yet) enforced

`k3s` uses **flannel**, which does not implement NetworkPolicies, so these
controls are inert on this cluster (they are valid and applied). The set is
portable: enable Calico/Cilium on any real cluster and the zero-trust intent
(default-deny plus explicit frontend→backend and backend→postgres allows)
becomes active with the same manifests.

## Secrets

`scripts/deploy.sh` writes `kubernetes/overlays/local/secret.env` **once**:

- If `.env` holds a real password it is reused; otherwise a random 24-byte hex
  password is generated (`openssl rand -hex 24`) and reported.
- `DATABASE_URL` is derived with the SQLAlchemy DSN
  (`postgresql+psycopg://<user>:<pw>@securecloud-postgres:5432/<db>`;
  `securecloud-postgres` is the Service DNS name).

`.gitignore` excludes `kubernetes/overlays/*/secret.env`. Re-apply the overlay
after changing it (`make deploy`) so kustomize rebuilds the Secret.

## End-to-end verification (`scripts/verify.sh`)

| Check | Proves |
| --- | --- |
| **T1** | every `app.kubernetes.io/part-of=securecloud` pod reaches `Ready` within 180s |
| **T2** | frontend is served through the ingress → `http://<host>:8080/` returns 200 |
| **T3** | backend is served through the ingress → `/api/health` returns `"ok"` |
| **T4** | the running app reaches PostgreSQL → `/api/health/db` returns `"ok"` |
| **T5** | in-cluster DNS works: `frontend pod → securecloud-backend:8000` |
| **T6** | the backend pod opens a real psycopg connection using the **Secret-provided** `DATABASE_URL` |

## Troubleshooting notes

- **`Invalid scanning root` / checksum errors in CI** are Phase 2 concerns — see
  `docs/SECURITY-PIPELINE.md`. The pipeline and the cluster are unrelated.
- **Backend `CrashLoopBackOff` with `failed to resolve host 'securecloud-postgres'`:**
  database was not up (headless Service has no endpoint). Fix postgres first;
  the backend restarts on its own. If a rollout previously exceeded its progress
  deadline, delete the stuck pods (`kubectl -n securecloud delete pod --all`)
  to force fresh ones.
- **`initdb: could not change permissions of /var/lib/postgresql/data`:**
  a bad mount layout polluted the PVC. Recreate it after fixing the manifest:
  `kubectl -n securecloud delete pvc data-securecloud-postgres-0`
  (data is disposable in local dev).
- **Secret key errors** (`couldn't find key database-url ...`): kustomize emits
  the keys named exactly as they appear in `secret.env` — use `DATABASE_URL`
  and `POSTGRES_PASSWORD` in `secretKeyRef`.

## Known limitations

- Single-replica, single-node — no HA, no autoscaling.
- NetworkPolicies not enforced by flannel (see above).
- No observability or admission control (later phase).
- `k3d image import` is required after changing images; `make deploy` does this
  automatically.