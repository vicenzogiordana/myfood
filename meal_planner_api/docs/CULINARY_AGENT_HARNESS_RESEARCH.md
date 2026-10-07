# Research: Harness Options for the Culinary Agent (Issue #82)

**Status:** Research input. No candidate is selected or ranked here.
**Date:** 2026-10-07
**Feeds:** Wayfinder map #80; later prototype and decision issues.

## 1. Scope, pinned revisions, method, limits

### Question

Which capabilities, integration boundaries, and tradeoffs do (a) adapting Pi components, (b) forking Pi, (c) an Elixir-native harness with or without LangChain, and (d) a hybrid architecture offer for a bounded culinary-agent loop (investigate recipes and prices, invoke the OR-Tools optimizer, evaluate proposals, refine, ask the user about real conflicts, preserve every hard constraint)?

### Pinned revisions

| Subject | Revision observed |
|---|---|
| MyFood | `a364c7a5ef2a52a155685129086ca9537618265a` (branch `feat/issue-38-recipe-lifecycle`) |
| MyFood `origin/main` | `cf97d607e7ab34b96184e74c94d755883ea58773`, the merge commit of PR #77 that contains `a364c7a`. `git diff --stat origin/main HEAD` is empty, so the inventory in section 6 applies to both. |
| Pi | tag `v1.0.4` → commit `7c10bd4337495ee613f2224843ecdf349b80d1df`, release published 2026-10-05T22:03:50Z. `main` at read time: `27c7b6ff48ccca57694a960e4af10529f77deae6` (2026-10-07T13:02:59Z). |
| OpenCode | tag `v1.18.35` → `53d1eabb61e21162157817bf677da0a4ad3332e3`, released 2026-10-06 |
| Claude Agent SDK | TypeScript `0.3.292` (2026-10-06), Python `0.2.164` (2026-10-06) |
| LangChain (Elixir) | `0.15.0` → tag commit `e7520c0a397fc1503854b5432414c29e0a028e5b`, hex release 2026-10-05 |
| ReqLLM | `1.26.0`, hex release 2026-09-29 |

### Claim labels

Every claim carries one of:

- **[F]** Documented fact, with the source that owns it.
- **[E]** Estimate, with the reasoning.
- **[U]** Unknown: not established in this session.
- **[P]** Needs prototype evidence.

### Method

- External: repository contents and manifests through the GitHub API at the tags above, the npm registry, hex.pm and PyPI APIs, and the official documentation pages. No blog posts or secondary write-ups were used.
- Internal: direct reads of the pinned checkout with `path:line` citations (paths are relative to `meal_planner_api/` unless they start with `../`).

### Limits

- One session. Nothing was installed, compiled, or run; no dependency resolution was attempted.
- The CodeGraph index returned only Python symbols for the AI-layer query, so the Elixir inventory was done with `rg` and direct file reads.
- Three documentation pages (OpenCode server, Agent SDK overview and hosting, LangChain hexdocs) were read through a fetch tool that summarises pages with a small model. Quoted sentences from those pages are reproduced as that tool returned them and were not byte-checked against the HTML.
- Pi source files (`.ts`) were not read; Pi findings come from READMEs, docs, and `package.json` files at `v1.0.4`.
- No latency, memory, or cost was measured. Every number in this document is a vendor-documented figure or is labelled otherwise.

---

## 2. Pi: identity, lineage, layers

### 2.1 Identity verdict

**`earendil-works/pi` is the canonical repository; `badlogic/pi-mono` is the same repository under its former owner and name, not a fork or a predecessor project.** Evidence:

- **[F]** `https://github.com/badlogic/pi-mono` answers `HTTP 301` with `location: https://github.com/earendil-works/pi`. The GitHub API call for `repos/badlogic/pi-mono` returns the `earendil-works/pi` object with `fork: false` and the same `created_at` (2025-08-09T14:03:50Z).
- **[F]** `LICENSE` at the repository root reads `MIT License / Copyright (c) 2025 Mario Zechner`. The earliest commits (for example `5bbaaa0`, 2025-08-11) are authored by Mario Zechner. `badlogic` is his GitHub and npm handle per the npm maintainer lists below.
- **[F]** npm, old scope: `@mariozechner/pi-ai`, `@mariozechner/pi-agent-core`, `@mariozechner/pi-coding-agent` stop at `0.73.1` (last modified 2026-05-07), declare `repository: github.com/badlogic/pi-mono`, and are deprecated with the message "please use @earendil-works/pi-ai instead going forward" (and the equivalent per package). Maintainers: `badlogic`, `mitsuhiko`.
- **[F]** npm, new scope: `@earendil-works/pi-ai`, `-agent-core`, `-coding-agent` were created 2026-05-07, declare `repository: github.com/earendil-works/pi`, have 57 versions, latest `1.0.4`. Maintainers: `mitsuhiko`, `badlogic`, `rwachtler`.
- **[F]** The repository is owned by the GitHub organization `earendil-works`; the README points to `pi.dev`, `rfc.earendil.com`, and `security@earendil.com`.

Lineage as established: Mario Zechner's `badlogic/pi-mono` (2025-08) → published as `@mariozechner/pi-*` up to `0.73.1` → repository transferred to `earendil-works/pi` and packages re-scoped to `@earendil-works/pi-*` on 2026-05-07 → `v1.0.0` on 2026-10-01 → `v1.0.4` on 2026-10-05.

- **[U]** The first version number published under the new scope, and whether any release was skipped across the rename.
- **[U]** The legal relationship between Earendil and the original author beyond the unchanged copyright line.

### 2.2 Release cadence

- **[F]** 327 tags exist. Eight releases were published between 2026-09-29 (`v0.99.0`) and 2026-10-05 (`v1.0.4`), five of them after `v1.0.0` in four days (`gh release list`).
- **[E]** `1.0.0` is six days old at the time of writing, so no evidence exists yet about post-1.0 API stability. Reasoning: there is no elapsed time to observe.

### 2.3 License and dependencies

- **[F]** Every inspected package (`pi-ai`, `pi-agent-core`, `pi-coding-agent`, `pi-server`, `pi-protocol`, `pi-client`, `pi-durable`, `pi-mcp`, `pi-codemode`, `pi-env`) declares `"license": "MIT"` and `engines.node >= 22.19.0` in its `package.json` at `v1.0.4`.
- **[F]** `pi-ai` direct dependencies: `@anthropic-ai/sdk 0.129.0`, `@aws-sdk/client-bedrock-runtime 3.1127.0`, `@google/genai 2.21.0`, `openai 7.19.0`, `@smithy/node-http-handler`, `http-proxy-agent`, `https-proxy-agent`, `partial-json`, `typebox 1.3.27`, `@earendil-works/pi-telemetry`. Versions are exact pins.
- **[F]** `pi-agent-core` depends only on `pi-ai` and `typebox`.
- **[F]** `pi-durable` depends on `@earendil-works/chord`, `pi-ai`, `diff`, `typebox`.
- **[F]** `pi-coding-agent` adds `chord`, `pi-tui`, `pi-mcp`, `pi-codemode`, `quickjs-wasi`, `undici`, `jiti`, `cross-spawn`, `@silvia-odwyer/photon-node`, `highlight.js`, and others.
- **[U]** The licenses of the transitive tree were not audited (no install was performed).

### 2.4 Layer breakdown

| Layer | Package | What the docs say it is | Separable from the coding runtime? |
|---|---|---|---|
| Model/provider | `@earendil-works/pi-ai` | "Unified multi-provider LLM API". Streaming, tool definitions with TypeBox schemas and argument validation, abort via `AbortSignal` (`stopReason === 'aborted'`), cross-provider handoff, a faux provider for tests. | **[F]** Yes; it has no dependency on the other Pi packages except telemetry. |
| Agent loop/tools | `@earendil-works/pi-agent-core` | "Stateful agent with tool execution and event streaming". `Agent` class and low-level `agentLoop()`. | **[F]** Yes; depends only on `pi-ai` and `typebox`. No built-in tools. |
| Durable session | `@earendil-works/pi-durable` | "A durable agent harness. Conversations, model turns, tool calls, and your own state are committed to storage before anything is shown." | **[F]** Separate package, built on `pi-ai` and `chord`, not on `pi-agent-core`. Marked "**Experimental.** The API changes without notice between releases." |
| Remote sessions | `pi-server`, `pi-protocol`, `pi-client` | "Experimental local server that routes clients to application-hosted durable Sessions"; CBOR framing over a Unix socket. | **[F]** Separate, experimental. "peer authentication remains application policy and is not implemented by the experimental Unix transport." |
| Coding runtime | `@earendil-works/pi-coding-agent` | CLI with read, bash, edit, write tools, JSONL sessions, extensions, skills, TUI. Exposes an in-process SDK (`createAgentSession`) and a subprocess RPC mode (`pi --mode rpc`). | This is the complete runtime; it is what "forking Pi" would most naturally target. |
| TUI | `@earendil-works/pi-tui` | Terminal UI library. | Not relevant to a server-side agent. |
| Tool adapters | `pi-mcp`, `pi-codemode` | MCP client; QuickJS-WASI sandbox "where the only capability is calling injected tools". | **[F]** Standalone packages. |

Capabilities relevant to the comparison, all from the `v1.0.4` READMEs:

- **Tool execution.** **[F]** `pi-agent-core` tools are `AgentTool` objects with a TypeBox `parameters` schema and `execute(toolCallId, params, signal, onUpdate)`. Execution is `"parallel"` by default, `"sequential"` globally or per tool. `beforeToolCall` runs after argument validation and "Can block execution"; `afterToolCall` can rewrite results; either can request termination. Thrown errors become tool results with `isError: true`.
- **Loop control.** **[F]** `prepareRequest` can rebuild the context before every provider request; `finishTurn` can force continue or end; `steer()` and follow-up queues inject user input mid-run.
- **Cancellation.** **[F]** `agent.abort()` cancels the current operation; tools receive an `AbortSignal`. In `pi-durable`, `conversation.abort()` withdraws queued inputs and aborts every task of the current work.
- **History serialization.** **[F]** `pi-ai`: "The `Context` object can be easily serialized and deserialized using standard JSON methods." `pi-coding-agent` persists a JSONL entry tree through `SessionManager`, which is "authoritative for finalized model context". `pi-durable` stores immutable entries, typed documents, and task checkpoints.
- **Persistent state.** **[F]** `pi-durable` backends: memory, SQLite (WAL, `synchronous = NORMAL`), JSONL. "One process owns a storage at a time; there is no cross-process locking." A custom backend must implement a promise-based SQLite facade or a `FileSystem`, and a conformance suite is shipped. **[U]** No PostgreSQL backend is documented.
- **Crash semantics.** **[F]** `pi-durable`: a tool's "intent is committed before `execute()` runs. If the process dies mid-call, the tool reruns on reopen only when it is declared `replay: \"safe\"`; otherwise the model gets an `interrupted` error result". Submissions are idempotent by `requestId`.
- **Provider portability.** **[F]** The `pi-ai` README lists more than thirty providers including Google (Gemini API), Vertex AI, Anthropic, OpenAI, Amazon Bedrock, Mistral, Groq, OpenRouter, and "Any OpenAI-compatible API". Custom providers are supported through `createProvider()`.
- **Streaming.** **[F]** Event stream with `message_update` deltas; partial-JSON streaming of tool-call arguments.
- **Language-neutral control.** **[F]** `pi --mode rpc` speaks strict LF-delimited JSONL on stdin/stdout: commands, `response` records, session events, extension-UI records. `agent_settled` marks that no automatic continuation follows. "Pi honors stdout backpressure, but a client that stops reading can stall the process."
- **Security posture.** **[F]** README: "Pi does not include a built-in permission system for restricting filesystem, process, network, or credential access." `SECURITY.md` lists as out of scope: "Local code execution or sandboxing behavior (the Pi coding agent intentionally does not have a sandbox)", "Prompt injection attacks", and "Public internet exposure of a Pi installation".
- **Contribution model.** **[F]** README: "New issues and PRs from new contributors are auto-closed by default. Maintainers review auto-closed issues daily."
- **Footprint.** **[F]** `pi-durable` README: loading TypeBox "costs about 23 MB of peak RSS unbundled, about 4 MB in a tree-shaken bundle." **[U]** Whole-process memory for an embedded agent was not documented in the files read.

### 2.5 "Adapt components" versus "fork"

- **[F]** Adapting means depending on published MIT packages (`pi-ai`, optionally `pi-agent-core` or `pi-durable`) from a Node process. No Pi code would be modified.
- **[F]** Forking is permitted by MIT. A fork of the monorepo carries 14 packages (`packages/` listing at `v1.0.4`), including the TUI and coding tools that a meal-planning agent does not use.
- **[E]** A fork must track an upstream that shipped eight releases in seven days around 1.0; merge cost is proportional to how many packages are touched. Reasoning: release list above. The actual conflict rate is **[P]**.
- **[E]** Upstreaming MyFood-specific changes is uncertain given the auto-close policy for new contributors. Reasoning: README statement above.

---

## 3. Comparators (not assumed dependencies)

### 3.1 OpenCode server

- **[F]** Repository: the API name `sst/opencode` resolves to `anomalyco/opencode`; MIT (`LICENSE`: "Copyright (c) 2025 opencode"); `v1.18.35` released 2026-10-06. npm `opencode-ai@1.18.35` ships per-platform binaries as `optionalDependencies`.
- **[F]** `https://opencode.ai/docs/server/`: `opencode serve [--port] [--hostname] [--cors]`, defaults `127.0.0.1:4096`. HTTP basic auth through `OPENCODE_SERVER_PASSWORD` and `OPENCODE_SERVER_USERNAME`. OpenAPI 3.1 spec at `/doc`.
- **[F]** Same page: "When you run `opencode` it starts a TUI and a server. Where the TUI is the client that talks to the server."
- **[F]** Endpoints include `POST /session/:id/message`, `POST /session/:id/abort`, SSE at `GET /event` and `GET /global/event`, `GET /mcp` and `POST /mcp`. Tool listing endpoints are under `/experimental/tool`.
- **[U]** Session storage mechanism, custom-tool registration over HTTP (beyond MCP), and multi-tenant isolation are not described on that page.

What the comparison shows: a coding agent exposed as an HTTP/SSE server with an OpenAPI contract is an existing pattern for a language-neutral boundary. It is a whole coding runtime behind that boundary, as Pi's RPC mode is.

### 3.2 Claude Agent SDK

- **[F]** `https://code.claude.com/docs/en/agent-sdk/overview` (the `platform.claude.com` URL redirects there): Python and TypeScript; "A library that runs the Claude Code binary, with Claude Code's capabilities, such as built-in tools, permissions, sessions, and hooks."
- **[F]** Hosting page (`/agent-sdk/hosting`): "The Agent SDK spawns and supervises a `claude` CLI subprocess that owns a shell, a working directory, and session files on disk." "One agent session maps to one subprocess." Transcripts default to `~/.claude/projects/`; a `SessionStore` adapter mirrors them to external storage, and "Mirror writes are best-effort".
- **[F]** Same page: "1 GiB RAM, 5 GiB disk, and 1 CPU per agent is a reasonable starting point". "No top-level session timeout" is listed as a known limitation; `maxTurns` bounds the loop.
- **[F]** Same page: network access goes "to `api.anthropic.com`, or to your provider's regional endpoint when running on Amazon Bedrock or Google Cloud's Agent Platform". **[E]** The pages read document only Claude models; MyFood's configured provider is Gemini (`config/runtime.exs:69`), so this comparator implies a provider change. Reasoning: no non-Claude model path appears in the overview or hosting pages.
- **[F]** License: npm `@anthropic-ai/claude-agent-sdk@0.3.292` declares `"SEE LICENSE IN README.md"`; the repository `LICENSE.md` reads "© Anthropic PBC. All rights reserved. Use is subject to Anthropic's Commercial Terms of Service". The Python package declares MIT on PyPI, and the docs state that use "is governed by Anthropic's Commercial Terms of Service ... except to the extent a specific component or dependency is covered by a different license".
- **[F]** For other languages the overview says to "run the CLI as a subprocess with the `-p` flag and `--output-format json`".

What the comparison shows: a documented production model for "agent runtime as supervised subprocess per session", with explicit per-session resource figures, explicit multi-tenant hazards (settings and memory files leaking across tenants), and a mirror-style session store.

---

## 4. Elixir-native options

### 4.1 With LangChain

- **[F]** hex.pm: `langchain 0.15.0`, released 2026-10-05, license `Apache-2.0`, repository `brainlid/langchain`. `0.14.3` (2026-09-24) and `0.14.4` (2026-09-30) precede it. The repository `LICENSE` begins "Copyright (c) 2023-present Mark Ericksen / Licensed under the Apache License, Version 2.0". (The GitHub API reports `NOASSERTION` for the license field; the hex metadata and the file text are the evidence used.)
- **[F]** Release requirements (hex API): Elixir `~> 1.17`. Required: `req >= 0.5.3`, `ecto ~> 3.10 or ~> 3.11`, `gettext`, `dotenvy`. Optional: `req_llm >= 1.11.0`, `nx`, `abacus`, `mint_web_socket`, `nimble_parsec`, `opentelemetry_api`.
- **[F]** `LLMChain` (hexdocs, v0.15.0): described as "The heart of the LangChain library". Struct fields include `llm`, `messages`, `last_message`, `exchanged_messages`, `tools`, `delta`, `callbacks`, `custom_context`, `max_retry_count`, `async_tool_timeout`, `message_processors`.
- **[F]** Run modes: `:while_needs_response`, `:until_success`, `:step`, and custom modules implementing `LangChain.Chains.LLMChain.Mode`; `run_until_tool_used/3`.
- **[F]** Loop bound: `max_runs` defaults to 25; exceeding it returns `%LangChainError{type: "exceeded_max_runs"}`.
- **[F]** Tools: functions defined with `async: true` "execute in parallel using Elixir's `Task.async/1`", bounded by `async_tool_timeout` (library default `:infinity`). `custom_context` is passed to tool functions.
- **[F]** Fallbacks: `:with_fallbacks` takes a list of fallback chat models, with a `before_fallback` hook; total failure returns `%LangChainError{type: "all_fallbacks_failed"}`.
- **[F]** Validation: message processors return `{:cont, message}` or `{:halt, chain, error_message}`; `:until_success` retries up to `max_retry_count`.
- **[F]** Cancellation: `cancel_delta/2,3` "Remove an incomplete MessageDelta from `delta` and add a Message with the desired status to the chain." **[U]** No function that cancels a whole multi-step run was found on the page; in an OTP design that would be done by terminating the owning process.
- **[F]** Persistence: the fetched `LLMChain` page documents no built-in transcript persistence. Chat models expose `serialize_config/1` and `restore_from_map/1` for model configuration.
- **[F]** Providers (`lib/chat_models/` at `main`): Anthropic, AWS Mantle, Bumblebee, DeepSeek, Google AI, Grok, Mistral, Ollama, OpenAI (Chat Completions and Responses), OpenAI-compatible, Orq, Perplexity, ReqLLM adapter, Vertex AI.
- **[F]** `ChatGoogleAI` (hexdocs, v0.15.0): tool calling with "a select subset of an OpenAPI 3.0 schema object", streaming, structured JSON output, `thinking_config`, Google Search as a native tool. README: Gemini context caching "requires a separate call which is not supported by Langchain."
- **[F]** README also describes `LangChain.Trajectory` for evaluating agent tool-call paths.
- **[E]** Dependency fit with MyFood: the lock already has `req 0.7.4` and `ecto 3.13.5` (`mix.lock:44`, `mix.lock:13`), which satisfy the stated ranges; `gettext` and `dotenvy` are not in the lock and would be added. `mix.exs:9` declares `elixir: "~> 1.15"` while LangChain needs `~> 1.17`; the local toolchain is Elixir 1.20.2. Reasoning: version-range arithmetic only. Actual resolution is **[P]** (`mix deps.get` was not run).
- **[E]** Version risk: pre-1.0 with three releases in twelve days. Reasoning: hex release dates above. Breaking-change frequency across `0.x` minors was not audited (**[U]**).

### 4.2 Without LangChain

Two sub-variants exist and should not be conflated:

1. **Bare**: extend the existing `MealPlannerApi.AI.Client` behaviour and write the provider request/response mapping (contents, tool declarations, tool results, streaming) and the loop directly on OTP.
   - **[F]** The current client already hand-rolls the Gemini REST calls on `:httpc` (`lib/meal_planner_api/ai/gemini_client.ex:64`, `:166`), so this continues an existing pattern.
   - **[E]** The loop itself (call model, validate tool call, execute, append result, repeat under a step bound) is small; the recurring cost is per-provider wire-format maintenance, including streamed tool-call assembly. Reasoning: that is exactly the surface `pi-ai`, LangChain chat models, and ReqLLM each exist to absorb.
2. **Provider library only**: use a provider-abstraction library and own the loop.
   - **[F]** `req_llm 1.26.0` (hex, Apache-2.0, `agentjido/req_llm`, 2026-09-29): "Composable Elixir library for LLM interactions built on Req and Finch". Required deps: `req ~> 0.6`, `finch ~> 0.22`, `jason`, `jsv`, `llm_db`, `nimble_options`, `server_sent_events`, `splode`, `websockex`, `zoi`, `dotenvy`.
   - **[F]** `jido 2.3.3` and `jido_ai 2.3.0` (Apache-2.0) exist on hex as an Elixir agent framework. **[U]** They were not evaluated in this session.

- **[F]** In both sub-variants, tool execution, authorization, and persistence run inside the BEAM, in the same process tree and database transaction scope as the existing services.

### 4.3 The historical LangChain-interface choice, revisited

- **[F]** Recorded decision, issue #21 (closed 2026-08-25): "La IA se integra con LangChain Elixir tras una interfaz de MyFood neutral respecto del proveedor". Issue #29 (open spec): "MyFood owns a provider-neutral AI boundary, backed by LangChain Elixir."
- **[F]** Issue #25 resolution: the AI "Convierte lenguaje natural en un borrador tipado de intención. No elige recetas, no decide hechos, no deriva compras ni persiste cambios." Issue #29 adds that it "retains neither planning-chat nor cooking-chat history" and "returns typed intent only".
- **[F]** State at the pinned revision: the decision is not implemented. LangChain is absent (`mix.exs:55-73`; no `langchain` entry in `mix.lock`), the neutral interface exists as two duplicate behaviours, and the only implementation is a direct Gemini client (section 6).
- **[F]** What the decision was sized for: single-shot natural language → typed intent. That needs a provider call with structured output; it does not need a tool loop, history, or cancellation.
- **[F]** What #80 now asks for: "a bounded autonomous planning loop: investigate recipes and prices, invoke ORTools, evaluate proposals, refine candidates". That requires multi-step tool calling and history within a run.
- Consequence for the comparison, without resolving it: the original rationale (provider neutrality) is served equally by LangChain chat models, ReqLLM, or `pi-ai`. The new requirement (agent loop) is served by `LLMChain`, `pi-agent-core`, `pi-durable`, or a hand-written loop. The two concerns are separable in every candidate.
- **Open policy question for the human (not decided here):** the #25/#29 authority rules (no recipe selection by the AI, typed intent only, no retained chat history) and the #80 loop description are in tension. Which rules remain hard constraints for the agent determines what tools it may hold and what transcript it may persist.

---

## 5. Hybrid topologies

A hybrid places a non-BEAM agent runtime next to Phoenix. The variants differ in which side owns the loop, the transcript, and tool execution.

| ID | Topology | Loop owner | Tool execution | Transcript of record |
|---|---|---|---|---|
| H1 | Node sidecar embedding `pi-agent-core` + `pi-ai`; tools are thin stubs that call back into Phoenix | Node | Phoenix (via callback) | Phoenix/Postgres, if the sidecar is stateless and receives context per run |
| H2 | `pi --mode rpc` child process driven from Elixir | Pi coding runtime | Pi process (extensions) or callbacks | Pi JSONL session, or `--no-session` |
| H3 | Node sidecar with `pi-durable` and SQLite/JSONL | Node | Node, or callbacks | The sidecar's own storage |
| H4 | Elixir owns the loop; a Node process is used only as a provider gateway | Elixir | Elixir | Phoenix/Postgres |
| H5 | OpenCode server or Agent SDK process as the sidecar | Sidecar | Sidecar (MCP for custom tools) | Sidecar disk, optionally mirrored |

Boundary facts and estimates:

- **[F]** MyFood already supervises one foreign-runtime child with a JSON-lines stdio protocol, handshake, per-request UUID correlation, frame reassembly, timeouts, and a circuit breaker: `OptimizerServer` over a `Port` (`lib/meal_planner_api/optimization/optimizer_server.ex:5-19`, `optimizer_port_runner.ex:28-36`). H2 has the same shape as that integration; Pi's RPC framing rules (LF-only splitting, continuous stdout reads) are documented.
- **[F]** In H2 the child is the full coding agent, which by its own documentation has no permission system and no sandbox (section 2.4). Its built-in tools are read, bash, edit, write.
- **[E]** In H1 and H4 the hard-constraint guarantee can stay where it is today (server-side validation in Elixir) because the sidecar never touches the database. In H2, H3, and H5 the runtime that owns the loop also holds process-level capabilities (filesystem, shell, network) that have to be removed or contained. Reasoning: sections 2.4, 3.1, 3.2.
- **[F]** H3 introduces a second store of record with single-process ownership ("no cross-process locking"), next to Postgres and the existing `planning_sessions` lock.
- **[E]** Tool callbacks in H1 need an authenticated internal channel carrying the acting membership, because tools must be account-scoped (section 6.6). Options include a loopback HTTP endpoint with a per-run token, or stdio frames if the sidecar is a `Port` child. Which is simpler is **[P]**.
- **[U]** Whether a maintained Elixir MCP server library would let Phoenix expose its tools over MCP to `pi-mcp`, OpenCode, or the Agent SDK. Not researched.
- **[F]** Every hybrid adds Node `>= 22.19` (Pi), or a platform binary (OpenCode, Agent SDK), to a deployment that today needs the BEAM and a Python interpreter (`config/config.exs:26`).
- **[U]** MyFood's production deployment topology. No Dockerfile, `fly.toml`, or `.tool-versions` was found at repository depth ≤ 3, so the cost of adding a runtime to the release could not be assessed.

---

## 6. Current MyFood inventory at `a364c7a`

### 6.1 Dependencies

- **[F]** `mix.exs:55-73` declares: `phoenix ~> 1.8.5`, `req ~> 0.5`, `jason`, `guardian ~> 2.4`, `bcrypt_elixir`, `ecto_sql ~> 3.12`, `postgrex`, `cors_plug`, `dns_cluster`, `bandit`, `bamboo`, `uuid`, `telemetry_*`, plus `mox` (test), `ex_doc` and `tidewave` (dev).
- **[F]** Locked versions (`mix.lock`): `phoenix 1.8.9`, `ecto_sql 3.13.5`, `guardian 2.4.0`, `req 0.7.4`, `finch 0.23.0`, `mint 1.9.3`, `phoenix_pubsub 2.2.0`, `bandit 1.12.0`. 53 packages in total.
- **[F]** No LLM, agent, or job-queue library is present: no `langchain`, `req_llm`, `jido`, `instructor`, `oban`.
- **[F]** `Req` is used for the Go scraper and a Python HTTP client (`lib/meal_planner_api/integrations/go_scraper_client.ex:76`, `python_client.ex:113`), but not for the LLM.

### 6.2 Provider coupling

- **[F]** Two behaviours with the same two callbacks exist: `AI.Client` (`lib/meal_planner_api/ai/client.ex:9-10`) and `AI.AIPort` (`ai/ai_port.ex:19`, `:30`). `GeminiClient` implements the first (`ai/gemini_client.ex:6`); `GeminiAdapter` wraps it to implement the second (`ai/gemini_adapter.ex:11-21`) and is used only by the voice parser (`lib/meal_planner_api/voice/ai_voice_parser.ex:21`).
- **[F]** The callback contract is `generate_text(prompt, opts)` and `stream_chat_completion(topic, prompt, opts)`: a single prompt string in, text out. Nothing in the contract carries messages, tools, or tool results.
- **[F]** Runtime selection accepts only Gemini: `config/runtime.exs:27-39` raises on any `AI_CLIENT` other than `gemini`. `AI.ensure_client_ready/1` pattern-matches `GeminiClient` and reads `GEMINI_API_KEY` (`lib/meal_planner_api/ai.ex:61-67`).
- **[F]** The provider client depends on the web layer: it aliases `MealPlannerApiWeb.Endpoint` and broadcasts channel events itself (`ai/gemini_client.ex:8`, `:19`, `:84-94`), as the `AIPort` contract requires (`ai/ai_port.ex:22-28`).
- **[F]** The API key is sent as a URL query parameter (`ai/gemini_client.ex:57`, `:159`). Default model `gemini-2.5-flash-lite`, temperature fixed at 0.4 (`config/runtime.exs:69`, `ai/gemini_client.ex:199`).
- **[F]** LLM call sites: AI chat streaming (`lib/meal_planner_api_web/channels/ai_channel.ex:77`), cooking Q&A (`lib/meal_planner_api/services/cooking_service.ex:323`), a seeding mix task (`lib/mix/tasks/ai_populate.ex:229`), and the voice parser.
- **[F]** The planning pipeline does not call the LLM. Chat modifications are parsed by regular expressions (`lib/meal_planner_api/services/generation_service.ex:109-131`).

### 6.3 Conversational state

- **[F]** History is client-supplied per message: `AIChannel` forwards `payload["messages"]` (`ai_channel.ex:78`), `Messages.parse_history/1` turns it into structs (`lib/meal_planner_api/messages.ex:13-29`), and `AI.stream_response/4` passes it as `message_history:` (`ai.ex:30`).
- **[F]** That history never reaches the provider: `build_request/2` emits exactly one user turn (`ai/gemini_client.ex:198`) and reads only `:system_prompt` and `:max_output_tokens` (`:185-195`). The `:persona` option (`ai.ex:29`) is likewise unread, so the AI chat sends no system instruction.
- **[F]** A `planning_messages` table and schema exist with `role`, `content`, `intent_kind` (`lib/meal_planner_api/persistence/planning/planning_message.ex:21-30`). In `lib/`, the only operations on it are deletes (`lib/meal_planner_api/data/planning_repo.ex:508`, `generation/planning_session_sweeper.ex:149`). **[E]** No insert path exists at this revision; reasoning: `rg` for the schema and for `create_message`/`list_messages` found no writer.
- **[F]** A `cooking_chat_messages` schema exists (`persistence/planning/cooking_chat_message.ex:8`). **[U]** Its write path was not traced.

### 6.4 Tool/function calling

- **[F]** None. The request payload has `contents`, `generationConfig`, and optionally `system_instruction` (`ai/gemini_client.ex:197-207`). Response parsing reads only `text` parts (`:123-124`, `:219-222`); a `functionCall` part would be ignored in streaming and joined as an empty string in sync mode.
- **[F]** A typed-intent boundary exists independently of the model: `GenerationService.validate_ai_intent/1` accepts three kinds (`change_constraints`, `request_slot_swap`, `request_recipe_suggestion`) and recursively rejects keys such as `recipe_id`, `proposal_id`, `insert`, `update` (`services/generation_service.ex:281-293`, `:316-348`).
- **[F]** The intent validated in `AIChannel` comes from the client payload, not from model output (`ai_channel.ex:74`).
- **[F]** A validated intent is stored as `pending_intent` in the session process and never read (`generation/planning_session_server.ex:318-327`; the only references are lines 55, 100, 321). The spec document states the same gap (`docs/CONVERSATIONAL_MEAL_PLAN_SPEC.md:16`).

### 6.5 Generation state and the OR-Tools path

Invocation path:

1. `PlanningChannel` `generate_menu` → `Generation.Server.start_generation/4` (`lib/meal_planner_api_web/channels/planning_channel.ex:60-68`).
2. Request validation, then run and proposal rows are created (`generation/server.ex:161-164`, `:515-534`).
3. `PlanningCandidateBuilder.build_candidate_set/3` builds the server-owned candidates (`generation/server.ex:265-266`; comment at `:260-261`: "The candidate builder is the only recipe source").
4. `OptimizerServer.select_weekly_menu/1` (`generation/server.ex:270`) → `GenServer.call` → JSON lines over a `Port` to `optimizador.py` (`optimization/optimizer_server.ex:58-59`, `optimizer_port_runner.ex:28-36`).
5. `optimizador.py` uses `ortools.linear_solver.pywraplp` with the SCIP backend and maps `INFEASIBLE`, `UNBOUNDED`, `ABNORMAL` (`../optimizador.py:18`, `:117`, `:190-196`).
6. The result is validated against candidates, coverage, budget, and macro bounds (`generation/server.ex:278-282`; `services/generation_service.ex:171-183`, `:391-465`), then persisted to the proposal.

Findings:

- **[F]** `OptimizerPort` is a clean two-callback behaviour (`optimization/optimizer_port.ex:49`, `:54`) with mock, fallback, and server implementations. Structured infeasibility is returned as `{:infeasible, details}` (`optimizer_server.ex:510-511`).
- **[F]** No solver time limit is set in `optimizador.py` (no `SetTimeLimit` or equivalent). The Elixir-side timeout is 15 s by default, 60 s in dev (`config/config.exs:27`, `config/dev.exs:43`).
- **[F]** Durable and well-guarded: the planning session lock. `PlanningSessionServer` mirrors a Postgres row protected by an EXCLUDE constraint, has a 120 s lease, rehydrates after a crash, and has explicit terminal statuses (`generation/planning_session_server.ex:8-19`, `:44`, `:232-247`).
- **[F]** In-memory only: `Generation.Server` holds `phase`, `proposal_json`, and `constraints` in process state with `restart: :temporary` (`generation/server.ex:19`, `:38-47`). A crash loses the working constraints; only the run and proposal rows survive.
- **[F]** Not cancellable: the pipeline runs synchronously inside `handle_info(:run_optimization, ...)` (`generation/server.ex:211-214`), blocking the process on the optimizer call. The public API has no cancel function (`:87-121`).
- **[F]** Chat modifications are computed and then dropped: `handle_cast({:chat, ...})` calls `handle_chat/3` and returns the old `state` (`generation/server.ex:199-202`), discarding the updated constraints built at `:474-504`. The re-optimization message is still sent (`:486`), so the solver re-runs with unchanged constraints.
- **[F]** A legacy HTTP path (`PlanningChatService.generate_menu/2`) writes a run as `:completed` immediately and fills a date range by cycling plan days with `rem(index, length(plan))` (`services/planning_chat_service.ex:61`, `:176`). **[U]** Whether that path validates optimizer output was not traced.

### 6.6 Auth and write paths an agent tool would cross

- **[F]** REST: Guardian pipeline with token-type check and membership loading (`lib/meal_planner_api_web/auth_pipeline.ex:23-30`); router pipelines `:auth`, `:enforce_account_scope`, `:enforce_capability` (`lib/meal_planner_api_web/router.ex:8`, `:15`, `:25`, `:176-177`, `:221-222`).
- **[F]** Sockets: JWT verified at connect and an active membership row required (`lib/meal_planner_api_web/user_socket.ex:77-84`, `:109-119`).
- **[F]** `planning:<account_id>` join checks topic account against membership and subscription capability (`planning_channel.ex:32-46`). `ai_chat:<room_id>` join checks only that the membership is active, because the topic carries no account id (`ai_channel.ex:11-17`, `:24-45`).
- **[F]** Services receive a user re-scoped to the DB-resolved membership account (`ai_channel.ex:60-61`).
- **[F]** The only persisting write for a plan is `confirm_proposal` on the channel: entitlement check, session-lock verification, then one transaction that accepts the proposal, writes scheduled meals, and rebuilds the shopping cart (`planning_channel.ex:134-145`; `generation/server.ex:193-196`, `:335-382`, `:392-420`, `:688`, `:742`). The HTTP confirm path was retired (`services/planning_chat_service.ex:239-241`).
- **[F]** Price data enters through `GoScraperClient`, called from a mix task (`lib/mix/tasks/price_sync/run.ex:46`). **[U]** `PriceService` and the recipe read APIs were not inventoried as tool surfaces.
- **[F]** Supervision tree: PubSub, two dynamic supervisors for generation and planning sessions, two sweepers, and the optional `OptimizerServer` (`lib/meal_planner_api/application.ex:10-36`).

### 6.7 Lead-by-lead revalidation

| Lead | Result | Evidence |
|---|---|---|
| LangChain is missing from deps | **Confirmed** | `mix.exs:55-73`; no `langchain` key in `mix.lock` |
| Gemini integration lacks history support | **Confirmed** | `ai/gemini_client.ex:198` sends one user turn; `:message_history` (`ai.ex:30`) is never read |
| Gemini integration lacks tool support | **Confirmed** | `ai/gemini_client.ex:197-207` has no tool declarations; parsing reads text parts only (`:123-124`) |
| Generation state is weak | **Partly confirmed** | Session lock is durable (`planning_session_server.ex:232-247`). Generation working state is in-memory and temporary (`generation/server.ex:19`), not cancellable (`:211-214`), and chat-modified constraints are discarded (`:199-202`) |
| Fallback behaviour is unsafe | **Partly confirmed** | See below |

Fallback detail:

- **[F]** When the circuit is open, `OptimizerServer` answers with `OptimizerFallback` (`optimization/optimizer_server.ex:103-110`).
- **[F]** The fallback picks the cheapest candidate per slot and checks neither budget nor macro bounds (`optimization/optimizer_fallback.ex:68-80`), although its moduledoc says it "always produces a valid plan" (`:8-9`).
- **[F]** Its result has the same shape as a solver result, with no provenance marker (`optimizer_fallback.ex:18`).
- **[F]** Mitigation in the canonical pipeline: every result, including a fallback one, passes `validate_optimizer_response/2`, which rejects budget and macro violations (`generation/server.ex:278-282`; `generation_service.ex:455-460`).
- **[F]** That guard is only as strict as the constraints sent: the spec document states the pipeline currently sends deliberately permissive macro limits (`docs/CONVERSATIONAL_MEAL_PLAN_SPEC.md:14`).
- **[F]** Cooking chat: on any LLM error the user receives a keyword-matched canned answer with no indication that the model was not used (`services/cooking_service.ex:323-329`, `:376-390`).
- **[F]** Streaming runs in an unsupervised `Task.start/1` with a 30 s idle timeout and no cancellation handle (`ai/gemini_client.ex:18`, `:102-108`).

### 6.8 Reuse and gap summary

Reusable as-is for an agent in any candidate:

- Guardian/membership/capability enforcement on REST and channels.
- Phoenix Channels and PubSub as the streaming transport to the client.
- `PlanningSessionServer` plus the Postgres lock as the unit of "one bounded run per account and range".
- `PlanningCandidateBuilder` as the only recipe source, `OptimizerPort`/`OptimizerServer` as the solver seam, `validate_optimizer_response/2` as the hard-constraint check, and channel `confirm_proposal` as the single write path.
- `validate_ai_intent/1` as a deny-list for model-originated structures.
- The `Port` supervision pattern for a foreign runtime.

Gaps that every candidate must close:

- A message-and-tool-capable provider contract (the current one is prompt-string only).
- A transcript model for a run (the `planning_messages` table has no writer).
- A cancellable, resumable run owner (the current generation server blocks and is temporary).
- Connecting validated intent to the pipeline (`pending_intent` is unread).
- Labelled degradation instead of silent substitution.

---

## 7. Comparison matrix

Columns: **A** adapt Pi components (published packages in a Node process, no Pi code changed); **B** fork Pi; **C** Elixir-native with LangChain; **D** Elixir-native bare (D1 hand-written provider mapping, D2 a provider library such as ReqLLM); **E** hybrid (H1–H5 in section 5; A and B are necessarily deployed as some hybrid, so E describes the boundary itself).

| Dimension | A: adapt Pi components | B: fork Pi | C: Elixir + LangChain | D: Elixir bare | E: hybrid boundary |
|---|---|---|---|---|---|
| Tool execution | [F] `AgentTool` + TypeBox validation, parallel or sequential, `beforeToolCall` can block. [E] Tools run in Node, so domain tools need callbacks into Phoenix. | [F] Same primitives, plus built-in read/bash/edit/write that would have to be removed. | [F] `LangChain.Function`, `async: true` via `Task.async/1`, `custom_context`. Tools run in the BEAM. | [F] Plain function calls inside OTP; all validation hand-written. | [E] Each tool call crosses a process boundary (H1) or runs in the foreign runtime (H2, H3, H5). |
| History serialization | [F] `pi-ai` `Context` is plain JSON; `pi-durable` uses immutable entries. | [F] Adds the coding agent's JSONL session tree. | [F] `messages` list of structs; no built-in persistence documented. | [F] Own format; `planning_messages` schema exists without a writer. | [E] Two representations must be mapped unless the sidecar is stateless (H1, H4). |
| Persistent state | [F] `pi-durable`: SQLite/JSONL/memory, single-process ownership, experimental. [U] No Postgres backend documented. | [F] Same; a fork could add a backend against the shipped conformance suite. | [U] Left to the application; Ecto and the session lock are available. | Same as C. | [F] H3 and H5 create a second store of record next to Postgres. |
| Cancellation | [F] `agent.abort()`, `AbortSignal` to tools, durable `abort()`. | Same. | [F] `cancel_delta` for streaming; [E] whole-run cancel by terminating the owning process. | [E] Process termination and monitors; the current generation server is not cancellable today. | [E] Cancel must propagate across the boundary and to in-flight Phoenix tool calls. [P] |
| Provider portability | [F] 30+ providers incl. Gemini, Vertex, Anthropic, OpenAI, Bedrock, OpenAI-compatible. | Same. | [F] 15 chat-model modules incl. Google AI, Vertex, Anthropic, OpenAI, ReqLLM adapter. | D1: [F] Gemini only today. D2: [U] ReqLLM provider list not audited. | Inherits the sidecar's. H5/Agent SDK: [E] Claude models only. |
| Streaming | [F] Event stream with text and partial tool-call deltas. | Same, plus RPC JSONL events. | [F] Callbacks and deltas (`merge_delta/2`). | [F] SSE parsing exists for text only (`gemini_client.ex:112-151`). | [E] Sidecar events must be relayed to Phoenix Channels. |
| Deployment topology | [F] Node ≥ 22.19 process beside the BEAM and Python. | Same, built from a private fork. | [F] No new runtime; four new hex packages at minimum incl. `gettext`, `dotenvy` ([E] by lock comparison). | [F] No new runtime; D2 adds ReqLLM's dependency set. | [U] Production topology of MyFood not found in the repo. |
| Runtime boundaries | [E] Loop in Node; domain authority must stay in Elixir via callbacks. | [E] Same, with the coding runtime's capabilities present until removed. | [F] Single runtime; loop, tools, auth, and transaction scope co-located. | Same as C. | This is the dimension that defines E; see section 5 table. |
| Licensing and transitive deps | [F] MIT; exact-pinned vendor SDKs (Anthropic, OpenAI, Google, AWS Bedrock). [U] Transitive tree not audited. | [F] MIT permits forking; copyright notice must be kept. | [F] Apache-2.0. | D1: none new. D2: [F] Apache-2.0. | H5: [F] OpenCode MIT; Agent SDK under Anthropic Commercial Terms. |
| Sandboxing/security | [F] `pi-agent-core` ships no tools, so capability is what the host registers. [F] Pi as a whole has "no built-in permission system". | [F] Coding agent "intentionally does not have a sandbox"; prompt injection is out of scope upstream. | [E] Capability equals the registered Elixir functions; Guardian/membership checks are in-process. | Same as C. | [E] The callback channel is a new authenticated surface; a foreign runtime with shell/file tools needs containment. |
| Upgrade and fork maintenance | [E] Track a project six days past 1.0 that released five times since; packages are exact-pinned. `pi-durable` "changes without notice". | [E] Additionally merge upstream into modified packages; upstream auto-closes new contributors' PRs. [P] | [E] Track a pre-1.0 library with three releases in twelve days. | D1: [E] Own every provider API change. D2: track ReqLLM. | Sum of the sidecar's burden and the boundary contract's. |
| Operational complexity | [E] One more supervised runtime, health checks, version skew between Node and Elixir sides. | [E] Same plus a private build pipeline for the fork. | [E] Unchanged process model. | Same as C. | [E] Highest for H3/H5 (second state store, per-session processes). |
| Latency | [P] | [P] | [P] | [P] | [E] Adds one local hop per tool call; magnitude is [P]. |
| Cost | [P] Token cost per run. [U] Node memory per concurrent run. | Same. | [P] | [P] | [F] Agent SDK doc: ~1 GiB RAM per agent as a starting point. [F] Same doc: token cost "typically dominates container infrastructure cost by an order of magnitude or more" (stated for that SDK). |

---

## 8. What would falsify each candidate's suitability

### A. Adapt Pi components

- The agent's domain tools cannot be invoked from Node with the acting membership's authorization without duplicating authorization logic outside Elixir.
- `pi-agent-core` hooks (`beforeToolCall`, `prepareRequest`, `finishTurn`) are insufficient to enforce a step bound and a "validated proposal only" termination rule.
- `pi-durable` is required for resumability but its experimental API or single-process SQLite/JSONL storage is unacceptable, and no Postgres-compatible backend can be written against its storage contract.
- Adding Node ≥ 22.19 to the production release is not permitted or not practical for the (currently undocumented) deployment target.
- Per-run memory or cold-start cost of the Node process is unacceptable at the expected concurrency.

### B. Fork Pi

- Everything under A, plus:
- The changes MyFood needs can be made through extensions or by composing the lower-level packages, which removes the reason to fork.
- The observed upstream merge cost over a trial period exceeds what the team can sustain.
- The coding runtime's built-in tools and absence of a sandbox cannot be removed or contained to the standard a multi-tenant service requires.

### C. Elixir-native with LangChain

- `LLMChain` with `ChatGoogleAI` cannot run a multi-step tool loop against the chosen Gemini model reliably (malformed tool calls, schema subset limits such as unsupported `additionalProperties`).
- Dependency resolution fails or forces unwanted upgrades in the existing lock.
- The run cannot be cancelled or resumed cleanly because chain state is an in-memory struct with no documented persistence, and adding that outside the library proves as much work as the bare loop.
- A `0.x` upgrade during the prototype window breaks the integration.
- The human decides that the #29 rule "backed by LangChain Elixir" no longer holds.

### D. Elixir-native bare

- D1: maintaining streamed tool-call parsing and tool-result formatting for Gemini (and any second provider required for portability) costs more than adopting a library.
- D2: the provider library does not support the needed provider features (tool calling with streaming, structured output), or its dependency set conflicts with the lock.
- The hand-written loop reproduces, without the tests, safeguards that a library already ships (step bounds, retry on invalid output, fallback models).
- Provider portability is a hard requirement and only one provider is ever implemented.

### E. Hybrid

- The boundary contract (tool callbacks, cancellation, streaming relay, transcript mapping) is larger or more fragile than the loop it outsources.
- A second store of record (H3, H5) cannot be reconciled with the Postgres session lock and the #29 retention rules.
- Authorization cannot be carried across the boundary without the sidecar holding credentials broader than one run.
- Failure of the sidecar cannot be surfaced as an explicit, labelled degradation and instead produces a silent fallback of the kind found in section 6.7.

---

## 9. Open questions

### Needs prototype evidence

1. **[P]** Does `gemini-2.5-flash-lite` (the configured default) or another approved model complete a bounded investigate → optimize → evaluate → refine loop with tool calls, under each of `pi-agent-core`, `LLMChain`, and a bare loop? What is the invalid-tool-call rate?
2. **[P]** End-to-end latency and token cost per planning run for each candidate, including solver time (no solver time limit is set today).
3. **[P]** Round-trip overhead and failure modes of Node → Phoenix tool callbacks (H1), including cancellation while a tool call is in flight.
4. **[P]** Whether `mix deps.get` resolves with `langchain 0.15.0` or `req_llm 1.26.0` against the current lock, and what else moves.
5. **[P]** Whether a run can be resumed after a BEAM or sidecar restart in each candidate, and what state must be persisted to do so.
6. **[P]** Memory per concurrent run for a Node sidecar embedding `pi-agent-core`, and for `pi --mode rpc`.
7. **[P]** Whether the optimizer can serve several agent-driven solves per run within its singleton `GenServer` and circuit-breaker design.
8. **[P]** Upstream merge cost of a Pi fork over a fixed observation window.

### Policy questions for the human (not decided here)

1. Do the #25/#29 authority rules (typed intent only, no recipe selection by the AI, no retained chat history) remain hard constraints for the agent described in #80?
2. Is provider portability a hard requirement, and is leaving Gemini acceptable?
3. Is adding a Node (or other) runtime to production acceptable?
4. What transcript, if any, may be persisted for a run, and for how long?
5. What degradation is acceptable when the model or the optimizer is unavailable, given the unlabelled fallbacks found in section 6.7?

### Unknowns and sourcing gaps

- Pi `.ts` sources were not read; behaviour is taken from READMEs and docs at `v1.0.4`.
- The transitive dependency trees and their licenses for Pi, OpenCode, LangChain, and ReqLLM were not audited.
- `pi-durable` Postgres or custom-backend feasibility beyond the README's adapter contract.
- OpenCode session storage, multi-tenancy, and custom-tool registration over HTTP.
- Claude Agent SDK pages beyond overview and hosting (sessions, permissions, custom tools, secure deployment) were not read.
- LangChain changelog and breaking-change history across `0.x`; ReqLLM's provider and tool-calling feature matrix; Jido and `jido_ai` entirely.
- Elixir MCP server libraries as a possible tool boundary.
- MyFood production deployment topology; `PriceService`, recipe read APIs, and the cooking chat write path as tool surfaces; the legacy `PlanningService.generate_weekly_plan/2` path.
- The provider names in the `pi-ai` README were recorded as listed and not cross-checked against provider documentation.

---

## Sources

External (all read 2026-10-07):

- Pi repository and files at `v1.0.4`: https://github.com/earendil-works/pi — `README.md`, `LICENSE`, `SECURITY.md`, `packages/{ai,agent,durable,server}/README.md`, `packages/coding-agent/docs/{sdk,rpc}.md`, `packages/*/package.json`
- Redirect evidence: https://github.com/badlogic/pi-mono (HTTP 301)
- npm registry: https://registry.npmjs.org/@earendil-works/pi-ai , `/@earendil-works/pi-agent-core` , `/@earendil-works/pi-coding-agent` , `/@mariozechner/pi-ai` , `/@mariozechner/pi-agent-core` , `/@mariozechner/pi-coding-agent` , `/opencode-ai` , `/@anthropic-ai/claude-agent-sdk`
- OpenCode: https://opencode.ai/docs/server/ ; https://github.com/anomalyco/opencode (`LICENSE`, release `v1.18.35`)
- Claude Agent SDK: https://code.claude.com/docs/en/agent-sdk/overview ; https://code.claude.com/docs/en/agent-sdk/hosting ; https://github.com/anthropics/claude-agent-sdk-typescript (`LICENSE.md`) ; https://pypi.org/pypi/claude-agent-sdk/json
- LangChain: https://langchain.hexdocs.pm/LangChain.Chains.LLMChain.html ; https://langchain.hexdocs.pm/LangChain.ChatModels.ChatGoogleAI.html ; https://hex.pm/api/packages/langchain ; https://github.com/brainlid/langchain (`LICENSE`, `README.md`, `lib/chat_models/`)
- ReqLLM and Jido: https://hex.pm/api/packages/req_llm ; https://hex.pm/api/packages/jido ; https://hex.pm/api/packages/jido_ai

Internal:

- MyFood at `a364c7a5ef2a52a155685129086ca9537618265a`, files cited inline.
- Issues #21, #25, #29, #80, #82 of `vicenzogiordana/myfood` (read-only).
