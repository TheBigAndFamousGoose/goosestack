/**
 * stripe.js — Stripe billing routes for GooseStack API
 *
 * Handles:
 *   POST /billing/checkout  — Create a Stripe Checkout session (credits or Pro sub)
 *   POST /billing/webhook   — Stripe webhook receiver (credits + subscription events)
 *   GET  /billing/portal    — Redirect to Stripe Customer Portal
 *
 * All credit amounts are in USD cents. Stripe also works in cents natively.
 */

const express = require('express');
const Stripe = require('stripe');
const db = require('./db');

const router = express.Router();

// Stripe client — initialized lazily so server can start without key during dev
let stripe;
function getStripe() {
  if (!stripe) {
    if (!process.env.STRIPE_SECRET_KEY) {
      throw new Error('STRIPE_SECRET_KEY environment variable is required');
    }
    stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
  }
  return stripe;
}

// ----- Credit top-up products -----
// Maps dollar amounts to what the user gets in credits (cents).
// We can adjust these to include bonuses later (e.g., $100 → $110 in credits).
const CREDIT_TIERS = {
  1000:  { credits_cents: 1000,  label: '$10 Credits' },
  2500:  { credits_cents: 2500,  label: '$25 Credits' },
  5000:  { credits_cents: 5000,  label: '$50 Credits' },
  10000: { credits_cents: 10000, label: '$100 Credits' },
};

const PRO_MONTHLY_CENTS = 1000; // $10/mo

// The URL users return to after checkout
const SUCCESS_URL = process.env.CHECKOUT_SUCCESS_URL || 'https://goosestack.com/billing?success=1';
const CANCEL_URL = process.env.CHECKOUT_CANCEL_URL || 'https://goosestack.com/billing?cancelled=1';

// ============================================================
// POST /billing/checkout
// Body: { type: 'credits' | 'pro', amount?: 1000|2500|5000|10000 }
// Auth: Bearer gsk_xxx
// ============================================================
router.post('/checkout', async (req, res) => {
  try {
    const user = req.user; // set by auth middleware in server.js
    if (!user) return res.status(401).json({ error: 'Authentication required' });

    const { type, amount } = req.body;

    const s = getStripe();

    // Ensure user has a Stripe customer ID
    let customerId = user.stripe_customer_id;
    if (!customerId) {
      const customer = await s.customers.create({
        email: user.email,
        metadata: { goosestack_user_id: String(user.id) },
      });
      customerId = customer.id;
      db.setStripeCustomerId(user.id, customerId);
    }

    let sessionParams;

    if (type === 'credits') {
      // ----- One-time credit purchase -----
      const tier = CREDIT_TIERS[amount];
      if (!tier) {
        return res.status(400).json({
          error: 'Invalid amount',
          valid_amounts: Object.keys(CREDIT_TIERS).map(Number),
        });
      }

      sessionParams = {
        customer: customerId,
        mode: 'payment',
        line_items: [{
          price_data: {
            currency: 'usd',
            product_data: {
              name: `GooseStack ${tier.label}`,
              description: 'API credits for GooseStack AI routing',
            },
            unit_amount: amount,
          },
          quantity: 1,
        }],
        metadata: {
          type: 'credits',
          credits_cents: String(tier.credits_cents),
          user_id: String(user.id),
        },
        success_url: SUCCESS_URL,
        cancel_url: CANCEL_URL,
      };

    } else if (type === 'pro') {
      // ----- Pro subscription ($10/mo) -----
      // We create a price on the fly. In production you'd use a fixed Price ID.
      // For now, use process.env.STRIPE_PRO_PRICE_ID if set.
      const priceId = process.env.STRIPE_PRO_PRICE_ID;

      if (priceId) {
        sessionParams = {
          customer: customerId,
          mode: 'subscription',
          line_items: [{ price: priceId, quantity: 1 }],
          metadata: { type: 'pro', user_id: String(user.id) },
          success_url: SUCCESS_URL,
          cancel_url: CANCEL_URL,
        };
      } else {
        // Ad-hoc price creation (dev/bootstrap mode)
        sessionParams = {
          customer: customerId,
          mode: 'subscription',
          line_items: [{
            price_data: {
              currency: 'usd',
              product_data: {
                name: 'GooseStack Pro',
                description: 'Pro subscription — BYOK support + priority routing',
              },
              unit_amount: PRO_MONTHLY_CENTS,
              recurring: { interval: 'month' },
            },
            quantity: 1,
          }],
          metadata: { type: 'pro', user_id: String(user.id) },
          success_url: SUCCESS_URL,
          cancel_url: CANCEL_URL,
        };
      }

    } else {
      return res.status(400).json({ error: 'type must be "credits" or "pro"' });
    }

    const session = await s.checkout.sessions.create(sessionParams);
    res.json({ url: session.url, session_id: session.id });

  } catch (err) {
    console.error('[stripe] checkout error:', err.message);
    res.status(500).json({ error: 'Failed to create checkout session' });
  }
});

// ============================================================
// GET /billing/portal
// Auth: Bearer gsk_xxx
// ============================================================
router.get('/portal', async (req, res) => {
  try {
    const user = req.user;
    if (!user) return res.status(401).json({ error: 'Authentication required' });
    if (!user.stripe_customer_id) {
      return res.status(400).json({ error: 'No billing account found. Make a purchase first.' });
    }

    const s = getStripe();
    const portalSession = await s.billingPortal.sessions.create({
      customer: user.stripe_customer_id,
      return_url: process.env.PORTAL_RETURN_URL || 'https://goosestack.com/billing',
    });

    res.json({ url: portalSession.url });
  } catch (err) {
    console.error('[stripe] portal error:', err.message);
    res.status(500).json({ error: 'Failed to create portal session' });
  }
});

// ============================================================
// POST /billing/webhook
// Raw body required for Stripe signature verification
// ============================================================
router.post('/webhook', express.raw({ type: 'application/json' }), async (req, res) => {
  const sig = req.headers['stripe-signature'];
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;

  if (!webhookSecret) {
    console.error('[stripe] STRIPE_WEBHOOK_SECRET not set!');
    return res.status(500).send('Webhook secret not configured');
  }

  let event;
  try {
    event = getStripe().webhooks.constructEvent(req.body, sig, webhookSecret);
  } catch (err) {
    console.error('[stripe] webhook signature failed:', err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  console.log(`[stripe] webhook: ${event.type}`);

  try {
    switch (event.type) {
      // ----- One-time payment completed (credit top-up) -----
      case 'checkout.session.completed': {
        const session = event.data.object;
        const paymentId = session.payment_intent || session.id;

        if (session.metadata?.type === 'credits' && session.payment_status === 'paid') {
          const userId = parseInt(session.metadata.user_id, 10);
          const creditsCents = parseInt(session.metadata.credits_cents, 10);

          if (userId && creditsCents > 0) {
            // Deduplicate: only credit if we haven't seen this payment before
            if (db.paymentExists(paymentId)) {
              console.log(`[stripe] duplicate payment ${paymentId} for user ${userId}, skipping credit`);
            } else {
              db.addCredits(userId, creditsCents);
              db.recordPayment(paymentId, userId, creditsCents, 'credits');
              console.log(`[stripe] credited ${creditsCents}¢ to user ${userId} (session: ${session.id}, payment: ${paymentId})`);
            }
          }
        }

        // Pro subscription — set pro_until on initial checkout
        if (session.metadata?.type === 'pro') {
          const userId = parseInt(session.metadata.user_id, 10);
          if (userId) {
            // Deduplicate pro activation
            if (db.paymentExists(paymentId)) {
              console.log(`[stripe] duplicate pro payment ${paymentId} for user ${userId}, skipping`);
            } else {
              // Set pro for 35 days (buffer beyond 1 month)
              const proUntil = new Date(Date.now() + 35 * 86400000).toISOString();
              db.setProUntil(userId, proUntil);
              db.recordPayment(paymentId, userId, 1000, 'pro');
              console.log(`[stripe] pro activated for user ${userId} until ${proUntil} (session: ${session.id}, payment: ${paymentId})`);
            }
          }
        }
        break;
      }

      // ----- Subscription renewed -----
      case 'invoice.paid': {
        const invoice = event.data.object;
        if (invoice.subscription) {
          const customerId = invoice.customer;
          const user = db.getUserByStripeCustomer(customerId);
          if (user) {
            // Extend pro by 35 days from now
            const proUntil = new Date(Date.now() + 35 * 86400000).toISOString();
            db.setProUntil(user.id, proUntil);
            console.log(`[stripe] pro renewed for user ${user.id} until ${proUntil}`);
          }
        }
        break;
      }

      // ----- Subscription cancelled or payment failed -----
      case 'customer.subscription.deleted': {
        const sub = event.data.object;
        const user = db.getUserByStripeCustomer(sub.customer);
        if (user) {
          // Let existing pro period expire naturally (don't revoke immediately)
          console.log(`[stripe] subscription cancelled for user ${user.id}, pro expires at ${user.pro_until}`);
        }
        break;
      }

      case 'invoice.payment_failed': {
        const invoice = event.data.object;
        const user = db.getUserByStripeCustomer(invoice.customer);
        if (user) {
          console.log(`[stripe] payment failed for user ${user.id}`);
          // Don't revoke immediately — Stripe will retry. Let pro_until handle expiry.
        }
        break;
      }

      default:
        // Unhandled event type — that's fine, just log
        break;
    }
  } catch (err) {
    console.error(`[stripe] webhook handler error for ${event.type}:`, err.message);
    // Still return 200 so Stripe doesn't retry (we logged the error)
  }

  // Always return 200 to acknowledge receipt
  res.json({ received: true });
});

module.exports = router;
