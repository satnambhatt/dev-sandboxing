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

{{/* Selector labels */}}
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
