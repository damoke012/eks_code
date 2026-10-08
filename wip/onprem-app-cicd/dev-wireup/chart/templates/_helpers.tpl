{{- define "etl.env" -}}
{{- required "environment is required (dev|qa|prod)" .Values.environment -}}
{{- end -}}

{{- define "etl.prefix" -}}
op-usxpress-{{ include "etl.env" . }}
{{- end -}}
