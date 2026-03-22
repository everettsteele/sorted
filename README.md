## Running Your Own Instance

This repo contains no API keys. To run your own instance:

1. Fork this repo
2. Deploy your own proxy (see [sorted-api](https://github.com/everettsteele/sorted-api) for the pattern)
3. Set `API_BASE` as an environment variable pointing to your proxy URL
4. Deploy to Cloudflare Pages with build command `npm run build` and output directory `/`
