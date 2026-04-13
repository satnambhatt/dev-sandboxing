# dev-sandboxing

One Helm chart, every environment. Spin up a full-stack sandbox with one command locally, or automatically per PR in a cloud cluster via ArgoCD.

**Docs:**
- [Article / narrative walkthrough](docs/article.md)
- [Architecture overview](docs/ARCHITECTURE.md)
- [Chart values reference](docs/CHART_REFERENCE.md)
- [ArgoCD setup guide](docs/ARGOCD_SETUP.md)
- [Contributing](CONTRIBUTING.md)

## Layout

- `apps/frontend` — React + Vite
- `apps/backend` — Node + Express
- `charts/app` — the chart (templates iterated over a `components` map in `values.yaml`)
- `charts/app/environments/values-*.yaml` — per-env overrides only
- `scripts/sandbox.sh` — local sandbox lifecycle on minikube
- `gitops/applicationset.yaml` — ArgoCD PR-preview generator

## Local sandbox (minikube)

One-time setup:
```bash
minikube start
minikube addons enable ingress
```

Create a sandbox:
```bash
./scripts/sandbox.sh pr-123
```

The script prints the `/etc/hosts` entry to add. Then:
- Frontend: http://pr-123.sandbox.local
- Backend: http://api-pr-123.sandbox.local

Tear down:
```bash
./scripts/sandbox.sh pr-123 --destroy
```

## Dev / staging / prod

Same chart, different values file:
```bash
helm upgrade --install app charts/app \
  -f charts/app/environments/values-dev.yaml \
  --set global.releaseName=dev \
  --set components.frontend.image.tag=<tag> \
  --set components.backend.image.tag=<tag>
```

Before deploying to cloud, edit `charts/app/environments/values-<env>.yaml` and replace `REPLACE_WITH_REGISTRY` with your registry host.

## PR previews (ArgoCD)

1. Edit `gitops/applicationset.yaml`: replace `REPLACE_WITH_ORG` and `REPLACE_WITH_REPO`, and ensure `secret/github-token` exists in the `argocd` namespace.
2. Apply it to your ArgoCD cluster:
   ```bash
   kubectl apply -f gitops/applicationset.yaml
   ```
3. CI builds and pushes `app-frontend:<sha>` and `app-backend:<sha>` on every PR commit.
4. ArgoCD provisions `app-pr-<N>` on PR open and prunes it on PR close.

## Adding a new component

Add a key under `components:` in `values.yaml`. Every template iterates the map — no template change needed.

## Chart tests

```bash
./charts/app/tests/render.sh
```

Lints the chart and renders it against every environment.
