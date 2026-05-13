{ pkgs, ... }:

let
  aiVmInstallDrivers = pkgs.writeShellApplication {
    name = "ai-install-drivers";
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
      echo "      NVIDIA_DRIVER_SPEC=nvidia:535-server ai-install-drivers"
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
    name = "ai-install-docker-gpu";
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
      echo "Then run: ai-test-gpu"
    '';
  };

  aiVmTestGpu = pkgs.writeShellApplication {
    name = "ai-test-gpu";
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
    name = "ai-up";
    runtimeInputs = [ aiVmPrewarmModels ] ++ (with pkgs; [ bash coreutils ]);
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
      nohup ai-prewarm-models >/tmp/ai-prewarm-models.log 2>&1 </dev/null &
      echo "Started background model prewarm; log: /tmp/ai-prewarm-models.log"
    '';
  };


  aiVmPrewarmModels = pkgs.writeShellApplication {
    name = "ai-prewarm-models";
    runtimeInputs = with pkgs; [ bash coreutils curl jq ];
    text = ''
      set -euo pipefail

      ollama_url="''${OLLAMA_URL:-http://127.0.0.1:11434}"
      primary_model="''${1:-qwen3-coder:30b}"
      small_model="''${2:-qwen2.5-coder:3b}"

      for _ in $(seq 1 60); do
        if curl -fsS "$ollama_url/api/tags" >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      warm() {
        model="$1"
        payload="$(jq -nc --arg model "$model" '{model: $model, messages: [{role: "user", content: "hi"}], stream: false}')"
        curl -fsS "$ollama_url/api/chat"           -H 'Content-Type: application/json'           -d "$payload"           >/dev/null || true
      }

      warm "$small_model"
      warm "$primary_model"
    '';
  };

  aiVmDown = pkgs.writeShellApplication {
    name = "ai-down";
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
    name = "ai-pull-model";
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


  aiVmIndexProject = pkgs.writeShellApplication {
    name = "ai-index-project";
    runtimeInputs = with pkgs; [ bash coreutils curl git jq python312 ripgrep ];
    text = ''
      set -euo pipefail

      repo="''${1:-.}"
      qdrant_url="''${QDRANT_URL:-http://127.0.0.1:6333}"
      ollama_url="''${OLLAMA_URL:-http://127.0.0.1:11434}"
      embed_model="''${AI_VM_EMBED_MODEL:-}"

      cd "$repo"

      python3 - "$qdrant_url" "$ollama_url" "$embed_model" <<'PY_INDEX'
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

QDRANT_URL, OLLAMA_URL, EMBED_MODEL = sys.argv[1:4]
DIM = 384
MAX_FILE_BYTES = 200_000
CHUNK_CHARS = 4000
OVERLAP_CHARS = 400
TEXT_SUFFIXES = {
    '.c', '.cc', '.cpp', '.cs', '.css', '.go', '.h', '.hpp', '.html', '.java', '.js', '.json',
    '.jsx', '.kt', '.lua', '.md', '.mdx', '.nix', '.php', '.py', '.rb', '.rs', '.sh', '.sql',
    '.svelte', '.toml', '.ts', '.tsx', '.txt', '.vue', '.yaml', '.yml', '.zig'
}
SKIP_PARTS = {
    '.git', '.direnv', '.venv', 'venv', 'node_modules', 'dist', 'build', 'target', '.next',
    '.turbo', '.cache', '__pycache__', 'coverage', '.pytest_cache'
}
SECRET_NAME_RE = re.compile(r'(^|[./_-])(\.env|env|secret|secrets|credential|credentials|token|tokens|key|keys)([./_-]|$)', re.I)


def http(method, url, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw else None


def collection_name(root):
    try:
        top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    except Exception:
        top = str(root.resolve())
    base = re.sub(r'[^A-Za-z0-9_-]+', '-', Path(top).name).strip('-').lower() or "project"
    digest = hashlib.sha1(top.encode()).hexdigest()[:10]
    return f'project-{base}-{digest}'


def list_files(root):
    try:
        files = subprocess.check_output(['git', 'ls-files'], text=True).splitlines()
    except Exception:
        files = [str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()]
    for rel in files:
        path = root / rel
        parts = set(path.parts)
        if parts & SKIP_PARTS:
            continue
        if SECRET_NAME_RE.search(rel):
            continue
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            if path.stat().st_size > MAX_FILE_BYTES:
                continue
        except OSError:
            continue
        yield rel, path


def read_text(path):
    raw = path.read_bytes()
    if b'\0' in raw[:4096]:
        return None
    return raw.decode('utf-8', errors='replace')


def chunks(text):
    text = text.replace('\r\n', '\n')
    start = 0
    while start < len(text):
        end = min(len(text), start + CHUNK_CHARS)
        yield text[start:end]
        if end == len(text):
            break
        start = max(0, end - OVERLAP_CHARS)


def hash_vector(text):
    vec = [0.0] * DIM
    tokens = re.findall(r'[A-Za-z_][A-Za-z0-9_]{1,}|\d+', text.lower())
    if not tokens:
        tokens = [text[:64] or 'empty']
    for token in tokens:
        h = hashlib.blake2b(token.encode(), digest_size=8).digest()
        idx = int.from_bytes(h[:4], 'little') % DIM
        sign = 1.0 if h[4] & 1 else -1.0
        vec[idx] += sign
    norm = math.sqrt(sum(x * x for x in vec)) or 1.0
    return [x / norm for x in vec]


def ollama_vector(text):
    if not EMBED_MODEL:
        return None
    body = {"model": EMBED_MODEL, "input": text}
    try:
        result = http("POST", f'{OLLAMA_URL}/api/embed', body)
        embeddings = result.get("embeddings") or []
        if not embeddings:
            return None
        vec = embeddings[0]
        if len(vec) == DIM:
            return vec
    except Exception:
        return None
    return None


def vector(text):
    return ollama_vector(text) or hash_vector(text)


def ensure_collection(name):
    try:
        http('PUT', f'{QDRANT_URL}/collections/{name}', {'vectors': {'size': DIM, 'distance': 'Cosine'}})
    except urllib.error.HTTPError as exc:
        if exc.code != 409:
            raise


def delete_existing_repo_points(name, repo):
    http('POST', f'{QDRANT_URL}/collections/{name}/points/delete?wait=true', {
        'filter': {'must': [{'key': 'repo', 'match': {'value': repo}}]}
    })


root = Path.cwd()
name = collection_name(root)
ensure_collection(name)
delete_existing_repo_points(name, str(root))
points = []
files = 0
chunk_count = 0
for rel, path in list_files(root):
    content = read_text(path)
    if not content:
        continue
    files += 1
    file_sha = hashlib.sha256(content.encode('utf-8', errors='replace')).hexdigest()
    for idx, chunk in enumerate(chunks(content)):
        point_id = str(uuid.UUID(hashlib.md5(f'{root}:{rel}:{idx}:{file_sha}'.encode()).hexdigest()))
        points.append({
            'id': point_id,
            "vector": vector(f'{rel}\n\n{chunk}'),
            'payload': {
                'repo': str(root),
                'path': rel,
                'chunk': idx,
                'sha256': file_sha,
                'text': chunk,
            },
        })
        chunk_count += 1
        if len(points) >= 64:
            http('PUT', f'{QDRANT_URL}/collections/{name}/points?wait=true', {'points': points})
            points = []
if points:
    http('PUT', f'{QDRANT_URL}/collections/{name}/points?wait=true', {'points': points})
print(json.dumps({'collection': name, 'repo': str(root), 'files_indexed': files, 'chunks_indexed': chunk_count}, indent=2))
PY_INDEX
    '';
  };

  aiVmSearchProject = pkgs.writeShellApplication {
    name = "ai-search-project";
    runtimeInputs = with pkgs; [ bash coreutils curl git jq python312 ];
    text = ''
      set -euo pipefail

      if [ "$#" -lt 1 ]; then
        echo "usage: ai-search-project <query> [repo]" >&2
        exit 2
      fi

      query="$1"
      repo="''${2:-.}"
      qdrant_url="''${QDRANT_URL:-http://127.0.0.1:6333}"
      ollama_url="''${OLLAMA_URL:-http://127.0.0.1:11434}"
      embed_model="''${AI_VM_EMBED_MODEL:-}"

      cd "$repo"

      python3 - "$qdrant_url" "$ollama_url" "$embed_model" "$query" <<'PY_SEARCH'
import hashlib
import json
import math
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

QDRANT_URL, OLLAMA_URL, EMBED_MODEL, QUERY = sys.argv[1:5]
DIM = 384


def http(method, url, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw else None


def collection_name(root):
    try:
        top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    except Exception:
        top = str(root.resolve())
    base = re.sub(r'[^A-Za-z0-9_-]+', '-', Path(top).name).strip('-').lower() or "project"
    digest = hashlib.sha1(top.encode()).hexdigest()[:10]
    return f'project-{base}-{digest}'


def hash_vector(text):
    vec = [0.0] * DIM
    tokens = re.findall(r'[A-Za-z_][A-Za-z0-9_]{1,}|\d+', text.lower()) or [text[:64] or 'empty']
    for token in tokens:
        h = hashlib.blake2b(token.encode(), digest_size=8).digest()
        idx = int.from_bytes(h[:4], 'little') % DIM
        sign = 1.0 if h[4] & 1 else -1.0
        vec[idx] += sign
    norm = math.sqrt(sum(x * x for x in vec)) or 1.0
    return [x / norm for x in vec]


def ollama_vector(text):
    if not EMBED_MODEL:
        return None
    try:
        result = http("POST", f'{OLLAMA_URL}/api/embed', {"model": EMBED_MODEL, "input": text})
        embeddings = result.get("embeddings") or []
        if embeddings and len(embeddings[0]) == DIM:
            return embeddings[0]
    except Exception:
        return None
    return None

root = Path.cwd()
name = collection_name(root)
vec = ollama_vector(QUERY) or hash_vector(QUERY)
result = http("POST", f'{QDRANT_URL}/collections/{name}/points/search', {
    "vector": vec,
    "limit": 8,
    "with_payload": True,
})
for item in result.get("result", []):
    payload = item.get("payload") or {}
    text = (payload.get("text") or "").replace("\n", " ")
    if len(text) > 240:
        text = text[:237] + "..."
    print(f'{item.get("score", 0):.4f}\t{payload.get("path")}#chunk-{payload.get("chunk")}\t{text}')
PY_SEARCH
    '';
  };


  aiVmAgent = pkgs.writeShellApplication {
    name = "ai-agent";
    runtimeInputs = with pkgs; [ bash coreutils findutils git gnused opencode ];
    text = ''
      set -euo pipefail

      usage() {
        cat >&2 <<'USAGE'
usage:
  ai-agent review <repo-path>
  ai-agent worker <repo-path> <branch-name> <prompt-file>
  ai-agent status <repo-path>
USAGE
      }

      if [ "$#" -lt 1 ]; then
        usage
        exit 2
      fi

      cmd="$1"
      shift

      sanitize() {
        printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#-#g'
      }

      repo_root() {
        git -C "$1" rev-parse --show-toplevel
      }

      logs_dir() {
        root="$1"
        mkdir -p "$root/.ai-agent/logs"
        printf '%s\n' "$root/.ai-agent/logs"
      }

      case "$cmd" in
        review)
          if [ "$#" -ne 1 ]; then usage; exit 2; fi
          root="$(repo_root "$1")"
          parent="$(dirname "$root")"
          base="$(basename "$root")"
          stamp="$(date +%Y%m%d-%H%M%S)"
          branch="ai/review-$stamp"
          worktree="$parent/$base-review-$stamp"
          log_dir="$(logs_dir "$root")"
          log_file="$log_dir/review-$stamp.log"

          git -C "$root" worktree add -b "$branch" "$worktree" HEAD
          prompt="Review this branch for correctness bugs, missing tests, security risks, and behavior changes. Do not modify files. Report findings with file paths and line references when possible."
          printf 'worktree=%s\nbranch=%s\nlog=%s\n' "$worktree" "$branch" "$log_file"
          (cd "$worktree" && opencode run "$prompt") 2>&1 | tee "$log_file"
          ;;

        worker)
          if [ "$#" -ne 3 ]; then usage; exit 2; fi
          root="$(repo_root "$1")"
          branch="$2"
          prompt_file="$3"
          if [ ! -f "$prompt_file" ]; then
            echo "prompt file not found: $prompt_file" >&2
            exit 1
          fi
          parent="$(dirname "$root")"
          base="$(basename "$root")"
          safe_branch="$(sanitize "$branch")"
          worktree="$parent/$base-worker-$safe_branch"
          log_dir="$(logs_dir "$root")"
          log_file="$log_dir/worker-$safe_branch.log"

          git -C "$root" worktree add -b "$branch" "$worktree" HEAD
          prompt="$(cat "$prompt_file")"
          prompt="$prompt

You are a bounded sidecar worker. Work only on the scope described above. Do not touch unrelated files. Run relevant tests and summarize changed files."
          printf 'worktree=%s\nbranch=%s\nlog=%s\n' "$worktree" "$branch" "$log_file"
          (cd "$worktree" && opencode run "$prompt") 2>&1 | tee "$log_file"
          ;;

        status)
          if [ "$#" -ne 1 ]; then usage; exit 2; fi
          root="$(repo_root "$1")"
          echo "worktrees:"
          git -C "$root" worktree list
          echo
          echo "logs:"
          if [ -d "$root/.ai-agent/logs" ]; then
            find "$root/.ai-agent/logs" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n' | sort
          else
            echo "none"
          fi
          ;;

        *)
          usage
          exit 2
          ;;
      esac
    '';
  };


  aiVmOrchestrator = pkgs.writeShellApplication {
    name = "ai-orchestrator";
    runtimeInputs = [ aiVmIndexProject aiVmSearchProject aiVmAgent ] ++ (with pkgs; [ bash coreutils findutils gawk git gnused jq opencode ]);
    text = ''
      set -euo pipefail

      usage() {
        cat >&2 <<'USAGE'
usage:
  ai-orchestrator prepare <repo-path> [query]
  ai-orchestrator review <repo-path> [query]
  ai-orchestrator worker <repo-path> <branch-name> <prompt-file> [query]
  ai-orchestrator gate <repo-path>
  ai-orchestrator status <repo-path>
USAGE
      }

      if [ "$#" -lt 1 ]; then
        usage
        exit 2
      fi

      cmd="$1"
      shift

      repo_root() {
        git -C "$1" rev-parse --show-toplevel
      }

      state_dir() {
        root="$1"
        mkdir -p "$root/.ai-agent/orchestrator"
        printf '%s\n' "$root/.ai-agent/orchestrator"
      }

      context_file() {
        root="$1"
        dir="$(state_dir "$root")"
        printf '%s\n' "$dir/context.md"
      }

      prepare_context() {
        root="$1"
        query="''${2:-project architecture test workflow agent instructions}"
        ctx="$(context_file "$root")"
        {
          echo '# Retrieved project context'
          echo
          echo "Repository: $root"
          echo "Query: $query"
          echo
          echo '## Qdrant search results'
          ai-index-project "$root"
          ai-search-project "$query" "$root" || true
          echo
          echo '## Git status'
          git -C "$root" status --short
          echo
          if [ -f "$root/AGENTS.md" ]; then
            echo '## AGENTS.md'
            sed -n '1,220p' "$root/AGENTS.md"
          fi
        } > "$ctx"
        printf '%s\n' "$ctx"
      }

      case "$cmd" in
        prepare)
          if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then usage; exit 2; fi
          root="$(repo_root "$1")"
          query="''${2:-project architecture test workflow agent instructions}"
          ctx="$(prepare_context "$root" "$query")"
          echo "context=$ctx"
          ;;

        review)
          if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then usage; exit 2; fi
          root="$(repo_root "$1")"
          query="''${2:-correctness bugs missing tests security risks}"
          ctx="$(prepare_context "$root" "$query")"
          prompt="Use the retrieved context in $ctx, then review this branch for correctness bugs, missing tests, security risks, and behavior changes. Do not modify files. Report findings with file paths and line references when possible."
          prompt_file="$(mktemp)"
          trap 'rm -f "$prompt_file"' EXIT
          printf '%s\n' "$prompt" > "$prompt_file"
          ai-agent worker "$root" "ai/review-$(date +%Y%m%d-%H%M%S)" "$prompt_file"
          ;;

        worker)
          if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then usage; exit 2; fi
          root="$(repo_root "$1")"
          branch="$2"
          source_prompt="$3"
          query="''${4:-$(cat "$source_prompt") }"
          ctx="$(prepare_context "$root" "$query")"
          prompt_file="$(mktemp)"
          trap 'rm -f "$prompt_file"' EXIT
          {
            echo "Use the retrieved project context in $ctx before editing."
            echo
            cat "$source_prompt"
          } > "$prompt_file"
          ai-agent worker "$root" "$branch" "$prompt_file"
          ;;

        gate)
          if [ "$#" -ne 1 ]; then usage; exit 2; fi
          root="$(repo_root "$1")"
          echo "source=$root"
          echo
          echo '## Source worktree status'
          git -C "$root" status --short
          echo
          echo '## Sidecar worktrees'
          git -C "$root" worktree list --porcelain | awk '
            /^worktree / { worktree=$2 }
            /^branch / { branch=$2; print worktree " " branch }
          ' | while read -r wt branch; do
            [ "$wt" = "$root" ] && continue
            echo
            echo "### $branch"
            echo "worktree=$wt"
            git -C "$wt" status --short || true
            echo
            git -C "$wt" diff --stat HEAD || true
          done
          echo
          echo '## Recent sidecar logs'
          if [ -d "$root/.ai-agent/logs" ]; then
            find "$root/.ai-agent/logs" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -nr | head -5 | while read -r _ log; do
              echo
              echo "### $log"
              tail -80 "$log" || true
            done
          else
            echo 'none'
          fi
          ;;

        status)
          if [ "$#" -ne 1 ]; then usage; exit 2; fi
          root="$(repo_root "$1")"
          ai-agent status "$root"
          ctx="$(context_file "$root")"
          if [ -f "$ctx" ]; then
            echo
            echo "context=$ctx"
          fi
          ;;

        *)
          usage
          exit 2
          ;;
      esac
    '';
  };

  aiVmSetOpencodePassword = pkgs.writeShellApplication {
    name = "ai-set-opencode-password";
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
      aiVmPrewarmModels
      aiVmPullModel
      aiVmIndexProject
      aiVmSearchProject
      aiVmAgent
      aiVmOrchestrator
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
            OLLAMA_CONTEXT_LENGTH: "16384"
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
            - /mnt/truenas/qdrant:/qdrant/storage
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
