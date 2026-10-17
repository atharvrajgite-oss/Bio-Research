# BioTrace AI - convenience targets.
#
# FalkorDB is the mandatory core database; `make up && make seed` is the
# supported way to run everything.
#
#   make up          start FalkorDB (docker compose)
#   make seed        create schema + load the knowledge graph, then verify
#   make check       validate the seed without touching a database
#   make test        run the offline test suite (208 tests, no FalkorDB needed)
#   make live        run the live acceptance test (needs FalkorDB up + seeded)
#   make api         run the FastAPI backend
#   make web         run the Next.js frontend
#   make down        stop FalkorDB
#
# The 4 hackathon differentiators live in:
#   F1 vector anchor routing .... app/tools/graph_tools.py:resolve_semantic_anchor
#   F2 sandbox .................. app/sandbox.py + app/tools/graph_tools.py:simulate_synthetic_intervention
#   F3 polarity balancer ........ app/scoring.py + app/tools/graph_tools.py:retrieve_literature_evidence
#   F4 storyteller .............. app/agent/report.py:narrate_cypher_path
#
# On Windows without `make`, run the same commands from backend/ and frontend/.

PY ?= .venv/Scripts/python.exe
PY_UNIX ?= .venv/bin/python

ifeq ($(OS),Windows_NT)
PYTHON := $(PY)
else
PYTHON := $(PY_UNIX)
endif

.PHONY: help up down seed check test live api web install build

help:
	@grep -E '^#   ' $(MAKEFILE_LIST) | sed 's/^#   //'

up:
	docker compose up -d
	@echo "FalkorDB starting. Browser UI: http://localhost:3001"

down:
	docker compose down

seed:
	cd backend && ../$(PYTHON) -m scripts.ingest_graph --verify

check:
	cd backend && ../$(PYTHON) -m scripts.ingest_graph --check

test:
	cd backend && ../$(PYTHON) -m pytest

live:
	cd backend && ../$(PYTHON) -m scripts.verify_live

api:
	cd backend && ../$(PYTHON) -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000

web:
	cd frontend && npm run dev

install:
	cd backend && python -m venv ../.venv && ../$(PYTHON) -m pip install -r requirements.txt
	cd frontend && npm install

build:
	cd frontend && npm run build
