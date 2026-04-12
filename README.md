## Backend env vars

Beyond the existing `ANTHROPIC_API_KEY`, `sorted-api` now needs:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_KV_NAMESPACE_ID` — create a KV namespace and paste its ID here
- `CLOUDFLARE_API_TOKEN` — scoped: `Account → Workers KV Storage → Edit`
- `PUBLIC_BASE_URL` (optional) — overrides the default `https://sorted.neverstill.llc` used when the API returns shareable plan URLs

Set these as Railway Variables, not in source.

## Running Your Own Instance

This repo contains no API keys. To run your own instance:

1. Fork this repo
2. Deploy your own proxy (see [sorted-api](https://github.com/everettsteele/sorted-api) for the pattern)
3. Set `API_BASE` as an environment variable pointing to your proxy URL
4. Deploy to Cloudflare Pages with build command `npm run build` and output directory `/`
