# Vast.ai API - Elixir Integration Reference

## Overview

Vast.ai is a GPU cloud marketplace connecting compute providers with users needing GPU resources. This document provides a reference for integrating Vast.ai into Elixir applications.

## Base Configuration

```elixir
# Base URL
@base_url "https://console.vast.ai"

# API Version
@api_version "v0"

# Full API Base
@api_base "https://console.vast.ai/api/v0"
```

## Authentication

All API requests require Bearer token authentication using your API key.

```elixir
# Headers for all requests
defp auth_headers(api_key) do
  [
    {"Authorization", "Bearer #{api_key}"},
    {"Content-Type", "application/json"},
    {"Accept", "application/json"}
  ]
end
```

### Getting Your API Key

1. Visit https://console.vast.ai/cli/
2. Copy your API key
3. Store securely (environment variable recommended)

```elixir
# Config example
config :lumainus, :vast_ai,
  api_key: System.get_env("VAST_API_KEY")
```

## Permission Categories

API keys can have restricted permissions:

| Category | Description |
|----------|-------------|
| `instance_read` | View instances, logs |
| `instance_write` | Create, update, destroy instances |
| `user_read` | View user info, IP addresses |
| `user_write` | Create subaccounts, reset API key |
| `billing_read` | View earnings, invoices |
| `billing_write` | Transfer credits |
| `machine_read` | View hosted machines |
| `machine_write` | List/unlist machines, set pricing |
| `misc` | Search offers, copy data |
| `team_read` | View team info |
| `team_write` | Manage team members/roles |

## Response Format

All responses are JSON. Success responses typically include:

```json
{
  "success": true,
  "data": { ... }
}
```

Error responses:

```json
{
  "error": "error_code",
  "msg": "Human readable message"
}
```

## Rate Limiting

- Standard requests: Generally unrestricted
- `--disable-bundling` searches: More heavily rate limited
- Implement exponential backoff for retries

## Core Concepts

### Offers vs Instances

- **Offer**: Available GPU configuration for rent (from `search offers`)
- **Instance**: A rented GPU (created from an offer)

### Instance States

- `running` - Active and billable
- `stopped` - Paused, storage billable only
- `scheduling` - Starting up
- `exited` - Container exited

### Pricing Types

- **On-demand**: Fixed price, guaranteed availability
- **Spot/Bid**: Interruptible, lower price
- **Reserved**: Long-term commitment, discounted

## Next Steps

- See `api-endpoints.md` for complete endpoint reference
- See `elixir-types.md` for type specifications
- See `search-query-syntax.md` for offer filtering
