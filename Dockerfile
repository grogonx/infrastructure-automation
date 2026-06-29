# =============================================================================
# Dockerfile
# Description: Multi-stage Dockerfile for a Python web application.
#              Stage 1 (builder) installs dependencies in an isolated layer.
#              Stage 2 (runtime) produces a lean, non-root production image.
# Author:      Joshua Harvey
#
# Build:  docker build -t my-app:latest .
# Run:    docker run -p 8080:8080 --env-file .env my-app:latest
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1 — Builder
# Installs all dependencies into a virtual environment
# ---------------------------------------------------------------------------
FROM python:3.11-slim AS builder

WORKDIR /build

# Install build tools needed for some Python packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy and install requirements first (layer caching — only re-runs if requirements change)
COPY requirements.txt .
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2 — Runtime
# Copies only the venv and application code — no build tools
# ---------------------------------------------------------------------------
FROM python:3.11-slim AS runtime

# Security: don't run as root
RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup --no-create-home --shell /bin/false appuser

WORKDIR /app

# Install runtime-only OS dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy virtual environment from builder stage
COPY --from=builder /opt/venv /opt/venv

# Copy application source
COPY --chown=appuser:appgroup . .

# Activate the virtual environment
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

# Switch to non-root user
USER appuser

EXPOSE 8080

# Health check — adjust the endpoint to match your app
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

# Start the application
CMD ["python", "-m", "gunicorn", "app:application", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "2", \
     "--threads", "4", \
     "--timeout", "60", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]
