{{/*
Expand the name of the chart.
*/}}
{{- define "fortiaigate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "fortiaigate.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "fortiaigate.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fortiaigate.labels" -}}
helm.sh/chart: {{ include "fortiaigate.chart" . }}
{{ include "fortiaigate.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fortiaigate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fortiaigate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Return the proper namespace
*/}}
{{- define "fortiaigate.namespace" -}}
{{- .Release.Namespace }}
{{- end }}

{{/*
Shared PVC name
*/}}
{{- define "fortiaigate.storageClaimName" -}}
{{- default (printf "%s-storage" (include "fortiaigate.fullname" .)) .Values.storage.claimName -}}
{{- end }}

{{/*
TLS secret name
*/}}
{{- define "fortiaigate.tlsSecretName" -}}
{{- if .Values.tls.existingSecret -}}
{{- .Values.tls.existingSecret -}}
{{- else -}}
{{- default "fortiaigate-tls-secret" .Values.tls.secretName -}}
{{- end -}}
{{- end }}

{{/*
License ConfigMap name
*/}}
{{- define "fortiaigate.licenseConfigMapName" -}}
{{- if .Values.license.existingConfigMap -}}
{{- .Values.license.existingConfigMap -}}
{{- else -}}
{{- printf "%s-license-config" (include "fortiaigate.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
License manager secret name
*/}}
{{- define "fortiaigate.licenseManagerSecretName" -}}
{{- if .Values.license_manager.existingSecret -}}
{{- .Values.license_manager.existingSecret -}}
{{- else -}}
{{- printf "%s-license-manager" (include "fortiaigate.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
TLS checksum used for restart annotations.
*/}}
{{- define "fortiaigate.tlsChecksum" -}}
{{- if .Values.tls.existingSecret -}}
{{- printf "existing:%s" .Values.tls.existingSecret | sha256sum -}}
{{- else if and .Values.tls.certData .Values.tls.keyData -}}
{{- printf "%s%s" .Values.tls.certData .Values.tls.keyData | sha256sum -}}
{{- else -}}
{{- printf "%s%s" (tpl (.Files.Get .Values.tls.cert) $) (tpl (.Files.Get .Values.tls.key) $) | sha256sum -}}
{{- end -}}
{{- end }}

{{/*
Render nodeSelector, affinity and tolerations from a placement block.
*/}}
{{- define "fortiaigate.renderPlacement" -}}
{{- $placement := . | default dict -}}
{{- with $placement.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- with $placement.affinity }}
affinity:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- with $placement.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Common app TLS environment variables.
*/}}
{{- define "fortiaigate.appTlsEnv" -}}
{{- if .Values.tls.enabled }}
- name: FORTIAIGATE_SSL_CERT_FILE
  value: {{ printf "%s/tls.crt" .Values.tls.mountPath | quote }}
- name: FORTIAIGATE_SSL_KEY_FILE
  value: {{ printf "%s/tls.key" .Values.tls.mountPath | quote }}
{{- end }}
{{- end }}

{{/*
Whether the shared TLS secret should be mounted into a pod.
This only covers the chart-managed common secret path.
*/}}
{{- define "fortiaigate.shouldMountTlsSecret" -}}
{{- if or .Values.tls.enabled (and (not .Values.externalDatabase.enabled) .Values.postgresql.tls.enabled) (and (not .Values.externalRedis.enabled) .Values.redis.tls.enabled) -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Whether an external database TLS secret should be mounted.
*/}}
{{- define "fortiaigate.shouldMountExternalDatabaseTlsSecret" -}}
{{- if and .Values.externalDatabase.enabled .Values.externalDatabase.ssl.enabled .Values.externalDatabase.ssl.existingSecret -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Whether an external Redis TLS secret should be mounted.
*/}}
{{- define "fortiaigate.shouldMountExternalRedisTlsSecret" -}}
{{- if and .Values.externalRedis.enabled .Values.externalRedis.ssl.enabled .Values.externalRedis.ssl.existingSecret -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Render external TLS secret volume mounts.
*/}}
{{- define "fortiaigate.externalTlsVolumeMounts" -}}
{{- if eq (include "fortiaigate.shouldMountExternalDatabaseTlsSecret" .) "true" }}
- name: external-database-tls
  mountPath: {{ .Values.externalDatabase.ssl.mountPath | quote }}
  readOnly: true
{{- end }}
{{- if eq (include "fortiaigate.shouldMountExternalRedisTlsSecret" .) "true" }}
- name: external-redis-tls
  mountPath: {{ .Values.externalRedis.ssl.mountPath | quote }}
  readOnly: true
{{- end }}
{{- end }}

{{/*
Render external TLS secret volumes.
*/}}
{{- define "fortiaigate.externalTlsVolumes" -}}
{{- if eq (include "fortiaigate.shouldMountExternalDatabaseTlsSecret" .) "true" }}
- name: external-database-tls
  secret:
    secretName: {{ .Values.externalDatabase.ssl.existingSecret }}
{{- end }}
{{- if eq (include "fortiaigate.shouldMountExternalRedisTlsSecret" .) "true" }}
- name: external-redis-tls
  secret:
    secretName: {{ .Values.externalRedis.ssl.existingSecret }}
{{- end }}
{{- end }}

{{/*
Render Redis SSL and password environment variables.
Host and port remain in the shared ConfigMap.
*/}}
{{- define "fortiaigate.redisEnv" -}}
{{- if .Values.externalRedis.enabled }}
- name: REDIS_SSL_ENABLED
  value: {{ .Values.externalRedis.ssl.enabled | quote }}
{{- if .Values.externalRedis.ssl.enabled }}
{{- if .Values.externalRedis.ssl.certFile }}
- name: REDIS_SSL_CERTFILE
  value: {{ .Values.externalRedis.ssl.certFile | quote }}
{{- else if and .Values.externalRedis.ssl.existingSecret .Values.externalRedis.ssl.certFilename }}
- name: REDIS_SSL_CERTFILE
  value: {{ printf "%s/%s" .Values.externalRedis.ssl.mountPath .Values.externalRedis.ssl.certFilename | quote }}
{{- end }}
{{- if .Values.externalRedis.ssl.keyFile }}
- name: REDIS_SSL_KEYFILE
  value: {{ .Values.externalRedis.ssl.keyFile | quote }}
{{- else if and .Values.externalRedis.ssl.existingSecret .Values.externalRedis.ssl.keyFilename }}
- name: REDIS_SSL_KEYFILE
  value: {{ printf "%s/%s" .Values.externalRedis.ssl.mountPath .Values.externalRedis.ssl.keyFilename | quote }}
{{- end }}
{{- if .Values.externalRedis.ssl.caFile }}
- name: REDIS_SSL_CA_CERTS
  value: {{ .Values.externalRedis.ssl.caFile | quote }}
{{- else if and .Values.externalRedis.ssl.existingSecret .Values.externalRedis.ssl.caFilename }}
- name: REDIS_SSL_CA_CERTS
  value: {{ printf "%s/%s" .Values.externalRedis.ssl.mountPath .Values.externalRedis.ssl.caFilename | quote }}
{{- end }}
{{- end }}
- name: REDIS_PASSWORD
{{- if .Values.externalRedis.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalRedis.existingSecret }}
      key: {{ .Values.externalRedis.existingSecretKey }}
{{- else }}
  value: {{ .Values.externalRedis.password | quote }}
{{- end }}
{{- else }}
- name: REDIS_SSL_ENABLED
  value: {{ .Values.redis.tls.enabled | quote }}
{{- if .Values.redis.tls.enabled }}
- name: REDIS_SSL_CERTFILE
  value: {{ printf "%s/tls.crt" .Values.tls.mountPath | quote }}
- name: REDIS_SSL_KEYFILE
  value: {{ printf "%s/tls.key" .Values.tls.mountPath | quote }}
- name: REDIS_SSL_CA_CERTS
  value: {{ printf "%s/tls.crt" .Values.tls.mountPath | quote }}
{{- end }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-redis
      key: redis-password
{{- end }}
{{- end }}

{{/*
Render PostgreSQL SSL and password environment variables.
Host, port, user and db remain in the shared ConfigMap.
*/}}
{{- define "fortiaigate.postgresEnv" -}}
{{- if .Values.externalDatabase.enabled }}
- name: POSTGRES_SSL_ENABLED
  value: {{ .Values.externalDatabase.ssl.enabled | quote }}
{{- if .Values.externalDatabase.ssl.enabled }}
{{- if .Values.externalDatabase.ssl.certFile }}
- name: POSTGRES_SSL_CERTFILE
  value: {{ .Values.externalDatabase.ssl.certFile | quote }}
{{- else if and .Values.externalDatabase.ssl.existingSecret .Values.externalDatabase.ssl.certFilename }}
- name: POSTGRES_SSL_CERTFILE
  value: {{ printf "%s/%s" .Values.externalDatabase.ssl.mountPath .Values.externalDatabase.ssl.certFilename | quote }}
{{- end }}
{{- if .Values.externalDatabase.ssl.keyFile }}
- name: POSTGRES_SSL_KEYFILE
  value: {{ .Values.externalDatabase.ssl.keyFile | quote }}
{{- else if and .Values.externalDatabase.ssl.existingSecret .Values.externalDatabase.ssl.keyFilename }}
- name: POSTGRES_SSL_KEYFILE
  value: {{ printf "%s/%s" .Values.externalDatabase.ssl.mountPath .Values.externalDatabase.ssl.keyFilename | quote }}
{{- end }}
{{- if .Values.externalDatabase.ssl.caFile }}
- name: POSTGRES_SSL_CA_CERTS
  value: {{ .Values.externalDatabase.ssl.caFile | quote }}
{{- else if and .Values.externalDatabase.ssl.existingSecret .Values.externalDatabase.ssl.caFilename }}
- name: POSTGRES_SSL_CA_CERTS
  value: {{ printf "%s/%s" .Values.externalDatabase.ssl.mountPath .Values.externalDatabase.ssl.caFilename | quote }}
{{- end }}
{{- end }}
- name: POSTGRES_PASSWORD
{{- if .Values.externalDatabase.existingSecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.externalDatabase.existingSecret }}
      key: {{ .Values.externalDatabase.existingSecretKey }}
{{- else }}
  value: {{ .Values.externalDatabase.password | quote }}
{{- end }}
{{- else }}
- name: POSTGRES_SSL_ENABLED
  value: {{ .Values.postgresql.tls.enabled | quote }}
{{- if .Values.postgresql.tls.enabled }}
- name: POSTGRES_SSL_CERTFILE
  value: {{ printf "%s/tls.crt" .Values.tls.mountPath | quote }}
- name: POSTGRES_SSL_KEYFILE
  value: {{ printf "%s/tls.key" .Values.tls.mountPath | quote }}
- name: POSTGRES_SSL_CA_CERTS
  value: {{ printf "%s/tls.crt" .Values.tls.mountPath | quote }}
{{- end }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-postgresql
      key: password
{{- end }}
{{- end }}
