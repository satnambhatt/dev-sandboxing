# One Helm Chart, Every Environment: Building Self-Serve Dev Sandboxes with ArgoCD

*How to spin up an isolated full-stack sandbox per pull request — with a single chart that serves local minikube, dev, staging, prod, and PR previews alike.*

---

## The problem nobody admits to

Here's how most teams ship code:

1. You open a PR.
2. The reviewer leaves "LGTM, can you test it on dev?"
3. You realize dev is already being used by three other people testing three other features.
4. You wait. Or you push to dev anyway. Or you give up and have the reviewer trust your screenshots.

The shared dev environment is the single most common bottleneck in a growing engineering org, and it gets worse the more people ship to it. The textbook answer — "just give every PR its own environment" — has historically been painful enough that most teams don't bother. You end up with either fragile bash scripts, expensive long-lived staging clones, or a platform team that becomes the bottleneck instead of the shared env.

But with Kubernetes, Helm, and ArgoCD, per-PR sandboxes have become genuinely easy. This post walks through a minimal reference implementation: **one Helm chart that serves every environment**, a single script for local sandboxes on minikube, and an ArgoCD `ApplicationSet` that automatically provisions and cleans up a sandbox for every open pull request.

The whole thing fits in under 500 lines. The full repo is [here](https://github.com/your-org/dev-sandboxing) — feel free to clone, deploy, and adapt.

---

## The goal

By the end of this, a developer should be able to:

**Locally:**
```bash
./scripts/sandbox.sh pr-123
```
→ full stack running on minikube in under a minute, reachable at `http://pr-123.sandbox.local`.

**In the cloud:**
```bash
git push origin feat/my-branch
gh pr create
```
→ ArgoCD spots the PR, provisions a namespace in your cluster, and posts the URL. PR closes → ArgoCD cleans up. Nobody on the platform team has to be involved.

And across dev, staging, and prod? **The exact same chart.** No chart museum, no "dev is different," no branching templates per environment.

---

## The core idea: one chart, DRY templates, layered values

The whole system rests on one pattern. Rather than writing separate templates for frontend and backend — or worse, a separate chart for each — we define a **`components` map** in `values.yaml` and iterate over it in every template.

Here's the shape:

```yaml
# charts/app/values.yaml

global:
  releaseName: ""
  imageRegistry: ""
  imagePullPolicy: IfNotPresent
  ingress:
    className: nginx
    scheme: https
    hostSuffix: sandbox.example.com
    tls:
      enabled: false

components:
  frontend:
    image: { repository: app-frontend, tag: latest }
    replicas: 1
    port: 80
    containerPort: 8080
    exposed: true
    hostPrefix: ""
    env:
      - name: BACKEND_URL
        value: "{{ .Values.global.ingress.scheme }}://api-{{ .Values.global.releaseName }}.{{ .Values.global.ingress.hostSuffix }}"
    probes:
      liveness:  { path: /, port: 8080 }
      readiness: { path: /, port: 8080 }

  backend:
    image: { repository: app-backend, tag: latest }
    replicas: 1
    port: 80
    containerPort: 3000
    exposed: true
    hostPrefix: "api-"
    probes:
      liveness:  { path: /api/health, port: 3000 }
      readiness: { path: /api/health, port: 3000 }
```

Every template is a single `range` over this map. Here's `deployment.yaml`:

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
    # ... containers, env, probes, all driven by $cfg
{{- end }}
```

No `if frontend / else backend` branches. No duplicated service templates. **Adding a new component — a worker, a cron job, a second API — is a values-file change, zero template work.**

The other templates (`service.yaml`, `ingress.yaml`, `configmap.yaml`) follow the same pattern. `ingress.yaml` adds a single `{{- if $cfg.exposed }}` guard so you can have components that don't need public access.

### Layering values per environment

The chart ships a directory of environment files:

```
charts/app/environments/
├── values-local.yaml       # minikube
├── values-dev.yaml
├── values-staging.yaml
├── values-prod.yaml
└── values-sandbox.yaml     # baseline for PR previews
```

Each file contains **only what differs** from base:

```yaml
# charts/app/environments/values-prod.yaml

global:
  imageRegistry: 123.dkr.ecr.us-east-1.amazonaws.com
  ingress:
    hostSuffix: app.example.com
    tls:
      enabled: true
      secretName: app-tls

components:
  frontend:
    replicas: 3
    resources:
      limits: { cpu: 500m, memory: 256Mi }
  backend:
    replicas: 3
    resources:
      limits: { cpu: 500m, memory: 512Mi }
```

Deploying to prod:

```bash
helm upgrade --install app charts/app \
  -f charts/app/environments/values-prod.yaml \
  --set global.releaseName=prod \
  --set components.frontend.image.tag=v1.2.3 \
  --set components.backend.image.tag=v1.2.3
```

Same chart. Same templates. Different values file. That's the whole story.

---

## The local flow: one command, zero yak-shaving

For local development, we want something that Just Works. The user shouldn't have to think about image registries, DNS, or ingress controllers.

```bash
./scripts/sandbox.sh pr-123
```

The script does four things:

1. **Points Docker at minikube's daemon:** `eval "$(minikube docker-env)"`. Now any image we build is immediately visible to the cluster — no push to a registry needed.
2. **Builds both images** with the release name as the tag: `app-frontend:pr-123`, `app-backend:pr-123`.
3. **Runs `helm upgrade --install`** with `values-local.yaml` overrides (`imagePullPolicy: Never`, `hostSuffix: sandbox.local`).
4. **Prints the `/etc/hosts` entry** to add, so the developer can hit `pr-123.sandbox.local` in a browser.

```bash
#!/usr/bin/env bash
set -euo pipefail

RELEASE="${1:?release name required (e.g. pr-123)}"
NAMESPACE="app-${RELEASE}"

# ... destroy branch omitted for brevity

eval "$(minikube docker-env)"

docker build -t "app-frontend:${RELEASE}" apps/frontend
docker build -t "app-backend:${RELEASE}"  apps/backend

helm upgrade --install "$RELEASE" charts/app \
  --namespace "$NAMESPACE" --create-namespace \
  -f charts/app/environments/values-local.yaml \
  --set global.releaseName="$RELEASE" \
  --set components.frontend.image.tag="$RELEASE" \
  --set components.backend.image.tag="$RELEASE" \
  --wait --timeout 3m

echo "Sandbox ready: http://${RELEASE}.sandbox.local"
```

Tearing down is just `./scripts/sandbox.sh pr-123 --destroy`. The entire namespace goes with it — no orphan resources, no cleanup task on Monday morning.

The `imagePullPolicy: Never` detail is what makes this work: because `minikube docker-env` pointed Docker at the cluster's own daemon, the image is already there. Kubernetes tries to use it locally and never attempts a pull. Same behavior you'd expect from a real deployment, but with zero registry setup.

---

## The cloud flow: ApplicationSet + PR generator

This is where ArgoCD earns its keep. We want:

- A developer opens a PR → their sandbox appears automatically
- Every push to the PR → the sandbox updates to the new commit
- PR closes → the sandbox disappears, and the namespace with it

ArgoCD's `ApplicationSet` with the **Pull Request generator** makes this entirely declarative. One YAML file, committed to the repo:

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
          owner: your-org
          repo: dev-sandboxing
          tokenRef:
            secretName: github-token
            key: token
        requeueAfterSeconds: 60
  template:
    metadata:
      name: 'app-pr-{{ .number }}'
    spec:
      project: default
      source:
        repoURL: https://github.com/your-org/dev-sandboxing
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

Every minute, ArgoCD polls the GitHub API for open PRs. For each one, it renders the template — substituting `{{ .number }}` and `{{ .head_sha }}` — and creates an `Application` resource. ArgoCD then syncs that Application, which runs `helm install` against the cluster.

When a new commit lands on the PR, `head_sha` changes, the Application reconciles, and the deployment rolls forward.

When the PR closes, the generator drops it, ArgoCD prunes the Application, and `syncOptions: [CreateNamespace=true]` combined with `prune: true` means the namespace (and everything in it) is cleaned up.

**CI's only job** in all of this is to build and push images tagged with the commit SHA. No `kubectl`, no `helm`, no `argocd` calls from CI. That's both faster (nothing to install in your runner) and safer (CI never has cluster credentials).

---

## The patterns worth stealing

Three ideas from this project are worth lifting into your own work even if you don't adopt the whole setup.

### 1. Iterate over a map, don't branch on type

In Helm, resist the urge to write:

```yaml
{{- if eq .Values.component "frontend" }}
# ... frontend-specific deployment
{{- else }}
# ... backend-specific deployment
{{- end }}
```

Instead, express the differences as data:

```yaml
components:
  frontend: { port: 80, containerPort: 8080, ... }
  backend:  { port: 80, containerPort: 3000, ... }
```

And iterate. You'll write one template instead of N. You'll add new components without touching templates. Your rendered YAML will stay grep-friendly because every component has the same shape.

The same applies well beyond Helm. Any time you find yourself writing parallel code for "the frontend case" and "the backend case," see if you can push the difference into data.

### 2. Runtime config via envsubst on a static SPA

A frustrating pattern in React apps is the build-time env problem: `import.meta.env.VITE_BACKEND_URL` bakes into the bundle, so you need to rebuild for every environment. With per-PR sandboxes, that's a non-starter.

The fix is trivial. Add one script tag to `index.html`:

```html
<script src="/config.js"></script>
<script type="module" src="/src/main.tsx"></script>
```

Ship a template in your public folder:

```js
// public/config.js.template
window.__APP_CONFIG__ = { backendUrl: "${BACKEND_URL}" };
```

And run `envsubst` in your container's entrypoint:

```bash
#!/bin/sh
envsubst '${BACKEND_URL}' < /usr/share/nginx/html/config.js.template \
                         > /usr/share/nginx/html/config.js
exec nginx -g 'daemon off;'
```

Now one static image serves every environment. The backend URL comes from the container's env var, which comes from Helm, which comes from the ingress hostSuffix — a single source of truth.

### 3. Let ArgoCD own lifecycle; don't push state from CI

The temptation with per-PR envs is to have CI do everything: build images, push to registry, run `helm install`, run tests, tear down on PR close.

Don't. Every `kubectl` call from CI is a credential you have to manage, a failure mode you have to handle, and a state-sync problem waiting to happen.

With an `ApplicationSet`, CI is pure: build and push. Everything else is declarative. Your sandbox lifecycle is in git, not in a Jenkinsfile. If ArgoCD falls behind, it catches up. If CI fails partway, there's no inconsistent state to clean up.

---

## What I'd add next

This implementation is deliberately minimal — it's the skeleton of a sandbox platform, not a production one. Things I'd reach for as it matures:

- **Resource budgets.** Per-PR sandboxes are cheap individually, expensive in aggregate. A `ResourceQuota` per namespace and a global cleanup job for stale PRs (`argocd admin app terminate-op` for apps whose PRs merged 7+ days ago) prevent surprises.
- **Preview deploy comments on PRs.** Add a GitHub Action that comments "Preview at `pr-123.sandbox.example.com`" when the Application becomes healthy. ArgoCD's webhook hooks or a simple exit-handler on the sync can drive this.
- **Persistent data.** The demo is stateless. For anything with a DB, you need either per-sandbox Postgres (a sub-chart with `values-sandbox.yaml` setting a tiny one) or shared branched data (much harder — worth thinking about up front).
- **Secrets.** This repo has none. In production you'd either mount Vault secrets via External Secrets Operator or use Sealed Secrets committed to the GitOps repo.

None of these change the core architecture. The `components` map is the stable spine; everything else is values layered on top.

---

## Try it yourself

```bash
git clone https://github.com/your-org/dev-sandboxing
cd dev-sandboxing
minikube start
minikube addons enable ingress
./scripts/sandbox.sh pr-first-try
```

The hosts entry will print in the script output. Add it, then open `http://pr-first-try.sandbox.local` in a browser. You should see two cards: a "Hello" card from the backend and a "Sandbox Info" card showing the pod name, release name, and version — proof you're hitting your own isolated sandbox and not somebody else's.

Poke at `values.yaml`. Add a third component. Break something. Rebuild. Tear it down.

That's the whole point of sandboxes: experiment freely, with no shared state to worry about.

---

*The full source for this project, including the Helm chart, frontend, backend, ArgoCD `ApplicationSet`, and the implementation plan, is at [github.com/your-org/dev-sandboxing](https://github.com/your-org/dev-sandboxing). If this pattern saves your team a few hours of "hey, are you done with dev yet?" Slack messages, consider it paid forward.*
