Below is an **Ubuntu Server VM** build, not NixOS. The VM stays Ubuntu, and Nix is used inside it to declaratively manage the toolchain, agent CLIs, scripts, environment files, and container configuration.

One important caveat: on Ubuntu, the NVIDIA kernel driver/DKMS/initramfs layer should remain Ubuntu-managed rather than Nix-managed. Ubuntu’s own server docs recommend `ubuntu-drivers` or APT for NVIDIA drivers, with `-server` drivers recommended for servers/compute tasks, and NVIDIA’s container toolkit docs also recommend installing the GPU driver through the distribution package manager. The tutorial below still makes those steps reproducible by putting the commands in Nix-managed scripts, but it does not pretend Ubuntu kernel modules are pure Nix artifacts. ([Ubuntu][1])

## Target architecture

```text
Proxmox host
  └── Ubuntu Server VM, q35 + OVMF + NVIDIA PCIe passthrough
        ├── Ubuntu-owned kernel + NVIDIA driver
        ├── Nix + System Manager
        │     ├── agent CLIs: OpenCode, aider, Goose, Ollama CLI
        │     ├── dev tools: git, gh, uv, Node, Python, Go, Rust, etc.
        │     ├── reproducible scripts
        │     └── generated /etc/ai-dev-vm/compose.yaml
        └── Docker + NVIDIA Container Toolkit
              ├── Ollama container with GPU access
              └── optional opencode web UI service
```

The primary Claude Code replacement here is **OpenCode + Ollama** for terminal-based agentic coding. I’d also install **aider** for precise Git-based editing, **Goose** for general agent workflows/MCP-style extension work, and expose **`opencode web`** as an optional browser UI for remote access. OpenCode is an open-source terminal coding agent, aider connects to local Ollama models, Goose supports CLI/Desktop/API usage and Ollama among other providers, and `opencode web` provides the browser path while staying aligned with the same local Ollama-backed setup. ([OpenCode][2])

---

## 1. Proxmox host: verify passthrough readiness

If your GPU passthrough already works for another VM, skim this section and reuse the same host settings. Proxmox’s PCI passthrough docs note that a passed-through PCI device becomes unavailable to the host or other VMs, that IOMMU support is required, and that PCIe passthrough is available with `q35` machine type. ([GitHub][3])

On the Proxmox host:

```bash
lspci -nn | grep -Ei 'nvidia|vga|3d|audio'
dmesg | grep -e DMAR -e IOMMU -e AMD-Vi
```

Enable these in BIOS/UEFI if not already enabled:

```text
Intel: VT-d
AMD: AMD-Vi / IOMMU
Usually useful: Above 4G Decoding
Usually useful: Resizable BAR off at first, then test later
```

For older Intel kernels or systems where IOMMU is not enabled automatically, add Proxmox kernel parameters. If Proxmox uses GRUB:

```bash
nano /etc/default/grub
```

Use something like:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

Then:

```bash
update-grub
reboot
```

If your Proxmox install uses `proxmox-boot-tool`:

```bash
nano /etc/kernel/cmdline
proxmox-boot-tool refresh
reboot
```

Load VFIO modules on the Proxmox host:

```bash
cat >/etc/modules-load.d/vfio.conf <<'EOF'
vfio
vfio_iommu_type1
vfio_pci
EOF

update-initramfs -u -k all
reboot
```

After reboot:

```bash
lsmod | grep vfio
dmesg | grep -e DMAR -e IOMMU -e AMD-Vi
```

If the Proxmox host grabs the NVIDIA GPU, bind it to `vfio-pci`. First find the GPU and its HDMI/audio function IDs:

```bash
lspci -nn | grep -Ei 'nvidia|vga|3d|audio'
```

Example output shape:

```text
02:00.0 VGA compatible controller [0300]: NVIDIA ... [10de:2684]
02:00.1 Audio device [0403]: NVIDIA ... [10de:22ba]
```

Then create a VFIO binding file, replacing the IDs:

```bash
cat >/etc/modprobe.d/vfio.conf <<'EOF'
options vfio-pci ids=10de:2684,10de:22ba disable_vga=1
EOF

update-initramfs -u -k all
reboot
```

Verify:

```bash
lspci -nnk -d 10de:
```

For passthrough, the GPU function should show:

```text
Kernel driver in use: vfio-pci
```

Proxmox explicitly recommends `q35`, OVMF/UEFI, and PCIe for best GPU passthrough compatibility, and allows passing all functions of a multifunction GPU with the shortened PCI address such as `02:00`. ([GitHub][3])

---

## 2. Create the Ubuntu Server VM

Use Ubuntu Server **24.04 LTS** for the conservative path. Docker currently supports Ubuntu 24.04 LTS and 26.04 LTS, so 26.04 is also viable, but 24.04 tends to be the safer driver/container baseline. ([Docker Documentation][4])

In Proxmox GUI, create a VM with:

```text
OS: Ubuntu Server ISO
Machine: q35
BIOS: OVMF / UEFI
Secure Boot: disabled initially
CPU type: host
Disk bus: VirtIO SCSI
Network: VirtIO
QEMU Guest Agent: enabled
GPU: PCI Device, All Functions, PCI-Express
Primary GPU: off for compute-only; on only if you need display output
```

A CLI example, using placeholders:

```bash
export VMID=240
export VMNAME=ai-dev
export GPU_PCI=02:00

qm create "$VMID" \
  --name "$VMNAME" \
  --memory 32768 \
  --cores 8 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --ostype l26 \
  --agent enabled=1

qm set "$VMID" --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set "$VMID" --scsihw virtio-scsi-single
qm set "$VMID" --scsi0 local-lvm:200,iothread=1,discard=on,ssd=1
qm set "$VMID" --net0 virtio,bridge=vmbr0
qm set "$VMID" --cdrom local:iso/ubuntu-24.04-live-server-amd64.iso
qm set "$VMID" --boot order=scsi0

qm set "$VMID" --hostpci0 "$GPU_PCI",pcie=on
```

For compute-only CUDA/Ollama usage, the GPU does **not** need to be the VM’s display device. Proxmox also notes that GPU framebuffer output generally will not show through NoVNC/SPICE, so use SSH after installation. ([GitHub][3])

---

## 3. Install Ubuntu Server

During Ubuntu installation:

```text
Install OpenSSH server: yes
Install Docker snap: no
Filesystem: ext4 or LVM is fine
Username example: dev
Secure Boot: keep disabled for the first pass
```

After first boot, SSH into the VM:

```bash
ssh dev@<vm-ip>
```

Bootstrap only the bare minimum before Nix:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y qemu-guest-agent curl git ca-certificates gnupg lsb-release
sudo systemctl enable --now qemu-guest-agent
sudo reboot
```

Reconnect and check that the passed-through GPU is visible inside the VM:

```bash
lspci -nn | grep -Ei 'nvidia|vga|3d'
```

---

## 4. Install Nix on Ubuntu Server

Use a multi-user Nix install. The official Nix docs recommend multi-user installation on Linux systems with systemd and sudo, and the Determinate installer enables flakes by default, which is convenient for this setup. ([Nix.dev][5])

Default option:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Reload your shell:

```bash
exec "$SHELL" -l
```

Verify:

```bash
nix --version
nix run nixpkgs#hello
```

Official upstream alternative:

```bash
bash <(curl -L https://nixos.org/nix/install) --daemon

sudo mkdir -p /etc/nix
echo "experimental-features = nix-command flakes" | sudo tee -a /etc/nix/nix.conf

exec "$SHELL" -l
```

---

## 5. Create the Nix-managed Ubuntu system config

System Manager is the key piece here: it brings a NixOS-like declarative model to Ubuntu/Debian without switching operating systems, and its docs show using `environment.systemPackages`, `/etc` file generation, and `nix run 'github:numtide/system-manager' -- switch --sudo`. ([system-manager.net][6])

Create a repo for the VM config:

```bash
mkdir -p ~/ai-dev-vm
cd ~/ai-dev-vm
git init
```

Create `flake.nix`:

```bash
cat > flake.nix <<'EOF'
{
  description = "Ubuntu Server AI coding VM managed with Nix System Manager";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, system-manager, ... }:
    {
      systemConfigs.default = system-manager.lib.makeSystemConfig {
        modules = [
          ./system.nix
        ];
      };
    };
}
EOF
```

Create `system.nix`:

```bash
cat > system.nix <<'EOF'
{ pkgs, ... }:

let
  aiVmInstallDrivers = pkgs.writeShellApplication {
    name = "ai-vm-install-drivers";
    runtimeInputs = with pkgs; [ bash coreutils curl gnugrep gnused ];
    text = ''
      set -euo pipefail

      echo "[1/4] Installing Ubuntu NVIDIA driver helper packages..."
      /usr/bin/sudo /usr/bin/apt-get update
      /usr/bin/sudo /usr/bin/apt-get install -y --no-install-recommends \
        ubuntu-drivers-common \
        "linux-headers-$(uname -r)" \
        qemu-guest-agent

      /usr/bin/sudo /usr/bin/systemctl enable --now qemu-guest-agent

      echo "[2/4] Available server/GPGPU NVIDIA drivers:"
      /usr/bin/sudo /usr/bin/ubuntu-drivers list --gpgpu || true

      echo "[3/4] Installing NVIDIA GPGPU driver..."
      echo "      To pin a branch, run for example:"
      echo "      NVIDIA_DRIVER_SPEC=nvidia:535-server ai-vm-install-drivers"
      driver_spec="''${NVIDIA_DRIVER_SPEC:-}"

      if [ -n "$driver_spec" ]; then
        /usr/bin/sudo /usr/bin/ubuntu-drivers install --gpgpu "$driver_spec"
      else
        /usr/bin/sudo /usr/bin/ubuntu-drivers install --gpgpu
      fi

      echo "[4/4] Done. Reboot the VM, then run:"
      echo "      nvidia-smi"
    '';
  };

  aiVmInstallDockerGpu = pkgs.writeShellApplication {
    name = "ai-vm-install-docker-gpu";
    runtimeInputs = with pkgs; [ bash coreutils curl gnupg gnused ];
    text = ''
      set -euo pipefail

      echo "[1/7] Removing conflicting distro Docker packages, if present..."
      for pkg in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        /usr/bin/sudo /usr/bin/apt-get remove -y "$pkg" >/dev/null 2>&1 || true
      done

      echo "[2/7] Installing Docker apt repository..."
      /usr/bin/sudo /usr/bin/apt-get update
      /usr/bin/sudo /usr/bin/apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg

      /usr/bin/sudo /usr/bin/install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | /usr/bin/sudo /usr/bin/tee /etc/apt/keyrings/docker.asc >/dev/null
      /usr/bin/sudo /usr/bin/chmod a+r /etc/apt/keyrings/docker.asc

      . /etc/os-release
      codename="''${UBUNTU_CODENAME:-''${VERSION_CODENAME:-}}"
      arch="$(/usr/bin/dpkg --print-architecture)"

      if [ -z "$codename" ]; then
        echo "Could not determine Ubuntu codename from /etc/os-release" >&2
        exit 1
      fi

      cat <<DOCKER_SOURCES | /usr/bin/sudo /usr/bin/tee /etc/apt/sources.list.d/docker.sources >/dev/null
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_SOURCES

      echo "[3/7] Installing Docker Engine and Compose plugin..."
      /usr/bin/sudo /usr/bin/apt-get update
      /usr/bin/sudo /usr/bin/apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

      echo "[4/7] Installing NVIDIA Container Toolkit repository..."
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor \
        | /usr/bin/sudo /usr/bin/tee /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg >/dev/null

      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | /usr/bin/sudo /usr/bin/tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

      echo "[5/7] Installing NVIDIA Container Toolkit..."
      /usr/bin/sudo /usr/bin/apt-get update
      /usr/bin/sudo /usr/bin/apt-get install -y nvidia-container-toolkit

      echo "[6/7] Configuring Docker NVIDIA runtime..."
      /usr/bin/sudo /usr/bin/nvidia-ctk runtime configure --runtime=docker
      /usr/bin/sudo /usr/bin/systemctl enable --now docker
      /usr/bin/sudo /usr/bin/systemctl restart docker

      echo "[7/7] Adding current user to docker group..."
      current_user="''${SUDO_USER:-$USER}"
      /usr/bin/sudo /usr/sbin/usermod -aG docker "$current_user" || true

      echo "Done. Log out and back in for docker group membership, or use sudo for Docker."
      echo "Then run: ai-vm-test-gpu"
    '';
  };

  aiVmTestGpu = pkgs.writeShellApplication {
    name = "ai-vm-test-gpu";
    runtimeInputs = with pkgs; [ bash coreutils ];
    text = ''
      set -euo pipefail

      echo "[1/2] Testing NVIDIA driver in Ubuntu..."
      /usr/bin/nvidia-smi

      echo "[2/2] Testing NVIDIA GPU from Docker..."
      if /usr/bin/docker info >/dev/null 2>&1; then
        /usr/bin/docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 nvidia-smi
      else
        /usr/bin/sudo /usr/bin/docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 nvidia-smi
      fi
    '';
  };

  aiVmUp = pkgs.writeShellApplication {
    name = "ai-vm-up";
    runtimeInputs = with pkgs; [ bash coreutils ];
    text = ''
      set -euo pipefail

      docker_cmd() {
        if /usr/bin/docker info >/dev/null 2>&1; then
          /usr/bin/docker "$@"
        else
          /usr/bin/sudo /usr/bin/docker "$@"
        fi
      }

      docker_cmd compose -f /etc/ai-dev-vm/compose.yaml "$@" up -d
    '';
  };

  aiVmDown = pkgs.writeShellApplication {
    name = "ai-vm-down";
    runtimeInputs = with pkgs; [ bash coreutils ];
    text = ''
      set -euo pipefail

      docker_cmd() {
        if /usr/bin/docker info >/dev/null 2>&1; then
          /usr/bin/docker "$@"
        else
          /usr/bin/sudo /usr/bin/docker "$@"
        fi
      }

      docker_cmd compose -f /etc/ai-dev-vm/compose.yaml down
    '';
  };

  aiVmPullModel = pkgs.writeShellApplication {
    name = "ai-vm-pull-model";
    runtimeInputs = with pkgs; [ bash coreutils ];
    text = ''
      set -euo pipefail

      model="''${1:-devstral}"

      docker_cmd() {
        if /usr/bin/docker info >/dev/null 2>&1; then
          /usr/bin/docker "$@"
        else
          /usr/bin/sudo /usr/bin/docker "$@"
        fi
      }

      docker_cmd exec ollama ollama pull "$model"
      docker_cmd exec ollama ollama show "$model" || true
    '';
  };

in
{
  config = {
    nixpkgs.hostPlatform = "x86_64-linux";

    environment.systemPackages = [
      aiVmInstallDrivers
      aiVmInstallDockerGpu
      aiVmTestGpu
      aiVmUp
      aiVmDown
      aiVmPullModel
    ] ++ (with pkgs; [
      git
      git-lfs
      gh
      curl
      wget
      jq
      ripgrep
      fd
      bat
      eza
      fzf
      btop
      tmux
      neovim
      direnv
      nix-direnv
      just

      python312
      uv
      nodejs_22
      pnpm
      bun
      go
      rustup

      gcc
      gnumake
      cmake
      pkg-config
      openssl

      nil
      nixd
      nixfmt-rfc-style

      ollama
      opencode
      aider-chat
      goose-cli
    ]);

    environment.etc."profile.d/ai-dev-vm.sh".text = ''
      export OLLAMA_HOST="http://127.0.0.1:11434"
      export OLLAMA_API_BASE="http://127.0.0.1:11434"
    '';

    environment.etc."ai-dev-vm/compose.yaml".text = ''
      name: ai-dev-vm

      services:
        ollama:
          image: ollama/ollama:latest
          container_name: ollama
          restart: unless-stopped
          ports:
            - "127.0.0.1:11434:11434"
          volumes:
            - ollama:/root/.ollama
          environment:
            OLLAMA_CONTEXT_LENGTH: "64000"
            OLLAMA_KEEP_ALIVE: "24h"
          deploy:
            resources:
              reservations:
                devices:
                  - driver: nvidia
                    count: all
                    capabilities: [gpu]

      volumes:
        ollama:
    '';

    environment.etc."ai-dev-vm/opencode-web.env.example".text = ''
      OPENCODE_SERVER_PASSWORD=change-me
    '';

    environment.etc."systemd/system/opencode-web.service".text = ''
      [Unit]
      Description=OpenCode Web UI
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      User=dev
      Group=dev
      WorkingDirectory=/home/dev
      Environment=HOME=/home/dev
      Environment=BROWSER=/bin/true
      EnvironmentFile=-/etc/default/opencode-web
      ExecStart=/run/current-system/sw/bin/opencode web --hostname 0.0.0.0 --port 3000
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
    '';

    environment.etc."ai-dev-vm/AGENTS.example.md".text = ''
      # Agent instructions for this VM

      You are working inside an Ubuntu Server VM whose development environment is managed by Nix.

      Rules:
      - Prefer project-local Nix flakes over global installs.
      - Do not install tools globally with pip, npm, cargo, or curl scripts unless explicitly asked.
      - Before editing, inspect the repository structure.
      - After editing, run the relevant formatter, linter, type checker, and tests.
      - Prefer small commits and explain the test result.

      Useful commands:
      - nix develop
      - nix flake check
      - git status
      - git diff
      - just --list
    '';
  };
}
EOF
```

Apply it:

```bash
cd ~/ai-dev-vm
nix flake lock
nix run 'github:numtide/system-manager' -- switch --sudo
source /etc/profile.d/system-manager-path.sh
source /etc/profile.d/ai-dev-vm.sh
```

Commit the config:

```bash
git add flake.nix system.nix flake.lock
git commit -m "Initial AI dev VM system-manager config"
```

---

## 6. Install NVIDIA drivers inside the Ubuntu VM

Run the Nix-managed driver script:

```bash
ai-vm-install-drivers
```

For a pinned Ubuntu server driver branch, first inspect available branches:

```bash
sudo ubuntu-drivers list --gpgpu
```

Then run, for example:

```bash
NVIDIA_DRIVER_SPEC=nvidia:535-server ai-vm-install-drivers
```

Reboot:

```bash
sudo reboot
```

Reconnect and verify:

```bash
nvidia-smi
cat /proc/driver/nvidia/version
```

Ubuntu documents both automatic GPGPU/server driver installation and pinning a specific `nvidia:<version>-server` branch with `ubuntu-drivers install --gpgpu`. ([Ubuntu][1])

---

## 7. Install Docker + NVIDIA Container Toolkit

Run:

```bash
ai-vm-install-docker-gpu
```

Log out and back in, or keep using `sudo docker`.

Test GPU access from both Ubuntu and Docker:

```bash
ai-vm-test-gpu
```

Docker’s Ubuntu docs recommend setting up Docker’s APT repository and installing `docker-ce`, `docker-ce-cli`, `containerd.io`, Buildx, and the Compose plugin; NVIDIA documents adding the container-toolkit repository and configuring Docker with `nvidia-ctk runtime configure --runtime=docker`; Docker Compose supports GPU reservations with `driver: nvidia` and `capabilities: [gpu]`. ([Docker Documentation][4])

---

## 8. Start Ollama with GPU support

Start the Nix-generated Compose stack:

```bash
ai-vm-up
```

Check:

```bash
docker ps
docker logs ollama --tail=100
```

Pull a first model:

```bash
ai-vm-pull-model devstral
```

Run it:

```bash
docker exec -it ollama ollama run devstral
```

Ollama’s Docker docs show running the container with NVIDIA GPU support after installing NVIDIA Container Toolkit, configuring Docker, and using `--gpus=all`; the Compose file above expresses the same idea using Compose GPU reservations. ([Ollama][7])

For agentic coding, start with:

```bash
ai-vm-pull-model devstral
```

Devstral is specifically described as an agentic software-engineering model with a 128k context window and 24B parameters, light enough for local deployment on hardware such as a single RTX 4090 or a 32 GB RAM Mac. ([Ollama][8])

Other useful Ollama model choices:

```bash
ai-vm-pull-model qwen3-coder:30b
ai-vm-pull-model deepseek-coder-v2:16b
```

Use the biggest model that fits your GPU at the context size you need. Ollama’s current context docs recommend at least about 64k tokens for agents/coding tools and warn that larger context increases memory use. ([Ollama][9])

---

## 9. Use OpenCode as the Claude Code-style terminal agent

Go to a Git repo:

```bash
mkdir -p ~/src
cd ~/src
git clone <your-repo>
cd <your-repo>
```

Copy the agent instruction template:

```bash
cp /etc/ai-dev-vm/AGENTS.example.md ./AGENTS.md
git add AGENTS.md
git commit -m "Add local agent instructions"
```

Launch OpenCode through Ollama:

```bash
export OLLAMA_HOST=http://127.0.0.1:11434
ollama launch opencode
```

Ollama’s OpenCode integration documents `ollama launch opencode`, and notes that OpenCode needs a larger context window, recommending at least 64k tokens. ([Ollama][10])

Good first prompts inside OpenCode:

```text
Read AGENTS.md, inspect this repository, and summarize the build/test workflow.
```

```text
Find the smallest useful improvement in this project, implement it, and run the relevant tests.
```

```text
Add a failing regression test for the bug described below, then fix the bug.
```

For safety, do agentic work in Git branches:

```bash
git switch -c ai/first-local-agent-test
```

---

## 10. Use aider for precise Git-based edits

Aider is especially good when you want a more controlled pair-programming workflow with clear diffs.

```bash
cd ~/src/<your-repo>
export OLLAMA_API_BASE=http://127.0.0.1:11434
aider --model ollama_chat/devstral
```

Aider’s Ollama docs recommend setting `OLLAMA_API_BASE`, then using `aider --model ollama_chat/<model>`, with `ollama_chat/` preferred over `ollama/`. ([Aider][11])

Example aider prompt:

```text
Refactor the parser module to reduce duplication. Keep behavior unchanged. Add or update tests, then run them.
```

---

## 11. Use Goose for broader agent workflows

Configure Goose interactively:

```bash
goose configure
```

Pick an Ollama/local provider where available, then use:

```bash
goose session
```

Goose is a general-purpose local AI agent with CLI/Desktop/API modes, and its docs state that it works with Ollama among many providers and can connect to extensions via MCP. ([goose-docs.ai][12])

Good Goose use cases:

```text
Inspect this repository and write a migration checklist.
```

```text
Use the GitHub CLI to list open issues and group them by likely subsystem.
```

```text
Create a release checklist based on the current repo tooling.
```

---

## 12. Optional: run `opencode web`

Instead of OpenHands, expose the browser UI directly from OpenCode as a systemd service. After applying the System Manager config, enable and start it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now opencode-web.service
```

Check that the service is listening locally:

```bash
systemctl status opencode-web.service
curl -I http://127.0.0.1:3000
```

Access it safely over SSH port forwarding from your workstation:

```bash
ssh -N -L 3000:127.0.0.1:3000 dev@<vm-ip>
```

Then open your browser to:

```text
http://127.0.0.1:3000
```

If you want password protection, create `/etc/default/opencode-web` with `OPENCODE_SERVER_PASSWORD=...` before starting the service. This keeps the browser path aligned with the same local Ollama-backed OpenCode setup without introducing a separate privileged UI container.

---

## 13. Make each project reproducible with Nix

Inside each code repo, add a project flake. Example for a Python project:

```bash
cd ~/src/<your-repo>

cat > flake.nix <<'EOF'
{
  description = "Project development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          python312
          uv
          ruff
          pyright
          pytest
          git
          jq
        ];

        shellHook = ''
          export UV_PROJECT_ENVIRONMENT=.venv
          echo "Project dev shell loaded"
        '';
      };
    };
}
EOF
```

Add direnv:

```bash
cat > .envrc <<'EOF'
use flake
EOF

direnv allow
```

Now tell agents to use:

```bash
nix develop
nix flake check
```

For a Node project, use a different `devShell`:

```nix
packages = with pkgs; [
  nodejs_22
  pnpm
  typescript
  nodePackages.prettier
  eslint
  git
];
```

For Rust:

```nix
packages = with pkgs; [
  rustup
  cargo-nextest
  cargo-deny
  rustfmt
  clippy
  pkg-config
  openssl
  git
];
```

The important rule is: **the VM has general tools, but each repo owns its exact build/test environment.** That makes your local agents much more reliable because they can run the same commands every time.

---

## 14. Pin container images for better reproducibility

The tutorial starts with:

```yaml
image: ollama/ollama:latest
```

That is convenient, not fully reproducible. After the first pull:

```bash
docker image inspect --format='{{index .RepoDigests 0}}' ollama/ollama:latest
```

Then edit `system.nix` and replace:

```yaml
image: ollama/ollama:latest
```

with something like:

```yaml
image: ollama/ollama@sha256:<digest>
```

Apply again:

```bash
cd ~/ai-dev-vm
nix run 'github:numtide/system-manager' -- switch --sudo
ai-vm-down
ai-vm-up
git add system.nix flake.lock
git commit -m "Pin AI service container images"
```

For Ubuntu-managed packages, capture the exact installed driver/container versions:

```bash
dpkg-query -W \
  'nvidia-*' \
  'docker-*' \
  'containerd.io' \
  'libnvidia-container*' \
  'nvidia-container-toolkit*' \
  | tee apt-versions.lock

git add apt-versions.lock
git commit -m "Record Ubuntu-managed GPU and container package versions"
```

For stricter pinning, install exact Docker/NVIDIA package versions from APT once you’ve chosen them. Docker’s docs show the version-pinning flow using `apt list --all-versions docker-ce` and installing a specific `VERSION_STRING`. ([Docker Documentation][4])

---

## 15. Day-2 operations

Update Nix-managed tools:

```bash
cd ~/ai-dev-vm
nix flake update
nix run 'github:numtide/system-manager' -- switch --sudo
git add flake.lock
git commit -m "Update Nix inputs"
```

Update Ubuntu security packages:

```bash
sudo apt update
sudo apt upgrade
sudo reboot
```

Update or add models:

```bash
ai-vm-pull-model devstral
ai-vm-pull-model qwen3-coder:30b
docker exec -it ollama ollama list
```

Check model GPU placement and context:

```bash
docker exec -it ollama ollama ps
```

Ollama’s context docs recommend checking `ollama ps` to confirm context allocation and whether the model is fully on GPU, partially split, or on CPU. ([Ollama][9])

---

## 16. Troubleshooting

### `nvidia-smi` fails inside the Ubuntu VM

Check that the VM sees the GPU:

```bash
lspci -nn | grep -Ei 'nvidia|vga|3d'
```

If it does not appear, fix Proxmox passthrough first. Recheck `q35`, OVMF, PCIe passthrough, all GPU functions, and host VFIO binding.

### `nvidia-smi` works, but Docker cannot see the GPU

Run:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
ai-vm-test-gpu
```

The Docker test uses NVIDIA’s CUDA image pattern from Docker’s Compose GPU docs. ([Docker Documentation][14])

### OpenCode or aider seems “dumb”

Usually one of these is true:

```text
The model is too small.
The context window is too small.
The repo has no AGENTS.md / instructions.
The project has no reproducible test command.
The model is partially offloaded to CPU and too slow.
```

Check:

```bash
docker exec -it ollama ollama ps
```

Then try a smaller repo, more explicit instructions, or a model better suited for agentic coding.

### Nix says a package attribute does not exist

Because `nixos-unstable` moves, one package name may change. Start by removing the failing package from `system.nix`, apply again, then search for its new package name:

```bash
nix search nixpkgs opencode
nix search nixpkgs aider
nix search nixpkgs goose
```

### `opencode web` is reachable without auth

If you bind `opencode web` beyond localhost, set `OPENCODE_SERVER_PASSWORD` and verify the service is only exposed on the interfaces you intend to trust. Keep the VM itself as the security boundary for browser-based access.

---

## Recommended default workflow

```bash
# Start services
ai-vm-up

# Pull/update your agentic model
ai-vm-pull-model devstral

# Work in a repo
cd ~/src/<repo>
git switch -c ai/some-task

# Terminal agent
ollama launch opencode

# Controlled diff-based editing
aider --model ollama_chat/devstral

# Before accepting changes
git diff
nix develop -c pytest
git commit
```

This gives you a local, reproducible Ubuntu Server VM with GPU-backed local models, a Claude Code-like terminal workflow, and a clean path for testing/iterating inside Git-controlled projects.

[1]: https://ubuntu.com/server/docs/how-to/graphics/install-nvidia-drivers/ "NVIDIA drivers installation - Ubuntu Server documentation"
[2]: https://opencode.ai/docs/ "Intro | AI coding agent built for the terminal"
[3]: https://github.com/proxmox/pve-docs/blob/master/qm-pci-passthrough.adoc "pve-docs/qm-pci-passthrough.adoc at master · proxmox/pve-docs · GitHub"
[4]: https://docs.docker.com/engine/install/ubuntu/ "Install Docker Engine on Ubuntu | Docker Docs"
[5]: https://nix.dev/manual/nix/stable/installation/installing-binary.html "Installing a Binary Distribution - Nix 2.28.7 Reference Manual"
[6]: https://system-manager.net/main/tutorials/getting-started/ "Getting Started - System Manager"
[7]: https://docs.ollama.com/docker "Docker - Ollama"
[8]: https://ollama.com/library/devstral "devstral"
[9]: https://docs.ollama.com/context-length?utm_source=chatgpt.com "Context length - Ollama"
[10]: https://docs.ollama.com/integrations/opencode "OpenCode - Ollama"
[11]: https://aider.chat/docs/llms/ollama.html "Ollama | aider"
[12]: https://goose-docs.ai/ "goose | Your open source AI agent"
[14]: https://docs.docker.com/compose/how-tos/gpu-support/ "Run Docker Compose services with GPU access | Docker Docs"

