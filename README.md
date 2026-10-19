# Kube Cluster Template

A hands-on 2-node Kubernetes cluster on cheap [BinaryLane](https://www.binarylane.com.au/) VPSs,
provisioned with Terraform and deployed with raw `kubectl` manifests. Built for learning — no Helm,
no managed K8s, everything visible from the terminal.

- **Distribution:** [k3s](https://k3s.io) (lightweight Kubernetes in a single binary)
- **Topology:** 1 control plane (`k8s-master`) + 1 worker (`k8s-worker`)
- **Demo stack:** nginx → Node.js API → PostgreSQL, in the `dev` namespace
- **Monitoring:** `kubectl` + `k9s`

```
Browser ──► nginx (frontend) ──► api ──► postgres
            NodePort :30080     ClusterIP    ClusterIP + PVC
```

---

## Repo layout

```
.
├── deploy.sh                # one command: fetch kubeconfig + apply all manifests
├── destroy.sh               # one command: terraform destroy + unlink kubectl
├── docs/
│   ├── kubernetes-cluster-guide.md        # full narrative walkthrough
│   ├── terraform-manifests-reference.md   # every .tf file and manifest, explained
│   └── kubectl-cheatsheet.md              # cluster/node/pod + exec + teardown commands
├── manifests/               # the Kubernetes objects (applied in numeric order)
│   ├── 00-namespace.yaml            # Namespace `dev`
│   ├── 01-secret.yaml               # Secret db-secret (POSTGRES_PASSWORD)
│   ├── 02-configmap.yaml            # ConfigMap db-config (POSTGRES_DB/USER)
│   ├── 10-postgres-pvc.yaml         # PersistentVolumeClaim (1Gi, local-path)
│   ├── 11-postgres.yaml             # Postgres Deployment + Service
│   ├── 12-api.yaml                  # API Deployment + Service
│   ├── 13-nginx-config.yaml         # nginx reverse-proxy config (ConfigMap)
│   └── 14-frontend.yaml             # nginx Deployment + NodePort Service :30080
├── terraform/               # creates the 2 servers + auto-installs k3s via cloud-init
└── src/                     # local secrets (.env — gitignored)
```

---

## Prerequisites

- Terraform ≥ 1.5
- `kubectl` (and optionally `k9s`) — `brew install kubectl k9s`
- `sshpass` — `brew install hudochenkov/sshpass/sshpass` (used by `deploy.sh` to copy the kubeconfig)
- Docker *(optional)* — only to build the real Node.js API image (see note below)

---

## Quick start

### 1. Configure secrets

```bash
# Copy the template and fill in real values
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
#   root_password = ...
#   k3s_token     = $(openssl rand -hex 16)

# BinaryLane API token lives in src/.env (gitignored)
```

### 2. Provision the servers + install k3s

```bash
cd terraform
export BINARYLANE_API_TOKEN="$(grep '^BINARYLANE_API_TOKEN=' ../src/.env | cut -d= -f2-)"
terraform init
terraform apply
```

This creates both servers and installs k3s on first boot (control plane + worker that joins it).

### 3. Deploy the stack

Edit `deploy.sh`'s CONFIG block with your server IP/password, then:

```bash
./deploy.sh
```

This installs `kubectl` if needed, copies the kubeconfig from the control plane, and applies every
manifest in order, waiting for each tier to become Ready.

### 4. Verify

```bash
kubectl get nodes                       # both Ready
kubectl -n dev get all                  # pods, services, deployments
curl http://<MASTER_IP>:30080/          # → "Hello from the API (public test image)"
```

---

## Teardown

```bash
./destroy.sh
```

Runs `terraform destroy` (deletes both servers and the cluster) then unlinks `kubectl`. Use
`SKIP_TERRAFORM=1 ./destroy.sh` to only unlink `kubectl` and keep the servers.

---

## Notes

- **The API image is a placeholder.** `manifests/12-api.yaml` uses the public `hashicorp/http-echo`
  image so the whole `nginx → api → postgres` networking path works with zero build step. To have the
  API actually query PostgreSQL, build the Node.js app from `docs/kubernetes-cluster-guide.md` §7.2,
  push it, and swap the `image:` line (a comment in the file shows how).
- **`curl` only proves networking.** The public API image doesn't hit Postgres; the database tier is
  verified separately (`kubectl -n dev exec -it deploy/postgres -- psql -U demo -d demo`).
- **Everything secret is gitignored** — `src/.env`, `terraform.tfvars`, `*.tfstate*`, `.terraform/`.
  The templates (`terraform/templates/*.tftpl`) and `.terraform.lock.hcl` are intentionally committed.

## Docs

- [`docs/kubernetes-cluster-guide.md`](docs/kubernetes-cluster-guide.md) — the full "why + how".
- [`docs/terraform-manifests-reference.md`](docs/terraform-manifests-reference.md) — file-by-file reference.
- [`docs/kubectl-cheatsheet.md`](docs/kubectl-cheatsheet.md) — every command, including `exec` and teardown.
