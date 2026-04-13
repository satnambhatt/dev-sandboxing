# Contributing

## Prerequisites

- **Docker** (or Docker Desktop)
- **minikube** for local sandboxes
- **kubectl** and **helm 3**
- **Node 20+** for running apps outside containers
- **jq** (used by some scripts — optional)

## Repo layout

```
dev-sandboxing/
├── apps/
│   ├── frontend/              React + Vite + TypeScript
│   └── backend/               Node + Express + TypeScript
├── charts/app/                The Helm chart (one chart for all envs)
│   ├── templates/             DRY templates iterating components map
│   ├── environments/          Per-env values files
│   └── tests/render.sh        Lint + render sanity check
├── gitops/
│   └── applicationset.yaml    ArgoCD PR-preview generator
├── scripts/
│   └── sandbox.sh             Local sandbox lifecycle
└── docs/                      Documentation (including the article)
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for how the pieces fit together.

## Local development

### Running the full stack on minikube

```bash
minikube start
minikube addons enable ingress
./scripts/sandbox.sh pr-local
```

The script prints `/etc/hosts` entries — add them, then browse to `http://pr-local.sandbox.local`.

Tear down:
```bash
./scripts/sandbox.sh pr-local --destroy
```

### Running apps outside Kubernetes

Fastest iteration loop for app code: run directly with Node, skip Docker and Helm.

**Backend:**
```bash
cd apps/backend
npm install
npm run dev         # ts-node-dev with hot reload on port 3000
```

**Frontend:**
```bash
cd apps/frontend
npm install
npm run dev         # Vite on port 5173
```

Set `BACKEND_URL` in `public/config.js` (or edit `config.js.template` and copy it) for the frontend to find the backend.

## Tests

### Backend
```bash
cd apps/backend
npm test            # node:test + supertest
```

### Frontend
Type check + build:
```bash
cd apps/frontend
npm run build
```

### Chart
Lint and render against every environment:
```bash
./charts/app/tests/render.sh
```

Run this after any chart change before committing.

## Making changes

### Changing app code

1. Edit in `apps/frontend/src/` or `apps/backend/src/`.
2. Run the relevant test command.
3. Rebuild the sandbox if you want to test end-to-end: `./scripts/sandbox.sh pr-<your-name>` — it rebuilds images into minikube's docker daemon and re-runs `helm upgrade --install`.

### Changing the chart

1. Edit templates or values.
2. Run `./charts/app/tests/render.sh` — verifies lint + rendering against all envs.
3. Rebuild a local sandbox to confirm it deploys.

**Adding a new component** (worker, cron, another API): add a key under `components:` in `charts/app/values.yaml`. No template edit needed. See [`docs/CHART_REFERENCE.md`](docs/CHART_REFERENCE.md#adding-a-new-component).

### Changing per-env config

Edit the right file in `charts/app/environments/`. Keep these files minimal — only what **differs** from `values.yaml`.

## PR workflow

1. Branch off `main`.
2. Make your changes. Write tests for anything non-trivial in the app code.
3. Run the three test commands above.
4. Commit with a clear message. Small, focused commits preferred over large ones.
5. Push and open a PR.
6. If ArgoCD is wired up (see [`docs/ARGOCD_SETUP.md`](docs/ARGOCD_SETUP.md)), a preview will appear at `pr-<N>.sandbox.example.com` within a minute.

## Coding conventions

### TypeScript (both apps)
- ES modules (`"type": "module"` in `package.json`, `.js` extensions on imports).
- Strict mode on.
- Backend: no business logic in route handlers — extract helpers if it grows.

### Helm
- **No `if component == X` branches.** Express the difference in values, not templates. If you find yourself wanting to branch on component identity, that's a signal to extend the `components` schema instead.
- Use helpers from `_helpers.tpl` — don't recompute names or hostnames inline.
- Guard optional values with `{{- with $cfg.foo }}` rather than `{{- if $cfg.foo }}` so the block is scoped and nil-safe.

### Shell (`scripts/sandbox.sh`)
- `set -euo pipefail` at the top.
- Quote variable expansions.
- Fail fast on missing args.

## Getting help

- Architecture overview: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Chart values reference: [`docs/CHART_REFERENCE.md`](docs/CHART_REFERENCE.md)
- Setting up ArgoCD: [`docs/ARGOCD_SETUP.md`](docs/ARGOCD_SETUP.md)
- The narrative: [`docs/article.md`](docs/article.md)
