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
          name: skypilot
        ---
        apiVersion: v1
        kind: Namespace
        metadata:
          name: ingress-nginx
        ---
%{ if deploy_gpu_operator ~}
        apiVersion: v1
        kind: Namespace
        metadata:
          name: gpu-operator
        ---
%{ endif ~}
      helm:
%{ if deploy_gpu_operator ~}
        # -----------------------------------------------------------------
        # NVIDIA GPU Operator — GPU drivers, device plugin, GFD
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
        # Ingress NGINX — shared ingress controller for SkyPilot services
        # -----------------------------------------------------------------
        - chart:
            name: ingress-nginx
            repo: https://kubernetes.github.io/ingress-nginx
            version: "${ingress_nginx_version}"
          release:
            name: ingress-nginx
            namespace: ingress-nginx
          values: |-
            controller:
              ingressClassResource:
                default: true
%{ if length(ingress_service_annotations) > 0 ~}
              service:
                annotations:
%{ for k, v in ingress_service_annotations ~}
                  ${k}: "${v}"
%{ endfor ~}
%{ endif ~}
        # -----------------------------------------------------------------
        # SkyPilot API Server
        # -----------------------------------------------------------------
        - chart:
            name: skypilot
            repo: https://helm.skypilot.co
            version: "${skypilot_version}"
          release:
            name: skypilot
            namespace: skypilot
          values: |-
            apiService:
              image: ${skypilot_image}
%{ if skypilot_config != "" ~}
              config: |
                ${indent(16, skypilot_config)}
%{ endif ~}
            kubernetesCredentials:
              useApiServerCluster: true
            ingress:
              enabled: true
              ingressClassName: nginx
%{ if auth_credentials != "" ~}
              authCredentials: "${auth_credentials}"
%{ endif ~}
            ingress-nginx:
              enabled: false
            storage:
              enabled: true
            rbac:
              create: true
              manageRbacPolicies: true
              manageSystemComponents: true
            prometheus:
              enabled: ${deploy_prometheus}
            grafana:
              enabled: ${deploy_grafana}
