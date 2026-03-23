# Debug: Add console.error logging to catch blocks

**Date:** 2026-03-22
**Source:** Notion prompt `32c4cf98-04bf-8174-9cce-ec5b5626c92e`

## What was done

Added detailed `console.error` logging to both catch blocks in `index.html`:

1. **`generate()` catch block (line ~358)** — logs full error object, name, message, and stack trace before showing the alert
2. **`pickActivity()` catch block (line ~399)** — same logging added

## Why

The error `The string did not match the expected pattern` is thrown somewhere in the frontend but the exact line is unknown. The API is confirmed healthy (200 + valid JSON + correct CORS). These console.error calls will expose the full stack trace in the browser console.

## Findings

- No service workers found — not intercepting requests
- No `new URL()` calls with user input
- Fetch URL is hardcoded to `${API}/api/chat`
- Two catch blocks handle errors: one in `generate()`, one in `pickActivity()`

## Next step

Reproduce the error in the browser, open DevTools Console, and paste the `[sorted]` log output.
