{{- define "deepagent-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "deepagent-app.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "deepagent-app.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "deepagent-app.labels" -}}
app.kubernetes.io/name: {{ include "deepagent-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "deepagent-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "deepagent-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
