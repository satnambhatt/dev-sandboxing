# Dev Sandbox (Helm + ArgoCD) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single Helm chart (`charts/app`) plus a minimal React frontend and Node/Express backend so a developer can run `./scripts/sandbox.sh pr-123` and get a full-stack sandbox on minikube, and ArgoCD's `ApplicationSet` can provision identical per-PR sandboxes in a cloud cluster.

**Architecture:** One chart iterated over a `components` map in `values.yaml` serves every environment (local, dev, staging, prod, PR sandbox). Env-specific values files override only what differs. Local flow builds into minikube's Docker daemon; cloud flow is declarative via ArgoCD PR generator.

**Tech Stack:** Helm 3, ArgoCD (`ApplicationSet` + PR generator), Kubernetes (minikube + EKS/AKS), Node 20 + Express + TypeScript (backend), Vite + React + TypeScript (frontend), nginx (frontend container), Docker multi-stage builds, bash.

**Reference spec:** `docs/superpowers/specs/2026-04-13-dev-sandbox-helm-argocd-design.md`

---

## File Structure

```
apps/
├── backend/
│   ├── src/
│   │   ├── index.ts              # Express bootstrap
│   │   ├── env.ts                # reads POD_NAME, RELEASE_NAME, VERSION
│   │   └── routes/
│   │       ├── hello.ts          # GET /api/hello
│   │       └── info.ts           # GET /api/info, GET /api/health
│   ├── test/
│   │   └── smoke.test.ts         # supertest-based smoke test
│   ├── Dockerfile
│   ├── package.json
│   └── tsconfig.json
└── frontend/
    ├── src/
    │   ├── main.tsx
    │   ├── App.tsx
    │   └── api.ts                # reads window.__APP_CONFIG__
    ├── public/
    │   └── config.js.template    # envsubst target
    ├── index.html
    ├── nginx.conf
    ├── entrypoint.sh             # runs envsubst, then nginx
    ├── Dockerfile
    ├── package.json
    ├── vite.config.ts
    └── tsconfig.json

charts/app/
├── Chart.yaml
├── values.yaml                   # base
├── templates/
│   ├── _helpers.tpl
│   ├── namespace.yaml
│   ├── deployment.yaml           # range .Values.components
│   ├── service.yaml              # range .Values.components
│   ├── ingress.yaml              # range (skips .exposed == false)
│   └── configmap.yaml            # no-op unless .configData set
└── environments/
    ├── values-local.yaml
    ├── values-dev.yaml
    ├── values-staging.yaml
    ├── values-prod.yaml
    └── values-sandbox.yaml

gitops/
└── applicationset.yaml

scripts/
└── sandbox.sh

README.md                         # updated with setup + run instructions
```

**Responsibilities:**
- `charts/app/templates/*` — resource manifests, each a single `range` over `components`. Never hardcode a component name.
- `charts/app/values.yaml` — the base structure. Other values files only override leaves.
- `charts/app/environments/values-<env>.yaml` — only the fields that differ for that environment.
- `apps/*` — the fixture application. Deliberately minimal; the point is to exercise the chart.
- `scripts/sandbox.sh` — the local single-command flow. No cluster-side logic lives here.
- `gitops/applicationset.yaml` — the cloud PR preview lifecycle, fully declarative.

---

## Task 1: Scaffold backend package

**Files:**
- Create: `apps/backend/package.json`
- Create: `apps/backend/tsconfig.json`
- Create: `apps/backend/.gitignore`

- [ ] **Step 1: Create `apps/backend/package.json`**

```json
{
  "name": "app-backend",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p .",
    "start": "node dist/index.js",
    "dev": "tsx watch src/index.ts",
    "test": "node --test --import tsx test/"
  },
  "dependencies": {
    "cors": "^2.8.5",
    "express": "^4.19.2"
  },
  "devDependencies": {
    "@types/cors": "^2.8.17",
    "@types/express": "^4.17.21",
    "@types/node": "^20.12.0",
    "@types/supertest": "^6.0.2",
    "supertest": "^7.0.0",
    "tsx": "^4.7.0",
    "typescript": "^5.4.0"
  }
}
```

- [ ] **Step 2: Create `apps/backend/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true
  },
  "include": ["src/**/*"]
}
```

- [ ] **Step 3: Create `apps/backend/.gitignore`**

```
node_modules
dist
*.log
```

- [ ] **Step 4: Install and commit**

Run:
```bash
cd apps/backend && npm install && cd ../..
git add apps/backend/package.json apps/backend/tsconfig.json apps/backend/.gitignore apps/backend/package-lock.json
git commit -m "chore(backend): scaffold TypeScript package"
```

Expected: `npm install` finishes without errors.

---

## Task 2: Backend — `env.ts` (runtime config)

**Files:**
- Create: `apps/backend/src/env.ts`

- [ ] **Step 1: Write `apps/backend/src/env.ts`**

```ts
export const env = {
  port: Number(process.env.PORT ?? 3000),
  podName: process.env.POD_NAME ?? "local",
  releaseName: process.env.RELEASE_NAME ?? "local",
  version: process.env.VERSION ?? "dev",
  corsOrigin: process.env.CORS_ORIGIN ?? "*",
};
```

- [ ] **Step 2: Commit**

```bash
git add apps/backend/src/env.ts
git commit -m "feat(backend): add env config module"
```

---

## Task 3: Backend — `/api/hello` route (TDD)

**Files:**
- Create: `apps/backend/test/hello.test.ts`
- Create: `apps/backend/src/routes/hello.ts`

- [ ] **Step 1: Write the failing test**

`apps/backend/test/hello.test.ts`:
```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import request from "supertest";
import { helloRouter } from "../src/routes/hello.js";

test("GET /api/hello returns greeting with release name", async () => {
  process.env.RELEASE_NAME = "pr-123";
  const app = express();
  app.use(helloRouter);
  const res = await request(app).get("/api/hello");
  assert.equal(res.status, 200);
  assert.equal(res.body.message, "Hello from sandbox pr-123");
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd apps/backend && npm test`
Expected: FAIL — cannot find module `../src/routes/hello.js`.

- [ ] **Step 3: Implement `apps/backend/src/routes/hello.ts`**

```ts
import { Router } from "express";
import { env } from "../env.js";

export const helloRouter = Router();

helloRouter.get("/api/hello", (_req, res) => {
  res.json({ message: `Hello from sandbox ${env.releaseName}` });
});
```

- [ ] **Step 4: Run to verify pass**

Run: `cd apps/backend && npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/backend/src/routes/hello.ts apps/backend/test/hello.test.ts
git commit -m "feat(backend): add /api/hello route"
```

---

## Task 4: Backend — `/api/info` and `/api/health` routes (TDD)

**Files:**
- Create: `apps/backend/test/info.test.ts`
- Create: `apps/backend/src/routes/info.ts`

- [ ] **Step 1: Write the failing test**

`apps/backend/test/info.test.ts`:
```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import request from "supertest";
import { infoRouter } from "../src/routes/info.js";

test("GET /api/info returns pod, release, version, uptime", async () => {
  process.env.POD_NAME = "app-pr-123-backend-abc";
  process.env.RELEASE_NAME = "pr-123";
  process.env.VERSION = "sha-deadbeef";
  const app = express();
  app.use(infoRouter);
  const res = await request(app).get("/api/info");
  assert.equal(res.status, 200);
  assert.equal(res.body.pod, "app-pr-123-backend-abc");
  assert.equal(res.body.release, "pr-123");
  assert.equal(res.body.version, "sha-deadbeef");
  assert.equal(typeof res.body.uptime, "number");
});

test("GET /api/health returns 200", async () => {
  const app = express();
  app.use(infoRouter);
  const res = await request(app).get("/api/health");
  assert.equal(res.status, 200);
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd apps/backend && npm test`
Expected: FAIL — cannot find module `../src/routes/info.js`.

- [ ] **Step 3: Implement `apps/backend/src/routes/info.ts`**

```ts
import { Router } from "express";
import { env } from "../env.js";

export const infoRouter = Router();

infoRouter.get("/api/info", (_req, res) => {
  res.json({
    pod: env.podName,
    release: env.releaseName,
    version: env.version,
    uptime: Math.round(process.uptime()),
  });
});

infoRouter.get("/api/health", (_req, res) => {
  res.status(200).send("ok");
});
```

- [ ] **Step 4: Run to verify pass**

Run: `cd apps/backend && npm test`
Expected: PASS (3 tests — hello + info + health).

- [ ] **Step 5: Commit**

```bash
git add apps/backend/src/routes/info.ts apps/backend/test/info.test.ts
git commit -m "feat(backend): add /api/info and /api/health routes"
```

---

## Task 5: Backend — `index.ts` bootstrap

**Files:**
- Create: `apps/backend/src/index.ts`

- [ ] **Step 1: Write `apps/backend/src/index.ts`**

```ts
import express from "express";
import cors from "cors";
import { env } from "./env.js";
import { helloRouter } from "./routes/hello.js";
import { infoRouter } from "./routes/info.js";

const app = express();
app.use(cors({ origin: env.corsOrigin }));
app.use(helloRouter);
app.use(infoRouter);

app.listen(env.port, () => {
  console.log(
    `backend listening on :${env.port} release=${env.releaseName} pod=${env.podName}`
  );
});
```

- [ ] **Step 2: Verify it builds and runs**

Run:
```bash
cd apps/backend
npm run build
PORT=3000 RELEASE_NAME=local node dist/index.js &
sleep 1
curl -s http://localhost:3000/api/hello
curl -s http://localhost:3000/api/health
kill %1
```

Expected: `{"message":"Hello from sandbox local"}` then `ok`.

- [ ] **Step 3: Commit**

```bash
git add apps/backend/src/index.ts
git commit -m "feat(backend): bootstrap express server"
```

---

## Task 6: Backend — Dockerfile

**Files:**
- Create: `apps/backend/Dockerfile`
- Create: `apps/backend/.dockerignore`

- [ ] **Step 1: Write `apps/backend/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci
COPY src ./src
RUN npm run build && npm prune --production

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package.json ./package.json
EXPOSE 3000
USER node
CMD ["node", "dist/index.js"]
```

- [ ] **Step 2: Write `apps/backend/.dockerignore`**

```
node_modules
dist
test
*.log
.git
```

- [ ] **Step 3: Build and smoke-test the image**

Run:
```bash
docker build -t app-backend:test apps/backend
docker run --rm -d -p 3001:3000 -e RELEASE_NAME=docker-test --name ab-test app-backend:test
sleep 2
curl -s http://localhost:3001/api/hello
docker stop ab-test
```

Expected: `{"message":"Hello from sandbox docker-test"}`.

- [ ] **Step 4: Commit**

```bash
git add apps/backend/Dockerfile apps/backend/.dockerignore
git commit -m "feat(backend): add multi-stage Dockerfile"
```

---

## Task 7: Scaffold frontend package

**Files:**
- Create: `apps/frontend/package.json`
- Create: `apps/frontend/tsconfig.json`
- Create: `apps/frontend/vite.config.ts`
- Create: `apps/frontend/index.html`
- Create: `apps/frontend/.gitignore`

- [ ] **Step 1: Create `apps/frontend/package.json`**

```json
{
  "name": "app-frontend",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@types/react": "^18.3.3",
    "@types/react-dom": "^18.3.0",
    "@vitejs/plugin-react": "^4.3.1",
    "typescript": "^5.4.0",
    "vite": "^5.3.0"
  }
}
```

- [ ] **Step 2: Create `apps/frontend/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "jsx": "react-jsx",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "noEmit": true
  },
  "include": ["src"]
}
```

- [ ] **Step 3: Create `apps/frontend/vite.config.ts`**

```ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: { outDir: "dist" },
});
```

- [ ] **Step 4: Create `apps/frontend/index.html`**

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>App Sandbox</title>
    <script src="/config.js"></script>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

- [ ] **Step 5: Create `apps/frontend/.gitignore`**

```
node_modules
dist
*.log
```

- [ ] **Step 6: Install and commit**

Run:
```bash
cd apps/frontend && npm install && cd ../..
git add apps/frontend/package.json apps/frontend/tsconfig.json apps/frontend/vite.config.ts apps/frontend/index.html apps/frontend/.gitignore apps/frontend/package-lock.json
git commit -m "chore(frontend): scaffold Vite + React + TS package"
```

Expected: `npm install` finishes without errors.

---

## Task 8: Frontend — runtime config + API module

**Files:**
- Create: `apps/frontend/public/config.js.template`
- Create: `apps/frontend/public/config.js` (dev-only local default)
- Create: `apps/frontend/src/api.ts`

- [ ] **Step 1: Create `apps/frontend/public/config.js.template`**

```js
window.__APP_CONFIG__ = { backendUrl: "${BACKEND_URL}" };
```

- [ ] **Step 2: Create `apps/frontend/public/config.js` (fallback for `npm run dev`)**

```js
window.__APP_CONFIG__ = { backendUrl: "http://localhost:3000" };
```

- [ ] **Step 3: Create `apps/frontend/src/api.ts`**

```ts
declare global {
  interface Window {
    __APP_CONFIG__?: { backendUrl: string };
  }
}

const backendUrl = window.__APP_CONFIG__?.backendUrl ?? "http://localhost:3000";

export async function fetchHello(): Promise<{ message: string }> {
  const res = await fetch(`${backendUrl}/api/hello`);
  if (!res.ok) throw new Error(`hello: ${res.status}`);
  return res.json();
}

export async function fetchInfo(): Promise<{
  pod: string;
  release: string;
  version: string;
  uptime: number;
}> {
  const res = await fetch(`${backendUrl}/api/info`);
  if (!res.ok) throw new Error(`info: ${res.status}`);
  return res.json();
}
```

- [ ] **Step 4: Commit**

```bash
git add apps/frontend/public apps/frontend/src/api.ts
git commit -m "feat(frontend): runtime config + api client"
```

---

## Task 9: Frontend — App component

**Files:**
- Create: `apps/frontend/src/main.tsx`
- Create: `apps/frontend/src/App.tsx`

- [ ] **Step 1: Create `apps/frontend/src/main.tsx`**

```tsx
import React from "react";
import ReactDOM from "react-dom/client";
import { App } from "./App";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
```

- [ ] **Step 2: Create `apps/frontend/src/App.tsx`**

```tsx
import { useEffect, useState } from "react";
import { fetchHello, fetchInfo } from "./api";

type Info = Awaited<ReturnType<typeof fetchInfo>>;

export function App() {
  const [message, setMessage] = useState<string>("...");
  const [info, setInfo] = useState<Info | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchHello()
      .then((r) => setMessage(r.message))
      .catch((e) => setError(String(e)));
    fetchInfo()
      .then(setInfo)
      .catch((e) => setError(String(e)));
  }, []);

  return (
    <main style={{ fontFamily: "system-ui", padding: 32, maxWidth: 640 }}>
      <h1>App Sandbox</h1>

      <section style={card}>
        <h2>Hello</h2>
        <p>{message}</p>
      </section>

      <section style={card}>
        <h2>Sandbox Info</h2>
        {error && <p style={{ color: "crimson" }}>{error}</p>}
        {info ? (
          <ul>
            <li><b>Pod:</b> {info.pod}</li>
            <li><b>Release:</b> {info.release}</li>
            <li><b>Version:</b> {info.version}</li>
            <li><b>Uptime:</b> {info.uptime}s</li>
          </ul>
        ) : (
          !error && <p>loading…</p>
        )}
      </section>
    </main>
  );
}

const card: React.CSSProperties = {
  border: "1px solid #ddd",
  borderRadius: 8,
  padding: 16,
  marginTop: 16,
};
```

- [ ] **Step 3: Smoke-test locally**

Run (in separate terminals):
```bash
# terminal 1
cd apps/backend && npm run build && PORT=3000 RELEASE_NAME=dev CORS_ORIGIN=http://localhost:5173 node dist/index.js
# terminal 2
cd apps/frontend && npm run dev
```

Open `http://localhost:5173`. Expected: "Hello from sandbox dev" and an info panel with release=dev.

- [ ] **Step 4: Verify prod build compiles**

Run:
```bash
cd apps/frontend && npm run build
```

Expected: `dist/` directory produced with no errors.

- [ ] **Step 5: Commit**

```bash
git add apps/frontend/src/main.tsx apps/frontend/src/App.tsx
git commit -m "feat(frontend): initial App UI"
```

---

## Task 10: Frontend — nginx, entrypoint, Dockerfile

**Files:**
- Create: `apps/frontend/nginx.conf`
- Create: `apps/frontend/entrypoint.sh`
- Create: `apps/frontend/Dockerfile`
- Create: `apps/frontend/.dockerignore`

- [ ] **Step 1: Create `apps/frontend/nginx.conf`**

```nginx
worker_processes  1;
events { worker_connections 1024; }
http {
  include       mime.types;
  default_type  application/octet-stream;
  sendfile      on;
  keepalive_timeout 65;

  server {
    listen 8080;
    root   /usr/share/nginx/html;
    index  index.html;

    location / {
      try_files $uri $uri/ /index.html;
    }
  }
}
```

- [ ] **Step 2: Create `apps/frontend/entrypoint.sh`**

```bash
#!/bin/sh
set -eu
: "${BACKEND_URL:=http://localhost:3000}"
envsubst '${BACKEND_URL}' < /usr/share/nginx/html/config.js.template > /usr/share/nginx/html/config.js
exec nginx -g 'daemon off;'
```

- [ ] **Step 3: Create `apps/frontend/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json tsconfig.json vite.config.ts index.html ./
COPY public ./public
COPY src ./src
RUN npm ci && npm run build

FROM nginx:1.27-alpine
RUN apk add --no-cache gettext
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 4: Create `apps/frontend/.dockerignore`**

```
node_modules
dist
*.log
.git
```

- [ ] **Step 5: Build and smoke-test**

Run:
```bash
docker build -t app-frontend:test apps/frontend
docker run --rm -d -p 8080:8080 -e BACKEND_URL=http://api.example.com --name af-test app-frontend:test
sleep 1
curl -s http://localhost:8080/config.js
docker stop af-test
```

Expected output of `config.js`:
```
window.__APP_CONFIG__ = { backendUrl: "http://api.example.com" };
```

- [ ] **Step 6: Commit**

```bash
git add apps/frontend/nginx.conf apps/frontend/entrypoint.sh apps/frontend/Dockerfile apps/frontend/.dockerignore
git commit -m "feat(frontend): add nginx-served Docker image with runtime config"
```

---

## Task 11: Helm chart — `Chart.yaml` and `values.yaml`

**Files:**
- Create: `charts/app/Chart.yaml`
- Create: `charts/app/values.yaml`

- [ ] **Step 1: Create `charts/app/Chart.yaml`**

```yaml
apiVersion: v2
name: app
description: DRY Helm chart for the dev sandbox frontend + backend
type: application
version: 0.1.0
appVersion: "0.1.0"
```

- [ ] **Step 2: Create `charts/app/values.yaml`**

```yaml
global:
  releaseName: ""
  namespace: ""
  imageRegistry: ""
  imagePullPolicy: IfNotPresent
  ingress:
    enabled: true
    className: nginx
    scheme: https
    hostSuffix: sandbox.example.com
    tls:
      enabled: false
      secretName: ""

components:
  frontend:
    image:
      repository: app-frontend
      tag: latest
    replicas: 1
    port: 80
    containerPort: 8080
    exposed: true
    hostPrefix: ""
    env:
      - name: BACKEND_URL
        value: "{{ .Values.global.ingress.scheme }}://api-{{ .Values.global.releaseName }}.{{ .Values.global.ingress.hostSuffix }}"
    resources:
      requests: { cpu: 50m, memory: 64Mi }
      limits:   { cpu: 200m, memory: 128Mi }
    probes:
      liveness:  { path: /, port: 8080 }
      readiness: { path: /, port: 8080 }

  backend:
    image:
      repository: app-backend
      tag: latest
    replicas: 1
    port: 80
    containerPort: 3000
    exposed: true
    hostPrefix: "api-"
    env:
      - name: NODE_ENV
        value: production
    resources:
      requests: { cpu: 50m, memory: 64Mi }
      limits:   { cpu: 200m, memory: 128Mi }
    probes:
      liveness:  { path: /api/health, port: 3000 }
      readiness: { path: /api/health, port: 3000 }
```

- [ ] **Step 3: Commit**

```bash
git add charts/app/Chart.yaml charts/app/values.yaml
git commit -m "feat(chart): add Chart.yaml and base values.yaml"
```

---

## Task 12: Helm chart — `_helpers.tpl`

**Files:**
- Create: `charts/app/templates/_helpers.tpl`

- [ ] **Step 1: Write `charts/app/templates/_helpers.tpl`**

```gotemplate
{{/* Release name resolution */}}
{{- define "app.release" -}}
{{- if .Values.global.releaseName -}}
{{- .Values.global.releaseName -}}
{{- else -}}
{{- .Release.Name -}}
{{- end -}}
{{- end -}}

{{/* Namespace resolution: global.namespace if set, else app-<release> */}}
{{- define "app.namespace" -}}
{{- if .Values.global.namespace -}}
{{- .Values.global.namespace -}}
{{- else -}}
app-{{ include "app.release" . }}
{{- end -}}
{{- end -}}

{{/* Component resource name: <release>-<component> */}}
{{- define "app.componentName" -}}
{{- $root := .root -}}
{{- printf "%s-%s" (include "app.release" $root) .name -}}
{{- end -}}

{{/* Image ref: [<registry>/]<repository>:<tag> */}}
{{- define "app.image" -}}
{{- $root := .root -}}
{{- $cfg := .cfg -}}
{{- if $root.Values.global.imageRegistry -}}
{{- printf "%s/%s:%s" $root.Values.global.imageRegistry $cfg.image.repository $cfg.image.tag -}}
{{- else -}}
{{- printf "%s:%s" $cfg.image.repository $cfg.image.tag -}}
{{- end -}}
{{- end -}}

{{/* Hostname for a component */}}
{{- define "app.host" -}}
{{- $root := .root -}}
{{- $cfg := .cfg -}}
{{- printf "%s%s.%s" $cfg.hostPrefix (include "app.release" $root) $root.Values.global.ingress.hostSuffix -}}
{{- end -}}

{{/* Kubernetes recommended labels */}}
{{- define "app.labels" -}}
app.kubernetes.io/name: app
app.kubernetes.io/instance: {{ include "app.release" .root }}
app.kubernetes.io/component: {{ .name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end -}}

{{/* Selector labels (subset of labels, stable across upgrades) */}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: app
app.kubernetes.io/instance: {{ include "app.release" .root }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{/* HTTP probe block from { path, port } */}}
{{- define "app.probe" -}}
httpGet:
  path: {{ .path }}
  port: {{ .port }}
initialDelaySeconds: 5
periodSeconds: 10
{{- end -}}
```

- [ ] **Step 2: Commit**

```bash
git add charts/app/templates/_helpers.tpl
git commit -m "feat(chart): add _helpers.tpl"
```

---

## Task 13: Helm chart — `namespace.yaml`

**Files:**
- Create: `charts/app/templates/namespace.yaml`

- [ ] **Step 1: Write `charts/app/templates/namespace.yaml`**

```yaml
{{- if not .Values.global.namespace }}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ include "app.namespace" . }}
  labels:
    app.kubernetes.io/instance: {{ include "app.release" . }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/app/templates/namespace.yaml
git commit -m "feat(chart): add namespace template"
```

---

## Task 14: Helm chart — `deployment.yaml`

**Files:**
- Create: `charts/app/templates/deployment.yaml`

- [ ] **Step 1: Write `charts/app/templates/deployment.yaml`**

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
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: RELEASE_NAME
              value: {{ include "app.release" $ | quote }}
            - name: VERSION
              value: {{ $cfg.image.tag | quote }}
          livenessProbe:
            {{- include "app.probe" $cfg.probes.liveness | nindent 12 }}
          readinessProbe:
            {{- include "app.probe" $cfg.probes.readiness | nindent 12 }}
          resources: {{- toYaml $cfg.resources | nindent 12 }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/app/templates/deployment.yaml
git commit -m "feat(chart): add deployment template (range over components)"
```

---

## Task 15: Helm chart — `service.yaml`

**Files:**
- Create: `charts/app/templates/service.yaml`

- [ ] **Step 1: Write `charts/app/templates/service.yaml`**

```yaml
{{- range $name, $cfg := .Values.components }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "app.componentName" (dict "root" $ "name" $name) }}
  namespace: {{ include "app.namespace" $ }}
  labels: {{- include "app.labels" (dict "root" $ "name" $name) | nindent 4 }}
spec:
  type: ClusterIP
  selector: {{- include "app.selectorLabels" (dict "root" $ "name" $name) | nindent 4 }}
  ports:
    - name: http
      port: {{ $cfg.port }}
      targetPort: {{ $cfg.containerPort }}
      protocol: TCP
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/app/templates/service.yaml
git commit -m "feat(chart): add service template"
```

---

## Task 16: Helm chart — `ingress.yaml`

**Files:**
- Create: `charts/app/templates/ingress.yaml`

- [ ] **Step 1: Write `charts/app/templates/ingress.yaml`**

```yaml
{{- if .Values.global.ingress.enabled }}
{{- range $name, $cfg := .Values.components }}
{{- if $cfg.exposed }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "app.componentName" (dict "root" $ "name" $name) }}
  namespace: {{ include "app.namespace" $ }}
  labels: {{- include "app.labels" (dict "root" $ "name" $name) | nindent 4 }}
spec:
  ingressClassName: {{ $.Values.global.ingress.className }}
  {{- if $.Values.global.ingress.tls.enabled }}
  tls:
    - hosts:
        - {{ include "app.host" (dict "root" $ "cfg" $cfg) }}
      secretName: {{ $.Values.global.ingress.tls.secretName }}
  {{- end }}
  rules:
    - host: {{ include "app.host" (dict "root" $ "cfg" $cfg) }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "app.componentName" (dict "root" $ "name" $name) }}
                port:
                  number: {{ $cfg.port }}
{{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/app/templates/ingress.yaml
git commit -m "feat(chart): add ingress template (host-based per component)"
```

---

## Task 17: Helm chart — `configmap.yaml` (placeholder)

**Files:**
- Create: `charts/app/templates/configmap.yaml`

This template only renders when a component provides `configData`. Keeps the door open for future non-env config (e.g., a JSON config file) without another template change.

- [ ] **Step 1: Write `charts/app/templates/configmap.yaml`**

```yaml
{{- range $name, $cfg := .Values.components }}
{{- if $cfg.configData }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "app.componentName" (dict "root" $ "name" $name) }}
  namespace: {{ include "app.namespace" $ }}
  labels: {{- include "app.labels" (dict "root" $ "name" $name) | nindent 4 }}
data:
{{- range $k, $v := $cfg.configData }}
  {{ $k }}: |
{{ $v | indent 4 }}
{{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/app/templates/configmap.yaml
git commit -m "feat(chart): add optional configmap template"
```

---

## Task 18: Helm chart — environment values files

**Files:**
- Create: `charts/app/environments/values-local.yaml`
- Create: `charts/app/environments/values-dev.yaml`
- Create: `charts/app/environments/values-staging.yaml`
- Create: `charts/app/environments/values-prod.yaml`
- Create: `charts/app/environments/values-sandbox.yaml`

- [ ] **Step 1: `charts/app/environments/values-local.yaml`**

```yaml
global:
  imageRegistry: ""
  imagePullPolicy: Never
  ingress:
    enabled: true
    className: nginx
    scheme: http
    hostSuffix: sandbox.local
    tls:
      enabled: false
```

- [ ] **Step 2: `charts/app/environments/values-dev.yaml`**

```yaml
global:
  imageRegistry: REPLACE_WITH_REGISTRY
  imagePullPolicy: IfNotPresent
  ingress:
    scheme: https
    hostSuffix: dev.example.com
    tls:
      enabled: true
      secretName: wildcard-dev-tls
components:
  frontend: { replicas: 1 }
  backend:  { replicas: 1 }
```

- [ ] **Step 3: `charts/app/environments/values-staging.yaml`**

```yaml
global:
  imageRegistry: REPLACE_WITH_REGISTRY
  imagePullPolicy: IfNotPresent
  ingress:
    scheme: https
    hostSuffix: staging.example.com
    tls:
      enabled: true
      secretName: wildcard-staging-tls
components:
  frontend: { replicas: 2 }
  backend:  { replicas: 2 }
```

- [ ] **Step 4: `charts/app/environments/values-prod.yaml`**

```yaml
global:
  imageRegistry: REPLACE_WITH_REGISTRY
  imagePullPolicy: IfNotPresent
  ingress:
    scheme: https
    hostSuffix: app.example.com
    tls:
      enabled: true
      secretName: app-tls
components:
  frontend:
    replicas: 3
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 500m, memory: 256Mi }
  backend:
    replicas: 3
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 500m, memory: 512Mi }
```

- [ ] **Step 5: `charts/app/environments/values-sandbox.yaml`**

```yaml
global:
  imageRegistry: REPLACE_WITH_REGISTRY
  imagePullPolicy: IfNotPresent
  ingress:
    scheme: https
    hostSuffix: sandbox.example.com
    tls:
      enabled: true
      secretName: wildcard-sandbox-tls
components:
  frontend: { replicas: 1 }
  backend:  { replicas: 1 }
```

- [ ] **Step 6: Commit**

```bash
git add charts/app/environments
git commit -m "feat(chart): add per-environment values files"
```

Note: `REPLACE_WITH_REGISTRY` is a deliberate placeholder — it must be filled before deploying to a real cluster. The README will document this.

---

## Task 19: Helm chart — lint + template rendering smoke tests

**Files:**
- Create: `charts/app/tests/render.sh`

- [ ] **Step 1: Create `charts/app/tests/render.sh`**

```bash
#!/usr/bin/env bash
# Lints the chart and renders it against every environment values file.
# Exits non-zero if any render fails or omits an expected resource.
set -euo pipefail

CHART="$(dirname "$0")/.."

helm lint "$CHART"

for env in local dev staging prod sandbox; do
  echo "--- rendering env=$env"
  helm template "test-$env" "$CHART" \
    -f "$CHART/environments/values-$env.yaml" \
    --set global.releaseName="test-$env" \
    --set components.frontend.image.tag=smoke \
    --set components.backend.image.tag=smoke \
    > "/tmp/app-$env.yaml"

  # Must produce both Deployments
  grep -q "name: test-$env-frontend" "/tmp/app-$env.yaml"
  grep -q "name: test-$env-backend"  "/tmp/app-$env.yaml"
  # Must produce both Services
  grep -Eq "kind: Service" "/tmp/app-$env.yaml"
  # Ingress present whenever ingress is enabled
  grep -Eq "kind: Ingress" "/tmp/app-$env.yaml"
done
echo "all environments rendered OK"
```

- [ ] **Step 2: Run it**

Run:
```bash
chmod +x charts/app/tests/render.sh
./charts/app/tests/render.sh
```

Expected: `all environments rendered OK`. No `helm lint` errors.

- [ ] **Step 3: Manually spot-check one render**

Run:
```bash
helm template pr-123 charts/app \
  -f charts/app/environments/values-local.yaml \
  --set global.releaseName=pr-123 \
  --set components.frontend.image.tag=pr-123 \
  --set components.backend.image.tag=pr-123 | less
```

Verify by eye:
- Two Deployments: `pr-123-frontend`, `pr-123-backend`
- Namespace `app-pr-123`
- Ingress hosts: `pr-123.sandbox.local`, `api-pr-123.sandbox.local`
- `BACKEND_URL` env on frontend = `http://api-pr-123.sandbox.local`
- `imagePullPolicy: Never` on both containers

- [ ] **Step 4: Commit**

```bash
git add charts/app/tests/render.sh
git commit -m "test(chart): lint + render smoke test across all environments"
```

---

## Task 20: `scripts/sandbox.sh`

**Files:**
- Create: `scripts/sandbox.sh`

- [ ] **Step 1: Write `scripts/sandbox.sh`**

```bash
#!/usr/bin/env bash
# Usage: ./scripts/sandbox.sh <release-name> [--destroy]
# Spins up or tears down a full-stack sandbox on minikube.
set -euo pipefail

RELEASE="${1:?release name required (e.g. pr-123)}"
NAMESPACE="app-${RELEASE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART_DIR="$REPO_ROOT/charts/app"

if [[ "${2:-}" == "--destroy" ]]; then
  echo "Destroying sandbox $RELEASE..."
  helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  echo "Destroyed."
  exit 0
fi

# Ensure we're pointed at minikube
if ! minikube status >/dev/null 2>&1; then
  echo "minikube is not running. Run: minikube start" >&2
  exit 1
fi

# Build directly into minikube's Docker daemon so imagePullPolicy: Never works
eval "$(minikube docker-env)"

echo "Building images with tag=$RELEASE..."
docker build -t "app-frontend:${RELEASE}" "$REPO_ROOT/apps/frontend"
docker build -t "app-backend:${RELEASE}"  "$REPO_ROOT/apps/backend"

echo "Installing chart..."
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$CHART_DIR/environments/values-local.yaml" \
  --set global.releaseName="$RELEASE" \
  --set components.frontend.image.tag="$RELEASE" \
  --set components.backend.image.tag="$RELEASE" \
  --wait --timeout 3m

MINIKUBE_IP="$(minikube ip)"
echo ""
echo "Sandbox ready:"
echo "  Frontend: http://${RELEASE}.sandbox.local"
echo "  Backend:  http://api-${RELEASE}.sandbox.local"
echo ""
echo "If not already done, add to /etc/hosts:"
echo "  ${MINIKUBE_IP}  ${RELEASE}.sandbox.local api-${RELEASE}.sandbox.local"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/sandbox.sh
```

- [ ] **Step 3: End-to-end smoke test**

Run:
```bash
minikube start
minikube addons enable ingress
./scripts/sandbox.sh pr-smoke
# Add the printed hosts entry
echo "$(minikube ip)  pr-smoke.sandbox.local api-pr-smoke.sandbox.local" | sudo tee -a /etc/hosts
curl -s http://api-pr-smoke.sandbox.local/api/hello
curl -sI http://pr-smoke.sandbox.local/
./scripts/sandbox.sh pr-smoke --destroy
```

Expected:
- `{"message":"Hello from sandbox pr-smoke"}`
- Frontend returns `HTTP/1.1 200 OK`
- Destroy removes the namespace.

- [ ] **Step 4: Commit**

```bash
git add scripts/sandbox.sh
git commit -m "feat(scripts): single-command sandbox lifecycle for minikube"
```

---

## Task 21: ArgoCD `ApplicationSet`

**Files:**
- Create: `gitops/applicationset.yaml`

- [ ] **Step 1: Write `gitops/applicationset.yaml`**

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
          owner: REPLACE_WITH_ORG
          repo: REPLACE_WITH_REPO
          tokenRef:
            secretName: github-token
            key: token
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
        repoURL: https://github.com/REPLACE_WITH_ORG/REPLACE_WITH_REPO
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
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

- [ ] **Step 2: Validate YAML syntax**

Run:
```bash
kubectl --dry-run=client apply -f gitops/applicationset.yaml 2>&1 | head -5
```

Expected: either "applicationset.argoproj.io/app-pr-previews created (dry run)" (if ArgoCD CRDs are installed) or an error about an unknown resource kind (acceptable — means the YAML parses but the CRD isn't here).

- [ ] **Step 3: Commit**

```bash
git add gitops/applicationset.yaml
git commit -m "feat(gitops): add ArgoCD ApplicationSet for PR previews"
```

Note: the `REPLACE_WITH_ORG` / `REPLACE_WITH_REPO` tokens must be substituted before applying to a real ArgoCD instance. README documents this.

---

## Task 22: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite `README.md`**

```markdown
# dev-sandboxing

One Helm chart, every environment. Spin up a full-stack sandbox with one command locally, or automatically per PR in a cloud cluster via ArgoCD.

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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README with sandbox usage and chart docs"
```

---

## Self-Review Notes

After drafting this plan, I checked it against the spec:

**Spec coverage:**
- Single chart → Tasks 11–17 ✓
- `components` map DRY pattern → Tasks 12, 14, 15, 16 ✓
- Per-env values files → Task 18 ✓
- Host-based Ingress, namespace-per-sandbox → Tasks 13, 16 ✓
- `sandbox.sh` local flow → Task 20 ✓
- ArgoCD ApplicationSet + PR generator → Task 21 ✓
- Backend (hello + info + health) → Tasks 3, 4, 5 ✓
- Frontend with runtime config → Tasks 8, 9, 10 ✓
- Chart tests → Task 19 ✓
- README → Task 22 ✓

**Placeholder scan:**
- `REPLACE_WITH_REGISTRY`, `REPLACE_WITH_ORG`, `REPLACE_WITH_REPO` are deliberate config tokens documented in the README and spec's Open Questions — not TBDs in the plan itself.

**Type/name consistency:**
- Helper names (`app.release`, `app.namespace`, `app.componentName`, `app.image`, `app.host`, `app.labels`, `app.selectorLabels`, `app.probe`) referenced identically in every template ✓
- `VERSION` env var set from `image.tag` in deployment; backend reads it in `env.ts` ✓
- `BACKEND_URL` templated using `global.ingress.scheme` + `hostSuffix` consistent with values files ✓
