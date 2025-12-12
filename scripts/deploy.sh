#!/bin/bash
# deploy.sh - Deploy Docker image to production
# Usage: ./deploy.sh <image> [app_dir] [service_name]

set -euo pipefail

# Arguments
IMAGE="${1:-}"
APP_DIR="${2:-/root/server}"
SERVICE_NAME="${3:-app}"

# Configuration
HEALTH_URL="http://127.0.0.1:8000/health"
HEALTH_RETRIES=15
HEALTH_WAIT=2

# Validate input
if [ -z "$IMAGE" ]; then
  echo "Usage: $0 <image> [app_dir] [service_name]"
  echo "Example: $0 username/app:abc1234 /root/server app"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Starting deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Image:   $IMAGE"
echo "App Dir: $APP_DIR"
echo "Service: $SERVICE_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Pull the new image
echo "📦 Pulling image..."
docker pull "$IMAGE"

# Create docker-compose override to pin the image
echo "📝 Creating docker-compose override..."
cat > "$APP_DIR/docker-compose.override.yml" <<EOF
version: "3.8"
services:
  ${SERVICE_NAME}:
    image: ${IMAGE}
    restart: unless-stopped
EOF

# Deploy with docker-compose
echo "🔄 Deploying containers..."
cd "$APP_DIR"
docker compose up -d --remove-orphans

# Health check
echo "🏥 Running health checks..."
n=0
until [ $n -ge $HEALTH_RETRIES ]
do
  status_code=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" || echo "000")
  if [ "$status_code" = "200" ]; then
    echo "✅ Health check passed!"
    break
  else
    n=$((n+1))
    echo "   Attempt $n/$HEALTH_RETRIES (status: $status_code) - retrying in ${HEALTH_WAIT}s..."
    sleep $HEALTH_WAIT
  fi
done

# Verify deployment
if [ "$status_code" != "200" ]; then
  echo "❌ Health check failed after $HEALTH_RETRIES attempts"
  echo ""
  echo "Container status:"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
  echo ""
  echo "Recent logs:"
  docker compose logs --no-color --tail=200
  exit 1
fi

# Cleanup
echo "🧹 Cleaning up unused images..."
docker image prune -f

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ Deployment completed successfully at $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

