## 2026-05-03T10:50:35+00:00
### nodes
NAME                            STATUS   ROLES           AGE     VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION                       CONTAINER-RUNTIME
devops-platform-control-plane   Ready    control-plane   7d23h   v1.30.0   172.18.0.2    <none>        Debian GNU/Linux 12 (bookworm)   5.15.153.1-microsoft-standard-WSL2   containerd://1.7.15
### pod count by namespace
      5 argocd
      9 kube-system
      1 local-path-storage
      4 platform-tools
      3 tenant-a
      2 tenant-b
### k8s version
Client Version: v1.34.1
Kustomize Version: v5.7.1
Server Version: v1.30.0
### kind container
devops-platform-control-plane Up 11 minutes kindest/node:v1.30.0
