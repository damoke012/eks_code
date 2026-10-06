{{- define "usxpress-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "usxpress-app.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "usxpress-app.labels" -}}
app.kubernetes.io/name: {{ include "usxpress-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
usxpress.io/environment: {{ .Values.environment }}
usxpress.io/cluster: {{ .Values.clusterName }}
usxpress.io/owner: {{ .Values.owner.team }}
{{- end -}}

{{- define "usxpress-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "usxpress-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "usxpress-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "usxpress-app.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
The image reference, by digest only.

A tag is refused here rather than at admission. Kyverno rejects it in the
cluster, but by then the release is already failing and the reason is three
layers away from the person who wrote the values file.
*/}}
{{- define "usxpress-app.image" -}}
{{- $d := .Values.image.digest | default "" -}}
{{- if not (hasPrefix "sha256:" $d) -}}
{{- fail "image.digest must be a sha256 digest. Tags are rejected: 515 of 517 ECR repositories accept org-wide push, so a tag can be moved under you." -}}
{{- end -}}
{{- printf "%s@%s" .Values.image.repository $d -}}
{{- end -}}

{{/*
Fail early on the combinations that have actually broken us.
*/}}
{{- define "usxpress-app.validate" -}}
{{- if not .Values.clusterName -}}
{{- fail "clusterName is required. external-dns owns DNS records by this value; a copied VirtualService with the wrong one fails to register and reports nothing." -}}
{{- end -}}
{{- if not (has .Values.clusterName (list "op-usxpress-dev" "op-usxpress-qa" "op-usxpress-prod")) -}}
{{- fail (printf "clusterName %q is not an on-prem cluster. Valid: op-usxpress-dev, op-usxpress-qa, op-usxpress-prod. (dpl, dpl2 and jbtest are decommissioned -- INFRA-1686.)" .Values.clusterName) -}}
{{- end -}}
{{- if not .Values.owner.team -}}
{{- fail "owner.team is required. Whoever owns the repo owns the pager; an app with no named owner is not ready to onboard." -}}
{{- end -}}
{{- if and .Values.serviceAccount.roleArn (not .Values.serviceAccount.create) -}}
{{- fail "serviceAccount.roleArn is set but serviceAccount.create is false -- the IRSA annotation would land on nothing." -}}
{{- end -}}
{{- if and .Values.expose.enabled (not .Values.expose.hostname) -}}
{{- fail "expose.enabled requires expose.hostname." -}}
{{- end -}}
{{- if and .Values.expose.enabled (not .Values.service.enabled) -}}
{{- fail "expose.enabled requires service.enabled -- a VirtualService needs a Service to route to." -}}
{{- end -}}
{{- if and (eq .Values.workload.kind "CronJob") (not .Values.workload.schedule) -}}
{{- fail "workload.kind CronJob requires workload.schedule." -}}
{{- end -}}
{{- if and .Values.autoscaling.enabled (ne .Values.workload.kind "Deployment") -}}
{{- fail "autoscaling is only valid for workload.kind Deployment." -}}
{{- end -}}
{{- if and .Values.persistence.enabled (eq .Values.workload.kind "Deployment") (gt (int .Values.workload.replicas) 1) (has "ReadWriteOnce" .Values.persistence.accessModes) -}}
{{- fail "A ReadWriteOnce volume cannot be shared by more than one Deployment replica. Use ceph-fs with ReadWriteMany, or a StatefulSet." -}}
{{- end -}}
{{- if and .Values.networkPolicy.enabled .Values.networkPolicy.defaultDeny (not .Values.networkPolicy.egress) -}}
{{- fail "networkPolicy.defaultDeny with no egress rules blocks DNS. Add at least a kube-dns rule, or set defaultDeny false." -}}
{{- end -}}
{{- end -}}

{{/*
Pod spec shared by every workload kind.
*/}}
{{- define "usxpress-app.podSpec" -}}
serviceAccountName: {{ include "usxpress-app.serviceAccountName" . }}
securityContext:
  runAsNonRoot: {{ .Values.securityContext.runAsNonRoot }}
  runAsUser: {{ .Values.securityContext.runAsUser }}
{{- with .Values.nodeSelector }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity: {{- toYaml . | nindent 2 }}
{{- end }}
{{- if and .Values.topologySpread.enabled (ne .Values.workload.kind "Job") }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: {{ .Values.topologySpread.topologyKey }}
    whenUnsatisfiable: {{ .Values.topologySpread.whenUnsatisfiable }}
    labelSelector:
      matchLabels: {{- include "usxpress-app.selectorLabels" . | nindent 8 }}
{{- end }}
containers:
  - name: {{ include "usxpress-app.name" . }}
    image: {{ include "usxpress-app.image" . }}
    imagePullPolicy: {{ .Values.image.pullPolicy }}
    {{- with .Values.command }}
    command: {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.args }}
    args: {{- toYaml . | nindent 6 }}
    {{- end }}
    securityContext:
      readOnlyRootFilesystem: {{ .Values.securityContext.readOnlyRootFilesystem }}
      allowPrivilegeEscalation: {{ .Values.securityContext.allowPrivilegeEscalation }}
      capabilities: {{- toYaml .Values.securityContext.capabilities | nindent 8 }}
    {{- if .Values.service.enabled }}
    ports:
    {{- range .Values.service.ports }}
      - name: {{ .name }}
        containerPort: {{ .targetPort }}
        protocol: {{ .protocol | default "TCP" }}
    {{- end }}
    {{- end }}
    envFrom:
      {{- if .Values.config }}
      - configMapRef:
          name: {{ include "usxpress-app.fullname" . }}-config
      {{- end }}
      {{- if .Values.externalSecrets.enabled }}
      - secretRef:
          name: {{ include "usxpress-app.fullname" . }}-secrets
      {{- end }}
      {{- with .Values.extraEnvFrom }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- with .Values.extraEnv }}
    env: {{- toYaml . | nindent 6 }}
    {{- end }}
    resources: {{- toYaml .Values.resources | nindent 6 }}
    {{- with .Values.probes.liveness }}
    livenessProbe: {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.probes.readiness }}
    readinessProbe: {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.probes.startup }}
    startupProbe: {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if or .Values.tmpVolume .Values.persistence.enabled }}
    volumeMounts:
      {{- if .Values.tmpVolume }}
      - name: tmp
        mountPath: /tmp
      {{- end }}
      {{- if .Values.persistence.enabled }}
      - name: data
        mountPath: {{ .Values.persistence.mountPath }}
      {{- end }}
    {{- end }}
{{- if or .Values.tmpVolume (and .Values.persistence.enabled (ne .Values.workload.kind "StatefulSet")) }}
volumes:
  {{- if .Values.tmpVolume }}
  # readOnlyRootFilesystem with no writable /tmp breaks every mktemp. This
  # cost a QA ETL job weeks of not applying a single file.
  - name: tmp
    emptyDir: {}
  {{- end }}
  {{- if and .Values.persistence.enabled (ne .Values.workload.kind "StatefulSet") }}
  - name: data
    persistentVolumeClaim:
      claimName: {{ include "usxpress-app.fullname" . }}-data
  {{- end }}
{{- end }}
{{- end -}}
