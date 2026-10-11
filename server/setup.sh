#!/bin/sh
# One-time setup for running the Player7 server without Docker (macOS / Linux / Termux).
#   ./setup.sh          create .venv and install everything
#   python3 server.py   start the server (it re-launches itself inside .venv)
set -e
cd "$(dirname "$0")"

missing=""
for tool in python3 ffmpeg; do
	command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
	echo "Please install:$missing"
	echo "  macOS:   brew install python ffmpeg deno"
	echo "  Debian:  sudo apt install python3 python3-venv ffmpeg"
	echo "  Termux:  pkg install python ffmpeg"
	exit 1
fi
command -v deno >/dev/null 2>&1 || echo "Note: install deno (https://deno.com) as well; yt-dlp needs it for some YouTube songs."

python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt || {
	# curl_cffi has no build for some systems (e.g. Termux); everything else works without it.
	.venv/bin/pip install -q "yt-dlp[default]" ytmusicapi
	echo "Note: curl_cffi could not be installed; Spotify playlists over 100 songs may be cut short."
}
[ -f config.json ] || cp config.example.json config.json

echo
echo "Done. Start the server with:  python3 server.py"
echo "Optional extras are described in the README (Spotify keys, token)."
