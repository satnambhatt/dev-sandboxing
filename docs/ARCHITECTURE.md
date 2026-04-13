# Architecture

How the pieces fit together. For the "why" and a narrative walkthrough, see [`article.md`](article.md).

## High-level flow

```
                ┌───────────────────────────────────────────────────┐
                │                     Developer                     │
                └────────────────┬─────────────────┬────────────────┘
                                 │                 │
                    local / minikube       git push / open PR
                                 │                 │
                                 ▼                 ▼
              ┌──────────────────────┐   ┌────────────────────────┐
              │  scripts/sandbox.sh  │   │  CI: build + push image │
              │  - minikube docker   │   │  tag = <commit SHA>     │
              │  - helm upgrade      │   └────────────┬────────────┘
              └──────────┬───────────┘                │
                         │                            ▼
                         │               ┌────────────────────────┐
                         │               │  ArgoCD ApplicationSet │
                         │               │  (PR generator)        │
                         │               │  - polls GitHub        │
                         │               │  - renders Application │
                         │               └────────────┬───────────┘
                         │                            │
                         ▼                            ▼
              ┌──────────────────────────────────────────────────┐
              │                charts/app (Helm)                 │
              │  one chart • iterated over components map        │
              │  layered values-<env>.yaml                       │
              └────────────────────────┬─────────────────────────┘
                                       ▼
              ┌──────────────────────────────────────────────────┐
              │      Kubernetes namespace: app-<releaseName>     │
              │  ┌────────────┐   ┌────────────┐                 │
              │  │  frontend  │──▶│   ingress  │◀── browser      │
              │  └────────────┘   └────────────┘                 │
              │  ┌────────────┐   ┌────────────┐                 │
              │  │  backend   │──▶│   ingress  │◀── browser      │
              │  └────────────┘   └────────────┘                 │
              └──────────────────────────────────────────────────┘
```

## Core pattern: one chart, components map, layered values

Every workload template iterates `.Values.components` — no per-component templates, no `if frontend / else backend` branches. Adding a new component (worker, cron, second API) is a values change.

Each environment gets a file in `charts/app/environments/` that contains **only what differs** from `values.yaml`. The chart itself doesn't know about environments.

| File | Role |
|---|---|
| `charts/app/values.yaml` | Base defaults — shape shared by every environment |
| `charts/app/environments/values-local.yaml` | minikube (HTTP, `imagePullPolicy: Never`, `sandbox.local`) |
| `charts/app/environments/values-dev.yaml` | Long-lived dev env |
| `charts/app/environments/values-staging.yaml` | Staging |
| `charts/app/environments/values-prod.yaml` | Production (replicas, resource limits, TLS) |
| `charts/app/environments/values-sandbox.yaml` | Baseline for PR previews in the cloud |

See [CHART_REFERENCE.md](CHART_REFERENCE.md) for every value and how to add components.

## Request flow (runtime)

A browser hits `pr-123.sandbox.example.com`:

1. Ingress controller routes to the frontend Service based on host.
2. Frontend container serves static assets via nginx. `config.js` is generated at container start by `envsubst` from `config.js.template`, injecting `window.__APP_CONFIG__.backendUrl` from the `BACKEND_URL` env var.
3. The React app reads `window.__APP_CONFIG__.backendUrl` and makes XHR calls to `api-pr-123.sandbox.example.com`.
4. Those requests go back out through the ingress, routed to the backend Service based on host.
5. Backend responds with JSON; frontend renders.

The key detail: **the backend URL is runtime config, not build-time.** One static image serves every sandbox because `BACKEND_URL` is computed from `global.ingress.scheme` + `global.releaseName` + `global.ingress.hostSuffix` in Helm, passed as an env var, and materialized into `config.js` by `envsubst` at pod start.

## Isolation model

- **One namespace per sandbox:** `app-<releaseName>` (e.g., `app-pr-123`, `app-dev`, `app-prod`). Teardown is `kubectl delete namespace` — no orphans.
- **Host-based ingress:** each exposed component gets its own hostname via `hostPrefix`. Frontend: `<releaseName>.<hostSuffix>`. Backend: `api-<releaseName>.<hostSuffix>`.
- **Browser-reachable backend:** the frontend calls the backend through the public ingress, not in-cluster DNS. Required so the browser — which is not in the cluster — can reach it.

## Lifecycle

### Local (minikube)

`scripts/sandbox.sh <release>`:
1. `eval "$(minikube docker-env)"` — point Docker at minikube's daemon.
2. `docker build` — images are immediately visible to the cluster; no registry push needed.
3. `helm upgrade --install` with `values-local.yaml` overrides (`imagePullPolicy: Never`, `scheme: http`, `hostSuffix: sandbox.local`).
4. Print the URLs.

Teardown: `scripts/sandbox.sh <release> --destroy` — uninstalls Helm release and deletes the namespace.

### Cloud (ArgoCD PR previews)

Declared in `gitops/applicationset.yaml`:
1. ArgoCD polls GitHub for open PRs (`requeueAfterSeconds: 60`).
2. For each PR, renders an `Application` with `releaseName: pr-<N>` and image tag = `<head_sha>`.
3. ArgoCD syncs → chart installed in namespace `app-pr-<N>`.
4. New commit → `head_sha` changes → reconcile → rolling update.
5. PR closed → generator drops it → `syncPolicy.automated.prune: true` + `CreateNamespace=true` means the namespace is deleted.

CI's only job is build-and-push. Setup in [ARGOCD_SETUP.md](ARGOCD_SETUP.md).

## Components

### `charts/app/` — the Helm chart
- **templates** iterate `.Values.components` via `range`. No component names hardcoded.
- **_helpers.tpl** provides `app.componentName`, `app.namespace`, `app.image`, `app.host`, `app.labels`, `app.selectorLabels`, `app.probe`.
- **ingress.yaml** guards on `$cfg.exposed` so internal components (workers, crons) don't get public hosts.
- Values for env vars are templated — `{{ .Values.global.releaseName }}` inside a values-file string works because `deployment.yaml` runs `tpl .value $` on each env var.

### `apps/backend/` — Node + Express + TypeScript
- Three routes: `GET /api/hello`, `GET /api/info`, `GET /api/health` (liveness/readiness target).
- `env.ts` captures `POD_NAME`, `RELEASE_NAME`, `VERSION` at import time.
- CORS configured for the frontend host.
- Multi-stage Dockerfile: build → `node:20-alpine` runtime.

### `apps/frontend/` — React + Vite + TypeScript
- Two cards: "Hello" (from `/api/hello`) and "Sandbox Info" (from `/api/info`).
- `public/config.js.template` defines `window.__APP_CONFIG__`; `entrypoint.sh` runs `envsubst` at container start.
- Multi-stage Dockerfile: Vite build → `nginx:1.27-alpine` serving assets.

### `gitops/applicationset.yaml` — ArgoCD PR-preview generator
- `pullRequest` generator with GitHub provider.
- Helm source with `valueFiles: [values.yaml, environments/values-sandbox.yaml]` and parameters for `releaseName` and both image tags.
- `syncPolicy.automated: { prune: true, selfHeal: true }` keeps state in git.

### `scripts/sandbox.sh` — local sandbox lifecycle
- Create: `sandbox.sh pr-123`
- Destroy: `sandbox.sh pr-123 --destroy`

## What's deliberately out of scope

- **Databases / persistent state.** The demo is stateless. For real apps, add a sub-chart or external DB per sandbox.
- **Secrets.** Chart supports `imagePullSecrets` but there's no Sealed Secrets / External Secrets wiring yet.
- **DNS provisioning.** Assumes wildcard DNS (`*.sandbox.example.com`) is already pointed at the ingress LB; `/etc/hosts` covers local.
- **Auth / rate limiting / observability.** Out of scope for the foundation.
- **Image build pipeline details.** CI only needs to build, tag with the commit SHA, and push.

See the [article's "What I'd add next"](article.md#what-id-add-next) section for how these would slot in.
