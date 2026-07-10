{{/* Chart name (overridable). */}}
{{- define "avtools.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully-qualified app name. */}}
{{- define "avtools.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "avtools.labels" -}}
app.kubernetes.io/name: {{ include "avtools.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: avtools
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
avtools/environment: {{ .Values.environment }}
{{- end -}}

{{/* Selector labels. */}}
{{- define "avtools.selectorLabels" -}}
app.kubernetes.io/name: {{ include "avtools.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Service account name for the job pods. */}}
{{- define "avtools.serviceAccountName" -}}
{{- default (include "avtools.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}
