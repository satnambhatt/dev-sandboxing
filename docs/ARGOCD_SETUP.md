# ArgoCD Setup

End-to-end guide to wiring up per-PR preview environments in a cloud cluster. For the pattern and motivation, see [`article.md`](article.md); for the ApplicationSet YAML itself, see `gitops/applicationset.yaml`.

## Prerequisites

- A Kubernetes cluster (EKS, GKE, AKS, or similar) with **cluster-admin** access.
- A container registry that the cluster can pull from (ECR, GHCR, GCR, Docker Hub private, etc.).
- A **wildcard DNS record** — e.g., `*.sandbox.example.com` pointing at your ingress controller's external LB. Without this, the per-PR hostnames won't resolve.
- An **ingress controller** installed in the cluster (this chart assumes `nginx` by default; configurable via `global.ingress.className`).
- A **GitHub personal access token** (or GitHub App token) with `repo` scope — ArgoCD uses it to list open PRs.

## 1. Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for pods:
```bash
kubectl -n argocd wait --for=condition=available --timeout=5m deployment --all
```

Access the UI (for debugging — not required for the flow):
```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# visit https://localhost:8080, username "admin"
# password: kubectl -n argocd get secret argocd-initial-admin-secret \
#   -o jsonpath='{.data.password}' | base64 -d
```

## 2. Install the ApplicationSet controller

Modern ArgoCD installs include the ApplicationSet controller by default. Verify:

```bash
kubectl -n argocd get deployment argocd-applicationset-controller
```

If it's missing, apply the controller manifest from the Argo CD releases page for your version.

## 3. Create the GitHub token secret

The PR generator authenticates to GitHub to list open PRs.

```bash
kubectl -n argocd create secret generic github-token \
  --from-literal=token="$GITHUB_TOKEN"
```

`GITHUB_TOKEN` needs `repo` scope for private repos, or `public_repo` for public ones.

## 4. Configure image pull (private registries only)

Skip this step if your registry is public.

```bash
# 1. Create the pull secret in every namespace ArgoCD will create.
#    Easiest: a controller like reflector, or a simple bootstrap job.
#    For a one-off, create in a template namespace and mirror manually.

kubectl create secret docker-registry regcred \
  --docker-server=<registry-host> \
  --docker-username=<user> \
  --docker-password=<pass> \
  -n app-template

# 2. Reference it in values-sandbox.yaml:
#    global:
#      imagePullSecrets:
#        - name: regcred
```

For ECR, use IRSA on the node IAM role or the `aws-ecr-credential-provider` plugin so you don't have to manage pull secrets manually.

## 5. Configure DNS + TLS

**DNS:** Point `*.sandbox.example.com` (or whatever `global.ingress.hostSuffix` is set to in `values-sandbox.yaml`) at your ingress LB's external hostname or IP.

**TLS:** The sandbox values file references a wildcard TLS secret:

```yaml
# charts/app/environments/values-sandbox.yaml
global:
  ingress:
    tls:
      enabled: true
      secretName: wildcard-sandbox-tls
```

Two common approaches:

**Option A — cert-manager + DNS-01:** Install cert-manager, create a `ClusterIssuer` pointing at your DNS provider, and a `Certificate` resource for `*.sandbox.example.com`. The secret will be populated automatically.

**Option B — static wildcard cert:** Upload a pre-issued wildcard cert as a Secret in every namespace ArgoCD creates (use a reflector to sync from a source namespace).

## 6. Edit the ApplicationSet

Open `gitops/applicationset.yaml` and replace the placeholders:

```yaml
spec:
  generators:
    - pullRequest:
        github:
          owner: your-org      # ← replace REPLACE_WITH_ORG
          repo: dev-sandboxing  # ← replace REPLACE_WITH_REPO
  template:
    spec:
      source:
        repoURL: https://github.com/your-org/dev-sandboxing  # ← same here
```

## 7. Apply it

```bash
kubectl apply -f gitops/applicationset.yaml
```

Verify:
```bash
kubectl -n argocd get applicationset app-pr-previews
kubectl -n argocd describe applicationset app-pr-previews
```

## 8. Wire up CI

CI's only job is **build + tag + push**. No `kubectl`, no `helm`, no `argocd` calls.

Example GitHub Actions workflow:

```yaml
name: build-images
on:
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # for OIDC to cloud registry
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3

      # authenticate to your registry (example: ECR)
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123:role/gha-ecr-push
          aws-region: us-east-1
      - uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push frontend
        uses: docker/build-push-action@v5
        with:
          context: apps/frontend
          push: true
          tags: ${{ secrets.REGISTRY }}/app-frontend:${{ github.event.pull_request.head.sha }}

      - name: Build and push backend
        uses: docker/build-push-action@v5
        with:
          context: apps/backend
          push: true
          tags: ${{ secrets.REGISTRY }}/app-backend:${{ github.event.pull_request.head.sha }}
```

The SHA-tagged images are what ArgoCD pulls — the ApplicationSet sets `components.*.image.tag` to `{{ .head_sha }}`.

## 9. Open a PR to verify

1. Push a branch, open a PR against `main`.
2. Within ~60 seconds, ArgoCD creates an Application named `app-pr-<N>`.
3. Visit `pr-<N>.sandbox.example.com` — frontend renders; Sandbox Info card shows the pod name and release.
4. Push a commit → ArgoCD re-syncs within a minute.
5. Close or merge the PR → the Application, namespace, and everything in it are deleted.

## Troubleshooting

**PR is open but no Application appears.**
- `kubectl -n argocd logs deploy/argocd-applicationset-controller | grep pr` — look for GitHub API errors.
- Confirm the `github-token` secret has the right token and scope.
- Confirm `requeueAfterSeconds` has elapsed (default: 60).

**Application exists but sync fails with ImagePullBackOff.**
- CI hasn't pushed the image yet, or the tag doesn't match `head_sha`.
- Pull secret is missing or not referenced in `global.imagePullSecrets`.
- Registry host in `values-sandbox.yaml` still says `REPLACE_WITH_REGISTRY`.

**Sync succeeds but the URL doesn't load.**
- DNS: `dig pr-<N>.sandbox.example.com` — does it resolve to the ingress LB?
- Ingress: `kubectl -n app-pr-<N> describe ingress` — any errors? Is the `className` correct?
- TLS: `kubectl -n app-pr-<N> get ingress -o yaml` — is the TLS secret present in the namespace?

**PR merged but namespace still exists.**
- Check the Application still has `syncPolicy.automated.prune: true`.
- Manually delete: `kubectl -n argocd delete application app-pr-<N>` — prune should cascade.

## Resource budgeting

Per-PR sandboxes are cheap individually but add up. Worth adding once you're running more than ~10 concurrent PRs:

- A `ResourceQuota` per namespace (e.g., 500m CPU / 512Mi mem). Set it in a post-sync hook or bake it into the chart.
- A cleanup CronJob that kills Applications for PRs merged more than N days ago: `argocd admin app terminate-op` followed by `kubectl delete application`.
- Registry lifecycle policies to prune images tagged with SHAs older than a week.

These aren't in this repo — out of scope for the foundation — but they're the natural next step as the platform matures.
