# dev-ai

Ubuntu Server AI coding VM managed with Nix System Manager.

## What this repo does

This repository defines the machine-level setup for a local AI coding host:

- Ubuntu stays the base OS.
- Nix System Manager installs and configures the developer toolchain.
- Docker runs Ollama with GPU access.
- `opencode` is available for terminal-based coding.
- `opencode web` is exposed for browser-based access.
- Qdrant provides local project-memory search.
- `ai-agent` creates isolated sidecar worktrees for review and bounded worker tasks.

The main files are:

- `flake.nix`: System Manager flake entrypoint.
- `system.nix`: declarative machine configuration.
- `opencode.json`: default OpenCode provider and model selection.
- `plan.md`: architecture and setup plan for the VM.

## Prerequisites

The VM is expected to have:

- Ubuntu Server
- Nix installed in multi-user mode
- NVIDIA driver installed and working
- Docker and NVIDIA Container Toolkit installed
- Access to `/mnt/truenas/models` for persistent Ollama model storage
- Access to `/mnt/truenas/qdrant` for persistent Qdrant storage

## Apply the configuration

From the repository root:

```bash
nix run github:numtide/system-manager -- switch --flake . --sudo
```

This applies the declarative config, writes files into `/etc`, and updates the `opencode-web.service` unit.

## Model storage

Ollama model data is stored on the host at:

```text
/mnt/truenas/models
```

Inside the container, that path is mounted as:

```text
/root/.ollama/models
```

## Terminal workflow

### 1. Start Ollama

```bash
ai-up
```

Check that the container is running:

```bash
docker ps
curl http://127.0.0.1:11434/api/tags
```

### 2. Pull models

Small or medium models:

```bash
ai-pull-model qwen2.5-coder:3b
ai-pull-model devstral
```

Larger coding models:

```bash
docker exec ollama ollama pull qwen3-coder:30b
docker exec ollama ollama pull deepseek-coder:33b
```

### 3. Run OpenCode in a repo

OpenCode should be run from the project you want to edit:

```bash
cd /path/to/your/project
opencode
```

If you want a non-interactive run:

```bash
opencode run "inspect this repository and summarize the build and test workflow"
```

### 4. Useful terminal helpers

```bash
ai-test-gpu
ai-down
systemctl status opencode-web.service
```

## Browser workflow

The browser UI is provided by `opencode web` through systemd.

### 1. Make sure the service is running

```bash
systemctl status opencode-web.service
curl -I http://127.0.0.1:3000
```

A healthy protected response is:

```text
HTTP/1.1 401 Unauthorized
```

### 2. Open it in your browser

From another machine on the same network:

```text
http://192.168.1.37:3000
```

There is also a secondary address if needed:

```text
http://10.1.18.128:3000
```

### 3. Authenticate

The UI uses the password stored in:

```text
/etc/default/opencode-web
```

Rotate it with:

```bash
ai-set-opencode-password
```

Or set an explicit password:

```bash
ai-set-opencode-password 'your-password-here'
```

### 4. Use OpenCode through the browser

Once logged in, the browser UI uses the same local Ollama endpoint configured in `opencode.json`.

Default model configuration currently points at:

- primary model: `ollama/qwen3-coder:30b`
- small model: `ollama/qwen2.5-coder:3b`


## Project memory

Qdrant runs locally on the VM and stores data under:

```text
/mnt/truenas/qdrant
```

Index a repository into Qdrant:

```bash
ai-index-project /path/to/your/project
```

Search indexed project context:

```bash
ai-search-project "opencode browser service" /path/to/your/project
```

By default, indexing uses a deterministic local hash vector so it works without any additional model. To use an Ollama embedding model, set `AI_VM_EMBED_MODEL` before indexing and searching; the current helper expects a 384-dimensional embedding vector.

Useful checks:

```bash
curl http://127.0.0.1:6333/healthz
curl http://127.0.0.1:6333/collections
```

## Sidecar agents

The main OpenCode session should own the coding loop. Use sidecar agents only for bounded review, investigation, verification, or isolated implementation tasks. The wrappers create separate git worktrees next to the target repository and write logs and orchestration state under `.ai-agent/`, which is ignored by Git.

Manual sidecar helper commands:

```bash
ai-agent status /path/to/your/project
ai-agent review /path/to/your/project
printf 'Only edit src/auth. Fix token refresh and add tests.' > /tmp/worker-prompt.txt
ai-agent worker /path/to/your/project ai/fix-token-refresh /tmp/worker-prompt.txt
```

Orchestrator commands:

```bash
ai-orchestrator prepare /path/to/your/project "auth test workflow"
ai-orchestrator review /path/to/your/project
ai-orchestrator worker /path/to/your/project ai/fix-token-refresh /tmp/worker-prompt.txt
ai-orchestrator gate /path/to/your/project
ai-orchestrator status /path/to/your/project
```

`prepare` refreshes the Qdrant index, retrieves project context, records git status, and includes `AGENTS.md` when present. `worker` and `review` prepend that retrieved context before delegating to sidecars. `gate` summarizes sidecar worktrees and recent logs so the main session can inspect work before merging or cherry-picking anything back.

## Operational checks

### Verify GPU access

```bash
nvidia-smi
ai-test-gpu
```

### Verify Ollama health

```bash
docker logs ollama --tail=100
curl http://127.0.0.1:11434/api/tags
```

### Verify Qdrant health

```bash
curl http://127.0.0.1:6333/healthz
curl http://127.0.0.1:6333/collections
```

### Verify browser service

```bash
systemctl status opencode-web.service
curl -I http://127.0.0.1:3000
```

## Notes

- `opencode web` is the browser entrypoint. OpenHands is not part of the active implementation.
- Qdrant is for project memory and retrieved notes only; source files, tests, and Git history remain authoritative.
- Large model downloads can take a long time and should be expected to continue in the background.
- If a model pull is interrupted, rerun the same `ollama pull` command; it will resume using the existing blobs in `/mnt/truenas/models`.
