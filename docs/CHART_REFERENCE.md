# Chart Reference

Every value `charts/app` understands, and how to extend it.

## Values schema

### `global`

Settings shared by every component.

| Key | Type | Default | Notes |
|---|---|---|---|
| `global.releaseName` | string | `""` | Required. Sets namespace, hostnames, component resource names. |
| `global.namespace` | string | `""` | Override namespace. Empty → `app-<releaseName>`. |
| `global.imageRegistry` | string | `""` | Prepended to component image repositories. Empty → use local image name. |
| `global.imagePullPolicy` | string | `IfNotPresent` | Use `Never` for minikube to force locally-built images. |
| `global.imagePullSecrets` | list | `[]` | List of `{ name: ... }` refs for private registries. |
| `global.ingress.enabled` | bool | `true` | Disable to skip creating Ingress resources entirely. |
| `global.ingress.className` | string | `nginx` | Ingress controller class. |
| `global.ingress.scheme` | string | `https` | `http` for local, `https` for cloud. Used by templated env vars. |
| `global.ingress.hostSuffix` | string | `sandbox.example.com` | Base domain. Full host = `<hostPrefix><releaseName>.<hostSuffix>`. |
| `global.ingress.tls.enabled` | bool | `false` | Enable HTTPS at the ingress. |
| `global.ingress.tls.secretName` | string | `""` | Name of the TLS secret (must exist in the target namespace). |

### `components.<name>`

Each key under `components` defines one workload. The chart iterates this map — **add a key, get a Deployment + Service + optional Ingress**.

| Key | Type | Required | Notes |
|---|---|---|---|
| `image.repository` | string | yes | Without registry prefix. `global.imageRegistry` is prepended if set. |
| `image.tag` | string | yes | Usually overridden via `--set` with commit SHA or release name. |
| `replicas` | int | yes | Pod count. |
| `port` | int | yes | Service port (what other pods / the ingress hit). |
| `containerPort` | int | yes | Port the pod listens on. |
| `exposed` | bool | yes | If false, no Ingress is created (internal-only component). |
| `hostPrefix` | string | yes | `""` means host is `<releaseName>.<hostSuffix>`. `"api-"` means `api-<releaseName>.<hostSuffix>`. |
| `env` | list | no | `{ name, value }` pairs. `value` is run through Helm's `tpl` so `{{ .Values.global.releaseName }}` etc. work inside values files. |
| `resources` | object | no | Standard Kubernetes `requests`/`limits`. |
| `probes.liveness` | object | no | `{ path, port }`. Omit to skip the probe. |
| `probes.readiness` | object | no | `{ path, port }`. Omit to skip the probe. |

## Environment layering

Files in `charts/app/environments/` override only what differs from `values.yaml`.

Deploying is always:
```bash
helm upgrade --install <release> charts/app \
  -f charts/app/environments/values-<env>.yaml \
  --set global.releaseName=<release> \
  --set components.frontend.image.tag=<tag> \
  --set components.backend.image.tag=<tag>
```

### `values-local.yaml`
- `imagePullPolicy: Never` (force use of locally-built images)
- `ingress.scheme: http`, `ingress.hostSuffix: sandbox.local`

### `values-dev.yaml` / `values-staging.yaml`
- Point `global.imageRegistry` at your registry
- Typically 1–2 replicas, modest resources
- TLS usually enabled for cloud envs

### `values-prod.yaml`
- Higher replica counts, tighter resource limits
- TLS enabled with a real cert secret

### `values-sandbox.yaml`
- Baseline used by ArgoCD's ApplicationSet for PR previews
- Registry + TLS like other cloud envs

**Before deploying to cloud envs**, replace `REPLACE_WITH_REGISTRY` in each cloud env's values file with your registry host.

## Templated env values

`env[].value` runs through Helm's `tpl` function in `deployment.yaml`. This means you can reference other values from within a values file:

```yaml
components:
  frontend:
    env:
      - name: BACKEND_URL
        value: "{{ .Values.global.ingress.scheme }}://api-{{ .Values.global.releaseName }}.{{ .Values.global.ingress.hostSuffix }}"
```

This is how one static frontend image serves every environment — the backend URL is computed at install time from the same values that drive the ingress.

## Adding a new component

Suppose you want a worker that processes a queue, with no public ingress.

Edit `charts/app/values.yaml`:

```yaml
components:
  # ... frontend and backend ...

  worker:
    image:
      repository: app-worker
      tag: latest
    replicas: 1
    port: 80             # unused but required by the schema
    containerPort: 9000
    exposed: false        # no Ingress
    hostPrefix: ""
    env:
      - name: QUEUE_URL
        value: "redis://redis-{{ .Values.global.releaseName }}:6379"
    probes:
      liveness:  { path: /health, port: 9000 }
      readiness: { path: /health, port: 9000 }
```

That's it. No template edits. `helm template` will now render a Deployment and Service for `worker`, and skip the Ingress because `exposed: false`.

If the worker doesn't have HTTP health endpoints, omit the `probes` block — templates handle missing probes gracefully.

## Helper templates

Reusable snippets in `templates/_helpers.tpl`:

| Helper | Purpose |
|---|---|
| `app.release` | Release name. |
| `app.namespace` | `global.namespace` or `app-<releaseName>`. |
| `app.componentName` | `<releaseName>-<componentName>`. Used for Deployment/Service/Ingress resource names. |
| `app.image` | `<registry>/<repo>:<tag>`, omitting the registry segment when empty. |
| `app.host` | `<hostPrefix><releaseName>.<hostSuffix>`. |
| `app.labels` | Full label set including `app.kubernetes.io/component`. |
| `app.selectorLabels` | Just the selector-relevant labels. |
| `app.probe` | Renders an HTTP probe block from `{ path, port }`. |

When authoring new templates, use these instead of recomputing strings inline.

## Testing

```bash
./charts/app/tests/render.sh
```

Runs `helm lint` and `helm template` against every `environments/values-*.yaml` file to verify the chart renders cleanly. Run this after any change to templates or base values.

To inspect the rendered output for a specific environment:

```bash
helm template release-name charts/app \
  -f charts/app/environments/values-prod.yaml \
  --set global.releaseName=prod \
  --set components.frontend.image.tag=v1.0.0 \
  --set components.backend.image.tag=v1.0.0
```
