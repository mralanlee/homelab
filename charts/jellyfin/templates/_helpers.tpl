{{- define "jellyfin.labels" -}}
app.kubernetes.io/name: jellyfin
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
