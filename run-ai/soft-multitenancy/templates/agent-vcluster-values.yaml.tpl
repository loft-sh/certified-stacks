controlPlane:
%{ if high_availability ~}
  statefulSet:
    highAvailability:
      replicas: ${ha_replicas}
    resources:
      requests:
        cpu: 100m
        memory: 1Gi
      limits:
        cpu: 500m
        memory: 2Gi
  backingStore:
    etcd:
      deploy:
        enabled: true
        statefulSet:
          resources:
            requests:
              cpu: 100m
              memory: 1Gi
            limits:
              cpu: 500m
              memory: 1Gi
%{ endif ~}
  proxy:
    extraSANs:
      - "${agent_domain}"
  ingress:
    enabled: true
    host: "${agent_domain}"
    spec:
      ingressClassName: "nginx"
    annotations:
      nginx.ingress.kubernetes.io/ssl-passthrough: "true"
      nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
  advanced:
    virtualScheduler:
      enabled: true

policies:
  networkPolicy:
    enabled: false

sync:
  fromHost:
    nodes:
      enabled: true
%{ if node_selector_label_value != "" ~}
      selector:
        labels:
          ${node_selector_label_key}: ${node_selector_label_value}
%{ endif ~}
    storageClasses:
      enabled: true
    ingressClasses:
      enabled: true
  toHost:
    ingresses:
      enabled: true
    persistentVolumes:
      enabled: true
    persistentVolumeClaims:
      enabled: true

networking:
  advanced:
    fallbackHostCluster: true
    proxyKubelets:
      byIP: true

deploy:
  ingressNginx:
    enabled: false

exportKubeConfig:
  server: "https://${agent_domain}"
  secret:
    name: "${agent_name}-vcluster-kubeconfig"

experimental:
  deploy:
    vcluster:
      manifests: |-
        apiVersion: v1
        kind: Namespace
        metadata:
          name: ${agent_namespace}
        ---
%{ if deploy_gpu_operator ~}
        apiVersion: v1
        kind: Namespace
        metadata:
          name: gpu-operator
        ---
        apiVersion: v1
        kind: ResourceQuota
        metadata:
          name: critical-pods
          namespace: gpu-operator
        spec:
          scopeSelector:
            matchExpressions:
            - operator: In
              scopeName: PriorityClass
              values:
              - system-node-critical
              - system-cluster-critical
        ---
%{ endif ~}
%{ if deploy_prometheus_operator ~}
        apiVersion: v1
        kind: Namespace
        metadata:
          name: monitoring
        ---
%{ endif ~}
%{ if enable_inference ~}
        apiVersion: v1
        kind: Namespace
        metadata:
          name: knative-serving
        ---
        apiVersion: v1
        kind: Namespace
        metadata:
          name: knative-operator
        ---
%{ if inference_tls_cert_b64 != "" ~}
        apiVersion: v1
        kind: Secret
        metadata:
          name: runai-cluster-inference-tls-secret
          namespace: knative-serving
        type: kubernetes.io/tls
        data:
          tls.crt: ${inference_tls_cert_b64}
          tls.key: ${inference_tls_key_b64}
        ---
%{ endif ~}
%{ endif ~}
        apiVersion: v1
        kind: Namespace
        metadata:
          name: ingress-nginx
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: ${registry_secret_name}
          namespace: ${agent_namespace}
        type: kubernetes.io/dockerconfigjson
        data:
          .dockerconfigjson: ${registry_credentials}
%{ if cp_ca_cert_b64 != "" ~}
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: runai-ca-cert
          namespace: ${agent_namespace}
          labels:
            run.ai/cluster-wide: "true"
            run.ai/name: runai-ca-cert
        type: Opaque
        data:
          runai-ca.pem: ${cp_ca_cert_b64}
%{ endif ~}
%{ if workload_domain_tls_cert_b64 != "" ~}
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: runai-cluster-domain-tls-secret
          namespace: ${agent_namespace}
        type: kubernetes.io/tls
        data:
          tls.crt: ${workload_domain_tls_cert_b64}
          tls.key: ${workload_domain_tls_key_b64}
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: runai-cluster-domain-tls-secret
          namespace: ingress-nginx
        type: kubernetes.io/tls
        data:
          tls.crt: ${workload_domain_tls_cert_b64}
          tls.key: ${workload_domain_tls_key_b64}
%{ endif ~}
      helm:
%{ if deploy_prometheus_operator ~}
        - chart:
            name: kube-prometheus-stack
            repo: https://prometheus-community.github.io/helm-charts
            version: "${kube_prometheus_stack_version}"
          release:
            name: kube-prometheus-stack
            namespace: monitoring
          values: |-
            grafana:
              enabled: false
%{ endif ~}
%{ if deploy_gpu_operator ~}
        - chart:
            name: gpu-operator
            repo: https://helm.ngc.nvidia.com/nvidia
            version: "${gpu_operator_version}"
          release:
            name: gpu-operator
            namespace: gpu-operator
          values: |-
            driver:
              enabled: ${gpu_operator_driver_enabled}
            hostPaths:
              driverInstallDir: "${gpu_operator_driver_install_dir}"
            toolkit:
              enabled: true
              installDir: "${gpu_operator_driver_install_dir}"
            cdi:
              enabled: true
              default: true
            devicePlugin:
              enabled: ${gpu_operator_device_plugin_enabled}
            dcgm:
              enabled: true
            dcgmExporter:
              enabled: true
            migManager:
              enabled: false
            nodeStatusExporter:
              enabled: true
            nfd:
              enabled: true
            gfd:
              enabled: true
            operator:
              defaultRuntime: containerd
%{ endif ~}
%{ if enable_inference ~}
        - chart:
            name: knative-operator
            repo: https://knative.github.io/operator
            version: "${knative_operator_version}"
          release:
            name: knative-operator
            namespace: knative-operator
        - chart:
            name: raw
            repo: https://bedag.github.io/helm-charts/
            version: "${raw_chart_version}"
          release:
            name: knative-serving-cr
            namespace: knative-serving
          values: |-
            resources:
              - apiVersion: operator.knative.dev/v1beta1
                kind: KnativeServing
                metadata:
                  name: knative-serving
                  namespace: knative-serving
                spec:
                  version: "${knative_serving_version}"
                  ingress:
                    kourier:
                      enabled: true
%{ if length(inference_service_annotations) > 0 ~}
                  services:
                  - name: kourier
                    annotations:
%{ for k, v in inference_service_annotations ~}
                      ${k}: "${v}"
%{ endfor ~}
%{ endif ~}
%{ if inference_tls_cert_b64 != "" ~}
                  workloads:
                  - name: net-kourier-controller
                    env:
                    - container: controller
                      envVars:
                      - name: CERTS_SECRET_NAMESPACE
                        value: "knative-serving"
                      - name: CERTS_SECRET_NAME
                        value: "runai-cluster-inference-tls-secret"
%{ endif ~}
                  config:
                    autoscaler:
                      enable-scale-to-zero: "true"
                    features:
                      kubernetes.podspec-schedulername: enabled
                      kubernetes.podspec-nodeselector: enabled
                      kubernetes.podspec-affinity: enabled
                      kubernetes.podspec-tolerations: enabled
                      kubernetes.podspec-volumes-emptydir: enabled
                      kubernetes.podspec-securitycontext: enabled
                      kubernetes.containerspec-addcapabilities: enabled
                      kubernetes.podspec-persistent-volume-claim: enabled
                      kubernetes.podspec-persistent-volume-write: enabled
                      multi-container: enabled
                      kubernetes.podspec-init-containers: enabled
%{ if inference_domain != "" ~}
                    domain:
                      ${inference_domain}: ""
%{ endif ~}
                    network:
                      ingress-class: "kourier.ingress.networking.knative.dev"
%{ if inference_tls_cert_b64 != "" ~}
                      default-external-scheme: "https"
%{ endif ~}
%{ endif ~}
        - chart:
            name: runai-cluster
            repo: ${agent_chart_repo}
            version: "${agent_chart_version}"
          release:
            name: runai-cluster
            namespace: ${agent_namespace}
          values: |-
            controlPlane:
              url: ${cp_url}
              clientSecret: "${client_secret}"
            cluster:
              uid: "${cluster_uid}"
              url: https://${workload_domain}
            global:
              subdomainSupport: true
              imagePullSecrets:
                - name: ${registry_secret_name}
%{ if cp_ca_cert_b64 != "" ~}
              customCA:
                enabled: true
%{ endif ~}
            gpu-operator:
              enabled: false
            runai-operator:
              config:
                nvidia-device-plugin:
                  enabled: ${deploy_gpu_operator ? "false" : "true"}
