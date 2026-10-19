# Biodata on Kubernetes (Helm)

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
