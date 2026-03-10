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
          name: kuberay
        ---
        apiVersion: v1
        kind: Namespace
        metadata:
          name: ray
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
%{ if deploy_default_cluster ~}
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: ray-dashboard
          namespace: ray
          annotations:
            nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
            nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
        spec:
          ingressClassName: nginx
          rules:
            - http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: ray-cluster-kuberay-head-svc
                        port:
                          number: 8265
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
        # Ingress NGINX — standalone LoadBalancer for external access
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
        # KubeRay Operator — manages RayCluster, RayJob, RayService CRDs
        # -----------------------------------------------------------------
        - chart:
            name: kuberay-operator
            repo: https://ray-project.github.io/kuberay-helm/
            version: "${kuberay_version}"
          release:
            name: kuberay-operator
            namespace: kuberay
%{ if deploy_default_cluster ~}
        # -----------------------------------------------------------------
        # Default RayCluster — head node + GPU worker group
        # Dashboard exposed via Ingress NGINX on auto-nodes.
        # Users can create additional RayCluster/RayJob/RayService CRs.
        # -----------------------------------------------------------------
        - chart:
            name: ray-cluster
            repo: https://ray-project.github.io/kuberay-helm/
            version: "${kuberay_version}"
          release:
            name: ray-cluster
            namespace: ray
          values: |-
            image:
              repository: ${ray_image}
              tag: "${ray_image_tag}"
            head:
              rayStartParams:
                dashboard-host: "0.0.0.0"
              resources:
                limits:
                  cpu: "1"
                  memory: "2Gi"
                requests:
                  cpu: "1"
                  memory: "2Gi"
%{ if enable_autoscaling ~}
              enableInTreeAutoscaling: true
%{ endif ~}
            headService:
              metadata:
%{ if length(head_service_annotations) > 0 ~}
                annotations:
%{ for k, v in head_service_annotations ~}
                  ${k}: "${v}"
%{ endfor ~}
%{ endif ~}
%{ if gpu_per_worker > 0 ~}
            worker:
              replicas: ${worker_replicas}
              minReplicas: ${worker_replicas}
              maxReplicas: ${max_workers}
              resources:
                limits:
                  cpu: "2"
                  memory: "4Gi"
                  nvidia.com/gpu: "${gpu_per_worker}"
                requests:
                  cpu: "2"
                  memory: "4Gi"
                  nvidia.com/gpu: "${gpu_per_worker}"
%{ else ~}
            worker:
              replicas: ${worker_replicas}
              minReplicas: ${worker_replicas}
              maxReplicas: ${max_workers}
              resources:
                limits:
                  cpu: "2"
                  memory: "4Gi"
                requests:
                  cpu: "2"
                  memory: "4Gi"
%{ endif ~}
%{ endif ~}
