# uni-exporter

The MetrixForge in-cluster agent. Collects Kubernetes metrics, percentiles and
pod-lifecycle events and exports them for FinOps, rightsizing and reliability
analytics.

```bash
helm repo add metrixforge https://metrixforge.github.io/helm-charts
helm install metrixforge metrixforge/uni-exporter \
  --namespace monitoring --create-namespace \
  --set-string credentials.appId=<APP_ID> \
  --set-string credentials.appSecret=<APP_SECRET>
```

Both credentials come from the MetrixForge dashboard when you connect a cluster.

Everything below is **off by default**. Each capability ships dormant in the
agent image and is turned on with a single `helm upgrade --set`, which also
grants exactly the RBAC that capability needs — so what the agent is allowed to
do always matches what you have switched on.

---

## Read-only (the default)

Out of the box the agent has read access only. It cannot change anything in your
cluster.

## Copilot / actuator — `actuator.enabled=true`

Lets you apply a recommendation from the dashboard: the agent patches workload
resources, Karpenter NodePools, or an HPA target.

Grants `patch` on Deployments/StatefulSets/DaemonSets, `patch` on `pods/resize`
(KEP-1287 in-place resize, no restart), `patch,delete` on Karpenter NodePools,
and `get,patch` on HorizontalPodAutoscalers. Deliberately **no** create/update of
arbitrary resources. Revoke instantly with `--set actuator.enabled=false`.

```yaml
actuator:
  enabled: true
  pollInterval: 10    # floor between polls, not a fixed cadence
  hourlyLimit: 20     # blast-radius cap: max applies per hour
  longPollWait: 25    # hold the poll open so a click is picked up in <1s
```

`longPollWait` asks the backend to hold the request until an action arrives
rather than polling on a timer. It cuts pickup latency for a clicked action from
10-60s to under a second and *lowers* request volume (~2/min instead of ~6/min).
Set it to `0` to go back to plain interval polling.

## GitOps PR-writeback — `gitops.writeback.enabled=true`

**The problem it solves.** On a Flux or Argo cluster the live object is a
projection of your git repository. If MetrixForge patches a NodePool directly,
your next reconcile reverts it — the change never sticks and the recommendation
keeps coming back.

**What it does instead.** Applying such a recommendation opens a pull/merge
request against your source repository. You review and merge; GitOps rolls it
out normally. No drift, no out-of-band change.

```bash
kubectl -n monitoring create secret generic mf-gitops-token --from-literal=token=<TOKEN>

helm upgrade metrixforge metrixforge/uni-exporter \
  --reuse-values \
  --set gitops.writeback.enabled=true \
  --set-string gitops.writeback.tokenSecretRef=mf-gitops-token
```

### The token

Create it in your git provider and put it in a Secret **in the agent's
namespace**. It never leaves your cluster and is never stored by MetrixForge.
The agent reads it fresh on each PR, so rotating the Secret takes effect without
restarting anything.

| Provider | Minimum scopes |
|---|---|
| GitHub (incl. Enterprise) | `contents: write`, `pull_requests: write` |
| GitLab (incl. self-hosted) | `write_repository`, plus API access for the MR |

Accepted Secret keys, in order: `token`, `password`, `GIT_TOKEN`, `git-token`,
`value`.

The chart grants `get` on **that one Secret by name** — not `list`, not `watch`.
Those two verbs ignore `resourceNames` and would widen the grant to every Secret
in the namespace, including the credentials your own Flux `GitRepository` uses.

### What it can read

Read-only access to Flux `Kustomizations`, `GitRepositories`/`OCIRepositories`/
`Buckets` and `HelmReleases`, and Argo `Applications`/`ApplicationSets`. That
grant is the feature's *entire* standing cost: repo discovery happens on demand
at the moment you click, reading these objects in memory. There is no metric for
your repository URL and nothing about it is transmitted continuously.

> ⚠️ **Disclosure:** listing Argo `Applications` is unavoidable — with
> apps-in-any-namespace the Application's namespace cannot be derived from the
> managed object. This means the agent can see your full application inventory,
> including every `repoURL`, while resolving. If that is not acceptable, leave
> writeback off.

### Patch-site detection — `gitops.writeback.llm`

A field rendered by Helm or Kustomize does not appear literally in the manifest;
the real value lives in a `values.yaml` or an overlay. When that happens the
agent sends the candidate files to MetrixForge so a model can locate the exact
line, and applies the returned one-line edit.

The output is a pull request **you review before merging**, so a wrong edit is a
rejected PR, never a broken cluster.

> ⚠️ **Disclosure:** in this mode configuration files (not Secrets) leave your
> cluster. Set `gitops.writeback.llm=false` to disable it — the agent then edits
> plain YAML only and openly refuses templated manifests instead of guessing.

The deterministic plain-YAML editor is always tried first, regardless of this
setting; the model is consulted only when the value genuinely is not a literal.

### When it declines

Some layouts cannot be resolved to a single file, and the agent says so plainly
rather than opening a PR against a guess:

| Reason | Meaning |
|---|---|
| `non_git_source` | Flux OCIRepository/Bucket, or an Argo Helm-chart/plugin source — no git manifest exists |
| `var_substitution` | The manifest uses `${VAR}` via `postBuild.substituteFrom`; the value is in a ConfigMap |
| `helm_rendered` | Rendered by a HelmRelease from a chart repo — the value lives in a neighbouring values file |
| `multi_source` | An Argo multi-source Application — which source renders the object is not derivable |
| `applicationset_generated` | The Application comes from an ApplicationSet; change the AppSet template instead |
| `unresolved_file` | The directory resolved, but no file in it declares this object |
| `ambiguous_file` | Several files declare it — the refusal lists them so you can pick |

If your cluster tracks an immutable ref (a tag, semver range or commit), the PR
targets your default branch and says so in its body: you will also need to move
the ref for the change to reach the cluster.

## Other switches

```yaml
leaderElection:
  enabled: true      # keep on — prevents double-counting if >1 replica ever runs
lifecycle:
  enabled: true      # pod-lifecycle events (restarts, evictions, rollouts)
rbac:
  create: true
```

`nodeSelector`, `tolerations`, `affinity`, `resources` and `serviceAccount`
behave as usual — see `values.yaml`.
