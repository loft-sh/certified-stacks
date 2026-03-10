controlPlane:
  proxy:
    extraSANs:
      - "${cluster_domain}"
  ingress:
    enabled: true
    host: "${cluster_domain}"
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
    enabled: true

sync:
  fromHost:
    nodes:
      enabled: true
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
    customResources:
      rayclusters.ray.io:
        enabled: true
      rayjobs.ray.io:
        enabled: true
      rayservices.ray.io:
        enabled: true

networking:
  advanced:
    fallbackHostCluster: true
    proxyKubelets:
      byIP: true

exportKubeConfig:
  server: "${cluster_url}"
  secret:
    name: "${name}-vcluster-kubeconfig"

%{ if install_gpu_operator ~}
experimental:
  deploy:
    vcluster:
      helm:
        - chart:
            name: gpu-operator
            repo: https://helm.ngc.nvidia.com/nvidia
            version: "${gpu_operator_version}"
          release:
            name: gpu-operator
            namespace: gpu-operator
          values: ""
%{ endif ~}
