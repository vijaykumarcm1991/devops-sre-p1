# Optimal, minimal, and secure Dockerfile for Python Memory Application
# Uses lightweight Python Alpine image for small attack surface and image size
FROM python:3.11-alpine AS base

# Set environment variables for Python optimization and unbuffered logging
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    APP_USER=appuser \
    APP_UID=10001 \
    APP_GID=10001

# Create a non-privileged group and user
RUN addgroup -g ${APP_GID} ${APP_USER} && \
    adduser -u ${APP_UID} -G ${APP_USER} -s /sbin/nologin -D ${APP_USER}

# Set working directory
WORKDIR /app

# Copy application source code with restricted permissions
COPY --chown=${APP_USER}:${APP_USER} app/ /app/

# Switch to non-root user for security best practices
USER ${APP_USER}

# Expose HTTP health check and service port
EXPOSE 8080

# Health check to monitor container status
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthcheck')" || exit 1

# Launch the application
ENTRYPOINT ["python", "/app/app.py"]
