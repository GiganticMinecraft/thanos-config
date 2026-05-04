# thanos-config

[seichi.click](https://www.seichi.click/) のオンプレ Kubernetes クラスタにデプロイする
**Thanos Querier / Store Gateway / Compactor** のマニフェスト集。

`main.jsonnet` 1 ファイルで完結する自己完結型の jsonnet で、上流の
[`thanos-io/kube-thanos`](https://github.com/thanos-io/kube-thanos) には依存しない
(kube-thanos は最新 release が 2022 年で実質的にメンテが止まっているため)。

直接の上流とみなすのは [Thanos 公式](https://github.com/thanos-io/thanos) の
コマンドラインフラグ仕様で、`quay.io/thanos/thanos` の image tag を Renovate の
docker manager が追って PR を出す。

## どこから読まれるか

[`GiganticMinecraft/seichi_infra`](https://github.com/GiganticMinecraft/seichi_infra) の
ArgoCD Application が `repoURL` でこの repo を直接参照し、
`directory.jsonnet` で `main.jsonnet` を評価して manifest を apply する。

## ローカルでの作業

```bash
brew install jsonnet

# render を確認
jsonnet main.jsonnet | jq '[.[] | {kind, name: .metadata.name}]'

# 個別フラグの確認
jsonnet main.jsonnet | jq '.[] | select(.kind=="Deployment") | .spec.template.spec.containers[0].args'
```

## 環境特化されている前提

- namespace: `monitoring`
- objstore Secret: `garage-thanos-credentials` / `objstore.yml`
  (kube-prometheus-stack の Thanos sidecar と共有)
- Querier の `--endpoint`: kube-prometheus-stack の sidecar discovery
  Service (`prometheus-kube-prometheus-thanos-discovery`) と本マニフェストの Store Gateway
- PVC StorageClass: `synology-iscsi-storage`
- Prometheus の `external_labels.prometheus_replica` を replica label として dedup
- ServiceMonitor に `release: prometheus` ラベル付与
  (kube-prometheus-stack の `serviceMonitorSelector` に拾わせるため)
