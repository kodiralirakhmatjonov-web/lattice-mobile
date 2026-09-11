// Retired in JSON Price Exchange v2.
//
// Price discovery no longer runs inside Cloudflare Workflows or Browser Rendering.
// iumrah Business exports a city-scoped JSON document, ChatGPT returns a reviewed
// price-update JSON document, and the active Worker validates/applies it through
// src/price-json.js only after explicit admin confirmation.
