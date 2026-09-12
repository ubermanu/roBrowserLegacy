FROM node:24-bookworm AS builder

LABEL org.opencontainers.image.description="Builds roBrowserLegacy JS bundles and HTML."

USER root

RUN apt-get update -y -qq && \
    apt-get install -y -qq build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies first (layer-cached separately from source)
COPY package*.json ./
RUN npm install

# Copy source and build
COPY . .

# Copy Config.local.js into the dist output so it's served alongside index.html.
# NOTE: Config.local.js is excluded from the build context via .dockerignore to
# prevent accidental secret baking. It must always be mounted at runtime.
# See applications/pwa/Config.local.js.example for the template.

# ---

FROM node:24-bookworm AS dev

LABEL org.opencontainers.image.description="Creates a environment to host the NodeJS and NPM environment."

USER root

RUN apt-get update -y -qq && \
    apt-get install -y -qq build-essential && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /app && \
    npm install wsproxy -g

WORKDIR /app

EXPOSE 3000
EXPOSE 5999

ENTRYPOINT []

# ---

FROM php:8.3-apache AS dist-server

LABEL org.opencontainers.image.description="Creates a environment to serve the dist files using Apache"

WORKDIR /var/www/html

USER root

RUN apt-get update -y -qq && \
    a2enmod rewrite && \
    a2enmod headers && \
    a2dissite 000-default && \
    rm -rf /var/lib/apt/lists/*

# For some IDEs this line is treated as wrongly configured, but this is a bug !
# This heredoc format is supported by Docker.
RUN cat <<EOF > /etc/apache2/sites-enabled/dist.conf
<VirtualHost *:8080>
    ServerAdmin webmaster@robrowser.legacy
    DocumentRoot /var/www/html

    # Disable directory listing
    <Directory /var/www/html>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    # Set default file
    DirectoryIndex index.html

    # MIME types for JavaScript and other files
    AddType application/javascript .js

    # Enable CORS
    <IfModule mod_headers.c>
        Header set Access-Control-Allow-Origin "*"
    </IfModule>
</VirtualHost>
EOF

RUN echo "Listen 8080" >> /etc/apache2/ports.conf

EXPOSE 8080

USER www-data

# ---

FROM --platform=$BUILDPLATFORM node:24-bookworm AS web-builder

LABEL org.opencontainers.image.description="Builds the web distribution."

WORKDIR /app

COPY package*.json ./
RUN npm install --package-lock-only && npm ci

COPY . .

# -H is only there for Config.js, which createHTML generates. Its index.html is a
# launcher that opens the other apps in a popup, and api.html is the dispatcher
# behind it. Both go, replaced by a page that imports Online.js directly.
RUN npm run build -- -O -T -H && test -f dist/Web/Config.js
RUN rm -f dist/Web/api.html dist/Web/api.js
COPY applications/docker/index.html dist/Web/index.html

# The include lets a deployment mount extra locations, typically to reverse proxy
# the asset server and the WebSocket proxy under the same origin. A wildcard that
# matches nothing is not an error.
RUN cat <<EOF > /app/default.conf
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    include /etc/nginx/robrowser.d/*.conf;
}
EOF

# ---

FROM nginx:1.27-alpine AS web

LABEL org.opencontainers.image.description="Serves the roBrowserLegacy web client."

COPY --from=web-builder /app/dist/Web /usr/share/nginx/html
COPY --from=web-builder /app/default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
