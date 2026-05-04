// Thanos Querier / Store Gateway / Compactor manifests for the seichi.click on-prem cluster.
//
// 上流 kube-thanos (thanos-io/kube-thanos) の release が長期間止まっており、
// vendor して追従するのが現実的でないため、Thanos 公式のフラグ仕様だけを
// 直接の上流とみなして必要最小限の構成をここで宣言する。
// 上流追従は Renovate の docker manager が `quay.io/thanos/thanos` の
// image tag を見て PR を出す形で機械化される。

local cfg = {
  namespace: 'monitoring',
  image: 'quay.io/thanos/thanos:v0.41.0',
  storageClassName: 'synology-iscsi-storage',

  // kube-prometheus-stack の Thanos sidecar が使っている Garage S3 への
  // objstore 設定。同じ Secret を Store Gateway / Compactor から再利用する。
  objstoreSecret: { name: 'garage-thanos-credentials', key: 'objstore.yml' },

  // kube-prometheus-stack が Prometheus に付ける external_labels と一致させる。
  // HA pair でないが、将来 replicas を増やしたときに dedup が即効くようにしておく。
  replicaLabels: ['prometheus_replica'],

  // kube-prometheus-stack の Prometheus.serviceMonitorSelector に拾わせるラベル。
  serviceMonitorReleaseLabel: 'prometheus',

  // Querier が fan-out する gRPC StoreAPI 群。
  // - Sidecar: kube-prometheus-stack の thanosService が出す Headless Service
  // - Store Gateway: 本マニフェストで作る thanos-store
  queryStores: [
    'dnssrv+_grpc._tcp.prometheus-kube-prometheus-thanos-discovery.monitoring.svc.cluster.local',
    'dnssrv+_grpc._tcp.thanos-store.monitoring.svc.cluster.local',
  ],
};

local commonLabels(name) = {
  'app.kubernetes.io/name': name,
  'app.kubernetes.io/instance': name,
  'app.kubernetes.io/part-of': 'thanos',
  'app.kubernetes.io/managed-by': 'argocd',
};

local podSelector(name) = {
  'app.kubernetes.io/name': name,
  'app.kubernetes.io/instance': name,
};

local podSecurityContext = {
  fsGroup: 65534,
  runAsUser: 65534,
  runAsGroup: 65532,
  runAsNonRoot: true,
  seccompProfile: { type: 'RuntimeDefault' },
};

local containerSecurityContext = {
  runAsUser: 65534,
  runAsGroup: 65532,
  runAsNonRoot: true,
  seccompProfile: { type: 'RuntimeDefault' },
  allowPrivilegeEscalation: false,
  readOnlyRootFilesystem: true,
  capabilities: { drop: ['ALL'] },
};

local objstoreEnv = [{
  name: 'OBJSTORE_CONFIG',
  valueFrom: { secretKeyRef: cfg.objstoreSecret },
}];

local serviceAccount(name) = {
  apiVersion: 'v1',
  kind: 'ServiceAccount',
  metadata: { name: name, namespace: cfg.namespace, labels: commonLabels(name) },
};

local headlessService(name, ports) = {
  apiVersion: 'v1',
  kind: 'Service',
  metadata: { name: name, namespace: cfg.namespace, labels: commonLabels(name) },
  spec: {
    clusterIP: 'None',
    selector: podSelector(name),
    ports: ports,
  },
};

local clusterIPService(name, ports) = {
  apiVersion: 'v1',
  kind: 'Service',
  metadata: { name: name, namespace: cfg.namespace, labels: commonLabels(name) },
  spec: {
    selector: podSelector(name),
    ports: ports,
  },
};

local serviceMonitor(name, port='http') = {
  apiVersion: 'monitoring.coreos.com/v1',
  kind: 'ServiceMonitor',
  metadata: {
    name: name,
    namespace: cfg.namespace,
    labels: commonLabels(name) + { release: cfg.serviceMonitorReleaseLabel },
  },
  spec: {
    selector: { matchLabels: podSelector(name) },
    endpoints: [{
      port: port,
      relabelings: [{
        action: 'replace',
        sourceLabels: ['namespace', 'pod'],
        separator: '/',
        targetLabel: 'instance',
      }],
    }],
  },
};

local podAntiAffinity(name) = {
  podAntiAffinity: {
    preferredDuringSchedulingIgnoredDuringExecution: [{
      weight: 100,
      podAffinityTerm: {
        topologyKey: 'kubernetes.io/hostname',
        labelSelector: { matchLabels: podSelector(name) },
      },
    }],
  },
};

local probes(port) = {
  livenessProbe: {
    httpGet: { path: '/-/healthy', port: port, scheme: 'HTTP' },
    periodSeconds: 30,
    failureThreshold: 4,
  },
  readinessProbe: {
    httpGet: { path: '/-/ready', port: port, scheme: 'HTTP' },
    periodSeconds: 5,
    failureThreshold: 20,
  },
};

// ---- Querier (stateless Deployment) -----------------------------------------
local queryName = 'thanos-query';
local queryHttpPort = 9090;
local queryGrpcPort = 10901;

local query = {
  serviceAccount: serviceAccount(queryName),

  service: clusterIPService(queryName, [
    { name: 'grpc', port: queryGrpcPort, targetPort: queryGrpcPort },
    { name: 'http', port: queryHttpPort, targetPort: queryHttpPort },
  ]),

  deployment: {
    apiVersion: 'apps/v1',
    kind: 'Deployment',
    metadata: { name: queryName, namespace: cfg.namespace, labels: commonLabels(queryName) },
    spec: {
      replicas: 2,
      selector: { matchLabels: podSelector(queryName) },
      template: {
        metadata: { labels: commonLabels(queryName) },
        spec: {
          serviceAccountName: queryName,
          securityContext: podSecurityContext,
          affinity: podAntiAffinity(queryName),
          terminationGracePeriodSeconds: 120,
          containers: [{
            name: 'thanos-query',
            image: cfg.image,
            imagePullPolicy: 'IfNotPresent',
            args: [
              'query',
              '--log.level=info',
              '--log.format=logfmt',
              '--grpc-address=0.0.0.0:%d' % queryGrpcPort,
              '--http-address=0.0.0.0:%d' % queryHttpPort,
              '--query.timeout=5m',
              '--query.lookback-delta=15m',
              '--query.auto-downsampling',
            ] + [
              '--query.replica-label=' + label
              for label in cfg.replicaLabels
            ] + [
              '--endpoint=' + s
              for s in cfg.queryStores
            ],
            ports: [
              { name: 'grpc', containerPort: queryGrpcPort },
              { name: 'http', containerPort: queryHttpPort },
            ],
            resources: {
              requests: { cpu: '100m', memory: '256Mi' },
              limits: { memory: '1Gi' },
            },
            securityContext: containerSecurityContext,
            terminationMessagePolicy: 'FallbackToLogsOnError',
          } + probes(queryHttpPort)],
        },
      },
    },
  },

  serviceMonitor: serviceMonitor(queryName),
};

// ---- Store Gateway (StatefulSet, local index/chunk cache on disk) -----------
local storeName = 'thanos-store';
local storeHttpPort = 10902;
local storeGrpcPort = 10901;

local store = {
  serviceAccount: serviceAccount(storeName),

  service: headlessService(storeName, [
    { name: 'grpc', port: storeGrpcPort, targetPort: storeGrpcPort },
    { name: 'http', port: storeHttpPort, targetPort: storeHttpPort },
  ]),

  statefulSet: {
    apiVersion: 'apps/v1',
    kind: 'StatefulSet',
    metadata: { name: storeName, namespace: cfg.namespace, labels: commonLabels(storeName) },
    spec: {
      replicas: 1,
      serviceName: storeName,
      selector: { matchLabels: podSelector(storeName) },
      template: {
        metadata: { labels: commonLabels(storeName) },
        spec: {
          serviceAccountName: storeName,
          securityContext: podSecurityContext,
          affinity: podAntiAffinity(storeName),
          terminationGracePeriodSeconds: 120,
          containers: [{
            name: 'thanos-store',
            image: cfg.image,
            imagePullPolicy: 'IfNotPresent',
            args: [
              'store',
              '--log.level=info',
              '--log.format=logfmt',
              '--grpc-address=0.0.0.0:%d' % storeGrpcPort,
              '--http-address=0.0.0.0:%d' % storeHttpPort,
              '--data-dir=/var/thanos/store',
              '--objstore.config=$(OBJSTORE_CONFIG)',
              '--ignore-deletion-marks-delay=24h',
            ],
            env: objstoreEnv,
            ports: [
              { name: 'grpc', containerPort: storeGrpcPort },
              { name: 'http', containerPort: storeHttpPort },
            ],
            resources: {
              requests: { cpu: '200m', memory: '1Gi' },
              limits: { memory: '4Gi' },
            },
            securityContext: containerSecurityContext,
            terminationMessagePolicy: 'FallbackToLogsOnError',
            volumeMounts: [{ name: 'data', mountPath: '/var/thanos/store' }],
          } + probes(storeHttpPort)],
        },
      },
      volumeClaimTemplates: [{
        metadata: { name: 'data', labels: commonLabels(storeName) },
        spec: {
          accessModes: ['ReadWriteOnce'],
          storageClassName: cfg.storageClassName,
          resources: { requests: { storage: '50Gi' } },
        },
      }],
    },
  },

  serviceMonitor: serviceMonitor(storeName),
};

// ---- Compactor (StatefulSet, single replica) --------------------------------
local compactName = 'thanos-compact';
local compactHttpPort = 10902;

local compact = {
  serviceAccount: serviceAccount(compactName),

  service: headlessService(compactName, [
    { name: 'http', port: compactHttpPort, targetPort: compactHttpPort },
  ]),

  statefulSet: {
    apiVersion: 'apps/v1',
    kind: 'StatefulSet',
    metadata: { name: compactName, namespace: cfg.namespace, labels: commonLabels(compactName) },
    spec: {
      replicas: 1,
      serviceName: compactName,
      selector: { matchLabels: podSelector(compactName) },
      template: {
        metadata: { labels: commonLabels(compactName) },
        spec: {
          serviceAccountName: compactName,
          securityContext: podSecurityContext,
          affinity: podAntiAffinity(compactName),
          terminationGracePeriodSeconds: 120,
          containers: [{
            name: 'thanos-compact',
            image: cfg.image,
            imagePullPolicy: 'IfNotPresent',
            args: [
              'compact',
              '--wait',
              '--log.level=info',
              '--log.format=logfmt',
              '--http-address=0.0.0.0:%d' % compactHttpPort,
              '--data-dir=/var/thanos/compact',
              '--objstore.config=$(OBJSTORE_CONFIG)',
              '--delete-delay=48h',
              '--compact.concurrency=1',
              '--downsample.concurrency=1',
              '--downsampling.disable',
              '--retention.resolution-raw=0d',
              '--retention.resolution-5m=0d',
              '--retention.resolution-1h=0d',
            ] + [
              '--deduplication.replica-label=' + label
              for label in cfg.replicaLabels
            ],
            env: objstoreEnv,
            ports: [{ name: 'http', containerPort: compactHttpPort }],
            resources: {
              requests: { cpu: '100m', memory: '256Mi' },
              limits: { memory: '1Gi' },
            },
            securityContext: containerSecurityContext,
            terminationMessagePolicy: 'FallbackToLogsOnError',
            volumeMounts: [{ name: 'data', mountPath: '/var/thanos/compact' }],
          } + probes(compactHttpPort)],
        },
      },
      volumeClaimTemplates: [{
        metadata: { name: 'data', labels: commonLabels(compactName) },
        spec: {
          accessModes: ['ReadWriteOnce'],
          storageClassName: cfg.storageClassName,
          resources: { requests: { storage: '50Gi' } },
        },
      }],
    },
  },

  serviceMonitor: serviceMonitor(compactName),
};

[
  query.serviceAccount,
  query.service,
  query.deployment,
  query.serviceMonitor,
  store.serviceAccount,
  store.service,
  store.statefulSet,
  store.serviceMonitor,
  compact.serviceAccount,
  compact.service,
  compact.statefulSet,
  compact.serviceMonitor,
]
