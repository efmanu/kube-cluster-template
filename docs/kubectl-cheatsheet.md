# kubectl Cheatsheet

Every command used to run, inspect, and tear down this cluster — from your Mac. All demo-stack
commands assume the `dev` namespace (drop `-n dev` and add `-A` to see everything).

## 0. Setup (once per cluster)

```bash
# Install the CLI tools
brew install kubectl k9s

# Point kubectl at this cluster's config
export KUBECONFIG=~/.kube/k3s.yaml     # or: deploy.sh does the scp + export for you
kubectl get nodes
```

## 1. Cluster & context

```bash
kubectl config get-contexts           # list contexts in the kubeconfig
kubectl config current-context        # which one is active
kubectl config use-context default    # switch (k3s names its context "default")
kubectl cluster-info                  # control-plane endpoint + CoreDNS
kubectl get nodes                     # nodes and their status/roles/version
```

## 2. Nodes — view & delete

```bash
kubectl get nodes                     # NAME / STATUS / ROLES / AGE / VERSION
kubectl get nodes -o wide             # + internal IP, OS, kernel, container-runtime
kubectl describe node <node-name>     # capacity, allocatable, conditions, events
kubectl label node <node> tier=db     # add a label

# Safe removal (drain first so pods move off, then delete)
kubectl drain <node-name> --ignore-daemonsets
kubectl delete node <node-name>
```

## 3. Pods — create, view, delete

**Create** (almost always via a Deployment; `apply` creates whatever's in the YAML):

```bash
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-secret.yaml -f manifests/02-configmap.yaml
kubectl apply -f manifests/10-postgres-pvc.yaml -f manifests/11-postgres.yaml
kubectl apply -f manifests/12-api.yaml
kubectl apply -f manifests/13-nginx-config.yaml -f manifests/14-frontend.yaml

# ...or deploy everything at once:
kubectl apply -f manifests/

# A bare one-off pod (no Deployment):
kubectl run my-pod --image=nginx
```

**View:**

```bash
kubectl -n dev get pods                     # NAME / READY / STATUS / RESTARTS / AGE
kubectl -n dev get pods -o wide             # + node, pod IP
kubectl -n dev get pods -w                  # stream status changes (Ctrl-C to stop)
kubectl -n dev describe pod <pod-name>      # events + why it's not starting
kubectl -n dev get events --sort-by=.lastTimestamp
```

**Logs:**

```bash
kubectl -n dev logs <pod-name>              # last lines
kubectl -n dev logs -f <pod-name>           # follow / stream
kubectl -n dev logs <pod-name> --previous   # logs of a crashed/restarted container
kubectl -n dev logs deploy/postgres         # logs by Deployment name
```

**Delete:**

```bash
kubectl -n dev delete pod <pod-name>        # Deployment recreates it
kubectl -n dev delete pods -l app=frontend  # delete by label (e.g. force restart)
kubectl -n dev delete deployment <name>
kubectl delete -f manifests/14-frontend.yaml  # delete what a file created
kubectl delete namespace dev                  # nuke the whole stack
```

## 4. Deployments & Services

```bash
kubectl -n dev get all                      # pods, services, deployments, replicasets
kubectl -n dev get deploy,svc,pvc,secret,configmap
kubectl -n dev describe deploy/api

# Scale up/down
kubectl -n dev scale deployment/api --replicas=3

# Update & roll back
kubectl -n dev set image deployment/api api=<your-user>/demo-api:1.1.0
kubectl -n dev rollout status deployment/api
kubectl -n dev rollout restart deployment/api
kubectl -n dev rollout undo deployment/api
```

## 5. exec into each pod

```bash
# postgres — psql straight into the database (no intermediate shell needed)
kubectl -n dev exec -it deploy/postgres -- psql -U demo -d demo
# inside psql:  \dt  (list tables)   \q  (quit)

# frontend (nginx) — open a shell in the container
kubectl -n dev exec -it deploy/frontend -- sh
#   nginx -t                        # test the config
#   cat /etc/nginx/conf.d/default.conf
#   curl -s http://api:3000/        # nginx can reach the API Service by name

# api — currently hashcoder/http-echo, which has NO shell (scratch image), so
# `exec -- sh` fails. Use logs/port-forward instead:
kubectl -n dev logs deploy/api
kubectl -n dev port-forward svc/api 3000:3000   # then open http://localhost:3000
# Once you swap in the real Node.js image, exec works:
kubectl -n dev exec -it deploy/api -- sh
```

## 6. Namespaces

```bash
kubectl get namespaces                  # list (note: kube-system, kube-public are built-in)
kubectl create namespace dev            # imperative create
kubectl delete namespace dev            # delete it and everything in it
```

## 7. Monitoring

```bash
# CPU & memory — needs metrics-server first (k3s doesn't ship it):
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl top nodes
kubectl -n dev top pods

# Reach a Service from your laptop without a NodePort
kubectl -n dev port-forward svc/api 3000:3000

# Full terminal dashboard
k9s   # then:  :dev  →  2 (deployments)  →  d (describe)  →  l (logs)  →  s (shell)
```

k9s key bindings: `:` + namespace to switch, `0` all namespaces, `1`–`9` resource views, `/` filter,
`d` describe, `l` logs, `s` shell, `e` edit, `y` YAML, `Ctrl-D` delete, `?` help.

## 8. Teardown — destroy the cluster & unlink kubectl

Two parts: **destroy the servers** (that destroys the cluster — k3s and every pod/PVC live on the
servers), then **unlink kubectl** from your Mac.

**One command:**

```bash
./destroy.sh        # runs `terraform destroy`, then unlinks kubectl
```

**Or manually:**

```bash
# A. Destroy the servers (and everything running on them)
cd terraform
export BINARYLANE_API_TOKEN="$(grep '^BINARYLANE_API_TOKEN=' ../src/.env | cut -d= -f2-)"
terraform destroy     # type `yes` at the confirmation prompt

# B. Unlink kubectl — remove the KUBECONFIG export from ~/.zshrc
sed -i '' '/export KUBECONFIG=~\/\.kube\/k3s\.yaml/d' ~/.zshrc

# C. Delete the kubeconfig file
rm -f ~/.kube/k3s.yaml

# D. Clear it from the current terminal session
unset KUBECONFIG

# E. Verify it's unlinked — this should now error ("no configuration has been provided")
kubectl get nodes
```

> If you'd used Option B from the guide (merged the context into `~/.kube/config`) instead of a
> separate kubeconfig, replace steps B–D with `kubectl config delete-context default`.
>
> Re-running `terraform apply` + `./deploy.sh` later recreates both the cluster and the link.
