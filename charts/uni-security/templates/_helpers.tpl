{{- define "uni-security.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully-qualified app name. Release-suffixed so cluster-scoped RBAC never collides
across two installs on one cluster.
*/}}
{{- define "uni-security.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "uni-security.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "uni-security.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "uni-security.labels" -}}
helm.sh/chart: {{ include "uni-security.chart" . }}
{{ include "uni-security.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: metrixforge
{{- end -}}

{{- define "uni-security.selectorLabels" -}}
app.kubernetes.io/name: {{ include "uni-security.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "uni-security.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "uni-security.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding APP_ID / APP_SECRET (existing or chart-created).
*/}}
{{- define "uni-security.secretName" -}}
{{- if .Values.credentials.existingSecret -}}
{{- .Values.credentials.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "uni-security.fullname" .) -}}
{{- end -}}
{{- end -}}
