{{/* Common labels */}}
{{- define "paperless.labels" -}}
app.kubernetes.io/name: paperless
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Selector labels for a given component */}}
{{- define "paperless.selectorLabels" -}}
app.kubernetes.io/name: paperless
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
