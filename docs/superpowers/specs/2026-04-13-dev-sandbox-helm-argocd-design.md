# Dev Sandbox Environments with Helm + ArgoCD

**Date:** 2026-04-13
**Status:** Approved for implementation planning

## Problem

A monorepo contains a React frontend and a Node/Express backend. Developers
need to spin up an isolated full-stack sandbox (for local development and for
per-PR previews in the cloud) with a single command. The same application
needs to deploy to dev, staging, and prod from the same chart. The goal of
this project is to build the Helm + ArgoCD foundation that makes this work.

## Goals

- One Helm chart drives every environment (local minikube, dev, staging, prod,
  PR sandboxes). Only values files differ between environments.
- Templates stay DRY: frontend and backend share the same Deployment/Service/
  Ingress templates, iterated from a `components` map.
- Single command for local sandbox lifecycle: `./scripts/sandbox.sh <name>`.
- Per-PR sandboxes in the cloud are fully declarative via an ArgoCD
  `ApplicationSet` with a pull-request generator — no imperative CI calls to
  `helm`/`kubectl`/`argocd`.
- Adding a third component (e.g., a worker) requires a values change only,
  not a template change.

## Non-Goals

- Database or persistent state. The demo app is stateless.
- Auth, rate limiting, observability stack. Out of scope for this foundation.
- Automatic DNS provisioning. The design assumes a wildcard DNS entry
  (`*.sandbox.example.com` → ingress LB) exists for cloud; `/etc/hosts` covers
  local.
- Image build pipeline details. CI only needs to build+tag+push — the chart
  consumes `image.tag` as input.

## Architecture

### High-level flow

```
Local:   developer → sandbox.sh → minikube docker build → helm install → minikube
Cloud:   developer → git push → CI build+push images → PR opened
                                         ↓
                   ArgoCD ApplicationSet (PR generator) sees open PR
                                         ↓
                   Renders Application manifest with image.tag = head_sha
                                         ↓
                   ArgoCD syncs → helm install in namespace app-pr-<N>
                                         ↓
                   Sandbox reachable at pr-<N>.sandbox.example.com
```

The same chart (`charts/app`) serves both paths. The only per-flow
difference is *which values files are layered on top* and *where the image
tag comes from*.

### Isolation model

- One Kubernetes namespace per sandbox/environment: `app-<releaseName>`
  (e.g., `app-pr-123`, `app-dev`, `app-prod`).
- Host-based Ingress, one host per exposed component:
  - frontend: `<releaseName>.<hostSuffix>`
  - backend:  `api-<releaseName>.<hostSuffix>`
- Frontend calls backend through the public ingress URL (injected at runtime
  via `window.__APP_CONFIG__.backendUrl`), not in-cluster service DNS — so
  the browser can reach it.

## Repository Layout

```
dev-sandboxing/
├── apps/
│   ├── frontend/               # React + Vite + TypeScript
│   │   ├── src/
│   │   ├── public/config.js.template
│   │   ├── nginx.conf
│   │   ├── Dockerfile
│   │   └── package.json
│   └── backend/                # Node + Express + TypeScript
│       ├── src/
│       │   ├── index.ts
│       │   ├── routes/
│       │   │   ├── hello.ts
│       │   │   └── info.ts
│       │   └── env.ts
│       ├── Dockerfile
│       └── package.json
├── charts/
│   └── app/                    # THE chart — one chart, all environments
│       ├── Chart.yaml
│       ├── values.yaml         # base defaults
│       ├── templates/
│       │   ├── _helpers.tpl
│       │   ├── namespace.yaml
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── ingress.yaml
│       │   └── configmap.yaml
│       └── environments/
│           ├── values-local.yaml
│           ├── values-dev.yaml
│           ├── values-staging.yaml
│           ├── values-prod.yaml
│           └── values-sandbox.yaml
├── gitops/
│   └── applicationset.yaml     # ArgoCD PR-preview generator
├── scripts/
│   └── sandbox.sh              # local single-command flow
├── docs/superpowers/specs/
└── README.md
```

## Chart Design

### `values.yaml` shape

The chart iterates over a `components` map. Every component has the same
shape — there is no `if frontend / else backend` logic in templates.

```yaml
global:
  releaseName: ""              # overridden per install
  namespace: ""                # empty → helpers default to app-{{ releaseName }}
  imageRegistry: ""            # "" for local minikube; registry host for cloud
  imagePullPolicy: IfNotPresent
  ingress:
    enabled: true
    className: nginx
    hostSuffix: sandbox.example.com
    tls:
      enabled: false
      secretName: ""

components:
  frontend:
    image:      { repository: app-frontend, tag: latest }
    replicas:   1
    port:       80
    containerPort: 8080
    exposed:    true
    hostPrefix: ""             # "" → {releaseName}.{hostSuffix}
    env:
      - name: BACKEND_URL
        value: "https://api-{{ .Values.global.releaseName }}.{{ .Values.global.ingress.hostSuffix }}"
    resources:
      requests: { cpu: 50m,  memory: 64Mi }
      limits:   { cpu: 200m, memory: 128Mi }
    probes:
      liveness:  { path: /, port: 8080 }
      readiness: { path: /, port: 8080 }

  backend:
    image:      { repository: app-backend, tag: latest }
    replicas:   1
    port:       80
    containerPort: 3000
    exposed:    true
    hostPrefix: "api-"
    env:
      - name: NODE_ENV
        value: production
    resources:
      requests: { cpu: 50m,  memory: 64Mi }
      limits:   { cpu: 200m, memory: 128Mi }
    probes:
      liveness:  { path: /api/health, port: 3000 }
      readiness: { path: /api/health, port: 3000 }
```

### Environment overrides (only what differs)

`values-local.yaml` (minikube):
```yaml
global:
  imageRegistry: ""
  imagePullPolicy: Never       # force use of locally-built image
  ingress:
    className: nginx
    hostSuffix: sandbox.local
```

`values-sandbox.yaml` (PR preview baseline in cloud):
```yaml
global:
  imageRegistry: <registry-host>
  imagePullPolicy: IfNotPresent
  ingress:
    className: nginx
    hostSuffix: sandbox.example.com
    tls: { enabled: true, secretName: wildcard-sandbox-tls }
```

`values-prod.yaml`:
```yaml
global:
  imageRegistry: <registry-host>
  ingress:
    hostSuffix: app.example.com
    tls: { enabled: true, secretName: app-tls }
components:
  frontend: { replicas: 3, resources: { limits: { cpu: 500m, memory: 256Mi } } }
  backend:  { replicas: 3, resources: { limits: { cpu: 500m, memory: 512Mi } } }
```

Rule of thumb: `values.yaml` holds structure shared across all environments.
Env files hold only the fields that differ (replicas, resource limits,
ingress host, TLS, image pull policy).

### Template pattern

Every workload template is a single `range` over `.Values.components`.
Example, `templates/deployment.yaml`:

```yaml
{{- range $name, $cfg := .Values.components }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "app.componentName" (dict "root" $ "name" $name) }}
  namespace: {{ include "app.namespace" $ }}
  labels: {{- include "app.labels" (dict "root" $ "name" $name) | nindent 4 }}
spec:
  replicas: {{ $cfg.replicas }}
  selector:
    matchLabels: {{- include "app.selectorLabels" (dict "root" $ "name" $name) | nindent 6 }}
  template:
    metadata:
      labels: {{- include "app.selectorLabels" (dict "root" $ "name" $name) | nindent 8 }}
    spec:
      containers:
        - name: {{ $name }}
          image: "{{ include "app.image" (dict "root" $ "cfg" $cfg) }}"
          imagePullPolicy: {{ $.Values.global.imagePullPolicy }}
          ports:
            - containerPort: {{ $cfg.containerPort }}
          env:
            {{- range $cfg.env }}
            - name: {{ .name }}
              value: {{ tpl .value $ | quote }}
            {{- end }}
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: RELEASE_NAME
              value: {{ $.Values.global.releaseName | quote }}
          livenessProbe:  {{- include "app.probe" $cfg.probes.liveness  | nindent 12 }}
          readinessProbe: {{- include "app.probe" $cfg.probes.readiness | nindent 12 }}
          resources: {{- toYaml $cfg.resources | nindent 12 }}
{{- end }}
```

`service.yaml` and `ingress.yaml` follow the same `range` shape.
`ingress.yaml` skips components where `.exposed` is false.

### `_helpers.tpl`

Provides:
- `app.componentName` → `{releaseName}-{componentName}`
- `app.namespace`     → `.Values.global.namespace | default "app-{{ .Values.global.releaseName }}"`
- `app.image`         → `{registry}/{repository}:{tag}` (omits registry prefix when empty)
- `app.host`          → `{hostPrefix}{releaseName}.{hostSuffix}`
- `app.labels` / `app.selectorLabels` → Kubernetes recommended labels including
  `app.kubernetes.io/component: {name}`
- `app.probe`         → renders HTTP probe block from `{ path, port }`

## Local Flow — `scripts/sandbox.sh`

```bash
#!/usr/bin/env bash
# Usage: ./scripts/sandbox.sh <release-name> [--destroy]
set -euo pipefail

RELEASE="${1:?release name required, e.g. pr-123}"
NAMESPACE="app-${RELEASE}"
CHART_DIR="$(dirname "$0")/../charts/app"

if [[ "${2:-}" == "--destroy" ]]; then
  helm uninstall "$RELEASE" -n "$NAMESPACE" || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  exit 0
fi

eval "$(minikube docker-env)"   # build directly into minikube's Docker daemon

docker build -t "app-frontend:${RELEASE}" apps/frontend
docker build -t "app-backend:${RELEASE}"  apps/backend

helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$CHART_DIR/environments/values-local.yaml" \
  --set global.releaseName="$RELEASE" \
  --set components.frontend.image.tag="$RELEASE" \
  --set components.backend.image.tag="$RELEASE"

echo "Sandbox ready:"
echo "  Frontend: http://${RELEASE}.sandbox.local"
echo "  Backend:  http://api-${RELEASE}.sandbox.local"
```

Prereqs (README): `minikube start`, `minikube addons enable ingress`, add
hosts entries mapping `*.sandbox.local` to `$(minikube ip)`.

## Cloud Flow — ArgoCD ApplicationSet

`gitops/applicationset.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: app-pr-previews
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - pullRequest:
        github:
          owner: <your-org>
          repo: dev-sandboxing
          tokenRef: { secretName: github-token, key: token }
        requeueAfterSeconds: 60
  template:
    metadata:
      name: 'app-pr-{{ .number }}'
      labels:
        preview: "true"
        pr: '{{ .number }}'
    spec:
      project: default
      source:
        repoURL: https://github.com/<your-org>/dev-sandboxing
        targetRevision: '{{ .head_sha }}'
        path: charts/app
        helm:
          releaseName: 'pr-{{ .number }}'
          valueFiles:
            - values.yaml
            - environments/values-sandbox.yaml
          parameters:
            - name: global.releaseName
              value: 'pr-{{ .number }}'
            - name: components.frontend.image.tag
              value: '{{ .head_sha }}'
            - name: components.backend.image.tag
              value: '{{ .head_sha }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'app-pr-{{ .number }}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions:
          - CreateNamespace=true
```

**Lifecycle:**
1. Developer opens PR → CI builds + pushes `app-frontend:<sha>` and
   `app-backend:<sha>` to the image registry.
2. ApplicationSet PR generator creates an Application named `app-pr-<N>`.
3. ArgoCD syncs — chart installed in namespace `app-pr-<N>`, reachable at
   `pr-<N>.sandbox.example.com`.
4. New commit → `head_sha` changes → ArgoCD re-syncs with the new image tag.
5. PR closed/merged → generator drops the PR → ArgoCD prunes the Application
   → namespace deleted.

CI is minimal: build, tag with `$GITHUB_SHA`, push to registry. Nothing else.

## Application Code

### Backend — `apps/backend`

Node 20 + Express + TypeScript. Endpoints:

| Route | Response |
|---|---|
| `GET /api/hello`  | `{ message: "Hello from sandbox <releaseName>" }` |
| `GET /api/info`   | `{ pod, release, version, uptime }` |
| `GET /api/health` | `200 OK` (probe target) |

Reads `POD_NAME`, `RELEASE_NAME`, `VERSION` from environment. CORS allows
the frontend host. No persistence. Multi-stage Dockerfile producing a small
image (distroless or `node:20-alpine`).

### Frontend — `apps/frontend`

Vite + React + TypeScript. One page with two cards:
- **Hello** — shows the greeting from `GET /api/hello`.
- **Sandbox Info** — shows pod/release/version from `GET /api/info`. Makes
  it obvious which sandbox the browser is pointed at.

**Runtime config:** one static build serves every sandbox. An entrypoint
shell script runs `envsubst` on `public/config.js.template` at container
start, writing `window.__APP_CONFIG__.backendUrl` from the `BACKEND_URL`
env var. `index.html` loads `config.js` before the app bundle.

Multi-stage Dockerfile: Vite build → `nginx:alpine` serving the built
assets.

## Error Handling

- Probes: liveness and readiness on both components; Kubernetes handles
  pod-level recovery.
- Helm: `helm upgrade --install` is idempotent; re-running the sandbox
  script recovers from partial installs.
- ArgoCD: `selfHeal: true` reconciles drift; `prune: true` removes orphaned
  resources when PR closes.
- Frontend: if the backend call fails, render the error on the info card —
  no retry storm. (The demo is for sandbox correctness, not resilience.)

## Testing

- `helm lint charts/app` and `helm template` rendering tests against each
  `environments/values-*.yaml` — verify output is valid and component loop
  produces the expected resources.
- Smoke test after `sandbox.sh pr-xxx`: curl both ingress hosts and confirm
  `/api/health` and the frontend HTML respond 200.
- CI on the chart: run `helm lint` and template rendering on every push.
- Application code testing is minimal (the app is a fixture, not the
  deliverable) — just a smoke test per route.

## Open Questions for Implementation

- Exact registry host for the cloud flow (ECR vs GHCR vs other) — plumbed
  through `global.imageRegistry`, so this is a values-file decision.
- GitHub org/repo path for the ApplicationSet `pullRequest` generator —
  filled in when the repo is hosted.
- Ingress controller assumption: `nginx`. If the cluster uses a different
  controller (e.g., AWS ALB), `global.ingress.className` and possibly
  annotations in `values-sandbox.yaml` change — template is unaffected.
