{{- define "biodata.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "biodata.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: biodata
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Selector labels. Call with (dict "root" . "component" "backend"). */}}
{{- define "biodata.selector" -}}
app.kubernetes.io/name: biodata
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "biodata.pullSecrets" -}}
{{- if .Values.imageCredentials.enabled }}
imagePullSecrets:
  - name: {{ include "biodata.fullname" . }}-regcred
{{- end }}
{{- end -}}
