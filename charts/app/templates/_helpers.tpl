{{- define "app.fullname" -}}
{{- .Release.Name }}-{{ .Chart.Name }}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "app.componentLabels" -}}
{{ include "app.labels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "app.componentSelectorLabels" -}}
{{ include "app.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
