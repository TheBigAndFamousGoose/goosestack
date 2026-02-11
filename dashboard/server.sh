#!/bin/bash
# GooseStack Dashboard Server
# Serves the dashboard and proxies API requests to the OpenClaw gateway
# Usage: ./server.sh [port] [gateway_url]

PORT="${1:-3000}"
GATEWAY="${2:-http://localhost:18789}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🪿 GooseStack Dashboard"
echo "   Dashboard: http://localhost:${PORT}"
echo "   Gateway:   ${GATEWAY}"
echo ""

node -e "
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = ${PORT};
const GATEWAY = '${GATEWAY}';
const DIR = '${DIR}';

const MIME = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url);

  // Proxy /api/* to gateway
  if (parsed.pathname.startsWith('/api/')) {
    const target = new URL(parsed.pathname + (parsed.search || ''), GATEWAY);
    const mod = target.protocol === 'https:' ? https : http;
    const proxyReq = mod.request(target, {
      method: req.method,
      headers: { ...req.headers, host: target.host },
    }, (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    });
    proxyReq.on('error', (e) => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Gateway unreachable: ' + e.message }));
    });
    req.pipe(proxyReq);
    return;
  }

  // Serve static files
  let filePath = path.join(DIR, parsed.pathname === '/' ? 'index.html' : parsed.pathname);
  // Also check ../docs/ for shared assets like logo
  const ext = path.extname(filePath);
  const mime = MIME[ext] || 'application/octet-stream';

  fs.readFile(filePath, (err, data) => {
    if (err) {
      // Try ../docs/ as fallback (for logo-goose.png etc.)
      const docsPath = path.join(DIR, '..', 'docs', path.basename(filePath));
      fs.readFile(docsPath, (err2, data2) => {
        if (err2) {
          res.writeHead(404, { 'Content-Type': 'text/plain' });
          res.end('Not found');
        } else {
          res.writeHead(200, { 'Content-Type': mime });
          res.end(data2);
        }
      });
    } else {
      res.writeHead(200, { 'Content-Type': mime });
      res.end(data);
    }
  });
});

server.listen(PORT, () => {
  console.log('Dashboard ready at http://localhost:' + PORT);
});
"
