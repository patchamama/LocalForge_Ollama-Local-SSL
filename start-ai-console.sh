#!/usr/bin/env bash

set -euo pipefail

START_PORT=8080
WOL_START_PORT=9999
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_free_port() {
  local port="${1}"
  while lsof -ti :"${port}" &>/dev/null; do
    ((port++))
  done
  echo "${port}"
}

PORT="$(find_free_port "${START_PORT}")"
WOL_PORT="$(find_free_port "${WOL_START_PORT}")"
URL="http://localhost:${PORT}/ai-console.html"

echo "Starting web server at ${URL}"
echo "Starting WOL proxy at http://127.0.0.1:${WOL_PORT}"

# Write WOL proxy port so the frontend can discover it
echo "${WOL_PORT}" > "${DIR}/.wol-proxy-port"

open_browser() {
  if command -v open &>/dev/null; then
    open "${URL}"
  elif command -v xdg-open &>/dev/null; then
    xdg-open "${URL}"
  fi
}

cleanup() {
  rm -f "${DIR}/.wol-proxy-port"
  kill 0
}
trap cleanup EXIT INT TERM

if command -v python3 &>/dev/null; then
  python3 "${DIR}/wol-proxy.py" "${WOL_PORT}" "http://localhost:${PORT}" &
  (sleep 1 && open_browser) &
  cd "${DIR}" && python3 -m http.server "${PORT}"
elif command -v python &>/dev/null; then
  python3 "${DIR}/wol-proxy.py" "${WOL_PORT}" "http://localhost:${PORT}" &
  (sleep 1 && open_browser) &
  cd "${DIR}" && python -m SimpleHTTPServer "${PORT}"
elif command -v php &>/dev/null; then
  python3 "${DIR}/wol-proxy.py" "${WOL_PORT}" "http://localhost:${PORT}" &
  (sleep 1 && open_browser) &
  cd "${DIR}" && php -S "localhost:${PORT}"
else
  echo "Error: no Python or PHP found. Install one and retry."
  exit 1
fi
