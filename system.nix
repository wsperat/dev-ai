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
        driver_package="nvidia-driver-''${driver_spec#nvidia:}"
      else
        /usr/bin/sudo /usr/bin/ubuntu-drivers install --gpgpu
        driver_package="$(/usr/bin/ubuntu-drivers list --gpgpu | /usr/bin/head -n1 | /usr/bin/cut -d, -f1)"
      fi

      driver_version="$(printf '%s\n' "$driver_package" | sed -n 's/^nvidia-driver-\([0-9][0-9]*\).*/\1/p')"
      if [ -n "$driver_version" ]; then
        if printf '%s\n' "$driver_package" | grep -q -- '-server'; then
          utils_pkg="nvidia-utils-''${driver_version}-server"
        else
          utils_pkg="nvidia-utils-''${driver_version}"
        fi
        /usr/bin/sudo /usr/bin/apt-get install -y "$utils_pkg"
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

      # shellcheck disable=SC1091
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

  aiVmSetOpencodePassword = pkgs.writeShellApplication {
    name = "ai-vm-set-opencode-password";
    runtimeInputs = with pkgs; [ bash coreutils openssl ];
    text = ''
      set -euo pipefail

      password="''${1:-$(openssl rand -base64 24)}"
      tmp="$(mktemp)"
      trap 'rm -f "$tmp"' EXIT

      printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$password" > "$tmp"
      /usr/bin/sudo /usr/bin/install -m 0600 "$tmp" /etc/default/opencode-web
      /usr/bin/sudo /usr/bin/systemctl restart opencode-web.service

      echo "Updated /etc/default/opencode-web and restarted opencode-web.service"
      echo "Username: opencode"
      echo "Password: $password"
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
      aiVmSetOpencodePassword
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
      export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:$LD_LIBRARY_PATH"
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
            - /mnt/truenas/models:/root/.ollama/models
          environment:
            OLLAMA_MODELS: "/root/.ollama/models"
            OLLAMA_CONTEXT_LENGTH: "64000"
            OLLAMA_KEEP_ALIVE: "24h"
          deploy:
            resources:
              reservations:
                devices:
                  - driver: nvidia
                    count: all
                    capabilities: [gpu]

        qdrant:
          image: qdrant/qdrant:latest
          container_name: qdrant
          restart: unless-stopped
          ports:
            - "127.0.0.1:6333:6333"
            - "127.0.0.1:6334:6334"
          volumes:
            - /var/lib/ai-dev-vm/qdrant:/qdrant/storage
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
      User=walter
      Group=walter
      WorkingDirectory=/mnt/truenas/Personal/dev-ai
      Environment=HOME=/home/walter
      Environment=BROWSER=/bin/true
      Environment=LD_LIBRARY_PATH=${pkgs.stdenv.cc.cc.lib}/lib
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
