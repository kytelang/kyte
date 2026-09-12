# 25. Continuous deployment with GitHub Actions

Chapter 23 deployed an app to Kynator by hand: build the binary, upload it to `artifactd`, bind a version,
write the workload manifest, and let `kynatord` reconcile the replicas. This chapter automates exactly that
loop so it runs on a GitHub event you choose, for example when a pull request merges to `main` or when you
push a release tag. There is no SSH, no container registry, and no database in the loop. The runner talks
to your orchestrator's `artifactd` over HTTP and the four steps from Chapter 23 happen for you.

The tool is a published GitHub Action, [`kytelang/kynator-deploy-action`](https://github.com/kytelang/kynator-deploy-action).
It builds your app (or takes a prebuilt binary), content-addresses it, uploads the blob, binds `app/version`
in the registry, and writes `workloads/<app>` into the config store. `kynatord` on the server then pulls the
binary by hash, verifies it, and rolls the replicas to it. This chapter shows how to wire it up, how to
choose the trigger, and how to keep the deploy secure.

## Before you start

You need the pieces from Chapter 23 already running on the server:

- **A reachable orchestrator.** `artifactd` must be reachable from the GitHub runner over HTTP(S). Note its
  base URL, for example `https://orch.example.com:8135`. If the orchestrator is on a private network, see
  "Reaching a private orchestrator" below.
- **A deploy token.** `artifactd` guards its routes with a single shared secret it reads from the
  `KYTE_ARTIFACT_TOKEN` environment variable. You choose this secret, set it on the server, and store the
  same value as a repository secret in CI. The action's README has the full
  ["Getting a deploy token"](https://github.com/kytelang/kynator-deploy-action#getting-a-deploy-token)
  steps; the short version is in the "Secrets and the deploy token" section below.
- **The `kyte` compiler on the runner**, so the action can build your app for the server's OS and
  architecture. A prior step provides it (build the toolchain, or install a prebuilt release).

## The minimal workflow

In your Kyte app repo, add `.github/workflows/deploy.yml`. This one deploys on a pushed release tag:

```yaml
name: Deploy
on:
  push:
    tags: ["v*"]              # deploy when you push a tag like v1.4.0

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Put `kyte` on PATH (build the toolchain, or install a prebuilt release).
      - uses: kytelang/setup-kyte@v1

      - uses: kytelang/kynator-deploy-action@v1
        with:
          orch-url: ${{ vars.ORCH_URL }}       # e.g. https://orch.example.com:8135
          token:    ${{ secrets.ORCH_TOKEN }}  # the deploy bearer token (a repository secret)
          app:      webapp                      # the workload name
          app-src:  src/main.ky                 # your app's entry .ky file
          target:   linux-x86_64                # the SERVER's OS/arch, not the runner's
          replicas: "3"
          port:     "8080"
```

Set `ORCH_URL` as a repository **variable** and `ORCH_TOKEN` as a repository **secret**, both under
Settings -> Secrets and variables -> Actions. On a tag push the action builds `src/main.ky` for the server,
uploads it, binds `webapp/<tag>` (the version defaults to the git ref name), writes the manifest, and
`kynatord` reconciles three replicas on port 8080.

## Choosing the trigger

The action does not care what starts it; you pick the event in the workflow's `on:` block. Common choices:

**Deploy when a pull request merges to `main`.** A merged PR is a `push` to the base branch, so trigger on
`push` to `main`. (A `pull_request` with a `closed` type would also fire when a PR is closed WITHOUT
merging, so `push` to the branch is the cleaner "merged" signal.)

```yaml
on:
  push:
    branches: [main]
```

**Deploy on a version tag** (the minimal example above), which keeps deploys tied to explicit releases:

```yaml
on:
  push:
    tags: ["v*"]
```

**Deploy when a GitHub Release is published:**

```yaml
on:
  release:
    types: [published]
```

**Deploy on demand, from the Actions tab**, optionally with inputs you pass through to the action:

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Version label to deploy"
        required: true
```

You can combine them, for example `push` to `main` for a staging app plus `workflow_dispatch` for manual
promotions. When you deploy on every merge to `main`, set an explicit, unique `version:` per run (for
example the commit SHA) because the registry bind is immutable: re-binding the same version to a different
binary is rejected. The commit SHA (`github.sha`) works well.

```yaml
      - uses: kytelang/kynator-deploy-action@v1
        with:
          orch-url: ${{ vars.ORCH_URL }}
          token:    ${{ secrets.ORCH_TOKEN }}
          app:      webapp
          app-src:  src/main.ky
          version:  ${{ github.sha }}          # immutable per commit
          target:   linux-x86_64
```

## What the action does

Every request carries `Authorization: Bearer <token>`. Against `artifactd` the action:

1. computes the binary's `sha256`, checks `GET /artifacts/<sha>/exists`, and `PUT`s the blob only if it is
   absent (verified against its hash, idempotent, so re-runs are cheap),
2. `PUT`s `apps/<app>/<version>` with body `sha256:<hex>` to bind the version in the registry (immutable),
3. `POST`s the workload manifest to the config store under `x-cfg-key: workloads/<app>`,
4. reads it back and confirms the digest.

Any non-2xx fails the step, and the token is only ever sent as a header, never printed. Chapter 24 covers
the content-addressed blob store and the pull-by-hash delivery that `kynatord` uses on the other side.

## Building for the server, or shipping a prebuilt binary

`target` is the SERVER's triple, not the runner's: the runner is `ubuntu-latest` (x86_64 Linux) but you set
`target: linux-x86_64` or `linux-aarch64` to match where `kynatord` runs. Kynator's production target is
Linux (its zero-downtime data plane hands sockets between processes with a POSIX mechanism), so deploy
targets are Linux.

If a previous job already built the binary, skip `app-src`/`target` and pass `binary:` instead; the action
deploys it as-is:

```yaml
      - uses: kytelang/kynator-deploy-action@v1
        with:
          orch-url: ${{ vars.ORCH_URL }}
          token:    ${{ secrets.ORCH_TOKEN }}
          app:      webapp
          binary:   ${{ runner.temp }}/webapp
```

## The manifest as the single source of truth

For anything beyond the basic knobs (`replicas`, `port`, `args`), commit one manifest that both runs AND
configures the app, and pass it as `spec-template`. It carries the orchestrator settings, the binary by
hash (a `sha256:__ARTIFACT__` placeholder the action fills in with the real digest), and the app's own
configuration under `config:`. `kynatord` injects each config entry into every replica as an environment
variable, so there is no second config file to manage. See the Chapter 23 manifest reference for the full
schema; a typical `deploy/workload.yaml`:

```yaml
apiVersion: kyte/v1
kind: App
metadata:
  name: webapp
workload:
  artifact: sha256:__ARTIFACT__     # the action substitutes the real digest
  restartPolicy: always
replicas:
  min: 2
  max: 6
network:
  expose: public
  portBase: 8080
  portFlag: --port
config:
  - LOG_LEVEL=info
  - DB_URL=postgresql://app@db.internal:5432/shop?sslmode=require
```

```yaml
      - uses: kytelang/kynator-deploy-action@v1
        with:
          orch-url:      ${{ vars.ORCH_URL }}
          token:         ${{ secrets.ORCH_TOKEN }}
          app:           webapp
          app-src:       src/main.ky
          spec-template: deploy/workload.yaml
```

## Secrets and the deploy token

The token is a shared secret, not something CI fetches. Generate a strong random value once, set it on the
server, and store the same string in CI:

```sh
openssl rand -hex 32
```

- On the server, set `KYTE_ARTIFACT_TOKEN=<that value>` in `artifactd`'s environment (for example in its
  systemd unit) and restart it. `artifactd` logs `auth=on` when a token is set; an empty token logs
  `auth=OFF (dev)` and accepts every request, which is for local development only, never a reachable host.
- In the app repo, store the same value as the `ORCH_TOKEN` repository **secret** (so it is masked in logs)
  and your base URL as the `ORCH_URL` repository **variable**.

Rotate the token by changing `KYTE_ARTIFACT_TOKEN` on the server and the `ORCH_TOKEN` secret together, in
one change. Treat it like an SSH deploy key: whoever holds it can ship a binary the orchestrator will
execute, so always use `https` for a publicly reachable orchestrator and scope who can read the secret.

## Reaching a private orchestrator

The runner needs a network path to `artifactd`. Pick by your topology:

| Orchestrator location | How the runner reaches it | `orch-url` |
|---|---|---|
| public / behind an HTTPS ingress | a GitHub-hosted runner pushes directly | `https://orch.example.com:8135` |
| private network / VPC | a self-hosted runner on that network | `http://10.0.0.5:8135` |
| locked-down host | a tunnel step (Tailscale / WireGuard / SSH `-L`), then push over it | `http://127.0.0.1:8135` |

The action is identical in all three; only `orch-url` and the runner's network path change.

## Rolling back

Versions are immutable, so a rollback is just deploying a version you already shipped. Re-run the deploy
with the previous `version:` (or dispatch the workflow manually with that version), and `kynatord` rolls
the replicas back to that binary. For operational recovery of the orchestrator itself (leader loss,
store outage), see Kynator's runbooks.

## A complete example: deploy on merge to main

```yaml
name: Deploy
on:
  push:
    branches: [main]
  workflow_dispatch: {}          # allow manual promotions too

jobs:
  deploy:
    runs-on: ubuntu-latest
    concurrency: deploy-webapp    # never let two deploys race
    steps:
      - uses: actions/checkout@v4
      - uses: kytelang/setup-kyte@v1
      - uses: kytelang/kynator-deploy-action@v1
        with:
          orch-url:      ${{ vars.ORCH_URL }}
          token:         ${{ secrets.ORCH_TOKEN }}
          app:           webapp
          app-src:       src/main.ky
          version:       ${{ github.sha }}
          target:        linux-x86_64
          spec-template: deploy/workload.yaml
```

Push to `main` (or merge a PR into it) and the app is built, uploaded, and rolled out, with the deploy's
`sha` and the config-store revision available as the action's `sha` and `revision` outputs for later steps
(a notification, a smoke test, a status check).

## Where to go next

- Chapter 23 for the orchestrator itself: the binaries, the manifest schema, and the config store this
  action writes to.
- Chapter 24 for artifact delivery: `artifactd`, the content-addressed blob store, and pull-by-hash.
- The [`kynator-deploy-action` README](https://github.com/kytelang/kynator-deploy-action) for the full
  input reference, the token guide, and the release process for the action itself.
