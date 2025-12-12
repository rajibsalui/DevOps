#!/bin/bash
# deploy.sh
# Usage: ./deploy.sh <image>
# Example: ./deploy.sh yourdockeruser/my-express-app:abc1234

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <image>"
  exit 1
fi

IMAGE="$1"
APP_DIR="/root/server"   # <-- path where docker-compose.yml lives
SERVICE_NAME="app"             # should match service name in docker-compose.yml
HEALTH_URL="http://127.0.0.1:8000/health"
HEALTH_RETRIES=15
HEALTH_WAIT=2

echo "Starting deploy: pulling image $IMAGE"
# Pull image (use sudo if needed)
docker pull "$IMAGE"

# Create override compose file to pin the image for the service
cat > "$APP_DIR/docker-compose.override.yml" <<EOF
version: "3.8"
services:
  ${SERVICE_NAME}:
    image: ${IMAGE}
    restart: unless-stopped
EOF

echo "Using docker-compose in $APP_DIR to (re)create containers"
cd "$APP_DIR"

# Bring up containers (will update running service with pinned image)
docker compose up -d --remove-orphans

# Wait for health endpoint to respond 200 (basic check)
echo "Waiting for health check at $HEALTH_URL"
n=0
until [ $n -ge $HEALTH_RETRIES ]
do
  status_code=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" || echo "000")
  if [ "$status_code" = "200" ]; then
    echo "Health check passed"
    break
  else
    n=$((n+1))
    echo "Health check attempt $n/$HEALTH_RETRIES — status: $status_code — sleeping ${HEALTH_WAIT}s"
    sleep $HEALTH_WAIT
  fi
done

if [ "$status_code" != "200" ]; then
  echo "ERROR: Health check failed after $HEALTH_RETRIES attempts. See 'docker ps' and logs."
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
  docker compose logs --no-color --tail=200
  exit 1
fi

echo "Cleaning up unused images"
docker image prune -f

echo "Deployment finished at $(date)"
