{{/*
Expand the name of the chart.
*/}}
{{- define "stackbill.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "stackbill.fullname" -}}
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
{{- define "stackbill.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "stackbill.labels" -}}
helm.sh/chart: {{ include "stackbill.chart" . }}
{{ include "stackbill.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: stackbill
environment: {{ .Values.global.environment }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "stackbill.selectorLabels" -}}
app.kubernetes.io/name: {{ include "stackbill.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "stackbill.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "stackbill.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
MySQL host
*/}}
{{- define "stackbill.mysql.host" -}}
{{- if .Values.mysql.enabled }}
{{- printf "%s-mysql" .Release.Name }}
{{- else }}
{{- .Values.mysql.external.host }}
{{- end }}
{{- end }}

{{/*
MySQL port
*/}}
{{- define "stackbill.mysql.port" -}}
{{- if .Values.mysql.enabled }}
{{- printf "3306" }}
{{- else }}
{{- .Values.mysql.external.port | default "3306" }}
{{- end }}
{{- end }}

{{/*
MySQL database
*/}}
{{- define "stackbill.mysql.database" -}}
{{- if .Values.mysql.enabled }}
{{- .Values.mysql.auth.database }}
{{- else }}
{{- .Values.mysql.external.database }}
{{- end }}
{{- end }}

{{/*
MySQL username
*/}}
{{- define "stackbill.mysql.username" -}}
{{- if .Values.mysql.enabled }}
{{- .Values.mysql.auth.username }}
{{- else }}
{{- .Values.mysql.external.username }}
{{- end }}
{{- end }}

{{/*
MySQL secret name
*/}}
{{- define "stackbill.mysql.secretName" -}}
{{- if .Values.mysql.enabled }}
{{- printf "%s-mysql" .Release.Name }}
{{- else }}
{{- .Values.mysql.external.existingSecret }}
{{- end }}
{{- end }}

{{/*
MongoDB host
*/}}
{{- define "stackbill.mongodb.host" -}}
{{- if .Values.mongodb.enabled }}
{{- printf "%s-mongodb" .Release.Name }}
{{- else }}
{{- .Values.mongodb.external.host }}
{{- end }}
{{- end }}

{{/*
MongoDB port
*/}}
{{- define "stackbill.mongodb.port" -}}
{{- if .Values.mongodb.enabled }}
{{- printf "27017" }}
{{- else }}
{{- .Values.mongodb.external.port | default "27017" }}
{{- end }}
{{- end }}

{{/*
MongoDB database
*/}}
{{- define "stackbill.mongodb.database" -}}
{{- if .Values.mongodb.enabled }}
{{- .Values.mongodb.auth.database }}
{{- else }}
{{- .Values.mongodb.external.database }}
{{- end }}
{{- end }}

{{/*
MongoDB username
*/}}
{{- define "stackbill.mongodb.username" -}}
{{- if .Values.mongodb.enabled }}
{{- .Values.mongodb.auth.username }}
{{- else }}
{{- .Values.mongodb.external.username }}
{{- end }}
{{- end }}

{{/*
MongoDB secret name
*/}}
{{- define "stackbill.mongodb.secretName" -}}
{{- if .Values.mongodb.enabled }}
{{- printf "%s-mongodb" .Release.Name }}
{{- else }}
{{- .Values.mongodb.external.existingSecret }}
{{- end }}
{{- end }}

{{/*
RabbitMQ host
*/}}
{{- define "stackbill.rabbitmq.host" -}}
{{- if .Values.rabbitmq.enabled }}
{{- printf "%s-rabbitmq" .Release.Name }}
{{- else }}
{{- .Values.rabbitmq.external.host }}
{{- end }}
{{- end }}

{{/*
RabbitMQ port
*/}}
{{- define "stackbill.rabbitmq.port" -}}
{{- if .Values.rabbitmq.enabled }}
{{- printf "5672" }}
{{- else }}
{{- .Values.rabbitmq.external.port | default "5672" }}
{{- end }}
{{- end }}

{{/*
RabbitMQ username
*/}}
{{- define "stackbill.rabbitmq.username" -}}
{{- if .Values.rabbitmq.enabled }}
{{- .Values.rabbitmq.auth.username }}
{{- else }}
{{- .Values.rabbitmq.external.username }}
{{- end }}
{{- end }}

{{/*
RabbitMQ secret name
*/}}
{{- define "stackbill.rabbitmq.secretName" -}}
{{- if .Values.rabbitmq.enabled }}
{{- printf "%s-rabbitmq" .Release.Name }}
{{- else }}
{{- .Values.rabbitmq.external.existingSecret }}
{{- end }}
{{- end }}

{{/*
Generate image pull secrets
*/}}
{{- define "stackbill.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ .name }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the proper image name
*/}}
{{- define "stackbill.image" -}}
{{- $registryName := .Values.global.imageRegistry -}}
{{- $repositoryName := .Values.stackbill.image.repository -}}
{{- $tag := .Values.stackbill.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- end }}

{{/*
PVC name
*/}}
{{- define "stackbill.pvc.name" -}}
{{- if .Values.persistence.existingClaim }}
{{- .Values.persistence.existingClaim }}
{{- else }}
{{- printf "%s-data" (include "stackbill.fullname" .) }}
{{- end }}
{{- end }}
