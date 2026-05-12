# dev-ai Current Runbook

Last updated: 2026-05-12

## Overview

This VM is an Ubuntu Server AI coding host managed declaratively with Nix System Manager.
The active local coding stack is:

- `ollama` in Docker with GPU access on `127.0.0.1:11434`
- `opencode` installed system-wide for terminal use
- `opencode web` exposed as a systemd service on port `4090`
- `aider` and `goose` installed for alternate agent workflows

The old OpenHands-based browser path is no longer part of the active design and has been removed from the declarative config.

## Current Access

### Browser and app access

- URL: `http://192.168.1.37:4090`
- Secondary URL: `http://10.1.18.128:4090`
- Username: `opencode`
- Password source: `/etc/default/opencode-web`
- Service name: `opencode-web.service`

### Local model endpoints

- Ollama base URL: `http://127.0.0.1:11434`
- `OLLAMA_HOST` and `OLLAMA_API_BASE` are exported by `/etc/profile.d/ai-dev-vm.sh`

## Current Model Configuration

The active `opencode.json` defaults are:

- Primary model: `ollama/qwen3-coder:30b`
- Small model: `ollama/qwen2.5-coder:3b`

Installed local models currently include:

- `qwen3-coder:30b`
- `qwen3-coder-openhands:30b`
- `deepseek-coder:33b`
- `devstral:latest`
- `qwen2.5-coder:3b`

## Operational Commands

### Re-apply the declarative config

```bash
cd /mnt/truenas/Personal/dev-ai
nix run github:numtide/system-manager -- switch --flake . --sudo
```

### Start and stop Ollama

```bash
ai-vm-up
ai-vm-down
```

### Pull another model

```bash
ai-vm-pull-model devstral
ai-vm-pull-model qwen3-coder:30b
```

### Rotate the opencode web password

```bash
ai-vm-set-opencode-password
```

To set an explicit password:

```bash
ai-vm-set-opencode-password 'your-password-here'
```

### Check the browser service

```bash
systemctl status opencode-web.service
curl -I http://127.0.0.1:4090
```

A healthy protected response is `401 Unauthorized` when no credentials are sent.

## Repo Files That Matter

- `flake.nix`: system-manager flake entrypoint
- `system.nix`: declarative VM configuration
- `opencode.json`: active opencode provider and model defaults

## Completed Milestones

- Browser access to `opencode` is live through a persistent systemd service.
- Basic auth is enabled for the browser endpoint.
- The declarative config now matches the current browser-first opencode setup.
- OpenHands has been removed from the active declarative path.
- The default opencode model has been promoted from `qwen2.5-coder:3b` to `qwen3-coder:30b`.

## Next Steps

1. Test real coding sessions in both terminal `opencode` and browser `opencode web` against `qwen3-coder:30b`.
2. Decide whether `devstral` should replace the small-model fallback for faster planning tasks.
3. Add project-specific flakes in the repositories that will be edited from this VM.
