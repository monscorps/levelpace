# LevelPace leaderboard server.
#
# The server is Python standard library only -- no pip install step, nothing
# to pin, nothing to break on a rebuild. The image is basically "python plus
# our source".

FROM python:3.12-slim

WORKDIR /app

# The server code and the page it serves.
COPY server/ /app/server/

# The uploader ships too: the server imports its Lua parser for --import, so
# a file someone emails you can still be ingested on the host.
COPY uploader/levelpace_upload.py /app/uploader/levelpace_upload.py

# publish_static reads the addon TOC to learn the current version, which is
# what tells players they are out of date. Only the TOC is needed, not the
# whole addon.
COPY LevelPace/LevelPace.toc /app/LevelPace/LevelPace.toc

# /data is a mounted volume. SQLite on the container filesystem would be
# wiped on every deploy, taking the whole board with it -- which is exactly
# the trap most free hosting tiers set.
VOLUME ["/data"]

EXPOSE 8080

# LEVELPACE_TOKEN is injected as a secret, never baked into the image.
CMD ["python3", "server/levelpace_server.py", \
     "--host", "0.0.0.0", "--port", "8080", "--db", "/data/levelpace.db"]
