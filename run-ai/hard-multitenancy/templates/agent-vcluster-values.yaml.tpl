controlPlane:
  proxy:
    extraSANs:
      - "${agent_domain}"

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
          name: ${agent_namespace}
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
        kind: Secret
        metadata:
          name: ${registry_secret_name}
          namespace: ${agent_namespace}
        type: kubernetes.io/dockerconfigjson
        data:
          .dockerconfigjson: ${registry_credentials}
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
        ---
        apiVersion: v1
        kind: Namespace
        metadata:
          name: ingress-nginx
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: runai-cluster-domain-tls-secret
          namespace: ${agent_namespace}
        type: kubernetes.io/tls
        data:
          tls.crt: ${agent_domain_tls_cert_b64}
          tls.key: ${agent_domain_tls_key_b64}
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: runai-cluster-domain-tls-secret
          namespace: ingress-nginx
        type: kubernetes.io/tls
        data:
          tls.crt: ${agent_domain_tls_cert_b64}
          tls.key: ${agent_domain_tls_key_b64}
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
        - chart:
            name: ingress-nginx
            repo: https://kubernetes.github.io/ingress-nginx
            version: "4.12.1"
          release:
            name: ingress-nginx
            namespace: ingress-nginx
          values: |-
            controller:
              ingressClassResource:
                default: true
              extraArgs:
                default-ssl-certificate: ingress-nginx/runai-cluster-domain-tls-secret
%{ if agent_static_ip != "" || length(ingress_service_annotations) > 0 ~}
              service:
%{ if agent_static_ip != "" ~}
                loadBalancerIP: "${agent_static_ip}"
%{ endif ~}
%{ if length(ingress_service_annotations) > 0 ~}
                annotations:
%{ for k, v in ingress_service_annotations ~}
                  ${k}: "${v}"
%{ endfor ~}
%{ endif ~}
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
            version: "2.0.2"
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
            cluster:
              uid: "${cluster_uid}"
              url: https://${agent_domain}
            controlPlane:
              url: https://${cp_domain}
              clientSecret: "${client_secret}"
            global:
              subdomainSupport: true
              imagePullSecrets:
                - name: ${registry_secret_name}
              customCA:
                enabled: true
            gpu-operator:
              enabled: false
            runai-operator:
              config:
                nvidia-device-plugin:
                  enabled: false
