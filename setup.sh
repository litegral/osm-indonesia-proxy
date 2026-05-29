#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# OSM Indonesia tile server — setup script
# Covers: requirements check → data download → mbtiles generation → styling → docker stack
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
CONFIG_DIR="$SCRIPT_DIR/config"
TILEMAKER_DIR="$SCRIPT_DIR/tilemaker"
LOG_FILE="$SCRIPT_DIR/setup.log"

# PBF_URL is set dynamically based on server region in detect_region()
PBF_URL_GEOFABRIK="https://download.geofabrik.de/asia/indonesia-latest.osm.pbf"
PBF_URL_ASIA="https://download.geofabrik.de/asia/indonesia-latest.osm.pbf"
PBF_URL=""
COASTLINE_URL="https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip"
PBF_FILE="$DATA_DIR/indonesia-latest.osm.pbf"
MBTILES_FILE="$DATA_DIR/indonesia-z19.mbtiles"
COASTLINE_ZIP="$TILEMAKER_DIR/water-polygons-split-4326.zip"
COASTLINE_DIR="$TILEMAKER_DIR/coastline"

TILEMAKER_IMAGE="ghcr.io/systemed/tilemaker:master"

MIN_DISK_GB=20        # minimum free disk space in GB
MIN_RAM_MB=2048       # minimum free RAM in MB
DOCKER_MIN_VERSION=20 # minimum docker major version

# =============================================================================
# color + logging
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

_log_raw() { echo -e "$*" | tee -a "$LOG_FILE"; }

log()     { _log_raw "${BLUE}[OSM]${NC}   $*"; }
success() { _log_raw "${GREEN}[OK]${NC}    $*"; }
warn()    { _log_raw "${YELLOW}[WARN]${NC}  $*"; }
error()   { _log_raw "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { _log_raw "\n${BOLD}${CYAN}==> $*${NC}"; }
detail()  { _log_raw "${DIM}        $*${NC}"; }

# =============================================================================
# helpers
# =============================================================================

ask_overwrite() {
  local label="$1"
  local path="$2"
  if [[ -f "$path" || -d "$path" ]]; then
    warn "$label already exists: $path"
    read -rp "        Overwrite? [y/N] " answer </dev/tty
    [[ "$answer" =~ ^[Yy]$ ]] && return 0 || return 1
  fi
  return 0
}

ask_yes() {
  # ask_yes "message" → returns 0 for yes, 1 for no
  read -rp "$* [y/N] " answer </dev/tty
  [[ "$answer" =~ ^[Yy]$ ]]
}

check_cmd() {
  # check_cmd <cmd> <package-hint> [required|optional]
  local cmd="$1"
  local hint="$2"
  local required="${3:-required}"
  if command -v "$cmd" &>/dev/null; then
    success "  $cmd found ($(command -v "$cmd"))"
    return 0
  else
    if [[ "$required" == "required" ]]; then
      error "  $cmd not found. Install it with: $hint"
    else
      warn "  $cmd not found (optional). Install with: $hint"
      return 1
    fi
  fi
}

free_disk_gb() {
  df -BG "$SCRIPT_DIR" | awk 'NR==2 {gsub("G",""); print $4}'
}

free_ram_mb() {
  if [[ -f /proc/meminfo ]]; then
    awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo
  else
    # macOS fallback
    vm_stat 2>/dev/null | awk '/Pages free/ {printf "%d", $3*4096/1024/1024}' || echo "0"
  fi
}

docker_major_version() {
  docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1 || echo "0"
}

file_size_mb() {
  local f="$1"
  if [[ -f "$f" ]]; then
    du -m "$f" | cut -f1
  else
    echo "0"
  fi
}

cleanup_on_error() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    warn "Script exited with error (code $exit_code)."
    warn "Partial downloads or temp files may remain. Check:"
    warn "  $DATA_DIR"
    warn "  $TILEMAKER_DIR"
    warn "Full log: $LOG_FILE"
  fi
}

trap cleanup_on_error EXIT

# =============================================================================
# region detection + mirror selection
# =============================================================================

detect_region() {
  log "Detecting server region for optimal download mirror..."

  local continent=""
  local country=""
  local region_label=""

  # try multiple IP geolocation APIs in case one is down
  local geo_response=""
  for api in \
    "https://ipapi.co/json/" \
    "https://ipwho.is/" \
    "https://ip-api.com/json/"; do
    geo_response=$(curl -sf --max-time 5 "$api" 2>/dev/null || true)
    if [[ -n "$geo_response" ]]; then
      break
    fi
  done

  if [[ -n "$geo_response" ]]; then
    # extract continent -- different APIs use different keys
    continent=$(echo "$geo_response" | grep -o '"continent[_code]*": *"[^"]*"' | head -1 | grep -o '"[A-Za-z ]*"$' | tr -d '"' || true)
    country=$(echo "$geo_response" | grep -o '"country[_code]*": *"[^"]*"' | head -1 | grep -o '"[A-Z]*"$' | tr -d '"' || true)
  fi

  # pick mirror based on detected region
  # geofabrik has regional mirrors but indonesia extract only lives in /asia/
  # the difference is routing -- european servers get better speeds direct from geofabrik.de
  # asian servers benefit from parallel connections to overcome the DE→Asia latency
  case "$continent" in
    AS|"Asia")
      region_label="Asia"
      PBF_URL="$PBF_URL_GEOFABRIK"
      ARIA2C_CONNECTIONS=16  # parallel connections help overcome DE→Asia latency
      ;;
    EU|"Europe")
      region_label="Europe"
      PBF_URL="$PBF_URL_GEOFABRIK"
      ARIA2C_CONNECTIONS=4   # close to geofabrik servers, fewer connections needed
      ;;
    NA|"North America")
      region_label="North America"
      PBF_URL="$PBF_URL_GEOFABRIK"
      ARIA2C_CONNECTIONS=8
      ;;
    *)
      region_label="Unknown"
      PBF_URL="$PBF_URL_GEOFABRIK"
      ARIA2C_CONNECTIONS=8
      ;;
  esac

  if [[ -n "$country" ]]; then
    success "Detected region: $region_label ($country) -- using $ARIA2C_CONNECTIONS parallel connections"
  else
    warn "Could not detect region -- defaulting to $ARIA2C_CONNECTIONS parallel connections"
    PBF_URL="$PBF_URL_GEOFABRIK"
    ARIA2C_CONNECTIONS=8
  fi
}

# =============================================================================
# step 0: requirements check
# =============================================================================

check_requirements() {
  step "Requirements check"

  local failures=0

  # --- OS check ---
  log "Operating system:"
  if [[ "$(uname -s)" != "Linux" ]]; then
    warn "  This script is designed for Linux. You're on $(uname -s) -- things may behave differently."
  else
    success "  Linux $(uname -r)"
  fi

  # --- required commands ---
  log "Required commands:"
  check_cmd "docker"   "https://docs.docker.com/engine/install/" required  || ((failures++))
  check_cmd "aria2c"   "apt install aria2 / yum install aria2"   required  || ((failures++))
  check_cmd "wget"     "apt install wget / yum install wget"      required  || ((failures++))
  check_cmd "curl"     "apt install curl / yum install curl"      required  || ((failures++))
  check_cmd "unzip"    "apt install unzip / yum install unzip"    required  || ((failures++))

  # --- optional but useful ---
  log "Optional commands:"
  check_cmd "jq"   "apt install jq"   optional || true
  check_cmd "git"  "apt install git"  optional || true

  # --- docker compose v2 ---
  log "Docker Compose V2:"
  if docker compose version &>/dev/null 2>&1; then
    local compose_ver
    compose_ver=$(docker compose version --short 2>/dev/null || echo "unknown")
    success "  docker compose found (v$compose_ver)"
  else
    error "  Docker Compose V2 is required. Install: https://docs.docker.com/compose/install/"
  fi

  # --- docker daemon running ---
  log "Docker daemon:"
  if ! docker info &>/dev/null 2>&1; then
    error "  Docker daemon is not running. Start it with: systemctl start docker"
  else
    success "  Docker daemon is running"
  fi

  # --- docker version ---
  log "Docker version:"
  local docker_ver
  docker_ver=$(docker_major_version)
  if [[ "$docker_ver" -lt "$DOCKER_MIN_VERSION" ]]; then
    warn "  Docker v$docker_ver detected. v$DOCKER_MIN_VERSION+ is recommended."
  else
    success "  Docker v$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  fi

  # --- current user can run docker ---
  log "Docker permissions:"
  if ! docker ps &>/dev/null 2>&1; then
    warn "  Current user may not have Docker access. Consider: usermod -aG docker \$USER"
    warn "  Continuing anyway -- some steps may fail if permissions are insufficient."
  else
    success "  Current user can run Docker"
  fi

  # --- disk space ---
  log "Disk space:"
  local free_disk
  free_disk=$(free_disk_gb)
  if [[ "$free_disk" -lt "$MIN_DISK_GB" ]]; then
    warn "  Only ${free_disk}GB free at $SCRIPT_DIR. Recommended: ${MIN_DISK_GB}GB+"
    warn "  Indonesia PBF ~600MB, MBTiles ~2-5GB, Docker images ~2GB."
    if ! ask_yes "        Continue anyway?"; then
      error "Aborted due to low disk space."
    fi
  else
    success "  ${free_disk}GB free at $SCRIPT_DIR"
  fi

  # --- RAM ---
  log "Available RAM:"
  local free_ram
  free_ram=$(free_ram_mb)
  if [[ "$free_ram" -lt "$MIN_RAM_MB" ]]; then
    warn "  Only ${free_ram}MB RAM available. Tilemaker needs 2GB+ for Indonesia."
    warn "  Generation may be slow or fail on low memory."
  else
    success "  ${free_ram}MB available"
  fi

  # --- internet connectivity ---
  log "Internet connectivity:"
  if curl -sf --max-time 5 "https://download.geofabrik.de" -o /dev/null; then
    success "  Geofabrik reachable"
  else
    warn "  Cannot reach download.geofabrik.de -- download steps will fail."
    failures=$((failures + 1))
  fi
  if curl -sf --max-time 5 "https://osmdata.openstreetmap.de" -o /dev/null; then
    success "  OSM coastline server reachable"
  else
    warn "  Cannot reach osmdata.openstreetmap.de -- coastline download will fail."
  fi

  # --- required project files ---
  log "Project structure:"
  local structure_ok=1
  for f in \
    "$SCRIPT_DIR/compose.yml" \
    "$SCRIPT_DIR/Dockerfile" \
    "$SCRIPT_DIR/main.go" \
    "$TILEMAKER_DIR/config.json" \
    "$TILEMAKER_DIR/process.lua"
  do
    if [[ -f "$f" ]]; then
      success "  found: ${f#$SCRIPT_DIR/}"
    else
      warn "  missing: ${f#$SCRIPT_DIR/}"
      structure_ok=0
    fi
  done
  if [[ $structure_ok -eq 0 ]]; then
    warn "Some expected project files are missing. The script may fail at later steps."
    if ! ask_yes "        Continue anyway?"; then
      error "Aborted due to missing project files."
    fi
  fi

  # --- port availability ---
  log "Port availability:"
  if ss -tlnp 2>/dev/null | grep -q ':3000 ' || netstat -tlnp 2>/dev/null | grep -q ':3000 '; then
    warn "  Port 3000 is already in use -- proxy may fail to bind."
  else
    success "  Port 3000 is free"
  fi

  if [[ $failures -gt 0 ]]; then
    error "$failures required check(s) failed. Fix them before continuing."
  fi

  success "All required checks passed."
}

# =============================================================================
# step 1: download OSM PBF extract
# =============================================================================

download_pbf() {
  step "Step 1/5: OSM extract (Geofabrik Indonesia)"
  mkdir -p "$DATA_DIR"

  if [[ -f "$PBF_FILE" ]]; then
    local size_mb
    size_mb=$(file_size_mb "$PBF_FILE")
    detail "Existing file: $PBF_FILE (${size_mb}MB)"

    # sanity check: indonesia pbf should be at least 300MB
    if [[ "$size_mb" -lt 300 ]]; then
      warn "Existing PBF is only ${size_mb}MB -- it may be incomplete or corrupted."
      if ask_yes "        Re-download?"; then
        rm -f "$PBF_FILE"
      else
        warn "Using potentially incomplete PBF."
        return
      fi
    elif ! ask_overwrite "PBF extract" "$PBF_FILE"; then
      success "Skipping PBF download, using existing file (${size_mb}MB)."
      return
    fi
  fi

  log "Downloading Indonesia OSM extract from Geofabrik..."
  detail "URL: $PBF_URL"
  detail "Destination: $PBF_FILE"
  detail "Using $ARIA2C_CONNECTIONS parallel connections"

  # aria2c -c resumes interrupted downloads, -x parallel connections
  # dir + out instead of full path to avoid double-path bug
  if aria2c -c \
    -x "$ARIA2C_CONNECTIONS" \
    -s "$ARIA2C_CONNECTIONS" \
    -k 1M \
    --dir="$DATA_DIR" \
    --out="indonesia-latest.osm.pbf" \
    "$PBF_URL"; then
    local size_mb
    size_mb=$(file_size_mb "$PBF_FILE")
    success "PBF downloaded: $PBF_FILE (${size_mb}MB)"
  else
    error "Download failed. Resume manually with:\n        aria2c -c -x 16 -s 16 -k 1M --dir=$DATA_DIR --out=indonesia-latest.osm.pbf $PBF_URL"
  fi
}

# =============================================================================
# step 2: download coastline shapefile
# =============================================================================

download_coastline() {
  step "Step 2/5: Coastline shapefile"
  mkdir -p "$TILEMAKER_DIR"

  if [[ -f "$COASTLINE_DIR/water_polygons.shp" ]]; then
    detail "Existing coastline: $COASTLINE_DIR"
    if ! ask_overwrite "Coastline shapefile" "$COASTLINE_DIR"; then
      success "Skipping coastline download, using existing files."
      return
    fi
    rm -rf "$COASTLINE_DIR"
  fi

  log "Downloading coastline from OSM..."
  detail "URL: $COASTLINE_URL"
  detail "Destination: $COASTLINE_ZIP"
  detail "Using $ARIA2C_CONNECTIONS parallel connections"

  if ! aria2c -c \
    -x "$ARIA2C_CONNECTIONS" \
    -s "$ARIA2C_CONNECTIONS" \
    -k 1M \
    --dir="$TILEMAKER_DIR" \
    --out="water-polygons-split-4326.zip" \
    "$COASTLINE_URL"; then
    rm -f "$COASTLINE_ZIP"
    error "Coastline download failed. Resume manually with:\n        aria2c -c -x 16 -s 16 -k 1M --dir=$TILEMAKER_DIR --out=water-polygons-split-4326.zip $COASTLINE_URL"
  fi

  log "Extracting coastline shapefile..."
  local tmp_extract="$TILEMAKER_DIR/_coastline_extract_tmp"
  rm -rf "$tmp_extract"
  mkdir -p "$tmp_extract"

  if ! unzip -q -o "$COASTLINE_ZIP" -d "$tmp_extract"; then
    rm -rf "$tmp_extract"
    error "Failed to extract coastline zip. File may be corrupted."
  fi

  mkdir -p "$COASTLINE_DIR"
  # the zip may contain a subdirectory -- find and flatten
  local shp_count
  shp_count=$(find "$tmp_extract" -name "water_polygons.shp" | wc -l)
  if [[ "$shp_count" -eq 0 ]]; then
    rm -rf "$tmp_extract"
    error "water_polygons.shp not found inside the zip. The archive structure may have changed."
  fi

  find "$tmp_extract" -name "water_polygons.*" -exec mv {} "$COASTLINE_DIR/" \;
  rm -rf "$tmp_extract"

  # verify all required shapefile components are present
  for ext in shp shx dbf prj; do
    if [[ ! -f "$COASTLINE_DIR/water_polygons.$ext" ]]; then
      error "Missing shapefile component: water_polygons.$ext"
    fi
  done

  success "Coastline ready: $COASTLINE_DIR"
}

# =============================================================================
# step 3: generate mbtiles with tilemaker
# =============================================================================

generate_mbtiles() {
  step "Step 3/5: Generating MBTiles with tilemaker"

  if [[ -f "$MBTILES_FILE" ]]; then
    local size_mb
    size_mb=$(file_size_mb "$MBTILES_FILE")
    detail "Existing MBTiles: $MBTILES_FILE (${size_mb}MB)"

    # sanity check: indonesia mbtiles should be at least 500MB
    if [[ "$size_mb" -lt 500 ]]; then
      warn "Existing MBTiles is only ${size_mb}MB -- it may be incomplete."
      if ask_yes "        Re-generate?"; then
        rm -f "$MBTILES_FILE"
      else
        warn "Using potentially incomplete MBTiles."
        return
      fi
    elif ! ask_overwrite "MBTiles" "$MBTILES_FILE"; then
      success "Skipping MBTiles generation, using existing file (${size_mb}MB)."
      return
    fi
  fi

  # dependency checks before spending time pulling image
  [[ -f "$PBF_FILE" ]]                         || error "PBF not found: $PBF_FILE -- complete step 1 first."
  [[ -f "$COASTLINE_DIR/water_polygons.shp" ]] || error "Coastline missing -- complete step 2 first."
  [[ -f "$TILEMAKER_DIR/config.json" ]]        || error "tilemaker/config.json not found."
  [[ -f "$TILEMAKER_DIR/process.lua" ]]        || error "tilemaker/process.lua not found."

  log "Pulling tilemaker Docker image..."
  docker pull "$TILEMAKER_IMAGE" || error "Failed to pull tilemaker image. Check Docker and internet."

  log "Running tilemaker (Indonesia z19 -- this takes 30-90 minutes)..."
  detail "Input:   $PBF_FILE"
  detail "Output:  $MBTILES_FILE"
  detail "Config:  $TILEMAKER_DIR/config.json"

  local tmp_mbtiles="${MBTILES_FILE}.tmp"
  rm -f "$tmp_mbtiles"

  if docker run --rm \
    -v "$DATA_DIR:/data" \
    -v "$TILEMAKER_DIR:/tilemaker" \
    "$TILEMAKER_IMAGE" \
    --input /data/indonesia-latest.osm.pbf \
    --output /data/indonesia-z19.mbtiles.tmp \
    --config /tilemaker/config.json \
    --process /tilemaker/process.lua; then
    mv "$tmp_mbtiles" "$MBTILES_FILE"
    local size_mb
    size_mb=$(file_size_mb "$MBTILES_FILE")
    success "MBTiles generated: $MBTILES_FILE (${size_mb}MB)"
  else
    rm -f "$tmp_mbtiles"
    error "Tilemaker failed. Check Docker logs or try pulling the image manually."
  fi
}

# =============================================================================
# step 4: setup style and config
# =============================================================================

setup_style() {
  step "Step 4/5: Style and config"

  local config_file="$CONFIG_DIR/config.json"

  # --- generate config.json if missing ---
  if [[ ! -f "$config_file" ]]; then
    log "config/config.json not found -- generating..."
    mkdir -p "$CONFIG_DIR"
    cat > "$config_file" <<EOF
{
  "options": {
    "paths": {
      "root": "/config",
      "mbtiles": "/data"
    }
  },
  "data": {
    "indonesia": {
      "mbtiles": "indonesia-z19.mbtiles"
    }
  },
  "styles": {
    "positron": {
      "style": "positron/style.json"
    }
  }
}
EOF
    success "Generated config/config.json"
  fi

  # --- ensure mbtiles reference is z19 ---
  if grep -q '"indonesia\.mbtiles"' "$config_file"; then
    warn "config.json points to indonesia.mbtiles -- updating to indonesia-z19.mbtiles..."
    sed -i 's|"indonesia\.mbtiles"|"indonesia-z19.mbtiles"|g' "$config_file"
    success "Updated config.json to use indonesia-z19.mbtiles"
  else
    success "config.json mbtiles reference looks correct"
  fi

  # --- check positron style source ---
  local positron_style="$CONFIG_DIR/positron/style.json"
  if [[ -f "$positron_style" ]]; then
    if grep -q '"mbtiles://indonesia"' "$positron_style"; then
      success "Positron style points to correct mbtiles source"
    else
      warn "Positron style may not point to local mbtiles:"
      grep -i '"url"' "$positron_style" | head -3 | while read -r line; do
        detail "$line"
      done
      warn "Edit $positron_style and set: \"url\": \"mbtiles://indonesia\""
    fi
  else
    warn "Positron style not found at $positron_style -- you will need to add a style manually."
  fi

  success "Style config done."
}

# =============================================================================
# step 5: build and start Docker stack
# =============================================================================

start_stack() {
  step "Step 5/5: Docker stack"

  cd "$SCRIPT_DIR"

  # --- check compose.yml exists ---
  [[ -f "$SCRIPT_DIR/compose.yml" ]] || error "compose.yml not found in $SCRIPT_DIR"

  # --- build Go proxy ---
  log "Building Go proxy image..."
  if ! docker compose build proxy; then
    error "Failed to build proxy image. Check Dockerfile and Go source."
  fi
  success "Proxy image built"

  # --- pull other images ---
  log "Pulling tileserver and redis images..."
  docker compose pull tileserver redis || warn "Could not pull some images -- will use cached versions if available."

  # --- handle already running services ---
  local running
  running=$(docker compose ps --services --filter status=running 2>/dev/null || true)

  if [[ -n "$running" ]]; then
    warn "Currently running services: $running"
    if ask_yes "        Restart all services? (No = restart tileserver only)"; then
      log "Bringing stack down..."
      docker compose down
      log "Starting fresh stack..."
      docker compose up -d
    else
      log "Restarting tileserver only to pick up config changes..."
      docker compose restart tileserver
    fi
  else
    log "Starting Docker stack..."
    docker compose up -d
  fi

  # --- wait for services to be healthy ---
  log "Waiting for services to come up..."
  local max_wait=60
  local waited=0
  local interval=3

  while true; do
    local running_now
    running_now=$(docker compose ps --services --filter status=running 2>/dev/null | wc -l || echo 0)
    if [[ "$running_now" -ge 3 ]]; then
      break
    fi
    if [[ $waited -ge $max_wait ]]; then
      warn "Services may not be fully up after ${max_wait}s. Check logs."
      break
    fi
    sleep $interval
    waited=$((waited + interval))
    log "  Still waiting... (${waited}s / ${max_wait}s)"
  done

  # --- check for startup errors in tileserver logs ---
  log "Checking tileserver startup logs..."
  local ts_logs
  ts_logs=$(docker compose logs tileserver --tail=30 2>/dev/null || true)

  if echo "$ts_logs" | grep -qi "ENOENT\|not found\|cannot read\|failed to load" ; then
    warn "Tileserver may have errors:"
    echo "$ts_logs" | grep -i "ENOENT\|not found\|cannot read\|failed to load" | while read -r line; do
      warn "  $line"
    done
    warn "Run 'docker compose logs tileserver' for details."
  else
    success "Tileserver logs look clean"
  fi

  success "Stack is up."

  # --- summary ---
  echo ""
  echo -e "${BOLD}Service status:${NC}"
  docker compose ps
  echo ""
  echo -e "${BOLD}Quick checks:${NC}"
  echo "  Tileserver logs:    docker compose logs -f tileserver"
  echo "  Proxy logs:         docker compose logs -f proxy"
  echo "  Stop all:           docker compose down"
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo "  Add an API key:     ./keys.sh add <client-name>"
  echo "  Tile endpoint:      http://localhost:3000/styles/positron/style.json?key=<your-key>"
  echo "  TileServer index:   http://localhost:3000/?key=<your-key>"
  echo ""
  echo -e "${DIM}Full setup log saved to: $LOG_FILE${NC}"
}

# =============================================================================
# entrypoint
# =============================================================================

main() {
  # initialize log file
  mkdir -p "$SCRIPT_DIR"
  echo "=== OSM Indonesia setup log — $(date) ===" > "$LOG_FILE"

  echo ""
  echo -e "${BOLD}OSM Indonesia Tile Server — Setup${NC}"
  echo -e "${DIM}Log: $LOG_FILE${NC}"
  echo "================================================"

  check_requirements
  detect_region
  download_pbf
  download_coastline
  generate_mbtiles
  setup_style
  start_stack

  echo ""
  success "Setup complete."
}

main "$@"
