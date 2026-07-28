{{/* Chart name, overridable. */}}
{{- define "swamp-serve.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name. */}}
{{- define "swamp-serve.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "swamp-serve.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "swamp-serve.labels" -}}
helm.sh/chart: {{ include "swamp-serve.chart" . }}
{{ include "swamp-serve.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "swamp-serve.selectorLabels" -}}
app.kubernetes.io/name: {{ include "swamp-serve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "swamp-serve.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "swamp-serve.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Name of the TLS secret backing the server certificate. */}}
{{- define "swamp-serve.tlsSecretName" -}}
{{- if .Values.tls.existingSecret }}
{{- .Values.tls.existingSecret }}
{{- else }}
{{- printf "%s-tls" (include "swamp-serve.fullname" .) }}
{{- end }}
{{- end }}

{{/* True when a swamp-club API key is available to inject as SWAMP_API_KEY. */}}
{{- define "swamp-serve.apiKeyEnabled" -}}
{{- if or .Values.swampAuth.existingSecret .Values.swampAuth.apiKey }}true{{- end }}
{{- end }}

{{/* Secret holding the swamp-club API key for the server process. */}}
{{- define "swamp-serve.apiKeySecretName" -}}
{{- if .Values.swampAuth.existingSecret }}
{{- .Values.swampAuth.existingSecret }}
{{- else }}
{{- printf "%s-auth" (include "swamp-serve.fullname" .) }}
{{- end }}
{{- end }}

{{- define "swamp-serve.apiKeySecretKey" -}}
{{- default "SWAMP_API_KEY" .Values.swampAuth.existingSecretKey }}
{{- end }}

{{/*
Environment shared by the init and serve containers. HOME must be writable —
swamp loads extensions through an embedded runtime under ~/.swamp.
*/}}
{{- define "swamp-serve.env" -}}
- name: HOME
  value: /home/swamp
{{- if include "swamp-serve.apiKeyEnabled" . }}
- name: SWAMP_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "swamp-serve.apiKeySecretName" . }}
      key: {{ include "swamp-serve.apiKeySecretKey" . }}
{{- end }}
{{- with .Values.extraEnv }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Pre-flight checks. These mirror the server's own hard refusals so a bad values
file fails at `helm install` time with an actionable message, rather than as a
CrashLoopBackOff whose reason is buried in the pod log.
*/}}
{{- define "swamp-serve.validate" -}}
{{- $mode := .Values.serve.authMode -}}
{{- if not (has $mode (list "none" "token" "oauth")) -}}
{{- fail (printf "serve.authMode must be one of none|token|oauth (got %q)" $mode) -}}
{{- end -}}
{{- if not (or (eq .Values.serve.host "127.0.0.1") (eq .Values.serve.host "::1")) -}}
  {{- if not .Values.tls.enabled -}}
  {{- fail (printf "swamp serve refuses to bind off-loopback (serve.host=%s) without TLS. Set tls.enabled=true or serve.host=127.0.0.1." .Values.serve.host) -}}
  {{- end -}}
  {{- if eq $mode "none" -}}
  {{- fail (printf "swamp serve refuses to bind off-loopback (serve.host=%s) with serve.authMode=none. Use token or oauth." .Values.serve.host) -}}
  {{- end -}}
{{- end -}}
{{- if eq $mode "oauth" -}}
  {{- if and (empty .Values.serve.oauth.allowedCollectives) (empty .Values.serve.oauth.allowedUsers) -}}
  {{- fail "serve.authMode=oauth requires an admission policy: set serve.oauth.allowedCollectives and/or serve.oauth.allowedUsers." -}}
  {{- end -}}
  {{- if empty .Values.serve.admins -}}
  {{- fail "serve.authMode=oauth requires serve.admins (swamp-club usernames) — without one nobody can administer the server." -}}
  {{- end -}}
  {{- /*
  OAuth needs a swamp-club credential before it can register its client and
  resolve admin usernames. token mode is only warned about (NOTES), because
  existing installs run it without a key.
  */ -}}
  {{- if and (not (include "swamp-serve.apiKeyEnabled" .)) (not .Values.swampAuth.assumeExistingLogin) -}}
  {{- fail "serve.authMode=oauth requires the server itself to be authenticated to swamp-club. Set swampAuth.existingSecret (or swampAuth.apiKey) to an API key with the serve:* scope, or swampAuth.assumeExistingLogin=true if ~/.swamp already carries credentials." -}}
  {{- end -}}
{{- end -}}
{{- end -}}
