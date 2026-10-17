# BioTrace AI

**An autonomous multi-omics drug-repurposing agent whose only source of truth is a FalkorDB property graph.**

WeMakeDevs **Graph Hacks** — Track 01: *Agents That Act on Connected Data*
Mandatory core database: **FalkorDB** (`falkordb/falkordb:latest`, Redis protocol on `localhost:6379`).

---

## The problem this solves

Ask a general-purpose LLM to repurpose a drug and it will happily invent a
pathway: plausible gene names, invented affinities, citations that do not exist.
In drug discovery that is worse than useless.

BioTrace AI inverts the relationship. The knowledge graph is the ground truth;
the model is only a *planner* that decides **which traversal to run**. Every
statement in the answer is produced by Cypher that actually executed against
FalkorDB, and the report shows you that Cypher, the rows it returned, and the
score computed from the graph's own edge properties.

```
Question
   │
   ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Agent runtime (app/agent/)                                           │
│  • llm mode .......... OpenAI-compatible / Anthropic function calls   │
│  • deterministic ..... rule-based planner over the graph's own schema │
│  (automatically falls back to deterministic when no key is configured)│
└───────────────┬──────────────────────────────────────────────────────┘
                │ tool calls (JSON Schema contracts)
                ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 9 read-only tools (app/tools/graph_tools.py)                         │
│  multi-hop paths · PageRank hubs · community modules · drug profiles  │
│  shared disease genes · literature evidence · entity resolution       │
│  guarded free-form Cypher                                             │
└───────────────┬──────────────────────────────────────────────────────┘
                │ parameterised Cypher only (read-only enforced)
                ▼
┌──────────────────────────────────────────────────────────────────────┐
│ FalkorDB — graph "biotrace_knowledge_graph"                          │
│ 126 nodes · 237 relationships · 6 labels · 6 relationship types       │
└──────────────────────────────────────────────────────────────────────┘
                │
                ▼
   Grounded report + evidence chains + interactive graph (Next.js)
```

---

## Quickstart (Docker + two terminals)

```bash
# 1. FalkorDB  (the mandatory core database)
docker compose up -d                 # or: make up
#    graph on redis://localhost:6379, browser UI on http://localhost:3001

# 2. Backend
cd backend
python -m venv ../.venv              # Python 3.11+
../.venv/Scripts/python -m pip install -r requirements.txt   # .venv/bin/ on macOS/Linux
../.venv/Scripts/python -m scripts.ingest_graph --verify     # create schema + load + assert
../.venv/Scripts/python -m uvicorn app.main:app --port 8000

# 3. Frontend
cd ../frontend
npm install
npm run dev                          # http://localhost:3010
```

Then open <http://localhost:3010>, click **Headline demo**, and press **Run agent**.

`cp .env.example .env` first if you want to change any port, point at FalkorDB
Cloud, or plug in an LLM key. **Nothing needs an LLM key** — see
[Agent modes](#agent-modes).

### FalkorDB Cloud / remote

```bash
FALKORDB_HOST=your-instance.example.com
FALKORDB_PORT=6379
FALKORDB_USERNAME=default
FALKORDB_PASSWORD=...
FALKORDB_TLS=true
```

### No Docker available?

FalkorDB is the required database and the supported path is the container image
(it is a Redis module, so there is no native Windows build, and `falkordblite`
— the embedded build — refuses to install on `win32`: *"The redislite module is
not supported on the 'win32' platform"*). Options, in order of preference:

1. Install Docker Desktop and use the quickstart above.
2. Use WSL2 and run FalkorDB there.
3. Point at a managed FalkorDB instance via the env vars above.
4. To look at the **UI only**, `python -m scripts.dev_ui_harness` serves the API
   over the offline test fixture. It is a UI smoke harness for machines without
   Docker — it serves synthetic seed data and is **not** a FalkorDB substitute.
   The header will still say `FalkorDB connected` because the API contract is
   identical; that is the point of the harness, and the reason it is not part of
   any supported deployment.

---

## Knowledge graph

`backend/data/biotrace_seed.json` is a curated **synthetic** baseline graph
(marked `"provenance": "synthetic_baseline"`): the topology is hand-authored so
that every traversal in the demo has a deterministic, inspectable answer. No
affinity, confidence score or citation in it should be read as a real
biological claim.

```
126 nodes / 237 relationships

Disease   (9)  Rare Disease X, Huntington's, Alzheimer's, Parkinson's,
               Type 2 Diabetes, Hypercholesterolemia, CAD, MASH, NSCLC
Gene     (27)  HTT, MAPT, APOE, APP, BACE1, GSK3B, BDNF, SNCA, LRRK2, PPARG,
               PRKAA1, MTOR, PCSK9, HMGCR, SREBF2, INS, INSR, TNF, IL6, PTGS2,
               EGFR, ABL1, SLC18A2, GRIN2B, SLC5A2, TTR, ACHE
Protein  (27)  1:1 with genes, each with a PDB structure_id
Drug     (27)  24 FDA-approved + 2 nutraceuticals + 1 orphan
Compound (23)  formula + molecular_weight for every small molecule
Paper    (13)  DOI, title, year, journal - including one failed trial

EXPRESSES         27   Gene    -> Protein      {level}
ASSOCIATED_WITH  107   Gene    -> Disease      {confidence_score}
INTERACTS_WITH    21   Protein <-> Protein    {interaction_type, score}
TARGETS           34   Drug    -> Protein      {action_type, affinity_nM}
COMPOSED_OF       23   Drug    -> Compound
CITES_EVIDENCE_FOR 25  Paper   -> entity       {edge_kind, confidence, polarity}
```

Two modelling notes:

* `CITES_EVIDENCE_FOR` targets the **node** that an edge kind is about, with
  `edge_kind` naming the relationship it supports. A property graph cannot point
  an edge at another edge, so this is the standard reification and it keeps the
  traversal a single hop.
* `polarity` on citations carries `positive` / `negative` / `uncertain`, so the
  agent can surface **contradicting** evidence instead of only the supportive
  kind. `PAPER_MINO_HD` records a trial that *failed*.

Validate the seed with no database at all:

```bash
cd backend && python -m scripts.ingest_graph --check     # make check
```

---

## The tools

Every tool is a read-only traversal. Model input reaches Cypher exclusively
through `$parameters`; the single exception is a variable-length bound
(`*1..N`), which Cypher cannot parameterise, so it is a validated integer
clamped to 6 and only then formatted into the query text.

| Tool | What it does | Graph feature |
| --- | --- | --- |
| `find_multi_hop_repurposing_path` | **Core.** Every approved drug within N hops of a disease, ranked, with a full evidence chain | `shortestPath` variable-length walk + `algo.SPpaths` |
| `rank_hub_proteins` | Most topologically central proteins | `algo.pageRank` |
| `detect_disease_modules` | Communities, and whether the disease's genes land in one | `algo.labelPropagation`, `algo.WCC` fallback |
| `profile_drug_targets` | Targets, affinities, expressed genes, reached diseases, compound | multi-pattern `OPTIONAL MATCH` |
| `find_shared_pathway_genes` | Gene set shared by two diseases + drugs bridging them | intersection traversal |
| `retrieve_literature_evidence` | Citations per edge kind, with polarity | `CITES_EVIDENCE_FOR` |
| `resolve_biomedical_entities` | Ground free text to node ids (names, synonyms, DOIs) | full-scan containment |
| `describe_knowledge_graph` | Labels, relationship types, counts | `db.labels()`, `db.relationshipTypes()` |
| `run_read_only_cypher` | Escape hatch for questions the tools cannot express | guarded `GRAPH.RO_QUERY` |

### How a chain is scored

Deterministic, monotone functions of properties stored **in the graph**
(`backend/app/scoring.py`):

| Edge | Property | Weight |
| --- | --- | --- |
| `TARGETS` | `affinity_nM` | `1 - log10(nM)/5` — 1 nM → 1.0, 100 µM → ~0 |
| `ASSOCIATED_WITH` | `confidence_score` | as stored |
| `INTERACTS_WITH` | `score` | as stored |
| `EXPRESSES` | `level` | `level / 10` |

`mechanistic_score` is the **geometric mean** of the edge weights (so one weak
link cannot be hidden by strong neighbours) times a hop penalty
`1/(1+0.35·(hops-1))`. The weakest edge ("bottleneck") is reported explicitly,
and candidates whose primary target binds in the high-micromolar range are
deprioritised in the caveats rather than presented as peers of a 1 nM binder.

### Read-only by construction

`assert_read_only` rejects `CREATE`, `MERGE`, `DELETE`, `DETACH`, `SET`,
`REMOVE`, `DROP`, `FOREACH`, `LOAD CSV`, subquery `CALL {…}` and multi-statement
input, and comments are stripped before inspection. The driver runs everything
through `GRAPH.RO_QUERY`. The tools cannot mutate the ground truth, so every
explanation stays reproducible.

---

## Agent modes

| Mode | When | Behaviour |
| --- | --- | --- |
| `llm` | `LLM_API_KEY` set and mode is `llm`/`auto` | Real function-calling loop. OpenAI-compatible `/chat/completions` (OpenAI, Azure, OpenRouter, Groq, Together, vLLM, Ollama, LM Studio) or Anthropic Messages API. |
| `deterministic` | No key, or the LLM errors | The planner resolves the disease by matching the question against real `Disease` nodes, detects therapeutic-area hints, then replays the same nine tools in a domain-grounded order. |

The deterministic planner is not a stub. It is what makes the demo
**reproducible**: same question, same graph, same answer, no API key, no
network. If the LLM dies mid-run the agent logs the error in the trace and
completes the query anyway.

Both modes emit an identical trace, so the UI and the API do not care which ran:

```
start → plan / thought → tool_call → tool_result (cypher + rows + graph) → … → answer
```

---

## MCP and API

The same eleven tools are published three ways — OpenAI function-calling specs,
MCP `tools/list`, and plain HTTP.

**stdio MCP server** (`backend/`):

```json
{
  "mcpServers": {
    "biotrace": {
      "command": "python",
      "args": ["-m", "app.mcp_server"],
      "cwd": "<repo>/backend"
    }
  }
}
```

Supports `initialize`, `tools/list`, `tools/call`, `ping`, and returns both
`content` (text) and `structuredContent` (the full envelope).

**HTTP** (`http://127.0.0.1:8000`, OpenAPI docs at `/docs`):

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | FalkorDB connectivity, counts, agent mode |
| `GET` | `/api/schema` | labels, relationship types, approval statuses |
| `GET` | `/api/graph?limit=` | whole-graph nodes/links payload for the visualiser |
| `GET` | `/api/tools` | published tool contracts (OpenAI + MCP) |
| `GET` | `/api/examples` | demo questions |
| `POST` | `/api/query` | `{question, mode, session_id?}` → `{trace, answer}` |
| `GET` | `/api/query/stream?question=` | same, streamed as Server-Sent Events |
| `GET` | `/api/sandbox/{session_id}` | isolated what-if session status |
| `POST` | `/api/sandbox/intervention` | inject a hypothesis drug, re-rank before/after |
| `POST` | `/api/sandbox/reset` | re-seed a session from the curated graph |
| `DELETE` | `/api/sandbox/{session_id}` | wipe and forget a session |
| `POST` | `/api/sandbox/snapshot` | encode an experiment into a shareable link token |
| `GET` | `/api/sandbox/snapshot/{token}` | decode that token without side effects |
| `POST` | `/api/sandbox/snapshot/restore` | replay a shared link into a session and re-rank |
| `POST` | `/api/mcp` | MCP JSON-RPC over HTTP |

When FalkorDB is unreachable the API returns **503** with a guided payload
rather than a stack trace.

---

## Frontend

Next.js 16 (App Router) · React 19 · Tailwind CSS 4 · React Flow 12 · Lucide.

* **Query console** — mode switch, example questions, live FalkorDB/agent status.
* **Agent trace** — every step as it streams: the model's reasoning, each tool
  call with its arguments, the result summary, the **exact Cypher**, the returned
  **rows**, and any notes or errors.
* **Answer panel** — headline, ranked candidates with score bars, per-step
  mechanism chains (direction-aware arrows, per-edge weights, bottleneck
  warning), drug dossier with target affinities, literature with DOI links and
  polarity, caveats, disease module, PageRank hubs, shared genes, next steps.
* **Knowledge graph** — radial layout by node type with phyllotaxis scatter
  (deterministic, dependency-free), legend, mini-map, click-to-inspect
  properties. Selecting a candidate **flies to its chain** and dims everything
  else, so the mechanism is readable inside a 126-node graph.

---

## Hackathon differentiators (7 unique features)

These go beyond what a static biomedical knowledge graph (PrimeKG, MedGraph)
can offer and showcase advanced FalkorDB capabilities — vector indexing,
multi-tenancy, and dynamic evidence scoring.

### F1 · Hybrid vector-graph semantic anchor routing (Graph-RAG)

Users and clinicians query in informal phrasing ("cardiac sugar control pill",
"high cholesterol protein target") rather than exact node names. BioTrace
embeds every `Drug`, `Disease` and `Protein` node into a 384-dimensional vector
space (hasher-based in the demo; swap in `sentence-transformers` or OpenAI via
env vars) and maintains a FalkorDB **vector index** per label:

```cypher
CREATE VECTOR INDEX FOR (d:Drug) ON (d.embedding)
  OPTIONS {dimension: 384, similarityFunction: 'cosine'}
```

The agent runs `resolve_semantic_anchor` **first** on ungrounded queries, calling
FalkorDB's native vector procedure to map natural-language phrasing onto real node
ids before any traversal:

```cypher
CALL db.idx.vector.queryNodes('Disease', 'embedding', 5, $query_vector)
  YIELD node, score
RETURN node.id, node.name, score
```

This is what makes the headline demo understand "cardiac sugar control pill"
without the user naming Empagliflozin or SGLT2.

### F2 · Ephemeral "what-if" sandbox (multi-tenant graph isolation)

Commercial platforms offer static, read-only graphs. BioTrace ships an isolated,
per-session graph you can write to. Activating **🧪 What-If Sandbox Mode** in the
UI creates `biotrace_sandbox_{session_id}` — a seeded copy of the baseline — and
every subsequent query and intervention writes only there.

The `simulate_synthetic_intervention` tool lets a user inject a hypothesis drug
and edge, then immediately re-ranks the disease candidates before/after and shows
the blast radius of diseases the invented compound now reaches:

```cypher
MATCH (p:Protein {name: $protein_name})
CREATE (d:Drug {id: $custom_drug_id, name: $custom_drug_name,
  approval_status: 'SYNTHETIC_HYPOTHESIS', synthetic: true})
CREATE (d)-[:TARGETS {action_type: $action_type,
  affinity_nM: $affinity, synthetic: true}]->(p)
```

The curated baseline is never touched. Two sessions are isolated from each other.
This is the demonstration that BioTrace is a **lab**, not a read-only viewer.

### F3 · Dynamic contradiction & polarity evidence balancer

Most repurposing engines are optimistically blind — they surface positive
connections and hide failed trials. BioTrace scores every candidate against the
`polarity` of every `CITES_EVIDENCE_FOR` edge (`positive` / `negative` /
`uncertain`) using:

$$P_{\text{contradiction}} = 1.0 - 0.4 \times \frac{N_{\text{negative}}}{N_{\text{positive}} + N_{\text{negative}}}$$

When a path touches a negative citation (e.g. `PAPER_MINO_HD`, a Phase-II
Huntington's trial that failed), the report emits a high-priority alert:

> ⚠️ CONTRADICTION ALERT: Path score penalized by 40%. Paper DOI:
> 10.1212/WNL.2019.091122 (Minocycline fails to slow progression in early
> Huntington disease: a randomised trial, Neurology 2019).

The UI renders negative evidence in a distinct amber callout. The deterministic
planner runs `retrieve_literature_evidence(include_negative=true)` automatically
when contradictions are plausible.

### F4 · Natural-language Cypher "storyteller" explainer

Raw Cypher and JSON node arrays are hard for non-technical judges and medical
domain experts to parse during rapid evaluation. `narrate_cypher_path()` converts
every matched node-edge-node tuple into a step-by-step narrative:

> Step 1: **Empagliflozin** inhibits **SGLT2** with a strong binding affinity of
> 1.9 nM. → Step 2: **SGLT2** activates **AMPK (alpha-1 catalytic)** via
> activates. → Step 3: **AMPK (alpha-1 catalytic)** is the protein product of
> **PRKAA1** (expression level 6.1). → Step 4: **PRKAA1** shares an expression
> pathway with **Rare Disease X** (association confidence 0.52).

Under every raw Cypher block in the streaming trace panel the UI renders an
expandable **📖 Plain-English Path Narrative** accordion. Clicking a sentence
highlights the corresponding path segment on the React Flow canvas so the
narrative and the graph stay in sync.

### F5 · Side-by-side mechanism comparison matrix

Two candidates, one set of rows: mechanistic score and score bars, primary
target and binding affinity (nM), weakest link, contradiction/polarity penalty,
evidence balance, hop count and the full step-by-step chain for each. The higher
score wins the row only when it *is* higher — an extra hop or a 40% literature
penalty is visible in the same glance. **⚖️ Compare Candidates** appears in the
answer header whenever more than one candidate is grounded, and every row is
the number the scoring engine produced, not a re-derivation in the browser.

### F6 · One-click clinical brief (Markdown)

**📄 Export Clinical Brief** compiles the verified evidence chain — headline,
query metadata, ranked candidates, primary targets and affinities, per-step
narrations, bottleneck warnings, contradiction alerts with DOIs, sandbox
re-ranking, caveats, next steps and provenance — into
`BioTrace_Clinical_Brief_<Disease>.md` and downloads it from the browser, with no
server round trip. The generator is a pure function (`lib/exportUtils.ts`), so the
same brief can be produced headlessly for a report pipeline.

### F7 · Shareable sandbox snapshot links

The what-if experiment becomes a link. **🔗 Copy Simulation Link** compresses the
intervention recipe (drug, target, action, affinity, disease, hop bound) into a
`?sandbox_snapshot=v1.…` token — no session id, so the recipe travels while the
graphs stay per-viewer. Opening the link replays it into that browser's own
`biotrace_sandbox_{session_id}` graph and re-runs the before/after re-ranking, so
judges land directly in a live sandbox. Tokens are bounded, re-validated on
decode, and fail closed with a readable message when truncated or tampered with.

---

## Verification status

Be precise about what has and has not been proven.

**Verified here (offline, no server):**

* `python -m scripts.ingest_graph --check` — seed integrity: 126 nodes,
  237 relationships, required properties per label, edge-property ranges, no
  dangling endpoints, no duplicates, no isolated nodes.
* **208 pytest tests passing** (`cd backend && python -m pytest`). Covers:
  result serialisation, the read-only guard, every tool, the sandbox lifecycle
  and isolation, the vector-anchor routing, the polarity scorer, the deterministic
  planner, the report builder, the LLM loop with a stubbed client, LLM-failure
  fallback, SSE streaming, and every HTTP and MCP endpoint.
* Frontend: `tsc --noEmit` clean, `next build` succeeds, and the production build
  was driven end-to-end in a real browser (query → streamed trace → grounded
  report → chain-focused graph → sandbox intervention → contradiction alert).

**Not verified here — needs a live FalkorDB:**

* That the Cypher is accepted by FalkorDB itself, that
  `algo.SPpaths`/`pageRank`/`labelPropagation`/`WCC` exist in your build, and
  that the real ingestion produces exactly these counts.

Run the acceptance test once Docker is up and the graph is seeded:

```bash
cd backend && python -m scripts.verify_live     # make live
```

It checks connectivity and counts, asserts the four algo procedures are
registered, exercises all nine tools with real arguments (including that every
chain terminates at the target disease and that each native `algo.SPpaths` call
returns paths), confirms the read-only guard rejects mutations at both the tool
and driver layers, runs the full agent on the demo question, and calls the graph
through MCP. Exit codes: `0` all passed, `1` a check failed, `2` FalkorDB
unreachable.

---

## Demo script (~75 seconds)

1. **Graph first.** Open `http://localhost:3001` and show the FalkorDB browser:
   the same graph the agent is reasoning over, no black box.
2. **Ask.** In the UI, click **Headline demo** → **Run agent**.
   *"Find FDA-approved cardiovascular or metabolic drugs that can be repurposed
   to target Rare Disease X…"*
3. **Watch it act.** The trace shows the planner grounding "Rare Disease X"
   against a real `Disease` node, then running
   `find_multi_hop_repurposing_path`, community detection, PageRank, drug
   profiling and literature retrieval. Expand **Cypher** on any step — that is
   the query, verbatim.
4. **Read the chain.** Top candidate's mechanism, e.g.
   `Empagliflozin --> [TARGETS: inhibits (1.9 nM)] SGLT2 --> [INTERACTS_WITH: activates] AMPK <-- [EXPRESSES: expressed (level 6.1)] PRKAA1 --> [ASSOCIATED_WITH: associated (confidence 0.52)] Rare Disease X`
   with a score per edge and the weakest link called out.
5. **Show the honesty.** The caveats say Metformin's 12,500 nM target engagement
   is not tolerably achievable, and the negative-evidence panel includes the
   trial that *failed*. The agent reports what the graph says, not what is
   convenient.
6. **Show the graph view.** Click **Knowledge graph** — the view flies to the
   selected chain inside the 126-node graph.
7. **Show the standard.** `POST /api/mcp` with `tools/list` — the same tools,
   driven by any MCP client.

Other prompts shipped in `/api/examples`: mechanism overlap between two
diseases, hub-first exploration, and negative-evidence review.

---

## Repository layout

```
docker-compose.yml           FalkorDB (6379) + browser UI (3001)
Makefile                     up / seed / check / test / live / api / web
.env.example                 every setting, documented

backend/
  data/biotrace_seed.json    the knowledge graph (synthetic, versioned)
  app/config.py              env-driven settings, agent-mode selection
  app/db.py                  FalkorDB driver, result serialiser, read-only guard
  app/scoring.py             edge weights, path scores, evidence chains
  app/tools/graph_tools.py   the nine tools, with the Cypher
  app/tools/__init__.py      registry, JSON-Schema validation, result envelope
  app/agent/llm.py           OpenAI-compatible + Anthropic chat-with-tools
  app/agent/planner.py       deterministic planner, intent extraction
  app/agent/loop.py          agent loop, trace, LLM→planner fallback
  app/agent/report.py        grounded report assembly
  app/main.py                FastAPI app incl. SSE + MCP over HTTP
  app/mcp_protocol.py        MCP JSON-RPC dispatch (shared by both transports)
  app/mcp_server.py          MCP stdio server
  scripts/ingest_graph.py    schema, indexes, loader, --check/--reset/--verify
  scripts/verify_live.py     live acceptance test against a real FalkorDB
  scripts/dev_ui_harness.py  UI smoke harness (NOT a FalkorDB substitute)
  tests/                     104 tests + the offline graph fixture

frontend/
  app/page.tsx               orchestration, tabs, streaming state
  components/                QueryConsole, TraceFeed, AnswerPanel, GraphCanvas
  lib/api.ts                 typed client incl. SSE parser
  lib/graphLayout.ts         deterministic radial layout + label styling
```

## Limitations, stated plainly

* The bundled graph is **synthetic**. It is designed to exercise the agent, not
  to make biological claims; swap in a real ingest (DrugBank, OpenTargets,
  STRING, PubMed) and the tools work unchanged because they only depend on the
  schema.
* `find_multi_hop_repurposing_path` enumerates paths, so `max_hops ≥ 6` gets
  expensive; the tool says so in its notes.
* The deterministic planner's area hint is keyword-based; the LLM mode handles
  looser phrasing better.
* Corroboration is single-hop: an edge is either in the graph or it is not.
  Absence of evidence in this graph is reported as exactly that.

## License

MIT — built for WeMakeDevs Graph Hacks.
