FROM taigaio/taiga-front:latest AS frontend

FROM taigaio/taiga-back:latest

USER root

# Install Nginx to serve taiga-front SPA, static/media assets, and reverse-proxy /api & /admin
RUN apt-get update && \
    apt-get install -y --no-install-recommends nginx && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

# Copy compiled Angular SPA from taiga-front
COPY --from=frontend /usr/share/nginx/html /taiga-front

# Configure Django settings for Cloud Run + HTTPS Load Balancer proxy headers and direct media storage
RUN printf '\n# Cloud Run & Global External HTTPS Load Balancer overrides\nDEFAULT_FILE_STORAGE = "django.core.files.storage.FileSystemStorage"\nUSE_X_FORWARDED_HOST = True\nSECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")\n' >> /taiga-back/settings/config.py

# Pre-collect Django static files at image build time
WORKDIR /taiga-back
RUN TAIGA_SECRET_KEY="build-time-collectstatic-key" \
    POSTGRES_DB="taiga" \
    POSTGRES_USER="taiga" \
    POSTGRES_PASSWORD="build-time-password" \
    POSTGRES_HOST="localhost" \
    python manage.py collectstatic --noinput

# Configure Nginx gateway and entrypoint script
COPY nginx.conf /etc/nginx/conf.d/taiga.conf
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
