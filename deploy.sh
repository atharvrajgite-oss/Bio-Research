#!/usr/bin/env bash
set -euo pipefail

# BioTrace AI — single-VM production deploy.
#
# Usage:
#   ./deploy.sh                        # use localhost defaults
#   VM_HOST=203.0.113.10 ./deploy.sh  # tell the frontend where its backend lives
#
# After the stack is up, seed the graph once:
#   docker compose -f docker-compose.prod.yml exec backend \
#     python -m scripts.ingest_graph --verify

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"

VM_HOST="${VM_HOST:-localhost}"
export VM_HOST

echo "==> Using compose file: ${COMPOSE_FILE}"
echo "==> VM_HOST=${VM_HOST}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not available on PATH." >&2
  exit 2
fi

if ! docker compose -f "${COMPOSE_FILE}" version >/dev/null 2>&1; then
  echo "ERROR: docker compose failed to parse ${COMPOSE_FILE}." >&2
  exit 2
fi

# Clean up any previous stack using the same compose file before starting a fresh
# build. This is deliberate for a single-VM deploy so a rebuild replaces the old
# containers/images instead of leaving orphaned ones.
if docker compose -f "${COMPOSE_FILE}" ps --quiet >/dev/null 2>&1; then
  echo "==> Stopping existing stack (if any)..."
  docker compose -f "${COMPOSE_FILE}" down --remove-orphans
fi

echo "==> Building images..."
docker compose -f "${COMPOSE_FILE}" build

echo "==> Starting stack..."
docker compose -f "${COMPOSE_FILE}" up --build -d

echo ""
echo "==> Waiting for services to start..."
sleep 3
docker compose -f "${COMPOSE_FILE}" ps --format "table {{ .Name }}\t{{ .Status }}\t{{ .Ports }}"

echo ""
echo "==> Quick status checks"
docker compose -f "${COMPOSE_FILE}" ps --quiet | while read -r cid; do
  if [ -n "$cid" ]; then
    echo "  container $cid:"
    docker logs "$cid" --tail 5 2>/dev/null || true
  fi
done

echo ""
echo "==> Expected endpoints once the VM firewall allows them:"
echo "   FalkorDB browser UI : http://${VM_HOST}:3001"
echo "   Backend API         : http://${VM_HOST}:8000"
echo "   Frontend app        : http://${VM_HOST}:3010"
echo ""
echo "Next step: seed the knowledge graph once FalkorDB is up:"
echo "   docker compose -f ${COMPOSE_FILE} exec backend python -m scripts.ingest_graph --verify"
