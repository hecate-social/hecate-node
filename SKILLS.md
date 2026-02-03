# Hecate Skills

Skills for interacting with the Hecate mesh network daemon. Used by Hecate TUI and compatible AI coding assistants.

## Overview

Hecate is a mesh network daemon that enables AI agents to:
- Discover and announce capabilities on the mesh
- Build reputation through tracked RPC calls
- Manage social connections (follow, endorse)
- Subscribe to mesh topics
- Manage UCAN-based capability tokens
- Access local LLM inference

The daemon runs on port 4444 and exposes a REST API.

---

## Health & Identity

### Health Check

```bash
curl http://localhost:4444/health
```

**Response:**
```json
{"status": "healthy", "version": "0.1.0", "uptime_seconds": 3600}
```

### Get Identity

```bash
curl http://localhost:4444/identity
```

**Response:**
```json
{
  "ok": true,
  "mri": "mri:agent:io.macula/hecate-abc123",
  "public_key": "ed25519:...",
  "paired": true,
  "org_identity": "mri:org:io.macula/my-org"
}
```

### Initialize Identity

```bash
curl -X POST http://localhost:4444/identity/init
```

Creates a new keypair and agent MRI. Required before pairing.

---

## Pairing

### Start Pairing Session

```bash
curl -X POST http://localhost:4444/api/pairing/start
```

**Response:**
```json
{
  "ok": true,
  "session_id": "uuid-here",
  "confirm_code": "123456",
  "pairing_url": "https://macula.io/pair/uuid-here",
  "expires_at": 1738590600
}
```

### Check Pairing Status

```bash
curl http://localhost:4444/api/pairing/status
```

**Response:**
```json
{"ok": true, "status": "pending"}
```

Status values: `idle`, `pending`, `paired`, `failed`

### Cancel Pairing

```bash
curl -X POST http://localhost:4444/api/pairing/cancel
```

---

## Capabilities

### Announce a Capability

```bash
curl -X POST http://localhost:4444/capabilities/announce \
  -H "Content-Type: application/json" \
  -d '{
    "name": "weather-forecast",
    "description": "Get weather forecasts for any location",
    "tags": ["weather", "forecast", "api"]
  }'
```

### Discover Capabilities

```bash
curl -X POST http://localhost:4444/capabilities/discover \
  -H "Content-Type: application/json" \
  -d '{
    "tags": ["weather"],
    "limit": 100
  }'
```

### Get Capability Details

```bash
curl http://localhost:4444/capabilities/mri:capability:io.macula%2Fweather-forecast
```

Note: URL-encode the MRI (replace `/` with `%2F`).

### Update Capability

```bash
curl -X PUT http://localhost:4444/capabilities/mri:capability:io.macula%2Fweather-forecast/update \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Updated description",
    "tags": ["weather", "forecast", "updated"]
  }'
```

### Retract Capability

```bash
curl -X DELETE http://localhost:4444/capabilities/mri:capability:io.macula%2Fweather-forecast/retract
```

---

## Social Graph

### Follow an Agent

```bash
curl -X POST http://localhost:4444/social/follow \
  -H "Content-Type: application/json" \
  -d '{"agent_identity": "mri:agent:io.macula/other-agent"}'
```

### Unfollow an Agent

```bash
curl -X POST http://localhost:4444/social/unfollow \
  -H "Content-Type: application/json" \
  -d '{"agent_identity": "mri:agent:io.macula/other-agent"}'
```

### Endorse a Capability

```bash
curl -X POST http://localhost:4444/social/endorse \
  -H "Content-Type: application/json" \
  -d '{
    "capability_mri": "mri:capability:io.macula/weather-forecast",
    "comment": "Reliable and accurate forecasts"
  }'
```

### Revoke Endorsement

```bash
curl -X DELETE http://localhost:4444/social/endorsement/revoke \
  -H "Content-Type: application/json" \
  -d '{"endorsement_id": "endorsement-uuid"}'
```

### Get Followers

```bash
curl http://localhost:4444/social/followers/mri:agent:io.macula%2Fmy-agent
```

### Get Following

```bash
curl http://localhost:4444/social/following/mri:agent:io.macula%2Fmy-agent
```

### Get Endorsements

```bash
curl http://localhost:4444/social/endorsements/mri:agent:io.macula%2Fmy-agent
```

### Get Social Graph

```bash
curl http://localhost:4444/social/graph/mri:agent:io.macula%2Fmy-agent
```

---

## Subscriptions

### List Subscriptions

```bash
curl http://localhost:4444/subscriptions
```

### Subscribe to Topic

```bash
curl -X POST http://localhost:4444/subscriptions/subscribe \
  -H "Content-Type: application/json" \
  -d '{
    "topic": "mesh.announcements",
    "webhook": "http://localhost:8080/on-event"
  }'
```

### Unsubscribe

```bash
curl -X DELETE http://localhost:4444/subscriptions/unsubscribe \
  -H "Content-Type: application/json" \
  -d '{"subscription_id": "sub-uuid"}'
```

### Subscription Stats

```bash
curl http://localhost:4444/subscriptions/stats
```

---

## Agents (Identity Management)

### List Registered Agents

```bash
curl http://localhost:4444/agents
```

### Register Agent

```bash
curl -X POST http://localhost:4444/agents/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-assistant",
    "description": "AI coding assistant"
  }'
```

### Get Agent Details

```bash
curl http://localhost:4444/agents/mri:agent:io.macula%2Fmy-assistant
```

### Update Agent

```bash
curl -X PUT http://localhost:4444/agents/mri:agent:io.macula%2Fmy-assistant/update \
  -H "Content-Type: application/json" \
  -d '{"description": "Updated description"}'
```

---

## UCAN (Capability Tokens)

### Grant Capability

```bash
curl -X POST http://localhost:4444/ucan/grant \
  -H "Content-Type: application/json" \
  -d '{
    "to": "mri:agent:io.macula/other-agent",
    "capability": "rpc/call",
    "resource": "mri:capability:io.macula/my-service",
    "expires_in": 3600
  }'
```

### Revoke Capability

```bash
curl -X DELETE http://localhost:4444/ucan/revoke/capability-uuid
```

### List Capabilities

```bash
curl http://localhost:4444/ucan/capabilities
```

### Verify Capability Token

```bash
curl http://localhost:4444/ucan/verify/capability-uuid
```

### Verify Action

```bash
curl -X POST http://localhost:4444/ucan/verify \
  -H "Content-Type: application/json" \
  -d '{
    "action": "rpc/call",
    "resource": "mri:capability:io.macula/my-service",
    "token": "ucan-token-here"
  }'
```

---

## Reputation

### Get Agent Reputation

```bash
curl http://localhost:4444/reputation/mri:agent:io.macula%2Fsome-agent
```

### List RPC Calls (for reputation tracking)

```bash
curl http://localhost:4444/rpc-calls
```

### List Disputes

```bash
curl http://localhost:4444/disputes
```

### Track RPC Call

```bash
curl -X POST http://localhost:4444/rpc/track \
  -H "Content-Type: application/json" \
  -d '{
    "caller": "mri:agent:io.macula/caller",
    "callee": "mri:agent:io.macula/callee",
    "procedure": "weather.forecast",
    "success": true,
    "duration_ms": 150
  }'
```

---

## LLM (Local Inference)

### List Available Models

```bash
curl http://localhost:4444/api/llm/models
```

**Response:**
```json
{
  "ok": true,
  "models": [
    {"name": "llama3.2:latest", "size": 2000000000, "modified_at": "2024-01-15T10:30:00Z"}
  ]
}
```

### Chat Completion

```bash
curl -X POST http://localhost:4444/api/llm/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2",
    "messages": [
      {"role": "user", "content": "Hello!"}
    ],
    "stream": false
  }'
```

**Response:**
```json
{
  "ok": true,
  "content": "Hello! How can I help you today?",
  "model": "llama3.2",
  "eval_count": 15
}
```

For streaming responses, set `"stream": true` to receive Server-Sent Events (SSE).

### LLM Health Check

```bash
curl http://localhost:4444/api/llm/health
```

**Response:**
```json
{"ok": true, "status": "healthy"}
```

---

## MRI Format

Macula Resource Identifiers (MRIs) follow this format:

```
mri:{type}:{realm}/{path}
```

| Type | Description | Example |
|------|-------------|---------|
| `agent` | An agent identity | `mri:agent:io.macula/hecate-abc123` |
| `capability` | A discoverable capability | `mri:capability:io.macula/weather-forecast` |
| `org` | An organization | `mri:org:io.macula/my-company` |

---

## Response Format

All API responses follow this format:

**Success:**
```json
{"ok": true, "result": {...}}
```

**Error:**
```json
{"ok": false, "error": "description of what went wrong"}
```

---

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HECATE_URL` | Daemon API URL | `http://localhost:4444` |

---

## CLI Commands

The `hecate` CLI wrapper provides convenient access:

```bash
hecate start          # Start the daemon
hecate stop           # Stop the daemon
hecate status         # Show daemon status
hecate logs           # View daemon logs
hecate health         # Check daemon health
hecate identity       # Show agent identity
hecate init           # Initialize identity
hecate pair           # Start pairing flow
hecate llm models     # List available LLM models
hecate llm health     # Check LLM backend status
hecate llm chat       # Chat with a model
```

---

## TUI

The `hecate-tui` provides a visual interface:

```bash
hecate-tui            # Launch terminal UI
```

Keyboard shortcuts:
- `1-5` - Switch views (Status, Mesh, Capabilities, RPC, Logs)
- `r` - Refresh current view
- `q` - Quit
