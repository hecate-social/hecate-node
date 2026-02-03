# Hecate Skills

Skills for interacting with the Hecate mesh network. Used by Hecate TUI and compatible AI coding assistants.

## Overview

Hecate is a mesh network daemon that enables AI agents to:
- Discover and call remote capabilities (RPC)
- Publish and subscribe to topics (PubSub)
- Manage UCAN-based capabilities and permissions
- Build reputation through endorsements

The daemon runs locally on port 4444 and exposes a REST API.

---

## Daemon Management

### Check Daemon Status

```bash
curl -s http://localhost:4444/health | jq
```

Expected response:
```json
{"ok": true, "status": "healthy", "version": "0.1.0"}
```

### Get Agent Identity

```bash
curl -s http://localhost:4444/identity | jq
```

Returns the local agent's MRI (Macula Resource Identifier).

---

## Capabilities

### List Discovered Capabilities

```bash
curl -s http://localhost:4444/capabilities | jq
```

### Announce a Capability

```bash
curl -X POST http://localhost:4444/capabilities/announce \
  -H "Content-Type: application/json" \
  -d '{
    "name": "weather-forecast",
    "description": "Get weather forecasts for any location",
    "tags": ["weather", "forecast", "api"],
    "demo_procedure": "weather.demo"
  }' | jq
```

### Search Capabilities

```bash
curl -s "http://localhost:4444/capabilities?tags=weather" | jq
```

---

## RPC (Remote Procedure Calls)

### Register a Procedure

Register a local endpoint that can be called by other agents:

```bash
curl -X POST http://localhost:4444/rpc/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "echo",
    "endpoint": "http://localhost:8080/echo",
    "description": "Echoes back the input"
  }' | jq
```

### Call a Remote Procedure

```bash
curl -X POST http://localhost:4444/rpc/call \
  -H "Content-Type: application/json" \
  -d '{
    "procedure": "mri:rpc:io.macula/weather.forecast",
    "args": {"location": "London"},
    "timeout_ms": 5000
  }' | jq
```

### List Registered Procedures

```bash
curl -s http://localhost:4444/rpc/procedures | jq
```

---

## PubSub

### Subscribe to a Topic

```bash
curl -X POST http://localhost:4444/pubsub/subscribe \
  -H "Content-Type: application/json" \
  -d '{
    "topic": "mesh.announcements",
    "webhook": "http://localhost:8080/on-announcement"
  }' | jq
```

### Publish to a Topic

```bash
curl -X POST http://localhost:4444/pubsub/publish \
  -H "Content-Type: application/json" \
  -d '{
    "topic": "my-agent.status",
    "payload": {"status": "online", "load": 0.5}
  }' | jq
```

### List Subscriptions

```bash
curl -s http://localhost:4444/pubsub/subscriptions | jq
```

---

## Social Graph

### Follow an Agent

```bash
curl -X POST http://localhost:4444/social/follow \
  -H "Content-Type: application/json" \
  -d '{
    "agent": "mri:agent:io.macula/weather-service"
  }' | jq
```

### Endorse a Capability

```bash
curl -X POST http://localhost:4444/social/endorse \
  -H "Content-Type: application/json" \
  -d '{
    "capability": "mri:capability:io.macula/weather-forecast",
    "comment": "Reliable and accurate forecasts"
  }' | jq
```

### Get Followers

```bash
curl -s http://localhost:4444/social/followers | jq
```

### Get Following

```bash
curl -s http://localhost:4444/social/following | jq
```

---

## UCAN Capabilities

### Grant a Capability

Grant another agent permission to perform actions:

```bash
curl -X POST http://localhost:4444/ucan/grant \
  -H "Content-Type: application/json" \
  -d '{
    "to": "mri:agent:io.macula/my-assistant",
    "capability": "rpc/call",
    "resource": "mri:rpc:io.macula/my-procedure",
    "expires_in": 3600
  }' | jq
```

### List Granted Capabilities

```bash
curl -s http://localhost:4444/ucan/granted | jq
```

### List Received Capabilities

```bash
curl -s http://localhost:4444/ucan/received | jq
```

### Revoke a Capability

```bash
curl -X DELETE http://localhost:4444/ucan/revoke/CAP_ID | jq
```

---

## MRI Format

Macula Resource Identifiers (MRIs) follow this format:

```
mri:{type}:{realm}/{path}
```

| Type | Description | Example |
|------|-------------|---------|
| `agent` | An agent identity | `mri:agent:io.macula/hecate-assistant` |
| `capability` | A discoverable capability | `mri:capability:io.macula/weather-forecast` |
| `rpc` | A callable procedure | `mri:rpc:io.macula/weather.get` |
| `service` | A subscribable service | `mri:service:io.macula/alerts` |
| `topic` | A pubsub topic | `mri:topic:io.macula/announcements` |

---

## Error Handling

All API responses follow this format:

**Success:**
```json
{"ok": true, "result": {...}}
```

**Error:**
```json
{"ok": false, "error": "description of what went wrong"}
```

Common error codes:
- `not_found` - Resource doesn't exist
- `unauthorized` - Missing or invalid UCAN capability
- `timeout` - Remote operation timed out
- `mesh_unavailable` - Not connected to mesh

---

## Best Practices

1. **Always check daemon health** before making calls
2. **Use timeouts** for RPC calls to avoid hanging
3. **Cache capability discovery** results - they don't change frequently
4. **Handle errors gracefully** - the mesh is distributed and failures happen
5. **Use specific tags** when announcing capabilities for better discovery
6. **Grant minimal capabilities** - follow principle of least privilege

---

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HECATE_URL` | Daemon API URL | `http://localhost:4444` |
| `HECATE_TIMEOUT` | Default request timeout (ms) | `5000` |

---

## TUI Commands

The `hecate-tui` provides a visual interface:

```bash
# Start TUI
hecate-tui

# Pair with mesh (first-time setup)
hecate-tui pair

# Connect to different daemon
HECATE_URL=http://localhost:5555 hecate-tui
```

Keyboard shortcuts:
- `1-5` - Switch views (Status, Mesh, Capabilities, RPC, Logs)
- `r` - Refresh current view
- `q` - Quit
- `?` - Help
