{{- define "backfort.pod" -}}
{{- $root := .root -}}
metadata:
  labels:
    {{- include "backfort.labels" $root | nindent 4 }}
  annotations:
    checksum/config: {{ toYaml $root.Values.config | sha256sum }}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  serviceAccountName: {{ include "backfort.serviceAccount" $root }}
  terminationGracePeriodSeconds: {{ $root.Values.terminationGracePeriodSeconds }}
  securityContext:
    {{- toYaml $root.Values.podSecurityContext | nindent 4 }}
  {{- with $root.Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $root.Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $root.Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $root.Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: backfort
      image: {{ include "backfort.image" $root | quote }}
      imagePullPolicy: {{ $root.Values.image.pullPolicy }}
      args:
        - -c
        - /etc/backfort/config.yaml
        {{- toYaml .args | nindent 8 }}
      securityContext:
        {{- toYaml $root.Values.securityContext | nindent 8 }}
      resources:
        {{- toYaml $root.Values.resources | nindent 8 }}
      {{- if $root.Values.envFromSecret }}
      envFrom:
        - secretRef:
            name: {{ $root.Values.envFromSecret | quote }}
      {{- end }}
      env:
        - name: HOME
          value: /var/lib/backfort/state
        - name: XDG_STATE_HOME
          value: /var/lib/backfort/state
        - name: GNUPGHOME
          value: /var/lib/backfort/state/gnupg
        {{- range $name, $value := $root.Values.env }}
        - name: {{ $name | quote }}
          value: {{ $value | quote }}
        {{- end }}
      volumeMounts:
        - name: config
          mountPath: /etc/backfort
          readOnly: true
        - name: state
          mountPath: /var/lib/backfort
        - name: work
          mountPath: /var/tmp/backfort
        - name: scratch
          mountPath: /tmp
        {{- if $root.Values.storage.backups.enabled }}
        - name: backups
          mountPath: /backups
        {{- end }}
        {{- range $source := $root.Values.sources }}
        - name: {{ printf "source-%s" $source.name }}
          mountPath: {{ $source.mountPath | quote }}
          readOnly: true
        {{- end }}
        {{- range $secret := $root.Values.secretMounts }}
        - name: {{ printf "secret-%s" $secret.name }}
          mountPath: {{ $secret.mountPath | quote }}
          readOnly: true
        {{- end }}
        {{- if .restoreClaim }}
        - name: restore
          mountPath: /restore
        {{- end }}
  volumes:
    - name: config
      configMap:
        name: {{ include "backfort.name" $root }}-config
    - name: state
      persistentVolumeClaim:
        claimName: {{ include "backfort.claim" (dict "root" $root "kind" "state") }}
    - name: work
      emptyDir:
        sizeLimit: {{ $root.Values.workSizeLimit | quote }}
    - name: scratch
      emptyDir:
        sizeLimit: {{ $root.Values.scratchSizeLimit | quote }}
    {{- if $root.Values.storage.backups.enabled }}
    - name: backups
      persistentVolumeClaim:
        claimName: {{ include "backfort.claim" (dict "root" $root "kind" "backups") }}
    {{- end }}
    {{- range $source := $root.Values.sources }}
    - name: {{ printf "source-%s" $source.name }}
      persistentVolumeClaim:
        claimName: {{ $source.claimName | quote }}
        readOnly: true
    {{- end }}
    {{- range $secret := $root.Values.secretMounts }}
    - name: {{ printf "secret-%s" $secret.name }}
      secret:
        secretName: {{ $secret.secretName | quote }}
        defaultMode: 0440
    {{- end }}
    {{- if .restoreClaim }}
    - name: restore
      persistentVolumeClaim:
        claimName: {{ .restoreClaim | quote }}
    {{- end }}
{{- end -}}
