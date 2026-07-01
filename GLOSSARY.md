# AdVanced OS — Glossary

> Terms, concepts, and definitions used throughout the project. Keeps communication precise when discussing architecture, patterns, and trade-offs.

## A

**Agent:** An autonomous AI system that perceives its environment, makes decisions, and takes actions to achieve goals. In AdVanced OS, agents are workers — Claude Code writes code, DeepSeek does research, cron runs schedules.

**Agentic OS:** An infrastructure layer that gives AI agents persistent memory, structured planning, disciplined execution, and safe production deployment. Like a computer OS manages hardware resources, an Agentic OS manages agent resources — dispatch, memory, observability, safety. Not a framework. Not an agent. The connective tissue.

**A2A (Agent-to-Agent):** Google's protocol for direct agent-to-agent communication. Designed for multi-runtime peer-to-peer discovery and task delegation. Not used in AdVanced OS — we have one serial tmux channel, not a network of peer agents.

**ACP (Agent Communication Protocol):** IBM's protocol for agent communication with structured task cards. Enterprise use cases. Not used in AdVanced OS.

## C

**Circuit breaker:** A safety mechanism that prevents runaway behavior. In AdVanced OS, the circuit breaker checks spend cap, dispatch depth, and global stop flag before every dispatch. Phase 2.

**Compound learning:** The practice of accumulating cross-session patterns, gotchas, and conventions discovered during agent work. Hermes maintains a compound learning file and injects relevant learnings into task doc preambles. Phase 5d.

**Context contamination:** When one subtask's context (files read, decisions made, errors encountered) bleeds into another subtask's context, degrading quality. A risk of the single-session dispatch pattern. Phase 5f (worker profiles) mitigates this.

**Context rot:** The degradation of agent output quality as a conversation grows longer and the context window fills with noise. The primary reason for subagent isolation in multi-agent systems. Addy Osmani identifies this as the "single-agent ceiling."

**Cooperative halt:** A kill sequence that lets the worker finish its current commit before stopping. Prevents dirty git trees that would wedge the next deploy. Part of the circuit breaker (Phase 2).

**Correlation ID:** A UUID generated at the start of every user interaction, carried through all downstream dispatches, cron logs, and events. Enables tracing a single request across the entire system. Phase 1b.

## D

**Delegate_task:** A Hermes tool that spawns an isolated subagent in its own context with a specific set of tools, model, and task. The primary mechanism for tool-scoped worker dispatch in AdVanced OS. Not the same as Claude Code's `Agent` tool — Hermes subagents are infra-agnostic.

**Depth counter:** An integer carried on the correlation ID that counts how many successive dispatches have occurred from a single user request. The circuit breaker kills at depth 4. Prevents runaway dispatch chains.

**Dispatch chain:** A sequence of dispatches triggered by a single user request. Example: Kevin asks → Hermes delegates design review → DeepSeek returns → Hermes dispatches Claude → Claude finishes → Hermes reports. Depth = number of successive dispatches.

**Dreaming:** Anthropic's term for a scheduled process that reviews past agent sessions, extracts patterns, and curates memory between runs. Not part of AdVanced OS — our compound learning file (5d) covers the same need without the infrastructure cost.

## F

**Fan-out:** A multi-agent pattern where one coordinator spawns multiple parallel specialists. High parallelism, partial failure mode (one branch fails, others succeed). Not directly applicable to our serial tmux channel.

## G

**Global stop:** A single command (`/stop-hermes`) that pauses all cron jobs, kills the current dispatch, and prevents new dispatches until Kevin re-enables. State persists to disk — not memory — so the 5-minute watchdog doesn't silently un-pause it.

**Goldie Mission Stack:** Julian Goldie's 4-layer Agentic OS architecture: Intelligence (Claude), Execution (OpenClaw), Research (Hermes), Self (Obsidian+OMI). The most commercially visible "Agentic OS" product in 2026.

## H

**Hermes:** The open-source orchestrator that AdVanced OS is built around. Developed by Nous Research. Handles task decomposition, dispatch, monitoring, cron scheduling, and deploy pipeline. The central component of the architecture.

**Human-in-the-loop:** A design pattern where the human operator (Kevin) must approve significant decisions — deploys, spending above threshold, architectural changes. The opposite of full autonomy. The top of every architecture diagram in AdVanced OS.

## M

**MCP (Model Context Protocol):** Anthropic's standardized protocol for agents to connect with tools, databases, APIs, and files. Primary tool access protocol in AdVanced OS. Our MCP servers: ObsoleteBot (guild data), OpenBrain (memory).

**Memory rot:** The degradation of agent memory quality over time as stale entries accumulate, duplicates compound, and context drifts. Anthropic's "Dreaming" was designed to address this. AdVanced OS addresses it through manual curation of the compound learning file.

**Mission Control:** A visual dashboard showing all active agents, their tasks, and their status in a single view. Inspired by Goldie's reactor-core-and-orbiting-nodes concept. Not built yet — Phase 5c (stretch). The data layer (5a, 5b) provides the same information in terminal-native form.

## O

**Observability:** The ability to know which agent did what, when, with what result, at what cost. AdVanced OS provides this through structured event logging (5a) and correlation ID tracking (1b), not through a formal tracing DB.

**Orchestration:** The process of decomposing a task, routing subtasks to the right workers, monitoring execution, handling failures, and synthesizing results. Hermes is the orchestrator in AdVanced OS. Distinguished from "conduction" (one agent, synchronous guidance).

**Outcomes:** Anthropic's term for rubric-driven self-correction. A separate Claude instance evaluates agent output against a rubric and the agent retries until it passes. Not used in AdVanced OS — Phase 5e (QA gate) uses shell commands instead of an LLM grader.

## P

**Pipeline (multi-agent pattern):** Sequential processing where each stage feeds the next. Failure mode: cascade — a bad mid-stage contaminates everything after. Used in AdVanced OS for cron job chains and the deploy pipeline.

## Q

**QA gate:** A verification step that runs after a worker signals completion but before Hermes reports success to Kevin. Phase 5e. Checks concrete success criteria with shell commands: commit landed? Tests pass? Required files changed? Not a rubric-driven LLM grader.

## R

**Research worker:** A tool-scoped worker profile with Read/Glob/Grep/Web search access only. No Write/Edit/Bash. Used for codebase exploration and web research without risking file modification. Phase 5f.

## S

**Serial tmux channel:** The single tmux session through which Hermes dispatches tasks to Claude Code. The defining constraint of the architecture. One puppet string. No concurrent RPC. No synchronous callbacks. Not a bug — a design feature that prevents race conditions.

**Spend cap:** A per-week dollar limit. When hit, Hermes stops dispatching to paid workers and alerts Kevin. Part of the circuit breaker (Phase 2).

**Supervisor (multi-agent pattern):** A coordinator that delegates non-overlapping tasks to specialist sub-agents and synthesizes their independent results. The pattern AdVanced OS implements — Hermes is the supervisor, workers are the specialists. The 2026 default for production multi-agent systems.

## T

**Task doc:** The scope document Hermes writes to `/tmp/` before dispatching to a worker. Contains background, goal, design, file change list, pitfalls, implementation order, and success criteria. The single most important artifact in the dispatch workflow.

**Tmux:** Terminal multiplexer. The transport layer for Hermes→Claude dispatch. One persistent session (`claude-obsoletebot`) handles all coding tasks.

## W

**Worker:** An agent that executes tasks dispatched by Hermes. Workers have defined roles, tool scopes, and model assignments. Current workers: Claude Code (coding), DeepSeek (design review), cron (scheduling). Planned workers: research, code-review (Phase 5f).

**Worker profile:** A configuration file defining a worker's tool access, model assignment, max turns, timeout, and output format. Hermes dispatches to the appropriate profile based on task type. Phase 5f.

## Z

**Zero-trust worker:** A worker that starts each session with no assumptions about context, no carryover from previous sessions, and no access to tools outside its defined scope. Research worker profile is the primary example — Read/Glob/Grep/Web only, no Write/Edit/Bash.
