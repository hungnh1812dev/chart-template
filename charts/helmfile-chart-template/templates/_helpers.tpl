{{- define "chart.fullNamespace" -}}
{{- printf "%s-%s" .Values.appNamespace .Values.appEnv -}}
{{- end -}}

{{- define "chart.fullServiceName" -}}
{{- $name := printf "%s-%s-%s" .Values.appName .Values.serviceName .Values.appEnv -}}
{{- if gt (len $name) 63 -}}
{{- fail (printf "full service name %q exceeds 63 chars (%d)" $name (len $name)) -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{/* Input formats are enforced by values.schema.json; this checks what the schema can't. */}}
{{- define "chart.validate" -}}
{{- $ns := include "chart.fullNamespace" . -}}
{{- if ne .Release.Namespace $ns -}}
{{- fail (printf "release must be deployed to namespace %q (<appNamespace>-<appEnv>), got %q" $ns .Release.Namespace) -}}
{{- end -}}
{{- if and .Values.initContainers.enabled (empty .Values.initContainers.containers) -}}
{{- fail "initContainers.enabled is true but initContainers.containers is empty" -}}
{{- end -}}
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
