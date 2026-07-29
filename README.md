# okteto-kit

An [Okteto](https://www.okteto.com) kit for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/). It gives the agent inside a sandbox a real, production-like environment on your own infrastructure to build, test, and verify against.

## Why

Docker Sandboxes solves the safety problem. Your coding agent runs in an isolated microVM with its own Docker daemon, filesystem, and network, so it cannot touch your host, your credentials, or your cluster.

That leaves the correctness problem. A sandboxed agent is safe but blind. There is no database, no message queue, no upstream API, no auth service, nothing to run against. So it writes code that looks right and cannot be verified. You find out at review time, or in CI, or in production.

Okteto's framing for this is direct: high quality code requires realistic environments. This kit is the bridge. It installs the Okteto CLI into the sandbox and wires up authentication to your Okteto instance, so the agent can create its own isolated, production-like environment on your infrastructure, deploy the app into it, run the tests, hit real endpoints, and read real logs. Real configs, real services, real data, full isolation.

The agent stays sandboxed. Its environment does not.

## What this is

A `kind: mixin` kit. It layers onto whatever agent you already run (`claude`, `codex`, `cursor`, and so on) rather than defining a new one. On sandbox creation it:

1. Installs the Okteto CLI into `/usr/local/bin/okteto`.
2. Declares the network egress the CLI needs (your Okteto instance plus Okteto's download hosts).
3. Wires your Okteto API token through the sandbox proxy, so the CLI can authenticate without the token ever entering the sandbox.
4. Drops Okteto agent skills into the workspace, so the agent knows how to drive Okteto correctly.

## Prerequisites

### The `sbx` CLI

On macOS:

```bash
brew trust docker/tap
brew install docker/tap/sbx
sbx login
```

Requires macOS 14 (Sonoma) or later on Apple silicon. Docker Desktop is not required. For Linux and Windows, see [Get started with Docker Sandboxes](https://docs.docker.com/ai/sandboxes/get-started/).

### An Okteto instance

Your own Okteto installation, reachable over HTTPS. This kit points at Okteto's demo instance out of the box, so you have to change it (see [Required modifications](#required-modifications)).

### An Okteto API token

Create a Personal Access Token in the **Okteto Dashboard**: click the **Settings** icon in the left navigation bar, click **New Token**, name it, pick an expiration, and click **Generate**. Copy the value immediately, it is not shown again. Full steps: [Personal Access Tokens](https://www.okteto.com/docs/core/credentials/personal-access-tokens/).

For shared automation, an Admin Access Token works the same way and is created the same way. A Personal Access Token is the right choice for a single developer's sandbox.

## Required modifications

The kit ships pointing at `demo.okteto.dev`. You must replace that with your own Okteto host in **four** places in `spec.yaml`. Missing any one of them produces a confusing failure rather than a clear error.

Using `okteto.example.com` as the example host:

**1 and 2. `caps.network.allow`**, both the apex and the wildcard entry:

```yaml
caps:
 network:
   allow:
    - okteto.example.com        # was demo.okteto.dev
    - "*.okteto.example.com"    # was "*.demo.okteto.dev"
    - downloads.okteto.com      # leave as-is
```

`downloads.okteto.com` is where the install step fetches the CLI binary and its checksum. Leave it alone.

**3. `network.serviceDomains`**, the map key:

```yaml
network:
  serviceDomains:
    okteto.example.com: okteto   # was demo.okteto.dev: okteto
```

Change the key only. The value `okteto` is the service identifier that `network.serviceAuth` refers to, and it stays as-is.

**4. `environment.variables.OKTETO_CONTEXT`**:

```yaml
environment:
  variables:
    OKTETO_CONTEXT: https://okteto.example.com   # was https://demo.okteto.dev
```

`OKTETO_CONTEXT` is the Okteto URL the CLI targets. It is not a secret, and it has to agree with the allow-list, so it is declared inline. See [Okteto environment variables](https://www.okteto.com/docs/core/credentials/environment-variables/).

### Two rules that are easy to get wrong

**The wildcard does not cover the apex.** In `sbx` domain patterns, `*` matches exactly one label and `**` matches any number. So `*.okteto.example.com` matches `dev.okteto.example.com` but does **not** match `okteto.example.com`. Both entries are required: the apex for the Okteto API, the wildcard for the per-namespace endpoint URLs your environments get. Drop the apex and every CLI call fails on egress. Drop the wildcard and the CLI works but your app's endpoints are unreachable.

**`serviceDomains` takes the apex only, never a wildcard.** A wildcard key there pushes the proxy into TLS-intercepting mode for every matching host, which corrupts downloads through those hosts. List only the host that actually needs auth injection. This is documented in the [Docker `amp` kit's README](https://github.com/docker/sbx-kits-contrib/blob/main/amp/README.md).

The same applies to the `--host` value in the next section: apex only, and it must match the `serviceDomains` key exactly.

## Create the required secret

The kit declares *where* the token goes, never *what* it is. The token lives in the `sbx` host secret store. Inside the sandbox, `OKTETO_TOKEN` is set to a harmless placeholder. When the sandbox makes an outbound request to your Okteto host, the proxy swaps in the real value.

```bash
sbx secret set-custom -g \
    --host okteto.example.com \
    --env OKTETO_TOKEN \
    --placeholder "okteto-{rand}" \
    --value "$OKTETO_TOKEN"
```

| Flag | What it does |
| --- | --- |
| `-g` | Global scope: available to every sandbox. Drop it and pass a sandbox name instead (`sbx secret set-custom my-sandbox ...`) to scope the token to one sandbox. |
| `--host` | The host whose outbound requests get the real token injected. Must match the `network.serviceDomains` key in `spec.yaml` exactly, and must be the apex only, no wildcard. |
| `--env` | The environment variable set inside the sandbox. `OKTETO_TOKEN` is the variable the Okteto CLI reads. |
| `--placeholder` | The value that variable is actually set to inside the sandbox. `{rand}` expands to a random suffix, so this becomes something like `okteto-a1b2c3d4`. |
| `--value` | The real token. It is written to the host secret store and never enters the sandbox. |

### History-safe variant

`--value` puts the token in your shell history. To avoid that, read it into a variable without echoing:

```bash
read -rs OKTETO_TOKEN
# paste the token, press Enter (nothing is displayed)

sbx secret set-custom -g \
    --host okteto.example.com \
    --env OKTETO_TOKEN \
    --placeholder "okteto-{rand}" \
    --value "$OKTETO_TOKEN"

unset OKTETO_TOKEN
```

### Removing the secret

```bash
sbx secret rm -g --host okteto.example.com
```

Both `sbx secret set-custom` and the `--host` flag on `sbx secret rm` are experimental and may not show up in `sbx secret --help`. They work today but the interface may change. The CLI reference also documents removal by placeholder value (`sbx secret rm -g --placeholder <value>`) if `--host` stops working for you.

### How the substitution works

Inside the sandbox, `$OKTETO_TOKEN` holds the placeholder, not the real token. The proxy substitutes the real value on requests to the host you configured, and `network.serviceAuth` tells it which header to write (`Authorization: Bearer <token>`).

So this:

```console
$ echo $OKTETO_TOKEN
okteto-a1b2c3d4
```

is correct and expected, not a bug. The token is not in the sandbox, and an agent that leaks `$OKTETO_TOKEN` into a log, a commit, or a prompt leaks a useless string.

## Usage

From your project directory, with a local clone of this repo:

```bash
sbx run claude --name my-sandbox --kit ./okteto-kit
```

Or pull the kit straight from GitHub:

```bash
sbx run claude --name my-sandbox \
    --kit "git+https://github.com/rberrelleza/okteto-kit.git"
```

Swap `claude` for whichever agent you use. `--kit` is repeatable, so this composes with other kits, and it is currently an experimental flag.

The first run installs the Okteto CLI and applies the network and proxy wiring, so it takes noticeably longer than later runs. Re-attaching to an existing sandbox by name reuses the installed CLI:

```bash
sbx run --name my-sandbox
```

## Verifying it works

Inside the sandbox:

```bash
echo $OKTETO_TOKEN     # expect okteto-<random>, not your real token
okteto version
okteto context use https://okteto.example.com
```

If `okteto context use` succeeds, the CLI reached your instance and the proxy injected a valid token. From there the agent can run `okteto deploy`, `okteto test`, `okteto exec`, and the rest against a real environment.

## Testing

`test/e2e.sh` is a manual end-to-end test. It creates a real sandbox with the kit applied, then verifies from inside it that the CLI installed for the right architecture and that the proxy actually substitutes your token. There is no CI for this yet, it is run by hand.

```bash
test/e2e.sh                 # or: test/e2e.sh my-sandbox-name
```

It reads the host from `OKTETO_CONTEXT` in `spec.yaml`, so it follows whatever instance the kit points at. You do not edit the test after changing the domain.

Seven steps, ordered so a failure localizes itself:

1. Environment: `sbx` version, kit commit, host architecture, resolved instance
2. Confirms a custom secret is registered for your host
3. Removes any previous sandbox of the same name
4. Creates the sandbox with `--kit`, running the real install command
5. Inside the sandbox: architecture, `$OKTETO_CONTEXT`, and that `$OKTETO_TOKEN` is a placeholder rather than empty, the `proxy-managed` sentinel, or a leaked real token
6. `okteto context use`, the actual proxy-substitution test, then `okteto namespace list` to prove the token authenticated rather than merely completing a handshake
7. `sbx policy log`, which should show your Okteto host as `forward` (intercepted, so the `Authorization` header can be injected) and `downloads.okteto.com` as `forward-bypass`

Output is also written to `test/e2e.log`. Clean up afterwards with `sbx rm -f okteto-e2e`.

### Run it from a GUI session on macOS

The `sbx` CLI reads the Docker Hub token and custom secrets from the macOS login keychain itself. A process in an SSH or background session cannot prompt for keychain access, so any command that touches credentials fails with:

```
ERROR: list custom secrets: cannot prompt the user for password
```

Run the test from the physical console or a screen-sharing session. This is a macOS session-isolation constraint, not something the kit or `sbx` configuration can change: Docker's `credsStore` setting only redirects the Docker CLI, not `sbx`.

## What the kit installs

**Okteto CLI 3.21.0**, pinned in `spec.yaml`. Bump `OKTETO_VERSION` in the install command to upgrade. The install step detects the sandbox architecture (`x86_64` and `aarch64`/`arm64`, mapped to Okteto's `x86_64` and `arm64` asset names), downloads the matching Linux binary from `downloads.okteto.com`, and verifies it against the published `.sha256` before installing. An unsupported architecture fails loudly instead of installing nothing.

**Okteto agent skills**, shipped under `files/workspace/.claude/skills/` and `files/workspace/.agents/skills/` (identical trees, one per convention) so they land in the sandbox workspace where the agent will find them:

| Skill | Covers |
| --- | --- |
| `okteto` | Core CLI knowledge and workflow patterns. Read `okteto.yaml` first, never run interactive `okteto up`, mutate the cluster only through `okteto build`/`okteto deploy`, one worktree per namespace, never destroy without authorization. |
| `okteto-onboarding` | Projects with no `okteto.yaml` yet. Authoring a manifest and getting a repo onto Okteto. |
| `okteto-preview` | Preview Environments. Deploying a live, shareable environment for a branch or pull request, and authoring the CI automation that owns them per-PR. |
| `okteto-debugging` | Triage for broken environments. `CrashLoopBackOff`, `OOMKilled`, `ImagePullBackOff`, pods stuck pending, file sync problems. Read-only diagnostics, fixes through Okteto. |

These are the same skills Okteto ships in its [Claude Code plugin](https://github.com/okteto/okteto-claude-plugins), packaged for a sandbox instead of a local install.

## Okteto is free for up to five users

Self-hosted Okteto is free for up to five users, with no license key required. Sign up at [okteto.com/signup](https://www.okteto.com/signup). Larger teams can start with a free trial from the same page, and [okteto.com/pricing](https://www.okteto.com/pricing) has the tier breakdown.

## Troubleshooting

**`$OKTETO_TOKEN` is empty inside the sandbox.**
Either the secret was never registered, or `--value` expanded to an empty string. The second one is the common mistake: if `$OKTETO_TOKEN` was not set on your host when you ran `sbx secret set-custom --value "$OKTETO_TOKEN"`, you stored an empty secret and the command still succeeded. Check with `sbx secret ls`, then re-register using the `read -rs` variant above. Note that `--env` and `--host` are matched at sandbox creation, so re-register the secret and then create a fresh sandbox.

**The token is rejected as invalid, or the CLI gets a 401.**
A host mismatch. Injection is matched by host, so these three must be the same host, and it must be the apex with no wildcard:

- `--host` in `sbx secret set-custom`
- the `network.serviceDomains` key in `spec.yaml`
- the host in `environment.variables.OKTETO_CONTEXT`

If they disagree, the request goes out carrying the placeholder and Okteto correctly rejects it. Also confirm the token itself has not expired (Personal Access Tokens default to 180 days) and that you copied it whole.

**Network errors reaching the Okteto instance.**
Connection refused, DNS failure, or a proxy denial means the host is not on the allow list. `caps.network.allow` is deny-by-default. Check that you added **both** the apex and the wildcard, because `*.okteto.example.com` does not match `okteto.example.com`. Symptom split: apex missing breaks `okteto` commands themselves, wildcard missing breaks reaching your deployed app's endpoints. `sbx policy ls` shows the active rules.

**The CLI install fails during sandbox creation.**
The install step needs `downloads.okteto.com` reachable. If you replaced every entry in `caps.network.allow` instead of just the first two, put `downloads.okteto.com` back.

**Downloads through your Okteto host are corrupted or truncated.**
You put a wildcard in `network.serviceDomains`. Use the apex only. See [Two rules that are easy to get wrong](#two-rules-that-are-easy-to-get-wrong).

## Reference

- [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) and [Kits](https://docs.docker.com/ai/sandboxes/customize/kits/)
- [Kit spec reference](https://docs.docker.com/ai/sandboxes/customize/kit-reference/)
- [`sbx secret set-custom`](https://docs.docker.com/reference/cli/sbx/secret/set-custom/) and [`sbx run`](https://docs.docker.com/reference/cli/sbx/run/)
- [Okteto docs](https://www.okteto.com/docs/), [Personal Access Tokens](https://www.okteto.com/docs/core/credentials/personal-access-tokens/), [Okteto CLI reference](https://www.okteto.com/docs/reference/okteto-cli/)
