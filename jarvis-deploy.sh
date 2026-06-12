#!/bin/bash
# jarvis-deploy.sh — Pull latest Jarvis configs and deploy all new services
# Usage: bash ~/k12-configs/jarvis-deploy.sh
# Or one-shot: bash <(curl -sL https://raw.githubusercontent.com/getjeevan/k12-configs/claude/jarvis-k12-build-8Phil/jarvis-deploy.sh)

set -e
BRANCH="claude/jarvis-k12-build-8Phil"
REPO_URL="https://github.com/getjeevan/k12-configs.git"
SERVICES_SRC=""
SERVICES_DST="$HOME/services"

# ── Colours ───────────────────────────────────────────────────────────────────
GRN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; BLD='\033[1m'; RST='\033[0m'
ok()   { echo -e "${GRN}✅ $*${RST}"; }
fail() { echo -e "${RED}❌ $*${RST}"; }
info() { echo -e "${YEL}▶  $*${RST}"; }
hdr()  { echo -e "\n${BLD}── $* ──────────────────────────────────────────${RST}"; }

# ── 1. Find or clone the repo ─────────────────────────────────────────────────
hdr "Locating repo"
for candidate in \
  "$HOME/k12-configs" \
  "$HOME/ops/k12-configs" \
  "$HOME/configs/k12-configs"; do
  if [ -d "$candidate/.git" ]; then
    SERVICES_SRC="$candidate/services"
    info "Found repo at $candidate"
    break
  fi
done

if [ -z "$SERVICES_SRC" ]; then
  info "Repo not found locally — cloning $BRANCH"
  git clone --branch "$BRANCH" "$REPO_URL" "$HOME/k12-configs"
  SERVICES_SRC="$HOME/k12-configs/services"
else
  REPO_DIR="${SERVICES_SRC%/services}"
  info "Pulling $BRANCH in $REPO_DIR"
  git -C "$REPO_DIR" fetch origin
  git -C "$REPO_DIR" checkout "$BRANCH"
  git -C "$REPO_DIR" pull origin "$BRANCH"
fi
ok "Repo up to date"

# ── 2. Sync new service directories to ~/services ─────────────────────────────
hdr "Syncing service configs"
NEW_SERVICES=(jarvis-ops-api whisper kokoro-tts jarvis-rag)

for svc in "${NEW_SERVICES[@]}"; do
  src="$SERVICES_SRC/$svc"
  dst="$SERVICES_DST/$svc"
  if [ ! -d "$src" ]; then
    fail "Source not found: $src"
    continue
  fi
  mkdir -p "$dst"
  cp -r "$src/." "$dst/"
  ok "Synced $svc → $dst"
done

# ── 3. Build local images ─────────────────────────────────────────────────────
for svc in jarvis-ops-api jarvis-rag; do
  hdr "Building $svc"
  cd "$SERVICES_DST/$svc"
  docker compose build
  ok "$svc build complete"
done

# ── 3b. Ensure embedding model is available ───────────────────────────────────
hdr "Embedding model"
if curl -s http://localhost:11434/api/tags | grep -q nomic-embed-text; then
  ok "nomic-embed-text already pulled"
else
  info "Pulling nomic-embed-text via Ollama (one-time, ~275MB)"
  curl -s http://localhost:11434/api/pull -d '{"model":"nomic-embed-text"}' > /dev/null
  ok "nomic-embed-text pulled"
fi

# ── 4. Start all new services ─────────────────────────────────────────────────
hdr "Starting services"
for svc in "${NEW_SERVICES[@]}"; do
  info "Starting $svc"
  cd "$SERVICES_DST/$svc"
  docker compose up -d
  ok "$svc started"
done

# ── 5. Health checks ──────────────────────────────────────────────────────────
hdr "Health checks (waiting 15s for containers to settle)"
sleep 15

check_url() {
  local label="$1" url="$2"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)
  [ "${code:0:1}" = "2" ] && ok "$label ($url) → HTTP $code" || fail "$label ($url) → HTTP $code"
}

check_url "Jarvis Ops API" "http://localhost:3006/health"
check_url "Whisper STT"    "http://localhost:9000/docs"
check_url "Kokoro TTS"     "http://localhost:8880/health"
check_url "Jarvis RAG"     "http://localhost:3007/health"

# ── 6. Live status from Ops API ───────────────────────────────────────────────
hdr "K12 live status"
curl -s http://localhost:3006/status/text 2>/dev/null || echo "(Ops API not yet ready — run again in 30s)"

echo ""
ok "Jarvis deploy complete."
echo -e "${BLD}  Next: Open WebUI → Admin → Tools → paste services/jarvis/open-webui-tool.py${RST}"
