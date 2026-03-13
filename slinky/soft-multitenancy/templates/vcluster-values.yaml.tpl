controlPlane:
  advanced:
    virtualScheduler:
      enabled: true

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
    persistentVolumes:
      enabled: true
    persistentVolumeClaims:
      enabled: true

networking:
  advanced:
    fallbackHostCluster: true
    proxyKubelets:
      byIP: true

exportKubeConfig:
  secret:
    name: "${tenant_name}-vcluster-kubeconfig"

experimental:
  deploy:
    vcluster:
      manifests: |-
        apiVersion: v1
        kind: Namespace
        metadata:
          name: slinky
        ---
        apiVersion: v1
        kind: Namespace
        metadata:
          name: slurm
        ---
        apiVersion: v1
        kind: Namespace
        metadata:
          name: cert-manager
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
          name: gcp-critical-pods
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
      helm:
        # -----------------------------------------------------------------
        # cert-manager – required by the Slinky slurm-operator
        # -----------------------------------------------------------------
        - chart:
            name: cert-manager
            repo: https://charts.jetstack.io
            version: "${cert_manager_version}"
          release:
            name: cert-manager
            namespace: cert-manager
          values: |-
            crds:
              enabled: true
%{ if deploy_prometheus_operator ~}
        # -----------------------------------------------------------------
        # Prometheus Operator – CRDs for Slurm metrics collection
        # -----------------------------------------------------------------
        - chart:
            name: kube-prometheus-stack
            repo: https://prometheus-community.github.io/helm-charts
            version: "${kube_prometheus_stack_version}"
          release:
            name: kube-prometheus-stack
            namespace: monitoring
          values: |-
            crds:
              enabled: true
            grafana:
              enabled: false
            alertmanager:
              enabled: false
            prometheus:
              enabled: false
            thanosRuler:
              enabled: false
            nodeExporter:
              enabled: false
            kubeStateMetrics:
              enabled: true
            prometheusOperator:
              enabled: true
%{ endif ~}
%{ if deploy_gpu_operator ~}
        # -----------------------------------------------------------------
        # NVIDIA GPU Operator – uses host drivers, no driver installation
        # -----------------------------------------------------------------
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
        # -----------------------------------------------------------------
        # Slinky – slurm-operator CRDs
        # -----------------------------------------------------------------
        - chart:
            name: slurm-operator-crds
            repo: oci://ghcr.io/slinkyproject/charts
            version: "${slinky_version}"
          release:
            name: slurm-operator-crds
            namespace: slinky
        # -----------------------------------------------------------------
        # Slinky – slurm-operator
        # -----------------------------------------------------------------
        - chart:
            name: slurm-operator
            repo: oci://ghcr.io/slinkyproject/charts
            version: "${slinky_version}"
          release:
            name: slurm-operator
            namespace: slinky
        # -----------------------------------------------------------------
        # Slurm cluster – deploys controller, restapi, nodesets, loginsets
        # -----------------------------------------------------------------
        - chart:
            name: slurm
            repo: oci://ghcr.io/slinkyproject/charts
            version: "${slinky_version}"
          release:
            name: slurm
            namespace: slurm
          values: |-
            clusterName: "${slurm_cluster_name}"
            configFiles:
              gres.conf: |
                AutoDetect=nvidia
            controller:
              persistence:
                enabled: false
%{ if deploy_prometheus_operator ~}
              metrics:
                enabled: true
                serviceMonitor:
                  enabled: true
%{ endif ~}
            restapi:
              replicas: 1
            accounting:
              enabled: false
            nodesets:
              slinky:
                enabled: false
              ${partition_name}:
                enabled: true
                replicas: ${worker_replicas}
                slurmd:
                  image:
                    repository: ghcr.io/slinkyproject/slurmd
                    tag: 25.11-ubuntu24.04
                  resources:
                    limits:
                      nvidia.com/gpu: ${gpu_per_node}
                logfile:
                  image:
                    repository: docker.io/library/alpine
                    tag: "3.21"
                tolerations:
                  - key: nvidia.com/gpu
                    operator: Exists
                    effect: NoSchedule
                taintKubeNodes: false
                useResourceLimits: true
                updateStrategy:
                  type: RollingUpdate
                  rollingUpdate:
                    maxUnavailable: 25%
                extraConfMap:
                  Gres: ["gpu:1"]
            loginsets:
              slinky:
                enabled: false
              login:
                enabled: true
                replicas: ${login_replicas}
%{ if length(ssh_authorized_keys) > 0 ~}
                rootSshAuthorizedKeys: |
%{ for key in ssh_authorized_keys ~}
                  ${key}
%{ endfor ~}
%{ endif ~}
                login:
                  image:
                    repository: ghcr.io/slinkyproject/login
                    tag: 25.11-ubuntu24.04
                initconf:
                  image:
                    repository: docker.io/library/alpine
                    tag: "3.21"
                service:
                  spec:
                    type: ClusterIP
                sssdConf: |
                  [sssd]
                  config_file_version = 2
                  services = nss,pam
                  domains = DEFAULT
                  [nss]
                  filter_groups = root,slurm
                  filter_users = root,slurm
                  [pam]
                  [domain/DEFAULT]
                  id_provider = files
            partitions:
              all:
                enabled: true
                nodesets:
                  - ALL
                configMap:
                  State: UP
                  Default: "YES"
                  MaxTime: UNLIMITED
%{ if deploy_slurm_exporter && deploy_prometheus_operator ~}
        # -----------------------------------------------------------------
        # Slinky – Prometheus exporter for Slurm metrics
        # -----------------------------------------------------------------
        - chart:
            name: slurm-exporter
            repo: oci://ghcr.io/slinkyproject/charts
            version: "${slurm_exporter_version}"
          release:
            name: slurm-exporter
            namespace: slurm
          values: |-
            exporter:
              enabled: true
%{ endif ~}
