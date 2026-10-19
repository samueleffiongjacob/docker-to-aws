# biodata

A small full-stack app for capturing and listing **biodata records** (name, contact,
date of birth, sex, height/weight, blood type, notes). It is deliberately built as
three separable pieces so the whole thing runs with one `docker compose up`:

- **`backend/`** — Python 3.12 / FastAPI service backed by Postgres 16
  (SQLAlchemy 2.x, psycopg 3, Alembic, pydantic v2). Owns the data and the
  validation rules.
- **`frontend/`** — Next.js 15 App Router UI (TypeScript strict, Tailwind CSS v4).
  The browser **never** talks to the Python service directly; the Next app proxies
  through its own route handlers under `/api/*`.
- **`db`** — Postgres 16, one named volume, published on host port **5433** so it
  does not collide with a Postgres you may already run locally.

The one behaviour worth calling out up front: **creating a record is replay-safe**.
See [Idempotency](#idempotency-guarantee).

---

## Architecture

```mermaid
flowchart LR
    subgraph browser["Browser"]
        UI["Next.js UI<br/>(client components)"]
    end

    subgraph frontendc["frontend container :3000"]
        RH["Route handlers<br/>/api/bio-records"]
    end

    subgraph backendc["backend container :8000"]
        API["FastAPI<br/>/api/v1/bio-records<br/>/health"]
        MIG["Alembic migrations<br/>(run at startup)"]
    end

    subgraph dbc["db container :5432 → host 5433"]
        PG[("Postgres 16<br/>bio_records")]
    end

    UI -->|"fetch + Idempotency-Key"| RH
    RH -->|"BACKEND_URL=http://backend:8000"| API
    API -->|"DATABASE_URL (psycopg 3)"| PG
    MIG --> PG

    classDef box fill:#0d1117,stroke:#30363d,color:#e6edf3;
```

Startup order is enforced by compose: `db` must pass its `pg_isready`
healthcheck before `backend` starts, and `backend` must pass `/health` before
`frontend` starts.

---

## Quickstart (Docker)

Requires Docker Engine 24+ with the Compose v2 plugin.

```bash
cp .env.example .env      # defaults work as-is for local use
make up                   # == docker compose up -d --build
```

Then:

| what              | where                                   |
|-------------------|-----------------------------------------|
| UI                | <http://localhost:3000>                   |
| API health        | <http://localhost:8000/health>            |
| API records       | <http://localhost:8000/api/v1/bio-records>|
| Postgres          | `localhost:5433` (user/pass `biodata`)  |

Useful targets:

```bash
make logs      # follow all service logs
make migrate   # run `alembic upgrade head` against the running stack
make build     # build both images
make down      # stop and drop volumes
make clean     # down + remove local images and caches
```

The backend container runs migrations then serves, via the compose `command`:

```
sh -c "uv run alembic upgrade head && uv run python -m biodata"
```

---

## Local dev without Docker

Start just Postgres, then run each service on the host:

```bash
docker compose up -d db          # Postgres on localhost:5433
```

**Backend** (cwd `backend/`, needs [uv](https://docs.astral.sh/uv/)):

```bash
uv sync --frozen
export DATABASE_URL=postgresql+psycopg://biodata:biodata@localhost:5433/biodata
uv run alembic upgrade head
uv run uvicorn biodata.app:app --reload --port 8000
```

**Frontend** (cwd `frontend/`, Node 22):

```bash
npm ci
BACKEND_URL=http://localhost:8000 npm run dev
```

Checks, mirroring CI exactly:

```bash
# backend/
uv run ruff check . && uv run ruff format --check . && uv run mypy src && uv run pytest -q
# frontend/
npm run lint && npm run typecheck && npm run build && npm test
# both, from the repo root:
make lint && make test
```

---

## Environment variables

Copy `.env.example` → `.env`. Nothing secret is committed; compose reads `.env`
and falls back to the defaults shown below.

| variable             | service   | default                                                      | notes |
|----------------------|-----------|--------------------------------------------------------------|-------|
| `POSTGRES_USER`      | db        | `biodata`                                                    | |
| `POSTGRES_PASSWORD`  | db        | `biodata`                                                    | change for anything non-local |
| `POSTGRES_DB`        | db        | `biodata`                                                    | |
| `POSTGRES_HOST_PORT` | db        | `5433`                                                       | host port mapped to container `5432` |
| `DATABASE_URL`       | backend   | `postgresql+psycopg://biodata:biodata@db:5432/biodata`       | SQLAlchemy URL; use `localhost:5433` off-compose |
| `CORS_ORIGINS`       | backend   | `http://localhost:3000`                                      | comma separated |
| `LOG_LEVEL`          | backend   | `INFO`                                                       | |
| `BACKEND_HOST_PORT`  | backend   | `8000`                                                       | |
| `BACKEND_URL`        | frontend  | `http://backend:8000`                                        | **server-side only**, never exposed to the browser |
| `FRONTEND_HOST_PORT` | frontend  | `3000`                                                       | |
| `TEST_DATABASE_URL`  | tests/CI  | see `.env.example`                                           | database the backend test suite targets |

---

## HTTP API

Backend, prefix `/api/v1` (health is bare `/health`):

| method | path                       | notes |
|--------|----------------------------|-------|
| GET    | `/health`                  | `200 {"status":"ok","database":"ok"}`; `503` with `"database":"error"` if the DB ping fails |
| POST   | `/api/v1/bio-records`      | requires `Idempotency-Key` header (8..128 chars). `201` created · `200` replay of an identical body · `409` same key with a *different* body · `422` validation error |
| GET    | `/api/v1/bio-records`      | `?limit=` (1..100, default 20) `&offset=` (>= 0, default 0) → `{"items":[…],"total":int,"limit":int,"offset":int}`, ordered `created_at DESC` |
| GET    | `/api/v1/bio-records/{id}` | `200` record · `404` unknown id |

Frontend proxy route handlers (what the browser actually calls):

| method | path                  | forwards to |
|--------|-----------------------|-------------|
| POST   | `/api/bio-records`    | `POST /api/v1/bio-records`, passing through the client-generated `Idempotency-Key` and the backend's status + JSON verbatim |
| GET    | `/api/bio-records`    | `GET /api/v1/bio-records?limit=&offset=` |

A record stores the columns of `bio_records`; `age` and `bmi` are **derived on
read** and never stored.

Example:

```bash
curl -i -X POST http://localhost:8000/api/v1/bio-records \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{
    "full_name": "Ada Lovelace",
    "email": "ada@example.com",
    "date_of_birth": "1990-05-02",
    "sex": "female",
    "height_cm": 170.0,
    "weight_kg": 62.5,
    "blood_type": "O+",
    "country": "NG"
  }'
```

---

## Idempotency guarantee

`POST /api/v1/bio-records` is safe to retry. The client generates an
`Idempotency-Key` (`crypto.randomUUID()`) once per logical submission and sends it
on every attempt, including retries.

- The table has a **UNIQUE constraint on `idempotency_key`**, and the insert uses
  on-conflict handling — not a read-then-write, which would race under concurrency.
- First request with a key → **`201`** and the new record.
- Same key, byte-identical body → **`200`** and the *same* record, unchanged. No
  duplicate row, no second side effect.
- Same key, different body → **`409 idempotency_key_reuse`**, so a key is never
  silently reused for different data.

This is verified in CI, not just documented: the `compose-smoke` job POSTs the same
payload twice with one key against the real stack and fails unless the first is
`201`, the second is `200`, and both return an identical `id`.

---

## How CI works

`.github/workflows/ci.yml` runs on every push and pull request, with
`concurrency` cancelling superseded runs and `permissions: contents: read`.

| job             | what it does |
|-----------------|--------------|
| `backend`       | `postgres:16` service container (health-gated), `TEST_DATABASE_URL` set, uv installed via `astral-sh/setup-uv` with caching, then `uv sync --frozen` → `ruff check` → `ruff format --check` → `mypy src` → `pytest -q` |
| `frontend`      | `actions/setup-node@v4`, Node 22, npm cache, then `npm ci` → `npm run lint` → `npm run typecheck` → `npm run build` → `npm test` |
| `docker`        | builds **both** images with buildx / `docker/build-push-action` using GitHub Actions layer cache. **Build only — nothing is pushed.** |
| `compose-smoke` | needs the three above; `docker compose up -d --build`, waits for `/health` and the frontend to answer, runs the idempotent-replay assertion, dumps `docker compose logs` on failure, and `docker compose down -v` always |

`.github/dependabot.yml` keeps uv, npm, Docker base images and GitHub Actions
up to date on a weekly cadence.

---

## Repo layout

```
backend/            FastAPI service (src/biodata, alembic/, tests/)
  Dockerfile        multi-stage, uv install, non-root, healthchecked
frontend/           Next.js app (src/app, route handlers under /api)
  Dockerfile        multi-stage node:22-alpine, non-root
docker-compose.yml  db + backend + frontend
Makefile            up / down / logs / migrate / test / lint / build / clean
.github/            CI workflow + dependabot
.env.example        every knob, with safe local defaults
CONTRACT.md         the shared spec all three services are built against
```

## tsexample

## dockerts-deploy-actions

## Biodata on Kubernetes (Helm)

One chart, two places: **k3s on the EC2 server** and **your local cluster**. It runs
**next to** the Docker Compose stack, never instead of it, so nothing clashes.

## Ports

| What | Docker stack (EC2) | Kubernetes (EC2 and local) |
| --- | --- | --- |
| Frontend | 3000 | **3300** |
| Backend | 8000 | **8300** |
| Postgres | 127.0.0.1:5433 | cluster-internal only (not published) |

Local machine: 3000, 8000, 8001 and 8080 are left alone. Pick other ports with
`--set frontend.service.port=... --set backend.service.port=...`.

Kubernetes has its **own database** (its own volume). It does not share data with the
Docker stack's `biodata_db_data`.

## Layout

```
helm/biodata/
  Chart.yaml
  values.yaml          defaults (safe, no password: the chart refuses to render without one)
  values-local.yaml    local cluster: images built locally, dev-only password
  values-ec2.yaml      server: non-secret settings
  templates/           db (StatefulSet+PVC), backend, frontend, config, secrets, optional ingress
scripts/k8s-local.sh   local build + load + helm
ansible/k8s-*.yml      k3s + Helm install and chart deploy on EC2
.github/workflows/deploy-k8s.yaml
```

## Run it locally

```bash
scripts/k8s-local.sh up        # builds both images, loads them into k3s, helm install
scripts/k8s-local.sh urls      # http://localhost:3300  and  http://localhost:8300/health
scripts/k8s-local.sh status
scripts/k8s-local.sh logs
scripts/k8s-local.sh down      # remove app, keep database data
scripts/k8s-local.sh destroy   # remove app and data
```

minikube instead of k3s: `RUNTIME=minikube scripts/k8s-local.sh up` (uses NodePorts 30300/30800).
Only run one of k3s or minikube at a time.

Without the script:

```bash
docker build -t biodata-backend:local ./backend && docker build -t biodata-frontend:local ./frontend
docker save biodata-backend:local  | sudo k3s ctr images import -
docker save biodata-frontend:local | sudo k3s ctr images import -
helm upgrade --install biodata helm/biodata -n biodata --create-namespace \
  -f helm/biodata/values-local.yaml --wait
```

## Deploy to EC2

The workflow **Deploy to Kubernetes (k3s on EC2)** (`deploy-k8s.yaml`) reuses the images the
Docker workflow built. Run it from the Actions tab (**Run workflow**) and leave the tag empty to
deploy the commit you selected, or give a commit SHA.

First run: it installs k3s (Traefik disabled) and Helm, then deploys. Later runs only deploy.

Secrets it reads (same as the Docker deploy, so nothing new is required):
`EC2_HOST`, `EC2_USERNAME`, `EC2_PORT`, `EC2_SSH_KEY`, `EC2_TARGET_DIR`, `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_DB`.

Optional:

| Name | Kind | Purpose |
| --- | --- | --- |
| `K8S_CORS_ORIGINS` | secret or variable | Browser origins for the Kubernetes frontend. Default `http://<EC2_HOST>:3300,http://localhost:3300` |
| `GHCR_USERNAME` + `GHCR_PAT` | secrets | Long-lived registry login (`read:packages`) for the cluster's pull secret |
| `K8S_AUTO_DEPLOY` | variable = `true` | Also deploy to Kubernetes after every successful Docker deploy |

By hand:

```bash
cd ansible
export EC2_HOST=... EC2_SSH_KEY_FILE=~/.ssh/github_actions
export POSTGRES_USER=... POSTGRES_PASSWORD=... POSTGRES_DB=... IMAGE_REPO=owner/repo
export GHCR_USER=you GHCR_TOKEN=ghp_...
ansible-playbook k8s-site.yml -e image_tag=<commit-sha>
```

## AWS security group

Add inbound TCP **3300** (frontend) and, only if browsers must call the API directly, **8300**.
Leave 3000/8000 as they are for the Docker stack. The Kubernetes API (6443) stays closed.

## Check it on the server

```bash
sudo k3s kubectl -n biodata get pods,svc
sudo k3s kubectl -n biodata logs deploy/biodata-backend --tail=50
sudo helm status biodata -n biodata --kubeconfig /etc/rancher/k3s/k3s.yaml
curl -i http://localhost:3300 ; curl -i http://<private-ip>:8300/health
```

## Roll back / remove

```bash
sudo helm history  biodata -n biodata --kubeconfig /etc/rancher/k3s/k3s.yaml
sudo helm rollback biodata -n biodata --kubeconfig /etc/rancher/k3s/k3s.yaml     # previous revision
sudo helm uninstall biodata -n biodata --kubeconfig /etc/rancher/k3s/k3s.yaml    # keeps the DB volume
```

A failed deploy collects pod status, events and logs, then rolls back by itself when a previous
revision exists.

## Things to know

- **Memory.** Docker stack plus k3s needs roughly 2 GB RAM (t3.small or larger). The provision
  step refuses to continue on a smaller host.
- **Docker and k3s share the host's iptables.** They normally coexist. If pods cannot reach each
  other after installing k3s, check `sudo iptables -S FORWARD` and `sudo k3s kubectl get pods -A`.
- **Registry token.** With the built-in GitHub token, pods already running are fine, but a pod that
  has to pull an image after the token expired will fail. Set `GHCR_PAT` to avoid that.
- **One backend replica by default.** The backend runs database migrations at startup, so keep
  `backend.replicas: 1` unless you move migrations into a separate Job.
- **Passwords** are base64-encoded in a Kubernetes Secret, which is not encryption. Anyone with
  cluster-admin on the server can read them.
