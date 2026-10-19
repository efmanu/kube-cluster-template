# Kubernetes Cluster Guide — k3s on BinaryLane

A hands-on guide to building a small Kubernetes cluster on cheap BinaryLane VPSs, deploying a
3-tier demo application (nginx → Node.js API → PostgreSQL), and monitoring it entirely from the
terminal.

- **Distribution:** [k3s](https://k3s.io) (lightweight, single-binary Kubernetes)
- **Topology:** 2 nodes — 1 control plane + 1 worker
- **Demo stack:** nginx (frontend) + Node.js API + PostgreSQL (database)
- **Monitoring:** `kubectl` + `k9s` (+ metrics-server for `kubectl top`)

---

## Table of Contents

1. [Overview & Architecture](#1-overview--architecture)
2. [Kubernetes Cluster Components](#2-kubernetes-cluster-components)
3. [Provisioning the BinaryLane Servers](#3-provisioning-the-binarylane-servers)
4. [Installing the Cluster (k3s)](#4-installing-the-cluster-k3s)
5. [Connecting from Your Mac](#5-connecting-from-your-mac)
6. [Configuration: Namespaces, ConfigMaps & Secrets](#6-configuration-namespaces-configmaps--secrets)
7. [Deploying the 3 Containers](#7-deploying-the-3-containers)
8. [Running & Operating the Cluster](#8-running--operating-the-cluster)
9. [Monitoring from the Terminal](#9-monitoring-from-the-terminal)
10. [Troubleshooting & Next Steps](#10-troubleshooting--next-steps)

---

## 1. Overview & Architecture

Kubernetes turns a group of servers into a single machine. You describe *what* you want running
("3 copies of my API, reachable on port 3000"), and Kubernetes continuously makes the actual state
match that description.

A cluster is split into two roles:

- **Control plane** — the "brain". It stores the desired state, schedules workloads, and makes
  decisions.
- **Worker node(s)** — the "muscle". They actually run your containers.

For this guide you will have **two BinaryLane VPSs**:

```
                          ┌──────────────────────────────┐
                          │      CONTROL PLANE (k3s)     │
                          │  api-server  scheduler       │
                          │  controller-manager  SQLite  │
                          │  kubelet + containerd        │
                          └──────────────┬───────────────┘
                                         │  (flannel VXLAN, port 8472/udp)
                          ┌──────────────┴───────────────┐
                          │       WORKER NODE (k3s)      │
                          │  kubelet + containerd        │
                          │  ┌─────────────────────────┐ │
                          │  │  Pod: nginx  → Pod: API │ │
                          │  │            → Pod: DB    │ │
                          │  └─────────────────────────┘ │
                          └──────────────────────────────┘
```

**Why k3s?** A full `kubeadm` install needs an `etcd` cluster and several components that add up to
1.5–2 GB RAM just for the control plane. k3s is the same Kubernetes API in a single binary, uses an
embedded SQLite datastore (or etcd if you want it), ships containerd and a networking plugin built
in, and runs comfortably on a $5/mo VPS. Everything you learn with `kubectl` is identical to a
"real" cluster.

---

## 2. Kubernetes Cluster Components

### 2.1 Control-plane components

| Component | What it does |
|-----------|--------------|
| **kube-apiserver** | The front door. Every `kubectl` command and every internal request goes through it. It validates and stores state. |
| **scheduler** | Watches for new Pods with no node assigned and picks the best node to run them on. |
| **controller-manager** | Runs "controllers" that reconcile reality with your desired state (e.g. keep 3 replicas running, fix a crashed pod). |
| **etcd** (vanilla K8s) | The key-value store holding all cluster state. **k3s default** replaces etcd with an embedded **SQLite** database — simpler and lighter. You can opt into etcd for HA with `--cluster-init`. |
| **cloud-controller-manager** | Talks to your cloud provider (load balancers, volumes). In a bare-VPS k3s setup this is largely unused; k3s bundles a built-in `ServiceLB` for `LoadBalancer` services. |

### 2.2 Worker-node components

| Component | What it does |
|-----------|--------------|
| **kubelet** | The agent on every node that receives instructions from the control plane and starts/stops containers. |
| **kube-proxy** | Implements Services: the networking rules that route traffic to the right Pods. |
| **container runtime** | The tool that actually runs containers. k3s bundles **containerd** (no Docker required on the nodes). |

### 2.3 k3s built-ins worth knowing

- **Flannel** — the default CNI (container networking) plugin, giving every Pod an IP and a flat
  network across nodes (VXLAN on `8472/udp`).
- **Traefik** — an ingress controller is bundled, so `Ingress` resources work out of the box on
  ports 80/443.
- **local-path-provisioner** — creates `PersistentVolume`s on the node's disk on demand, so a
  simple `PersistentVolumeClaim` "just works" without configuring storage.
- **ServiceLB** — answers `Service` of `type: LoadBalancer` without cloud hardware.

### 2.4 The core objects you'll use every day

| Object | Purpose |
|--------|---------|
| **Pod** | The smallest unit — one or more containers sharing a network namespace and storage. |
| **Deployment** | Declares "run N replicas of this container" and manages rolling updates. |
| **ReplicaSet** | The thing a Deployment creates to actually keep N Pods alive. |
| **Service** | A stable network address + DNS name for a set of Pods. Types: `ClusterIP` (internal), `NodePort` (node IP + port), `LoadBalancer` (external). |
| **ConfigMap** | Non-secret config (env vars, config files). |
| **Secret** | Base64-encoded sensitive data (passwords, tokens). |
| **Namespace** | A virtual partition of the cluster (e.g. `demo`, `kube-system`). |
| **PersistentVolumeClaim (PVC)** | A request for storage that survives Pod restarts. |
| **Ingress** | HTTP routing rules into the cluster (handled by Traefik here). |

---

## 3. Provisioning the BinaryLane Servers

> BinaryLane's control panel changes over time, so these are the *decisions* to make rather than
> an exact click-path. The k3s commands in the next section are identical on any provider.

Create **two** VPS instances in the same region/datacenter (so they can talk to each other over a
private network if one is available):

| | Control plane | Worker |
|---|---|---|
| **OS** | Ubuntu 22.04 or 24.04 LTS | same |
| **CPU/RAM** | 2 vCPU / 2 GB minimum | 1–2 vCPU / 1–2 GB |
| **Disk** | 20 GB | 20 GB |
| **Hostname (suggested)** | `k8s-master` | `k8s-worker` |

A cheap tier works fine for this experiment — k3s is genuinely lightweight.

### Firewall / security groups

Open these ports (in BinaryLane's firewall if it has one, and/or on the OS with `ufw`):

| Port | Protocol | Used by |
|------|----------|---------|
| 22 | TCP | SSH |
| 6443 | TCP | k3s API server (control plane) |
| 8472 | UDP | Flannel VXLAN (pod-to-pod networking between nodes) |
| 10250 | TCP | kubelet |
| 30000–32767 | TCP | `NodePort` services (we'll use one to reach nginx) |
| 80 / 443 | TCP | Traefik ingress (optional) |

On each server you can run:

```bash
sudo ufw allow 22/tcp
sudo ufw allow 6443/tcp
sudo ufw allow 8472/udp
sudo ufw allow 10250/tcp
sudo ufw allow 30000:32767/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

> ⚠️ If you lock SSH down too aggressively you'll lose access — make sure port 22 is allowed before
> enabling a firewall.

---

## 4. Installing the Cluster (k3s)

SSH into each server as root (or a sudo user). Run these as the user that can `sudo`.

### 4.1 Control plane — install the k3s **server**

```bash
# On the control-plane server
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644
```

- `--write-kubeconfig-mode 644` makes `/etc/rancher/k3s/k3s.yaml` readable by non-root users,
  which simplifies copying it to your Mac.

Check it's up:

```bash
sudo k3s kubectl get nodes
# NAME          STATUS   ROLES                  AGE   VERSION
# k8s-master    Ready    control-plane,master   30s   v1.xx.x+k3s1
```

Grab the **node token** — the worker will use this to join:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
# K10xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx::server:xxxx
```

### 4.2 Worker — install the k3s **agent**

On the worker server, set the server URL and token and run the installer:

```bash
# On the worker server — replace <CONTROL_PLANE_IP> and <TOKEN>
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<CONTROL_PLANE_IP>:6443 \
  K3S_TOKEN=<TOKEN> \
  sh -
```

### 4.3 Verify the cluster

Back on the control plane:

```bash
sudo k3s kubectl get nodes
# NAME          STATUS   ROLES                  AGE   VERSION
# k8s-master    Ready    control-plane,master   5m    v1.xx.x+k3s1
# k8s-worker    Ready    <none>                 1m    v1.xx.x+k3s1
```

Both nodes `Ready` = your cluster is live. 🎉

---

## 5. Connecting from Your Mac

Running `kubectl` on your laptop is much nicer than SSHing into the server every time.

### 5.1 Install local tools (macOS)

```bash
brew install kubectl k9s
# If k9s isn't in the default tap:  brew install derailed/k9s/k9s
```

You'll also want Docker *only* if you plan to build the API image in section 7.

### 5.2 Copy the kubeconfig

```bash
mkdir -p ~/.kube
scp root@<CONTROL_PLANE_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s.yaml
# Point it at the public IP instead of 127.0.0.1 (note: '' is macOS sed syntax)
sed -i '' 's/127.0.0.1/<CONTROL_PLANE_IP>/g' ~/.kube/k3s.yaml
```

Then either export it per-session or merge it into your default kubeconfig:

```bash
# Option A — per-session (simplest, keeps things isolated)
export KUBECONFIG=~/.kube/k3s.yaml
kubectl get nodes

# Option B — merge into the default ~/.kube/config and switch contexts
KUBECONFIG=~/.kube/config:~/.kube/k3s.yaml kubectl config view --flatten > ~/.kube/config
kubectl config use-context default   # k3s names its context "default"
```

> Tip: add `export KUBECONFIG=~/.kube/k3s.yaml` to `~/.zshrc` if you want it to persist.

---

## 6. Configuration: Namespaces, ConfigMaps & Secrets

Everything below is applied with `kubectl apply -f`. We'll put the demo stack in its own
`demo` namespace so it doesn't mix with system components.

### 6.1 Namespace

```yaml
# 00-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
```

```bash
kubectl apply -f 00-namespace.yaml
```

### 6.2 Secret (database password)

Secrets hold sensitive values. `stringData` lets you write them as plain text (Kubernetes stores
them base64-encoded).

```yaml
# 01-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
  namespace: demo
type: Opaque
stringData:
  POSTGRES_PASSWORD: change-me-please
```

### 6.3 ConfigMap (non-secret database config)

```yaml
# 02-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: db-config
  namespace: demo
data:
  POSTGRES_DB: demo
  POSTGRES_USER: demo
```

Apply both:

```bash
kubectl apply -f 01-secret.yaml -f 02-configmap.yaml
kubectl -n demo get secret,configmap
```

---

## 7. Deploying the 3 Containers

The demo stack is a classic 3-tier app:

```
Browser ──► nginx (frontend) ──► api (Node.js) ──► postgres (database)
           NodePort 30080        ClusterIP         ClusterIP + PVC
```

Services are how the tiers find each other. Each `ClusterIP` Service gets a stable DNS name inside
the cluster: `postgres.demo.svc.cluster.local`, `api.demo.svc.cluster.local`, etc. The API reaches
PostgreSQL simply by using hostname `postgres` — no IPs.

### 7.1 PostgreSQL (database)

**PersistentVolumeClaim** — k3s's `local-path-provisioner` satisfies this automatically:

```yaml
# 10-postgres-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: demo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

**Deployment + Service**:

```yaml
# 11-postgres.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              valueFrom:
                configMapKeyRef:
                  name: db-config
                  key: POSTGRES_DB
            - name: POSTGRES_USER
              valueFrom:
                configMapKeyRef:
                  name: db-config
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-secret
                  key: POSTGRES_PASSWORD
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: demo
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
```

> Note: `postgres` runs with a single replica on purpose — running multiple replicas of a stateful
> database requires more setup (a StatefulSet + read replicas) and is beyond this intro.

### 7.2 Node.js API (backend)

This tier is the only one that needs a custom image, because it contains your own code. Create a
tiny project locally, build it, and push it to a free registry (Docker Hub / GitHub Container
Registry).

**`server.js`**:

```js
const express = require('express');
const { Pool } = require('pg');

const app = express();
const port = process.env.PORT || 3000;

const pool = new Pool({
  user: process.env.POSTGRES_USER || 'demo',
  host: process.env.POSTGRES_HOST || 'postgres',
  database: process.env.POSTGRES_DB || 'demo',
  password: process.env.POSTGRES_PASSWORD,
  port: 5432,
});

app.get('/', async (_req, res) => {
  try {
    const { rows } = await pool.query('SELECT NOW() AS db_time');
    res.json({ message: 'Hello from the API', dbTime: rows[0].db_time });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.listen(port, () => console.log(`API listening on :${port}`));
```

**`package.json`**:

```json
{
  "name": "demo-api",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.19.2",
    "pg": "^8.12.0"
  }
}
```

**`Dockerfile`**:

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
EXPOSE 3000
CMD ["node", "server.js"]
```

Build and push (from your Mac):

```bash
docker build -t <your-dockerhub-user>/demo-api:1.0.0 .
docker login
docker push <your-dockerhub-user>/demo-api:1.0.0
```

**Deployment + Service** — replace `<your-dockerhub-user>` with your actual username:

```yaml
# 12-api.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: <your-dockerhub-user>/demo-api:1.0.0
          ports:
            - containerPort: 3000
          env:
            - name: POSTGRES_HOST
              value: "postgres"
            - name: POSTGRES_DB
              valueFrom:
                configMapKeyRef:
                  name: db-config
                  key: POSTGRES_DB
            - name: POSTGRES_USER
              valueFrom:
                configMapKeyRef:
                  name: db-config
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-secret
                  key: POSTGRES_PASSWORD
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: demo
spec:
  selector:
    app: api
  ports:
    - port: 3000
      targetPort: 3000
```

> **No registry / want to skip building?** You can deploy just `postgres` + `nginx` and skip the
> API for now — the guide still works for learning Services, Deployments, and NodePorts. Swap the
> API image for any public image (e.g. `traefik/whoami`) if you only want to test networking.

### 7.3 nginx (frontend)

We use the **public** `nginx` image and inject a custom config via a ConfigMap that reverse-proxies
to the API — so the frontend reaches the backend through the `api` Service DNS name, with no custom
image needed.

**ConfigMap (nginx config)**:

```yaml
# 13-nginx-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: demo
data:
  default.conf: |
    server {
      listen 80;
      location / {
        proxy_pass http://api:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
      }
    }
```

**Deployment + NodePort Service**:

```yaml
# 14-frontend.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: nginx-config
          configMap:
            name: nginx-config
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: demo
spec:
  type: NodePort
  selector:
    app: frontend
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
```

### 7.4 Apply everything (in order)

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-secret.yaml -f 02-configmap.yaml
kubectl apply -f 10-postgres-pvc.yaml -f 11-postgres.yaml
kubectl apply -f 12-api.yaml
kubectl apply -f 13-nginx-config.yaml -f 14-frontend.yaml
```

Watch the Pods come up:

```bash
kubectl -n demo get pods -w
# NAME                        READY   STATUS    RESTARTS   AGE
# postgres-xxxx               1/1     Running   0          40s
# api-xxxx                    1/1     Running   0          10s
# api-yyyy                    1/1     Running   0          10s
# frontend-xxxx               1/1     Running   0          5s
```

### 7.5 Reach it from your browser

The `frontend` Service is a `NodePort` on `30080`, so hit **either** node's public IP:

```
http://<CONTROL_PLANE_IP>:30080/    # or <WORKER_IP>:30080
```

You should see the API's JSON response — proof the whole chain works:

```json
{ "message": "Hello from the API", "dbTime": "2026-10-18T..." }
```

`nginx → api → postgres` in one request. 🎉

---

## 8. Running & Operating the Cluster

The daily `kubectl` toolkit (all from your Mac, using the `demo` namespace):

```bash
# Inspect
kubectl get namespaces
kubectl -n demo get all                       # pods, services, deployments, replicasets
kubectl -n demo get pods -o wide              # which node + pod IP
kubectl -n demo describe pod <pod-name>       # events + why it's not starting
kubectl -n demo get events --sort-by=.lastTimestamp

# Logs
kubectl -n demo logs <pod-name>               # last lines
kubectl -n demo logs -f <pod-name>            # follow / stream
kubectl -n demo logs <pod-name> --previous    # logs of a crashed container

# Shell into a container
kubectl -n demo exec -it <pod-name> -- sh

# Reach a Service from your laptop without a NodePort
kubectl -n demo port-forward svc/api 3000:3000
# now open http://localhost:3000

# Scale up / down
kubectl -n demo scale deployment/api --replicas=3

# Update & roll back
kubectl -n demo set image deployment/api api=<your-user>/demo-api:1.1.0
kubectl -n demo rollout status deployment/api
kubectl -n demo rollout restart deployment/api
kubectl -n demo rollout undo deployment/api

# Delete
kubectl -n demo delete pod <pod-name>         # Deployment recreates it
kubectl delete -f 14-frontend.yaml            # delete a resource
```

---

## 9. Monitoring from the Terminal

### 9.1 `kubectl top` (CPU & memory)

Needs **metrics-server**, which k3s doesn't install by default. Add it:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# k3s kubelet uses a self-signed cert, so allow insecure TLS scraping:
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Wait a minute, then:

```bash
kubectl top nodes
kubectl -n demo top pods
```

### 9.2 `kubectl` watch loops

```bash
kubectl -n demo get pods -w          # stream pod status changes (Ctrl-C to stop)
kubectl -n demo logs -f <pod>        # stream logs
```

### 9.3 k9s — a full terminal dashboard

k9s turns your terminal into an interactive cluster explorer. Start it with:

```bash
k9s
```

It opens on the default namespace's Pods. Essential keys:

| Key | Action |
|-----|--------|
| `:` + `namespace` | switch namespace (e.g. `:demo`) |
| `0` | show all namespaces |
| `1`–`9` | jump to a resource view (`1` pods, `2` deployments, `3` services …) |
| `/` | filter by name |
| `d` | describe the selected resource |
| `l` | logs of the selected pod |
| `s` | shell into the selected pod |
| `e` | edit the resource in `$EDITOR` |
| `y` | view YAML |
| `Shift-F` | port-forward the selected pod |
| `Ctrl-D` | delete the selected resource |
| `Ctrl-A` / `Esc` | go back |
| `?` | help |

Try: `k9s` → `:demo` → press `2` (deployments) → select `api` → `d` to describe it.

> k9s is the single biggest quality-of-life upgrade for terminal-only cluster work — learn the
> first 8 keys and you can do almost everything without memorising long `kubectl` commands.

---

## 10. Troubleshooting & Next Steps

### Common issues

| Symptom | Likely cause / fix |
|---------|--------------------|
| Worker stuck `NotReady` | Can't reach the control plane. Check `K3S_URL` IP, that port `6443` is open, and that the token was copied correctly. |
| `kubectl` from Mac times out | Firewall blocking `6443`, or the kubeconfig still points at `127.0.0.1` (see section 5.2). |
| Pod stuck `Pending` | Insufficient CPU/RAM on the node, or a PVC that can't be provisioned. Check `kubectl -n demo describe pod <pod>`. |
| Pod stuck `CrashLoopBackOff` | App exits immediately. Check `kubectl -n demo logs <pod> --previous`. For the API, usually a bad `POSTGRES_PASSWORD` or the DB isn't ready yet. |
| `kubectl top` errors | metrics-server not installed/patched yet (section 9.1), or give it a minute to scrape. |
| `ImagePullBackOff` | Wrong image name/tag, or the API image wasn't pushed as public. `docker push` again and check the image name matches the manifest. |

### Where to go next

- Add an **Ingress** so Traefik routes `api.example.com` and `www.example.com` instead of raw
  NodePorts.
- Convert PostgreSQL to a **StatefulSet** and add **readiness/liveness probes**.
- Lock down access with **RBAC** and **NetworkPolicies**.
- Learn **Helm** to install real apps (WordPress, Grafana, etc.) from charts.
- Read the official docs: [kubernetes.io/docs](https://kubernetes.io/docs) and
  [docs.k3s.io](https://docs.k3s.io).

---

*Guide built for a 2-node k3s cluster on BinaryLane VPSs. All manifests are self-contained and can
be applied as-is (after replacing the API image placeholder).*
