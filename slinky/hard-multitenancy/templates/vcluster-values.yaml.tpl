privateNodes:
  enabled: true
  vpn:
    enabled: true
  autoNodes:
    - provider: ${node_provider_name}
%{ if length(auto_node_properties) > 0 ~}
      properties:
%{ for k, v in auto_node_properties ~}
        ${k}: "${v}"
%{ endfor ~}
%{ endif ~}
%{ if length(static_node_groups) > 0 ~}
      static:
%{ for sg in static_node_groups ~}
        - name: ${sg.name}
          quantity: ${sg.quantity}
%{ if length(sg.node_types) > 0 ~}
          nodeTypeSelector:
            - property: node.kubernetes.io/instance-type
              operator: In
              values:
%{ for nt in sg.node_types ~}
                - ${nt}
%{ endfor ~}
%{ endif ~}
%{ if length(sg.labels) > 0 ~}
          labels:
%{ for k, v in sg.labels ~}
            ${k}: "${v}"
%{ endfor ~}
%{ endif ~}
%{ if length(sg.taints) > 0 ~}
          taints:
%{ for t in sg.taints ~}
            - key: ${t.key}
              value: "${t.value}"
              effect: ${t.effect}
%{ endfor ~}
%{ endif ~}
%{ endfor ~}
%{ endif ~}
%{ if length(dynamic_node_groups) > 0 ~}
      dynamic:
%{ for dg in dynamic_node_groups ~}
        - name: ${dg.name}
%{ if length(dg.node_types) > 0 ~}
          nodeTypeSelector:
            - property: node.kubernetes.io/instance-type
              operator: In
              values:
%{ for nt in dg.node_types ~}
                - ${nt}
%{ endfor ~}
%{ endif ~}
%{ if dg.limits != null ~}
          limits:
%{ if dg.limits.nodes != null ~}
            nodes: "${dg.limits.nodes}"
%{ endif ~}
%{ if dg.limits.cpu != null ~}
            cpu: "${dg.limits.cpu}"
%{ endif ~}
%{ if dg.limits.memory != null ~}
            memory: "${dg.limits.memory}"
%{ endif ~}
%{ endif ~}
%{ if length(dg.labels) > 0 ~}
          labels:
%{ for k, v in dg.labels ~}
            ${k}: "${v}"
%{ endfor ~}
%{ endif ~}
%{ if length(dg.taints) > 0 ~}
          taints:
%{ for t in dg.taints ~}
            - key: ${t.key}
              value: "${t.value}"
              effect: ${t.effect}
%{ endfor ~}
%{ endif ~}
%{ endfor ~}
%{ endif ~}


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
        # NVIDIA GPU Operator – GPU drivers and device plugin
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
            toolkit:
              enabled: true
            devicePlugin:
              enabled: true
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
        # via Kubernetes CRs managed by the slurm-operator.
        # Ref: https://slinky.schedmd.com/projects/slurm-operator/en/release-1.0/installation.html
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
                    tag: latest
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
                    tag: latest
                service:
                  spec:
                    type: LoadBalancer
%{ if length(login_service_annotations) > 0 ~}
                  annotations:
%{ for k, v in login_service_annotations ~}
                    ${k}: "${v}"
%{ endfor ~}
%{ endif ~}
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
              enabled: false
%{ endif ~}
