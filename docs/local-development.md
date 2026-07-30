# Local development

A minikube-based environment for exercising the controller and the full
AgentRun / AgentPlaybookRun flow against a real LLM.

## Quick start

```bash
make dev-doctor                    # preflight: tools, driver, arch, runtime
make dev-up                        # cluster + Agent Sandbox + images + controller
eval "$(make dev-kubeconfig)"      # point your shell at it

export ANTHROPIC_API_KEY=sk-ant-...
make dev-apply                     # create the dev CRs

make dev-status                    # what's running
make dev-shell                     # shell into the agent pod
make dev-probe                     # can agents stage and execute scripts here?
make dev-down                      # delete the cluster
```

No key handy? `make dev-apply DEV_APPLY_ARGS=--emulator` wires up the bundled
mock LLM server instead.

## Why minikube and not kind

The repo's e2e suite (`make e2e`) runs on kind and stays that way — it is the CI
regression path and is untouched by any of this.

But kind is **containerd-only**: *"kind only supports containerd, with
experimental support for podman"*, where podman is the host driver, not the
in-node CRI. **OpenShift runs CRI-O**, and the two runtimes treat image-volume
mounts differently — CRI-O passes `ro,noexec,nosuid,nodev` when mounting the
image store, containerd's path does not. A result measured only on containerd
would not transfer to the product target.

minikube's `--container-runtime` accepts `docker`, `cri-o`, and `containerd`, so
this environment defaults to `cri-o`. Override with
`make dev-up CONTAINER_RUNTIME=containerd` to compare.

`docker` is not a useful choice here: cri-dockerd does not implement ImageVolume
at all, so skills cannot mount.

## Your kubectl context is safe

Every script exports a repo-local `KUBECONFIG`
(`.dev/<profile>.kubeconfig`) *before* starting minikube, so nothing here reads
or writes your current context. `make dev-apply` cannot create Agents on
whatever cluster you happened to be pointed at.

To use plain `kubectl` against the dev cluster: `eval "$(make dev-kubeconfig)"`.

## The probe

`make dev-probe` answers one question: **can an agent write a script to a
writable directory in its pod and execute it?**

That is the question that matters, because agents do not execute scripts from
the read-only skill mount — they emit the script from `SKILL.md` text (or copy
it off the mount) into a writable directory and run it from there. `noexec`
blocks `execve()`; it never blocks reads, so reading from the skill mount always
works.

It probes `/tmp`, `/workspace`, `$HOME` and `/workspace/.konveyor`, twice: once
in a standalone pod that needs no CRDs or controller, and once in the real
controller-created Sandbox. **If the two disagree, that is itself a finding** —
it means the controller's mount construction differs from a hand-written pod.

Verdicts:

| Verdict | Meaning |
|---|---|
| `OK_USE_<dir>` | That directory is writable, executable, and outside the git worktree. Use it. |
| `OK_BUT_COMMIT_RISK` | The only exec-capable directories are inside the git worktree. Staging there risks committing scripts to the user's branch. |
| `BLOCKED_NO_EXEC_SURFACE` | Nothing writable is executable. **This is the only outcome that invalidates the current approach.** |

Raw per-check output lands in `.dev/results/`.

### Reading the output

`stage_<dir>_noexec` is taken from field 6 of the covering line in
`/proc/self/mountinfo`. `MS_NOEXEC` is a per-mount flag and lives there — not in
the filesystem's super options after the `-` separator. Reading the wrong field
is the easiest way to get this question wrong.

`stage_<dir>_exec` vs `stage_<dir>_interp` is the load-bearing distinction. Under
`noexec`, `execve` fails but `sh <file>` still succeeds, because the interpreter
only reads the file. If you see `exec=denied` with `interp=ok`, scripts still
work — compiled binaries do not (`binexec=denied`).

The skill-mount rows (`skill_*`) are informational. They record whether skills
*could* ship executable payloads, which is not currently how anything works.

## Staging convention

**Agents should stage scripts in `/tmp`, not `/workspace`.**

`/workspace` is the git worktree. The harness commits and force-pushes it, and
the filesystem watcher in PR #53 auto-commits during a run — so a script staged
there can end up on the user's branch. `/tmp` is writable, executable, and
outside the worktree.

This needs saying explicitly in `SKILL.md` authoring guidance, because a model's
untrained instinct is `chmod +x ./foo.sh && ./foo.sh` in the current directory,
which is `/workspace`.

For payloads too large to inline in `SKILL.md`, ship the file in the skill and
copy it out — reading from the mount always works regardless of `noexec`:

```sh
cp /opt/skills/<name>/helper.sh /tmp/ && chmod +x /tmp/helper.sh && /tmp/helper.sh
```

## Gotchas

**A bad API key still goes Ready.** The LLMProvider verification Job checks
*reachability*, not credential validity: it sends `Authorization: Bearer` while
Anthropic expects `x-api-key`, so a wrong key returns 401 — which matches the
controller's `^[2-4]` test and passes. A bad key surfaces only when an agent
actually talks to the model.

**The stub agent sleeps by default.** `images/agentic-controller-agent` ends in
`exec sleep infinity`, which keeps the pod inspectable but means the AgentRun
never reaches `Succeeded` — so an AgentPlaybookRun would hang on stage 1 forever.
Set `KONVEYOR_STUB_MODE=exit` to make it exit 0 instead; the playbook fixture
does this. (Related: issue #51, where a *failing* stage crashloops rather than
failing the run.)

**Playbook params are forwarded wholesale.** Every stage's Agent must declare
every param used by any stage, or that stage's AgentRun fails validation. Issue
#52.

**ImageVolume is a feature gate**, beta and default-on from k8s 1.33. If it is
off, the API server prunes the `image` field and pod creation fails with
`must specify a volume type`, which reads like a malformed manifest.
`make dev-doctor` reports the gate state from kubelet metrics. Runtime support
also matters: CRI-O ≥ 1.31, containerd ≥ 2.0.

**Architecture mismatch.** A `FROM scratch` skill image still declares os/arch.
Building arm64 images for an amd64 node gives `exec format error` with no obvious
cause. `make dev-doctor` compares host arch to node arch.

**Image loading on cri-o** is the flakiest step. If images do not appear in
`minikube ssh -- sudo crictl images`, retry with
`make dev-load MINIKUBE_LOAD_MODE=ssh`.

## Digging deeper

The in-pod probe can *eliminate* SELinux but never *confirm* it — an AVC denial
returns `EACCES`, byte-identical to `noexec` and to a missing `+x` bit. To
confirm, you need node-side access:

```bash
# what options the CRI actually handed runc
crictl inspect $(crictl ps --name agent -q) \
  | jq -r '.info.runtimeSpec.mounts[] | select(.destination|startswith("/opt/skills"))'

# SELinux denials
ausearch -m AVC,USER_AVC -ts recent | grep -i skills
```

On OpenShift both are reachable via `oc debug node/<name> -- chroot /host ...`.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `CONTAINER_RUNTIME` | `cri-o` | `cri-o`, `containerd`. Not `docker` — no ImageVolume. |
| `MINIKUBE_PROFILE` | `agentic-dev` | Change to run several side by side. |
| `MINIKUBE_DRIVER` | `$(CONTAINER_TOOL)` | podman or docker; `vfkit`/`qemu2`/`kvm2` for a real VM. |
| `MINIKUBE_K8S_VERSION` | `v1.34.0` | |
| `MINIKUBE_FEATURE_GATES` | `ImageVolume=true` | Set empty once the gate is GA'd and removed. |
| `MINIKUBE_LOAD_MODE` | `archive` | `ssh` drives the node's own image tooling directly. |
| `ANTHROPIC_API_KEY` | — | Read by `make dev-apply`; never written to a file. |
| `DEV_APPLY_ARGS` | — | `--emulator` for the keyless mock LLM. |
| `AGENT_RUN` | `dev-run` | Which run `dev-shell` / `dev-agent-logs` target. |

Changing the runtime, k8s version, gates, or driver on an existing profile is
refused rather than silently reusing the old cluster — `make dev-down` first.
