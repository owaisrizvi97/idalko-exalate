# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Base image: python:3.12-slim
# ---------------------------------------------------------------------------
# Why not ubuntu:latest? Bloated (~75MB) with unnecessary OS packages, and
# "latest" is unpinned so builds are not reproducible.
#
# Why not Alpine? Alpine uses musl libc. Python packages with C extensions
# can have compatibility issues on musl. python:3.12-slim is Debian-based
# with glibc -- small (~50MB) and drop-in compatible with standard Python
# packages.
#
# The tag is pinned to a specific minor version so builds are reproducible.
FROM python:3.12-slim AS runtime

# ---------------------------------------------------------------------------
# Environment hygiene
# ---------------------------------------------------------------------------
# PYTHONDONTWRITEBYTECODE=1  -> no .pyc files (smaller image, cleaner layer)
# PYTHONUNBUFFERED=1         -> stdout/stderr not buffered, logs appear in
#                               real-time (important for container log drivers)
# PIP_NO_CACHE_DIR=1         -> don't keep pip's wheel cache (smaller image)
# PIP_DISABLE_PIP_VERSION_CHECK=1 -> skip pip's self-update check at runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
WORKDIR /app

# ---------------------------------------------------------------------------
# Dependencies (layer-cached separately from app code)
# ---------------------------------------------------------------------------
# Copy requirements first so this layer is cached when only app code changes.
# Without this, every code change invalidates the pip install layer.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# Application code
# ---------------------------------------------------------------------------
COPY app.py .

# ---------------------------------------------------------------------------
# Non-root user
# ---------------------------------------------------------------------------
# The original Dockerfile ran as root. If the app is compromised, an attacker
# would have root inside the container. Create a dedicated service user and
# switch to it before running the app.
#
# -r            -> system user (no login, no home directory overhead)
# -s /bin/false -> no shell (prevents interactive login even if compromised)
RUN useradd -r -s /bin/false appuser && \
    chown -R appuser:appuser /app
USER appuser

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
# Port 8080 is used (not 80) because:
#   1. We run as non-root, which cannot bind to privileged ports (<1024)
#   2. The EC2 host maps host port 80 -> container port 8080 via `docker run`
EXPOSE 8080

# ---------------------------------------------------------------------------
# Run with gunicorn (production WSGI server)
# ---------------------------------------------------------------------------
# The original CMD used Flask's built-in dev server -- single-threaded, shows
# debug tracebacks on errors, not designed for production traffic.
#
# gunicorn flags:
#   --bind 0.0.0.0:8080  -> listen on all interfaces, port 8080
#   --workers 2          -> 2 worker processes (matches t3.micro's 2 vCPUs)
#   --access-logfile -   -> access logs to stdout (captured by Docker logs)
#   --error-logfile -    -> error logs to stderr (captured by Docker logs)
#   app:app              -> module `app`, WSGI callable `app`
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "2", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
