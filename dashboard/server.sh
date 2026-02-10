#!/bin/bash

# GooseStack Dashboard Server
# Serves the dashboard on localhost:3721

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=3721

echo "🪿 GooseStack Dashboard Server"
echo "=============================="
echo "Starting HTTP server on port $PORT..."
echo "Dashboard URL: http://localhost:$PORT"
echo ""
echo "Press Ctrl+C to stop the server"
echo ""

# Check if Python 3 is available, fallback to Python 2
if command -v python3 &> /dev/null; then
    cd "$SCRIPT_DIR" && python3 -m http.server $PORT
elif command -v python &> /dev/null; then
    cd "$SCRIPT_DIR" && python -m SimpleHTTPServer $PORT
else
    echo "Error: Python not found. Please install Python to run the dashboard server."
    exit 1
fi