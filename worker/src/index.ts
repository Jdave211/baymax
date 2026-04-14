/**
 * Baymac Proxy Worker
 *
 * Proxies requests to Claude, ElevenLabs, and Stripe APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat              → Anthropic Messages API (streaming)
 *   POST /tts               → ElevenLabs TTS API
 *   POST /transcribe-token  → AssemblyAI temp token
 *   POST /log               → Insert interaction log into Supabase (service_role)
 *   POST /embed             → Generate embedding via Workers AI & update log row
 *   POST /usage               → Return this month's interaction count + tier + limit
 *   POST /stripe/checkout     → Create Stripe Checkout session
 *   POST /stripe/payg-subscribe → Enable pay-as-you-go metered billing for free users
 *   POST /stripe/report-usage   → Report 1 interaction to Stripe for pay-as-you-go users
 *   POST /stripe/payg-status    → Check pay-as-you-go status and remaining cap
 *   POST /stripe/portal     → Create Stripe Customer Portal session
 *   POST /stripe/webhook    → Handle Stripe webhooks
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  AI: Ai;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }

      if (url.pathname === "/log") {
        return await handleLog(request, env);
      }

      if (url.pathname === "/embed") {
        return await handleEmbed(request, env);
      }

      if (url.pathname === "/usage") {
        return await handleUsage(request, env);
      }

      if (url.pathname === "/stripe/checkout") {
        return await handleStripeCheckout(request, env);
      }

      if (url.pathname === "/stripe/portal") {
        return await handleStripePortal(request, env);
      }

      if (url.pathname === "/stripe/webhook") {
        return await handleStripeWebhook(request, env);
      }

      if (url.pathname === "/stripe/payg-subscribe") {
        return await handlePaygSubscribe(request, env);
      }

      if (url.pathname === "/stripe/report-usage") {
        return await handleReportUsage(request, env);
      }

      if (url.pathname === "/stripe/payg-status") {
        return await handlePaygStatus(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "anthropic-beta": "prompt-caching-2024-07-31",
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const requestBody = await request.json() as { voiceId?: string; [key: string]: unknown };
  const voiceId = requestBody.voiceId || env.ELEVENLABS_VOICE_ID;

  // Remove voiceId from the body before forwarding to ElevenLabs
  const { voiceId: _, ...elevenlabsBody } = requestBody;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body: JSON.stringify(elevenlabsBody),
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}

async function handleLog(request: Request, env: Env): Promise<Response> {
  const { userId, transcript, aiResponse, characterName, characterColor } = await request.json() as {
    userId: string;
    transcript: string;
    aiResponse: string;
    characterName: string;
    characterColor: string;
  };

  if (!userId || !transcript) {
    return new Response(
      JSON.stringify({ error: "Missing required fields: userId, transcript" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  const logRow = {
    user_id: userId,
    transcript,
    ai_response: aiResponse || "",
    character_name: characterName || "",
    character_color: characterColor || "",
    created_at: new Date().toISOString(),
  };

  const supabaseResponse = await fetch(
    `${env.SUPABASE_URL}/rest/v1/baymax_logs`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        Prefer: "return=representation",
      },
      body: JSON.stringify(logRow),
    }
  );

  if (!supabaseResponse.ok) {
    const errorText = await supabaseResponse.text();
    console.error("[/log] Supabase insert failed:", errorText);
    return new Response(
      JSON.stringify({ error: "Failed to insert log", detail: errorText }),
      { status: supabaseResponse.status, headers: corsHeaders() }
    );
  }

  const insertedRows = await supabaseResponse.json() as { id: string }[];
  const insertedLogId = insertedRows?.[0]?.id;

  // Fire-and-forget: generate embedding asynchronously so it never blocks the client
  if (insertedLogId && env.AI) {
    const embeddingText = `${transcript} ${aiResponse || ""}`.trim();
    const selfUrl = new URL(request.url);
    selfUrl.pathname = "/embed";

    // Use waitUntil-style fire-and-forget via a non-awaited fetch to self
    fetch(selfUrl.toString(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ logId: insertedLogId, text: embeddingText }),
    }).catch((err) => console.error("[/log] async embed dispatch failed:", err));
  }

  return new Response(
    JSON.stringify({ success: true, id: insertedLogId }),
    { status: 201, headers: corsHeaders() }
  );
}

async function handleEmbed(request: Request, env: Env): Promise<Response> {
  const { logId, text } = await request.json() as { logId: string; text: string };

  if (!logId || !text) {
    return new Response(
      JSON.stringify({ error: "Missing required fields: logId, text" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  if (!env.AI) {
    return new Response(
      JSON.stringify({ error: "Workers AI binding not configured" }),
      { status: 500, headers: corsHeaders() }
    );
  }

  // Generate embedding via Cloudflare Workers AI (768 dimensions, free tier)
  const embeddingResponse = await env.AI.run("@cf/baai/bge-base-en-v1.5", {
    text: [text],
  }) as { data: number[][] };

  const embeddingVector = embeddingResponse?.data?.[0];
  if (!embeddingVector) {
    console.error("[/embed] Workers AI returned no embedding for log:", logId);
    return new Response(
      JSON.stringify({ error: "Embedding generation failed" }),
      { status: 500, headers: corsHeaders() }
    );
  }

  // Format as pgvector literal: [0.1,0.2,...]
  const pgvectorLiteral = `[${embeddingVector.join(",")}]`;

  const updateResponse = await fetch(
    `${env.SUPABASE_URL}/rest/v1/baymax_logs?id=eq.${logId}`,
    {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
      body: JSON.stringify({ embedding: pgvectorLiteral }),
    }
  );

  if (!updateResponse.ok) {
    const errorText = await updateResponse.text();
    console.error("[/embed] Supabase embedding update failed:", errorText);
    return new Response(
      JSON.stringify({ error: "Embedding update failed", detail: errorText }),
      { status: updateResponse.status, headers: corsHeaders() }
    );
  }

  return new Response(
    JSON.stringify({ success: true, logId, dimensions: embeddingVector.length }),
    { status: 200, headers: corsHeaders() }
  );
}

function getMonthlyLimitForTier(tier: string): number {
  switch (tier) {
    case "pro": return 500;
    case "max": return 1500;
    case "lifetime": return 500;
    default: return 20;
  }
}

async function handleUsage(request: Request, env: Env): Promise<Response> {
  const { userId } = await request.json() as { userId: string };

  if (!userId) {
    return new Response(
      JSON.stringify({ error: "Missing required field: userId" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  // First day of the current month in UTC
  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));

  // Count this month's logged interactions using PostgREST exact count
  const countResponse = await fetch(
    `${env.SUPABASE_URL}/rest/v1/baymax_logs?user_id=eq.${userId}&created_at=gte.${monthStart.toISOString()}&select=id`,
    {
      method: "GET",
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        Prefer: "count=exact",
        Range: "0-0",
      },
    }
  );

  let interactionsThisMonth = 0;
  const contentRange = countResponse.headers.get("content-range");
  if (contentRange) {
    const parts = contentRange.split("/");
    if (parts.length === 2) {
      interactionsThisMonth = parseInt(parts[1]) || 0;
    }
  }

  const profileResponse = await fetch(
    `${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}&select=tier`,
    {
      method: "GET",
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    }
  );

  const profiles = await profileResponse.json() as { tier?: string }[];
  const tier = profiles?.[0]?.tier || "free";
  const monthlyLimit = getMonthlyLimitForTier(tier);

  return new Response(
    JSON.stringify({ interactionsThisMonth, monthlyLimit, tier }),
    { status: 200, headers: corsHeaders() }
  );
}

// Stripe API helper for making authenticated requests
async function stripeRequest(
  endpoint: string,
  method: string,
  body: Record<string, string> | null,
  env: Env
): Promise<Response> {
  const url = `https://api.stripe.com/v1${endpoint}`;
  const headers: Record<string, string> = {
    Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
  };

  const options: RequestInit = { method, headers };

  if (body) {
    headers["Content-Type"] = "application/x-www-form-urlencoded";
    options.body = new URLSearchParams(body).toString();
  }

  return fetch(url, options);
}

async function handleStripeCheckout(request: Request, env: Env): Promise<Response> {
  const { priceId, userId, email, successUrl, cancelUrl, tier } = await request.json() as {
    priceId: string;
    userId: string;
    email: string;
    successUrl: string;
    cancelUrl: string;
    tier: string;
  };

  if (!priceId || !userId || !email) {
    return new Response(
      JSON.stringify({ error: "Missing required fields: priceId, userId, email" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  const checkoutParams: Record<string, string> = {
    "mode": tier === 'lifetime' ? "payment" : "subscription",
    "customer_email": email,
    "line_items[0][price]": priceId,
    "line_items[0][quantity]": "1",
    "success_url": successUrl || "https://baymac.app/success",
    "cancel_url": cancelUrl || "https://baymac.app/",
    "metadata[user_id]": userId,
    "metadata[tier]": tier || "pro",
  };
  
  if (tier !== 'lifetime') {
    checkoutParams["subscription_data[metadata][user_id]"] = userId;
    checkoutParams["subscription_data[metadata][tier]"] = tier || "pro";
  }

  const response = await stripeRequest("/checkout/sessions", "POST", checkoutParams, env);
  const data = await response.json() as { url?: string; error?: { message: string } };

  if (!response.ok) {
    console.error("[/stripe/checkout] Stripe error:", data);
    return new Response(JSON.stringify({ error: data.error?.message || "Checkout failed" }), {
      status: response.status,
      headers: corsHeaders(),
    });
  }

  return new Response(JSON.stringify({ url: data.url }), {
    status: 200,
    headers: corsHeaders(),
  });
}

async function handleStripePortal(request: Request, env: Env): Promise<Response> {
  const { customerId, returnUrl } = await request.json() as {
    customerId: string;
    returnUrl: string;
  };

  if (!customerId) {
    return new Response(
      JSON.stringify({ error: "Missing required field: customerId" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  const portalParams: Record<string, string> = {
    customer: customerId,
    return_url: returnUrl || "https://baymac.app/",
  };

  const response = await stripeRequest("/billing_portal/sessions", "POST", portalParams, env);
  const data = await response.json() as { url?: string; error?: { message: string } };

  if (!response.ok) {
    console.error("[/stripe/portal] Stripe error:", data);
    return new Response(JSON.stringify({ error: data.error?.message || "Portal creation failed" }), {
      status: response.status,
      headers: corsHeaders(),
    });
  }

  return new Response(JSON.stringify({ url: data.url }), {
    status: 200,
    headers: corsHeaders(),
  });
}

async function handleStripeWebhook(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const signature = request.headers.get("stripe-signature");

  if (!signature) {
    return new Response(JSON.stringify({ error: "Missing stripe-signature header" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  // For production, you should verify the webhook signature
  // This requires the stripe library or manual HMAC verification
  // For now, we'll parse the event directly (add verification in production)

  let event;
  try {
    event = JSON.parse(body) as {
      type: string;
      data: {
        object: {
          id: string;
          customer: string;
          status: string;
          payment_status?: string;
          metadata?: { user_id?: string; tier?: string };
          current_period_end?: number;
        };
      };
    };
  } catch (err) {
    console.error("[/stripe/webhook] Invalid JSON:", err);
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  console.log(`[/stripe/webhook] Received event: ${event.type}`);

  const subscription = event.data.object;
  const userId = subscription.metadata?.user_id;

  if (!userId) {
    console.log("[/stripe/webhook] No user_id in metadata, skipping");
    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  // Update user tier in Supabase based on subscription status
  let tier = "free";
  const requestedTier = subscription.metadata?.tier || "pro";

  if (
    event.type === "customer.subscription.created" ||
    event.type === "customer.subscription.updated"
  ) {
    if (subscription.status === "active" || subscription.status === "trialing") {
      tier = requestedTier;
    }
  } else if (
    event.type === "checkout.session.completed" &&
    requestedTier === "lifetime" &&
    subscription.payment_status === "paid"
  ) {
    tier = "lifetime";
  } else if (
    event.type === "customer.subscription.deleted" ||
    event.type === "customer.subscription.paused"
  ) {
    tier = "free";
  }

  // Update Supabase profile
  if (env.SUPABASE_URL && env.SUPABASE_SERVICE_KEY) {
    try {
      const supabaseResponse = await fetch(
        `${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}`,
        {
          method: "PATCH",
          headers: {
            "Content-Type": "application/json",
            apikey: env.SUPABASE_SERVICE_KEY,
            Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
          body: JSON.stringify({
            tier,
            stripe_customer_id: subscription.customer,
            stripe_subscription_id: subscription.id,
            subscription_status: subscription.status,
            current_period_end: subscription.current_period_end
              ? new Date(subscription.current_period_end * 1000).toISOString()
              : null,
            updated_at: new Date().toISOString(),
          }),
        }
      );

      if (!supabaseResponse.ok) {
        const errorText = await supabaseResponse.text();
        console.error("[/stripe/webhook] Supabase update failed:", errorText);
      } else {
        console.log(`[/stripe/webhook] Updated user ${userId} to tier: ${tier}`);
      }
    } catch (err) {
      console.error("[/stripe/webhook] Supabase request failed:", err);
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

// Pay-as-you-go: $0.07 CAD per interaction after free tier, user-selected cap
const PAYG_PRICE_ID = "price_1TKbwZPL9XW4eka1dFAZnx6E";
const PAYG_PRICE_CENTS = 7; // $0.07 per interaction
const AVAILABLE_CAPS_CENTS = [500, 1000, 2000, 5000]; // $5, $10, $20, $50 options

async function handlePaygSubscribe(request: Request, env: Env): Promise<Response> {
  const { userId, email, capCents } = await request.json() as { userId: string; email: string; capCents: number };

  if (!userId || !email || !capCents) {
    return new Response(
      JSON.stringify({ error: "Missing required fields: userId, email, capCents" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  // Validate cap is one of the allowed values
  if (!AVAILABLE_CAPS_CENTS.includes(capCents)) {
    return new Response(
      JSON.stringify({ error: `Invalid cap. Must be one of: ${AVAILABLE_CAPS_CENTS.join(", ")}` }),
      { status: 400, headers: corsHeaders() }
    );
  }

  // Check if user already has a customer ID
  const profileResponse = await fetch(
    `${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}&select=stripe_customer_id,stripe_payg_subscription_id`,
    {
      method: "GET",
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    }
  );

  const profiles = await profileResponse.json() as { 
    stripe_customer_id?: string; 
    stripe_payg_subscription_id?: string;
  }[];
  
  const profile = profiles?.[0];

  // If already has active payg subscription, return it
  if (profile?.stripe_payg_subscription_id) {
    return new Response(
      JSON.stringify({ 
        success: true, 
        subscriptionId: profile.stripe_payg_subscription_id,
        message: "Pay-as-you-go already active" 
      }),
      { status: 200, headers: corsHeaders() }
    );
  }

  // Get or create Stripe customer
  let customerId = profile?.stripe_customer_id;
  if (!customerId) {
    const customerResponse = await stripeRequest("/customers", "POST", {
      email,
      "metadata[user_id]": userId,
    }, env);
    const customerData = await customerResponse.json() as { id: string };
    customerId = customerData.id;
  }

  // Create metered subscription
  const subscriptionResponse = await stripeRequest("/subscriptions", "POST", {
    customer: customerId,
    "items[0][price]": PAYG_PRICE_ID,
    "metadata[user_id]": userId,
    "metadata[type]": "payg",
    "metadata[cap_cents]": capCents.toString(),
  }, env);

  const subscriptionData = await subscriptionResponse.json() as { 
    id?: string; 
    error?: { message: string };
    items?: { data: { id: string }[] };
  };

  if (!subscriptionResponse.ok || !subscriptionData.id) {
    console.error("[/stripe/payg-subscribe] Stripe error:", subscriptionData);
    return new Response(
      JSON.stringify({ error: subscriptionData.error?.message || "Failed to create subscription" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  const subscriptionItemId = subscriptionData.items?.data?.[0]?.id;

  // Update Supabase profile with subscription info
  await fetch(
    `${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}`,
    {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
      body: JSON.stringify({
        stripe_customer_id: customerId,
        stripe_payg_subscription_id: subscriptionData.id,
        stripe_payg_item_id: subscriptionItemId,
        payg_cap_cents: capCents,
        payg_usage_this_period: 0,
        updated_at: new Date().toISOString(),
      }),
    }
  );

  return new Response(
    JSON.stringify({ 
      success: true, 
      subscriptionId: subscriptionData.id,
      message: "Pay-as-you-go enabled" 
    }),
    { status: 200, headers: corsHeaders() }
  );
}

async function handleReportUsage(request: Request, env: Env): Promise<Response> {
  const { userId } = await request.json() as { userId: string };

  if (!userId) {
    return new Response(
      JSON.stringify({ error: "Missing required field: userId" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  // Get user's payg subscription item ID, current usage, and cap
  const profileResponse = await fetch(
    `${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}&select=stripe_payg_item_id,payg_usage_this_period,payg_cap_cents`,
    {
      method: "GET",
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    }
  );

  const profiles = await profileResponse.json() as { 
    stripe_payg_item_id?: string;
    payg_usage_this_period?: number;
    payg_cap_cents?: number;
  }[];
  
  const profile = profiles?.[0];

  if (!profile?.stripe_payg_item_id) {
    return new Response(
      JSON.stringify({ error: "User does not have pay-as-you-go enabled" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  const currentUsage = profile.payg_usage_this_period || 0;
  const userCapCents = profile.payg_cap_cents || 1000; // Default to $10 if not set
  const maxInteractions = Math.floor(userCapCents / PAYG_PRICE_CENTS);

  // Check if at cap
  if (currentUsage >= maxInteractions) {
    return new Response(
      JSON.stringify({ 
        success: false, 
        atCap: true,
        message: "Monthly pay-as-you-go cap reached" 
      }),
      { status: 200, headers: corsHeaders() }
    );
  }

  // Report 1 unit of usage to Stripe
  const usageResponse = await stripeRequest("/subscription_items/" + profile.stripe_payg_item_id + "/usage_records", "POST", {
    quantity: "1",
    action: "increment",
  }, env);

  if (!usageResponse.ok) {
    const errorData = await usageResponse.json();
    console.error("[/stripe/report-usage] Stripe error:", errorData);
    return new Response(
      JSON.stringify({ error: "Failed to report usage" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  // Update local usage counter
  await fetch(
    `${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}`,
    {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
      body: JSON.stringify({
        payg_usage_this_period: currentUsage + 1,
        updated_at: new Date().toISOString(),
      }),
    }
  );

  return new Response(
    JSON.stringify({ 
      success: true, 
      usage: currentUsage + 1,
      remaining: maxInteractions - (currentUsage + 1),
    }),
    { status: 200, headers: corsHeaders() }
  );
}

async function handlePaygStatus(request: Request, env: Env): Promise<Response> {
  const { userId } = await request.json() as { userId: string };

  if (!userId) {
    return new Response(
      JSON.stringify({ error: "Missing required field: userId" }),
      { status: 400, headers: corsHeaders() }
    );
  }

  const profileResponse = await fetch(
    `${env.SUPABASE_URL}/rest/v1/profiles?id=eq.${userId}&select=stripe_payg_subscription_id,payg_usage_this_period,payg_cap_cents`,
    {
      method: "GET",
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    }
  );

  const profiles = await profileResponse.json() as { 
    stripe_payg_subscription_id?: string;
    payg_usage_this_period?: number;
    payg_cap_cents?: number;
  }[];
  
  const profile = profiles?.[0];
  const hasPayg = !!profile?.stripe_payg_subscription_id;
  const usage = profile?.payg_usage_this_period || 0;
  const userCapCents = profile?.payg_cap_cents || 1000;
  const maxInteractions = Math.floor(userCapCents / PAYG_PRICE_CENTS);

  return new Response(
    JSON.stringify({ 
      enabled: hasPayg,
      usage,
      cap: maxInteractions,
      capCents: userCapCents,
      remaining: hasPayg ? Math.max(0, maxInteractions - usage) : 0,
      atCap: usage >= maxInteractions,
    }),
    { status: 200, headers: corsHeaders() }
  );
}

function corsHeaders(): Record<string, string> {
  return {
    "content-type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
}
