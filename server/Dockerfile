FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# yt-dlp needs a JavaScript runtime for YouTube.
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py ./

ENV PYTHONUNBUFFERED=1 PORT=8787 UPDATE_YTDLP=1
EXPOSE 8787
VOLUME ["/app/data", "/app/cache", "/app/secrets"]
HEALTHCHECK --interval=60s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/health', timeout=4)"

# YouTube changes often; a fresh yt-dlp on every start keeps playback working.
CMD ["sh", "-c", "if [ \"$UPDATE_YTDLP\" = 1 ]; then pip install --no-cache-dir -q -U 'yt-dlp[default]' || true; fi; exec python server.py"]
