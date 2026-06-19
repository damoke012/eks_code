{{/*
Compute the resolved service namespace — defaults to release namespace.
*/}}
{{- define "platform-app-expose.serviceNamespace" -}}
{{- default .Release.Namespace .Values.service.namespace -}}
{{- end -}}

{{/*
Compute the certificate name — defaults to ${hostname}-cert with dots replaced.
*/}}
{{- define "platform-app-expose.certName" -}}
{{- if .Values.certificate.name -}}
{{ .Values.certificate.name }}
{{- else -}}
{{ printf "%s-cert" (.Values.hostname | replace "." "-") }}
{{- end -}}
{{- end -}}

{{/*
Standard labels.
*/}}
{{- define "platform-app-expose.labels" -}}
app.kubernetes.io/managed-by: helm
app.kubernetes.io/component: app-expose
app.kubernetes.io/name: {{ .Release.Name }}
platform.usxpress.io/exposure: shared-http
{{- end -}}
