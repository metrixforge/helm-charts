# MetrixForge Helm charts

Official Helm charts for the [MetrixForge](https://metrixforge.io) platform.

```bash
helm repo add metrixforge https://metrixforge.github.io/helm-charts
helm repo update
```

---

## `uni-exporter` — the in-cluster agent

Collects Kubernetes metrics, usage percentiles and pod-lifecycle events and ships
them to MetrixForge for FinOps, rightsizing and reliability analytics. Runs as a
single **leader-elected** Deployment and is **read-only by default**.

Chart source & every option: **[`charts/uni-exporter/values.yaml`](charts/uni-exporter/values.yaml)**.

### Install (read-only)

Get your `APP_ID` / `APP_SECRET` from the dashboard (**Settings → Connect cluster**):

```bash
helm install uni-exporter metrixforge/uni-exporter \
  --namespace metrixforge --create-namespace \
  --set-string credentials.appId=<APP_ID> \
  --set-string credentials.appSecret=<APP_SECRET>
```

### Copilot mode (apply rightsizing from the dashboard)

Adds a **patch-only** ClusterRole (Deployments / StatefulSets / DaemonSets +
`pods/resize` + Karpenter NodePools). Opt-in and instantly revocable:

```bash
helm upgrade uni-exporter metrixforge/uni-exporter -n metrixforge --reuse-values \
  --set actuator.enabled=true
# revoke:  helm upgrade ... --reuse-values --set actuator.enabled=false
```

### GitOps / pre-created Secret (keep the secret off the CLI)

```bash
kubectl -n metrixforge create secret generic uni-exporter-secrets \
  --from-literal=APP_ID=<APP_ID> --from-literal=APP_SECRET=<APP_SECRET>

helm install uni-exporter metrixforge/uni-exporter \
  --namespace metrixforge --create-namespace \
  --set credentials.create=false \
  --set credentials.existingSecret=uni-exporter-secrets
```

### Pin the agent to specific nodes

```bash
helm install uni-exporter metrixforge/uni-exporter \
  --namespace metrixforge --create-namespace \
  --set-string credentials.appId=<id> --set-string credentials.appSecret=<secret> \
  --set nodeSelector.workload-type=system \
  --set 'tolerations[0].key=dedicated,tolerations[0].operator=Equal,tolerations[0].value=monitoring,tolerations[0].effect=NoSchedule'
```

For anything non-trivial, use a values file: `helm install ... -f my-values.yaml`.

### Key values

| Key | Default | What |
| --- | --- | --- |
| `credentials.appId` / `.appSecret` | `""` | per-cluster credentials (required unless `existingSecret`) |
| `credentials.create` / `.existingSecret` | `true` / `""` | create the Secret, or reference a pre-created one |
| `actuator.enabled` | `false` | Copilot write mode (patch-only RBAC + apply loop) |
| `lifecycle.enabled` | `true` | pod-lifecycle informer (reliability recs / alerts / scaling-activity) |
| `leaderElection.enabled` | `true` | k8s Lease singleton guard (safe with >1 replica) |
| `nodeSelector` / `tolerations` / `affinity` | `{}` / `[]` / `{}` | scheduling |
| `priorityClassName` | `""` | pod PriorityClass |
| `resources` | 100m/128Mi → 500m/512Mi | requests / limits |
| `image.repository` / `.tag` | `felexa/uni-exporter` / `.Chart.appVersion` | agent image |
| `rbac.create` / `serviceAccount.create` | `true` | create RBAC / ServiceAccount |
| `serviceAccount.annotations` | `{}` | e.g. IRSA `eks.amazonaws.com/role-arn` |
| `extraArgs` / `extraEnv` | `[]` | escape hatches |

Full reference (with comments): [`charts/uni-exporter/values.yaml`](charts/uni-exporter/values.yaml).

### Upgrade / uninstall

```bash
helm repo update && helm upgrade uni-exporter metrixforge/uni-exporter -n metrixforge --reuse-values
helm uninstall uni-exporter -n metrixforge
```
