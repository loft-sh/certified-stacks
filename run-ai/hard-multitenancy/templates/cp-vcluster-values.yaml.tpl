%{ if cp_static_ip == "" && length(cp_ingress_service_annotations) == 0 ~}
deploy:
  ingressNginx:
    enabled: true
%{ endif ~}

controlPlane:
  proxy:
    extraSANs:
      - "${domain}"

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
          name: ${backend_namespace}
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: ${registry_secret_name}
          namespace: ${backend_namespace}
        type: kubernetes.io/dockerconfigjson
        data:
          .dockerconfigjson: ${registry_credentials}
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: runai-backend-tls
          namespace: ${backend_namespace}
        type: kubernetes.io/tls
        data:
          tls.crt: ${tls_cert_b64}
          tls.key: ${tls_key_b64}
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: runai-ca-cert
          namespace: ${backend_namespace}
          labels:
            run.ai/cluster-wide: "true"
            run.ai/name: runai-ca-cert
        type: Opaque
        data:
          runai-ca.pem: ${cp_ca_cert_b64}
      helm:
%{ if cp_static_ip != "" || length(cp_ingress_service_annotations) > 0 ~}
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
              service:
%{ if cp_static_ip != "" ~}
                loadBalancerIP: "${cp_static_ip}"
%{ endif ~}
%{ if length(cp_ingress_service_annotations) > 0 ~}
                annotations:
%{ for k, v in cp_ingress_service_annotations ~}
                  ${k}: "${v}"
%{ endfor ~}
%{ endif ~}
%{ endif ~}
        - chart:
            name: control-plane
            repo: ${cp_chart_repo}
            version: "${cp_chart_version}"
          release:
            name: runai-backend
            namespace: ${backend_namespace}
          values: |-
            global:
              domain: ${domain}
              customCA:
                enabled: true
              imagePullSecrets:
                - name: ${registry_secret_name}
            tenantsManager:
              config:
                adminUsername: ${admin_email}
                adminPassword: "${admin_password}"
