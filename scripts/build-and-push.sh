#!/usr/bin/env bash
# build-and-push.sh
# Build images from docker-compose, tag them, push to Docker Hub,
# and optionally replace __IMAGE_TAG__ placeholder in a GitHub Actions workflow file.
#
# Usage:
#   DOCKERHUB_REPO=youruser/myapp \
#   DOCKERHUB_USERNAME=youruser \
#   DOCKERHUB_TOKEN=your_token \
#   ./build-and-push.sh [--workflow-file .github/workflows/deploy-to-ec2.yml]
#
# Requirements:
#  - docker and docker compose available on PATH
#  - git (to compute default tag from git sha)
#  - env DOCKERHUB_REPO must be provided
#  - DOCKERHUB_USERNAME and DOCKERHUB_TOKEN must be provided (for pushing)
#
set -euo pipefail

# ---------- config / args ----------
WORKFLOW_FILE_ARG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --workflow-file) WORKFLOW_FILE_ARG="$2"; shift 2 ;;
    --help|-h) echo "Usage: DOCKERHUB_REPO=your/repo DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=... $0 [--workflow-file path]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ---------- env validation ----------
if [[ -z "${DOCKERHUB_REPO:-}" ]]; then
  echo "ERROR: set DOCKERHUB_REPO (example: myuser/myapp)"
  exit 1
fi

if [[ -z "${DOCKERHUB_USERNAME:-}" || -z "${DOCKERHUB_TOKEN:-}" ]]; then
  echo "ERROR: set DOCKERHUB_USERNAME and DOCKERHUB_TOKEN (Docker Hub credentials)"
  exit 1
fi

# ---------- helper functions ----------
log() { printf "\n[INFO] %s\n" "$*"; }
err() { printf "\n[ERROR] %s\n" "$*" >&2; }

# compute tag: prefer GITHUB_SHA if present, else git short sha, else timestamp
if [[ -n "${GITHUB_SHA:-}" ]]; then
  TAG="${GITHUB_SHA:0:7}"
else
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    TAG="$(git rev-parse --short HEAD)"
  else
    TAG="$(date +%Y%m%d%H%M%S)"
  fi
fi

log "Using Docker Hub repo: ${DOCKERHUB_REPO}"
log "Computed tag: ${TAG}"

# ---------- build stage ----------
log "Listing services from docker-compose..."
SERVICES=$(docker compose config --services)
if [[ -z "$SERVICES" ]]; then
  err "No services found in docker-compose config. Exiting."
  exit 1
fi

NUM_SERVICES=$(echo "$SERVICES" | wc -l)
log "Detected services: ${NUM_SERVICES}"
echo "$SERVICES" | sed 's/^/ - /'

# create a dynamic override compose to set image names for each service
OVERRIDE_FILE=".docker-compose.image.override.yml"
log "Creating override file: ${OVERRIDE_FILE}"
cat > "${OVERRIDE_FILE}" <<EOF
version: "3.8"
services:
EOF

# if single service, tag as DOCKERHUB_REPO:TAG; if multiple, append service name
if [[ "$NUM_SERVICES" -eq 1 ]]; then
  SERVICE_NAME=$(echo "$SERVICES" | tr -d '[:space:]')
  IMAGE_NAME="${DOCKERHUB_REPO}:${TAG}"
  cat >> "${OVERRIDE_FILE}" <<EOF
  ${SERVICE_NAME}:
    image: ${IMAGE_NAME}
EOF
  log "Single service detected. Will tag ${SERVICE_NAME} -> ${IMAGE_NAME}"
else
  for s in $SERVICES; do
    # sanitize service name for image subname
    S_SAFE=$(echo "$s" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]-' '-')
    IMAGE_NAME="${DOCKERHUB_REPO}-${S_SAFE}:${TAG}"
    cat >> "${OVERRIDE_FILE}" <<EOF
  ${s}:
    image: ${IMAGE_NAME}
EOF
    log "Will tag ${s} -> ${IMAGE_NAME}"
  done
fi

# Build using combined compose files (the override sets image names so built images are properly tagged)
log "Running: docker compose -f docker-compose.yml -f ${OVERRIDE_FILE} build --pull --no-cache"
docker compose -f docker-compose.yml -f "${OVERRIDE_FILE}" build --pull --no-cache

# ---------- docker login ----------
log "Logging in to Docker Hub"
echo "${DOCKERHUB_TOKEN}" | docker login --username "${DOCKERHUB_USERNAME}" --password-stdin

# ---------- push stage ----------
log "Pushing images to Docker Hub..."
PUSHED_IMAGES=()
if [[ "$NUM_SERVICES" -eq 1 ]]; then
  pushed="${DOCKERHUB_REPO}:${TAG}"
  log "Pushing ${pushed}"
  docker push "${pushed}"
  PUSHED_IMAGES+=("${pushed}")
else
  for s in $SERVICES; do
    S_SAFE=$(echo "$s" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]-' '-')
    pushed="${DOCKERHUB_REPO}-${S_SAFE}:${TAG}"
    log "Pushing ${pushed}"
    docker push "${pushed}"
    PUSHED_IMAGES+=("${pushed}")
  done
fi

log "Pushed images:"
printf '%s\n' "${PUSHED_IMAGES[@]}"

# ---------- optionally update GitHub workflow ----------
# The script will look for a literal placeholder "__IMAGE_TAG__" in the workflow file path
# provided. If found, it will replace it with the computed TAG.
# This avoids fragile replaces and gives you control where the tag should go.
if [[ -n "${WORKFLOW_FILE_ARG}" ]]; then
  WF="${WORKFLOW_FILE_ARG}"
  if [[ ! -f "${WF}" ]]; then
    err "Workflow file ${WF} not found. Skipping workflow update."
  else
    if grep -q "__IMAGE_TAG__" "${WF}"; then
      log "Updating workflow file ${WF}: replacing __IMAGE_TAG__ -> ${TAG}"
      # use a safe in-place replace that works on mac/linux
      if sed --version >/dev/null 2>&1; then
        sed -i "s/__IMAGE_TAG__/${TAG}/g" "${WF}"
      else
        # macOS fallback
        sed -i '' "s/__IMAGE_TAG__/${TAG}/g" "${WF}"
      fi
      log "Workflow file updated."
    else
      log "No __IMAGE_TAG__ placeholder found in ${WF}. Nothing changed. To enable automatic update,"
      log "add the literal token __IMAGE_TAG__ at the correct place in the workflow file."
      log "Example usage in workflow YAML (deploy step env or tag field):"
      cat <<EXAMPLE
env:
  IMAGE_TAG: __IMAGE_TAG__

or

tags: |
  youruser/yourrepo:__IMAGE_TAG__
EXAMPLE
    fi
  fi
else
  log "No workflow file provided. Skipping workflow update step."
fi

# ---------- cleanup override file ----------
log "Cleaning up temporary override file ${OVERRIDE_FILE}"
rm -f "${OVERRIDE_FILE}"

log "Done. Built and pushed images with tag ${TAG}."
