{{- define "chart.fullNamespace" -}}
{{- printf "%s-%s" .Values.appNamespace .Values.appEnv -}}
{{- end -}}

{{- define "chart.fullServiceName" -}}
{{- printf "%s-%s-%s" .Values.appName .Values.serviceName .Values.appEnv -}}
{{- end -}}

{{- define "chart.selectorLabels" -}}
app.kubernetes.io/instance: {{ include "chart.fullServiceName" . }}
{{- end -}}

{{- define "chart.labels" -}}
app.kubernetes.io/name: {{ .Values.appName }}
app.kubernetes.io/component: {{ .Values.serviceName }}
app.kubernetes.io/part-of: {{ .Values.appNamespace }}
environment: {{ .Values.appEnv }}
{{ include "chart.selectorLabels" . }}
{{- end -}}
