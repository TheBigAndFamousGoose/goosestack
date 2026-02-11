# GooseStack API

Credit-based AI proxy gateway. Routes requests to Anthropic and OpenAI with per-user API keys, prepaid credits, and Stripe billing.

## Quick Start

```bash
cd api/
npm install
cp .env.example .env
# Fill in your API keys and Stripe credentials in .env
node server.js
```

Server runs on `http://localhost:3000` by default.

## Architecture

Single-process Node.js + SQLite. No Redis, no Postgres, no queue. Handles ~100 req/s on a $5 VPS.

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│  Client app  │────▶│  GooseStack API  │────▶│  Anthropic   │
│  (gsk_ key)  │◀────│  (credit gate)   │◀────│  / OpenAI    │
└─────────────┘     └──────────────────┘     └─────────────┘
                           │
                    ┌──────┴──────┐
                    │   SQLite    │
                    │  (users,    │
                    │   credits,  │
                    │   usage)    │
                    └─────────────┘
```

## API Endpoints

### Issue API Key

```bash
curl -X POST http://localhost:3000/v1/keys \
  -H "Content-Type: application/json" \
  -d '{"email": "user@example.com", "name": "my-agent"}'
```

Returns a `gsk_` key. **Save it — cannot be retrieved again.**

### OpenAI-Compatible Proxy

```bash
curl http://localhost:3000/v1/chat/completions \
  -H "Authorization: Bearer gsk_YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

Supports streaming (`"stream": true`).

### Anthropic-Compatible Proxy

```bash
curl http://localhost:3000/v1/messages \
  -H "Authorization: Bearer gsk_YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

### Check Usage & Balance

```bash
curl http://localhost:3000/v1/usage \
  -H "Authorization: Bearer gsk_YOUR_KEY"
```

### Buy Credits (Stripe Checkout)

```bash
curl -X POST http://localhost:3000/billing/checkout \
  -H "Authorization: Bearer gsk_YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"type": "credits", "amount": 1000}'
```

Valid amounts: `1000` ($10), `2500` ($25), `5000` ($50), `10000` ($100).

### Subscribe to Pro ($10/mo)

```bash
curl -X POST http://localhost:3000/billing/checkout \
  -H "Authorization: Bearer gsk_YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"type": "pro"}'
```

Pro subscribers can use BYOK (Bring Your Own Key) by passing `X-Provider-Key` header.

### Manage Billing

```bash
curl http://localhost:3000/billing/portal \
  -H "Authorization: Bearer gsk_YOUR_KEY"
```

Returns a Stripe Customer Portal URL.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `PORT` | No | Server port (default: 3000) |
| `OPENAI_API_KEY` | Yes | Master OpenAI API key |
| `ANTHROPIC_API_KEY` | Yes | Master Anthropic API key |
| `STRIPE_SECRET_KEY` | Yes | Stripe secret key |
| `STRIPE_WEBHOOK_SECRET` | Yes | Stripe webhook signing secret |
| `STRIPE_PRO_PRICE_ID` | No | Fixed Stripe Price ID for Pro subscription |
| `CHECKOUT_SUCCESS_URL` | No | Post-checkout redirect URL |
| `CHECKOUT_CANCEL_URL` | No | Checkout cancellation redirect URL |
| `PORTAL_RETURN_URL` | No | Portal return URL |
| `DB_PATH` | No | SQLite database path (default: `./goosestack.db`) |

## Stripe Webhook Setup

1. In Stripe Dashboard → Webhooks → Add endpoint
2. URL: `https://api.goosestack.com/billing/webhook`
3. Events to listen for:
   - `checkout.session.completed`
   - `invoice.paid`
   - `invoice.payment_failed`
   - `customer.subscription.deleted`
4. Copy the signing secret to `STRIPE_WEBHOOK_SECRET`

For local development:

```bash
stripe listen --forward-to localhost:3000/billing/webhook
```

## Credit System

- All credits are in USD cents (integers — no floating point)
- Credits are prepaid only — balance can never go negative
- Before each request, we estimate max cost and check the balance
- After the response, we bill actual tokens (always rounds up)
- If balance is insufficient, returns HTTP 402

## BYOK (Bring Your Own Key)

Pro subscribers ($10/mo) can pass their own provider API key:

```bash
curl http://localhost:3000/v1/chat/completions \
  -H "Authorization: Bearer gsk_YOUR_KEY" \
  -H "X-Provider-Key: sk-your-openai-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4o", "messages": [...]}'
```

BYOK requests don't deduct credits — users pay their provider directly.

## Production Deployment

```bash
# Install deps
npm install --production

# Run with systemd, PM2, or similar
PORT=3000 node server.js
```

Recommended: put behind nginx/Caddy for TLS termination.

### Caddy example:

```
api.goosestack.com {
    reverse_proxy localhost:3000
}
```

### Backups:

```bash
# SQLite backup (safe even while running with WAL)
sqlite3 goosestack.db ".backup /backups/goosestack-$(date +%Y%m%d).db"
```

## Database

SQLite with WAL mode. Tables:

- **users** — id, email, stripe_customer_id, pro_until, created_at
- **api_keys** — key_hash (SHA-256), key_prefix, user_id, name, revoked
- **credits** — user_id, balance_cents, updated_at
- **usage_log** — user_id, provider, model, tokens, cost, timestamp

All money in cents. All timestamps in UTC ISO 8601.
