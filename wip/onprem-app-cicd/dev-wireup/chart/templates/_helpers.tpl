{{- define "etl.env" -}}
{{- required "environment is required (dev|qa|prod)" .Values.environment -}}
{{- end -}}

{{- define "etl.prefix" -}}
op-usxpress-{{ include "etl.env" . }}
{{- end -}}

{{- define "etl.labels" -}}
app.kubernetes.io/name: etl-pipeline
app.kubernetes.io/part-of: risingwave
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
