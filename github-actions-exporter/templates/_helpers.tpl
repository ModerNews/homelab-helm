{{/*
The Prometheus scrape config, as a standalone template so prometheus.yaml can
both mount it and hash it without the two drifting apart.
*/}}
{{- define "rig.prometheusConfig" -}}
{{- with .Values.prometheusServer }}
global:
  scrape_interval: {{ .scrapeInterval }}
  {{- with .externalLabels }}
  external_labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
scrape_configs:
  # The exporter. `up{job="github-actions-exporter"}` is the first thing to
  # look at: 1 means the metrics endpoint answered at all, independently of
  # whether any webhook has ever arrived.
  - job_name: github-actions-exporter
    metrics_path: {{ .metricsPath }}
    static_configs:
      - targets: [{{ .target | quote }}]
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
{{- end }}
{{- end -}}
