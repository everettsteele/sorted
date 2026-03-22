#!/bin/bash
# Cloudflare Pages build script
# Injects API_BASE environment variable into index.html at deploy time
set -e
cp index.html index.html.bak
sed -i "s|__API_BASE__|${API_BASE}|g" index.html
echo "Build complete. API_BASE injected."
