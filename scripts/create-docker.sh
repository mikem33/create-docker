#!/usr/bin/env bash
# create-docker — local web development environment creator
#
# Creates a project folder under $CREATE_DOCKER_DIR/{slug}/ (default: ~/Dev/)
# with a docker-compose.yml, configures a .test domain with HTTPS, and sets
# up the global Traefik reverse proxy on first run.
#
# Supported container types:
#   html       — Nginx serving static files
#   php        — PHP 8.3 + Apache or Nginx+FPM (mod_rewrite, pdo_mysql, mysqli)
#   wordpress  — PHP 8.3 + MySQL + phpMyAdmin + MailHog (Apache or Nginx+FPM)

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'    # Used for CREATE rows in logo (→ Gruvbox teal #89b482)
ORANGE='\033[0;33m'  # Used for DOCKER rows in logo (→ Gruvbox yellow #d8a657)
BOLD='\033[1m'
RESET='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────────────────

DEV_DIR="${CREATE_DOCKER_DIR:-$HOME/Dev}"
PROXY_DIR="$DEV_DIR/.proxy"
CERTS_DIR="$PROXY_DIR/certs"

# ─── Output helpers ───────────────────────────────────────────────────────────

info()    { echo -e "${BLUE}  →${RESET} $*"; }
success() { echo -e "${GREEN}  ✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}  !${RESET} $*"; }
die()     { echo -e "${RED}  ✗${RESET} $*" >&2; exit 1; }

# ─── Header ───────────────────────────────────────────────────────────────────
#
# Pixel art logo inspired by the Omarchy block-character branding style.
# Each letter is 5 columns × 5 rows. Two colours map to the Gruvbox palette:
#   CYAN   → terminal color6 → #89b482 (teal)
#   ORANGE → terminal color3 → #d8a657 (warm yellow)

print_header() {
    echo ""
    echo -e "${CYAN}   ████ ████  █████  ███  █████ █████${RESET}"
    echo -e "${CYAN}  █     █   █ █     █   █   █   █    ${RESET}"
    echo -e "${CYAN}  █     ████  ████  █████   █   ████ ${RESET}"
    echo -e "${CYAN}  █     █ █   █     █   █   █   █    ${RESET}"
    echo -e "${CYAN}   ████ █  ██ █████ █   █   █   █████${RESET}"
    echo -e "${ORANGE}  ████   ███   ████ █   █ █████ ████ ${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     █  █  █     █   █${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     ███   ████  ████ ${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     █  █  █     █ █  ${RESET}"
    echo -e "${ORANGE}  ████   ███   ████ █   █ █████ █  ██${RESET}"
    echo ""
    echo -e "  local web development environment creator"
    echo "  ─────────────────────────────────────────"
    echo ""
}

# ─── Dependency checks ────────────────────────────────────────────────────────

check_dependencies() {
    local missing=()

    command -v docker &>/dev/null          || missing+=("docker")
    docker compose version &>/dev/null     || missing+=("docker-compose-plugin")
    command -v mkcert &>/dev/null          || missing+=("mkcert")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}  Missing required tools:${RESET}"
        for dep in "${missing[@]}"; do
            echo "      - $dep"
        done
        echo ""
        echo "  Install on Arch Linux:"
        echo "    sudo pacman -S docker docker-compose mkcert"
        echo ""
        echo "  Other distributions:"
        echo "    Docker  → https://docs.docker.com/engine/install/"
        echo "    mkcert  → https://github.com/FiloSottile/mkcert"
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        die "Docker daemon is not running. Start it with: sudo systemctl start docker"
    fi
}

# ─── Global proxy (Traefik) ───────────────────────────────────────────────────

setup_proxy() {
    # If proxy is already configured and running, nothing to do
    if [ -f "$PROXY_DIR/docker-compose.yml" ]; then
        if docker compose --project-directory "$PROXY_DIR" -f "$PROXY_DIR/docker-compose.yml" ps --quiet 2>/dev/null | grep -q .; then
            info "Global proxy is already running."
            return
        else
            info "Starting existing global proxy..."
            docker compose --project-directory "$PROXY_DIR" -f "$PROXY_DIR/docker-compose.yml" up -d
            success "Global proxy started."
            return
        fi
    fi

    echo ""
    info "First run — setting up global Traefik reverse proxy..."
    mkdir -p "$PROXY_DIR" "$CERTS_DIR" "$PROXY_DIR/conf"

    # Register the mkcert root CA with NSS (Firefox, curl, system tools)
    mkcert -install

    # Chrome 120+ on Linux uses its own root store instead of NSS.
    # An enterprise policy file is the supported way to trust a local CA.
    local ca_root
    ca_root=$(mkcert -CAROOT)
    local chrome_policy_dir="/etc/opt/chrome/policies/managed"
    local chrome_policy_file="$chrome_policy_dir/mkcert-trust.json"
    if [ ! -f "$chrome_policy_file" ]; then
        info "Adding mkcert CA to Chrome trust store (requires sudo)..."
        if sudo mkdir -p "$chrome_policy_dir" 2>/dev/null && \
           python3 -c "import json; cert=open('$ca_root/rootCA.pem').read(); print(json.dumps({'CACertificates': [cert]}, indent=2))" \
           | sudo tee "$chrome_policy_file" > /dev/null 2>&1; then
            success "Chrome trust configured. Restart Chrome to apply."
        else
            warn "Chrome trust setup skipped (sudo declined or Chrome not installed)."
            echo "  To trust certs manually in Chrome:"
            echo "    chrome://settings/certificates → Authorities → Import"
            echo "    Select: $ca_root/rootCA.pem → Trust for websites"
        fi
    fi

    # Shared Docker network — all project containers connect to this network
    # so Traefik can route traffic to them by hostname
    if ! docker network ls --format '{{.Name}}' | grep -q '^proxy$'; then
        docker network create proxy
        success "Docker network 'proxy' created."
    fi

    # Traefik static configuration
    cat > "$PROXY_DIR/traefik.yml" <<'TRAEFIK_EOF'
# Traefik v3 — static configuration
# Manages HTTPS routing for all local development projects

api:
  dashboard: false

log:
  level: ERROR

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"

providers:
  docker:
    # Only route containers that explicitly opt in via the traefik.enable=true label
    exposedByDefault: false
    network: proxy
  file:
    # Per-project certificate configs are placed here by create-docker
    directory: /etc/traefik/conf
    watch: true
TRAEFIK_EOF

    # Proxy docker-compose
    cat > "$PROXY_DIR/docker-compose.yml" <<'PROXY_EOF'
services:
  traefik:
    image: traefik:v3
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      # Read-only access to Docker socket — Traefik watches container events
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/traefik.yml:ro
      - ./conf:/etc/traefik/conf:ro
      - ./certs:/certs:ro
    networks:
      - proxy

networks:
  proxy:
    external: true
PROXY_EOF

    docker compose --project-directory "$PROXY_DIR" -f "$PROXY_DIR/docker-compose.yml" up -d
    success "Global proxy (Traefik) is running."
}

# ─── /etc/hosts management ───────────────────────────────────────────────────

add_hosts_entry() {
    local domain="$1"

    if grep -q "[[:space:]]${domain}$" /etc/hosts; then
        info "Host entry for ${BOLD}${domain}${RESET} already exists."
        return
    fi

    info "Adding ${BOLD}${domain}${RESET} to /etc/hosts (requires sudo)..."
    echo "127.0.0.1 $domain" | sudo tee -a /etc/hosts > /dev/null
    success "Added: 127.0.0.1 $domain"
}

# ─── Secure password generator ───────────────────────────────────────────────

gen_password() {
    # 24 random hex characters — 96 bits of entropy, no special chars to escape
    openssl rand -hex 12
}

# ─── MySQL identifier names ──────────────────────────────────────────────────
# MySQL caps user names at 32 characters and rejects hyphens in unquoted
# identifiers. A slug long enough to overflow that cap makes the image's
# entrypoint abort on CREATE USER; the container then restarts onto an already
# initialized data dir and reports healthy without the app user ever existing.
# So the name is shortened here, a trailing word at a time, until it fits.

db_identifier() {
    # $1 = project slug, $2 = suffix (db|user), $3 = max length
    local base="${1//-/_}" suffix="$2" max="$3"
    local keep=$(( max - ${#suffix} - 1 ))
    # shed whole words from the end first, so the name stays readable
    while (( ${#base} > keep )) && [[ "$base" == *_* ]]; do
        base="${base%_*}"
    done
    # a single word longer than the budget still has to be cut
    (( ${#base} > keep )) && base="${base:0:$keep}"
    echo "${base}_${suffix}"
}

# ─── Per-project TLS certificate ────────────────────────────────────────────
# Generates a cert with the project's exact hostnames as SANs.
# Wildcard certs (*.test) are rejected by TLS stacks for 2-label domains.
# Traefik picks up the conf file automatically via the file provider (watch: true).

generate_project_cert() {
    local slug="$1"
    local container_type="$2"
    local cert_file="$CERTS_DIR/${slug}.pem"
    local key_file="$CERTS_DIR/${slug}-key.pem"
    local conf_file="$PROXY_DIR/conf/${slug}.yml"

    # Build the list of hostnames this cert needs to cover
    local -a domains=("${slug}.test")
    if [ "$container_type" = "wordpress" ]; then
        domains+=("${slug}-db.test" "${slug}-mail.test")
    fi

    info "Generating TLS certificate for ${domains[*]}..."
    mkcert -cert-file "$cert_file" -key-file "$key_file" "${domains[@]}"

    # Traefik dynamic config for this project's cert
    cat > "$conf_file" <<EOF
tls:
  certificates:
    - certFile: /certs/${slug}.pem
      keyFile: /certs/${slug}-key.pem
EOF
    success "TLS certificate ready."
}

# ─── HTML container ──────────────────────────────────────────────────────────

create_html() {
    local slug="$1"
    local dir="$DEV_DIR/$slug"

    mkdir -p "$dir/src"

    cat > "$dir/docker-compose.yml" <<EOF
services:
  web:
    image: nginx:alpine
    container_name: ${slug}-web
    restart: unless-stopped
    volumes:
      - ./src:/usr/share/nginx/html:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}.rule=Host(\`${slug}.test\`)"
      - "traefik.http.routers.${slug}.entrypoints=websecure"
      - "traefik.http.routers.${slug}.tls=true"
      - "traefik.http.services.${slug}.loadbalancer.server.port=80"
    networks:
      - proxy

networks:
  proxy:
    external: true
EOF

    # Starter page
    cat > "$dir/src/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${slug}</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 600px; margin: 4rem auto; padding: 0 1rem; }
        code { background: #f0f0f0; padding: 0.2em 0.4em; border-radius: 3px; }
    </style>
</head>
<body>
    <h1>${slug}</h1>
    <p>Your HTML environment is running at <strong>https://${slug}.test</strong></p>
    <p>Add your files to <code>src/</code> — changes appear immediately without restarting the container.</p>
</body>
</html>
EOF
}

# ─── Vite container ──────────────────────────────────────────────────────────
# Two services: node container runs Vite dev server, nginx proxies to it.
# Both share an internal network; nginx also connects to Traefik's proxy network.

create_vite() {
    local slug="$1"
    local dir="$DEV_DIR/$slug"

    mkdir -p "$dir/nginx" "$dir/src"

    cat > "$dir/nginx/nginx.conf" <<'NGINX_EOF'
server {
    listen 80;
    # Nginx only sees Traefik's plain-HTTP hop, so its own redirects (e.g. adding a
    # directory's trailing slash) would point at http://. Keep them relative, so the
    # browser stays on https://{slug}.test.
    absolute_redirect off;
    server_name _;

    location / {
        proxy_pass http://vite:5173;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass $http_upgrade;
    }
}
NGINX_EOF

    cat > "$dir/docker-compose.yml" <<EOF
services:
  vite:
    image: node:lts-alpine
    container_name: ${slug}-vite
    working_dir: /app
    volumes:
      - ./src:/app
      - pnpm_store:/pnpm/store
    environment:
      - CI=true
    command: sh -c "corepack enable && pnpm install --store-dir /pnpm/store && pnpm dev"
    restart: unless-stopped
    networks:
      - internal

  web:
    image: nginx:alpine
    container_name: ${slug}-web
    restart: unless-stopped
    depends_on:
      - vite
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}.rule=Host(\`${slug}.test\`)"
      - "traefik.http.routers.${slug}.entrypoints=websecure"
      - "traefik.http.routers.${slug}.tls=true"
      - "traefik.http.services.${slug}.loadbalancer.server.port=80"
    networks:
      - proxy
      - internal

networks:
  proxy:
    external: true
  internal:
    driver: bridge

volumes:
  pnpm_store:
EOF
}

# ─── Composer (optional, PHP and WordPress) ──────────────────────────────────
# Appends the Composer layer to a Dockerfile being written, if the user asked
# for it. Each PHP generator writes its Dockerfile in two parts and calls this
# between them, ahead of USER www-data — apt needs root. Without Composer
# nothing is appended, so the Dockerfile is byte-for-byte what it was before.

append_composer_layer() {
    [ "${install_composer:-n}" = "y" ] || return 0
    cat >> "$1" <<'EOF'
# Install Composer, so PHP dependencies are managed inside the container and the
# host needs neither PHP nor Composer. The binary is copied from the official
# image instead of fetched with the installer script, which pins Composer 2 with
# no checksum step. Composer unpacks dist archives with unzip and clones source
# packages with git. www-data's home is /var/www, owned by root, so Composer
# cannot keep its cache under $HOME; COMPOSER_HOME points at a directory handed
# to www-data instead, beside html/ so the ./src bind mount does not shadow it.
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
RUN apt-get update && apt-get install -y git unzip --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/www/.composer \
    && chown -R www-data:www-data /var/www/.composer
ENV COMPOSER_HOME=/var/www/.composer

EOF
}

# ─── Bedrock (optional, WordPress) ───────────────────────────────────────────
# Bedrock serves WordPress from src/web/, and keeps .env, config/ and vendor/
# one level up, out of reach of the browser. The tool does not install Bedrock:
# it points the web server at web/, writes Bedrock's .env with what it already
# knows, and leaves a welcome page that shows the install command. Bedrock needs
# Composer, so choosing it turns Composer on too.

gen_salt() {
    # 64 base64 characters — never a quote or a $, so safe single-quoted in .env
    openssl rand -base64 48
}

# Appends the Apache document root change to the Dockerfile being written.
append_bedrock_docroot_layer() {
    [ "${use_bedrock:-n}" = "y" ] || return 0
    cat >> "$1" <<'EOF'
# Bedrock serves WordPress from web/, keeping .env, config/ and vendor/ outside
# the document root. AllowOverride All is set on <Directory /var/www/> above,
# so .htaccess files in web/ are still honoured.
RUN sed -i 's#DocumentRoot /var/www/html$#DocumentRoot /var/www/html/web#' \
        /etc/apache2/sites-available/000-default.conf

EOF
}

# Writes src/.env for Bedrock and the welcome page in src/web/.
write_bedrock_files() {
    local dir="$1" slug="$2" db_name="$3" db_user="$4" db_password="$5"

    mkdir -p "$dir/src/web"

    # Key names follow Bedrock's .env.example. DB_HOST must be set: Bedrock
    # defaults to localhost, which inside the container is not MySQL.
    cat > "$dir/src/.env" <<EOF
# Bedrock configuration — generated by create-docker.
# The database values match ../.env, which configures the MySQL container.
# DO NOT commit this file (Bedrock's .gitignore excludes it once installed).
DB_NAME='${db_name}'
DB_USER='${db_user}'
DB_PASSWORD='${db_password}'
DB_HOST='db'

WP_ENV='development'
WP_HOME='https://${slug}.test'
WP_SITEURL="\${WP_HOME}/wp"

AUTH_KEY='$(gen_salt)'
SECURE_AUTH_KEY='$(gen_salt)'
LOGGED_IN_KEY='$(gen_salt)'
NONCE_KEY='$(gen_salt)'
AUTH_SALT='$(gen_salt)'
SECURE_AUTH_SALT='$(gen_salt)'
LOGGED_IN_SALT='$(gen_salt)'
NONCE_SALT='$(gen_salt)'
EOF

    # Welcome page — shown until Bedrock's own web/index.php replaces it.
    # create-project refuses a non-empty directory, and src/ already holds .env
    # and this page, so the command installs into /tmp and copies the result
    # across, dropping any .env the package ships so the one above survives.
    cat > "$dir/src/web/index.php" <<'WELCOME'
<?php
$host = $_SERVER['HTTP_HOST'] ?? 'your-project.test';
$slug = explode('.', $host)[0];
// PHP runs in {slug}-web on Apache and in {slug}-php behind Nginx
$service = stripos($_SERVER['SERVER_SOFTWARE'] ?? '', 'nginx') !== false ? 'php' : 'web';
$container = $slug . '-' . $service;
?><!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Ready — <?= htmlspecialchars($host) ?></title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 600px; margin: 80px auto; padding: 0 24px; color: #1a1a1a; }
    h1   { font-size: 1.5rem; margin-bottom: 0.25rem; }
    p    { color: #555; margin: 0.4rem 0; }
    code { background: #f0f0f0; padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }
    pre  { background: #f0f0f0; padding: 12px; border-radius: 6px; overflow-x: auto; }
    .step { margin: 1.5rem 0 0.5rem; font-weight: 600; }
    a    { color: #2563eb; }
  </style>
</head>
<body>
  <h1>Your Bedrock environment is ready.</h1>
  <p>PHP <?= phpversion() ?> &middot; <a href="https://<?= htmlspecialchars($slug) ?>-db.test" target="_blank">phpMyAdmin</a> &middot; <a href="https://<?= htmlspecialchars($slug) ?>-mail.test" target="_blank">MailHog</a></p>

  <p><code>src/.env</code> is already filled in: database, URLs and fresh salts. The site is served from <code>src/web/</code>.</p>

  <p class="step">Install Bedrock</p>
  <p>From any directory:</p>
  <pre><code>docker exec <?= htmlspecialchars($container) ?> sh -c 'composer create-project roots/bedrock /tmp/bedrock &amp;&amp; rm -f /tmp/bedrock/.env &amp;&amp; cp -a /tmp/bedrock/. /var/www/html/ &amp;&amp; rm -rf /tmp/bedrock'</code></pre>
  <p>Any other Bedrock-based project installs the same way: replace <code>roots/bedrock</code> with its package name.</p>
  <p>Then open <a href="https://<?= htmlspecialchars($host) ?>">https://<?= htmlspecialchars($host) ?></a> to run the WordPress installer.</p>

  <p style="margin-top:2rem;font-size:0.85rem;color:#999;">The install replaces this page with Bedrock's own <code>web/index.php</code>.</p>
</body>
</html>
WELCOME
}

# ─── PHP / Apache container ───────────────────────────────────────────────────
# Single container: php:8.3-apache with mod_rewrite and DB extensions.

create_php_apache() {
    local slug="$1"
    local dir="$DEV_DIR/$slug"

    mkdir -p "$dir/src"

    cat > "$dir/Dockerfile" <<'EOF'
FROM php:8.3-apache

# Match www-data's UID/GID to the host user, so files created by Apache
# inside the container are owned by you on the host, not by an unmapped UID.
RUN usermod -u 1000 www-data && groupmod -g 1000 www-data && \
    find / -path /proc -prune -o -user 33 -exec chown -h www-data {} \; && \
    find / -path /proc -prune -o -group 33 -exec chgrp -h www-data {} \;

# Enable common extensions for PHP development
RUN docker-php-ext-install pdo pdo_mysql mysqli \
    && a2enmod rewrite

# Allow .htaccess files to override Apache directives (needed for most frameworks)
# Move Apache to port 8080 so it can run as www-data (unprivileged ports require root)
RUN sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf \
    && sed -i 's/80/8080/g' /etc/apache2/ports.conf /etc/apache2/sites-available/000-default.conf

# Traefik terminates TLS and forwards plain HTTP here, so PHP sees no HTTPS and
# builds http:// URLs for a site served over https://. WordPress turns that into
# a redirect loop on /wp-admin/: it thinks the request is insecure and bounces to
# the https siteurl, which arrives looking insecure again. Translate Traefik's
# X-Forwarded-Proto into the flag PHP actually reads. Trusting the header is safe
# because the container is not published — Traefik is the only way in.
RUN printf 'SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on\n' \
        > /etc/apache2/conf-available/forwarded-proto.conf \
    && a2enconf forwarded-proto

# Apache builds its own redirects (e.g. mod_dir adding the trailing slash to a
# directory) from how it was reached: plain HTTP on port 8080, behind Traefik. So
# /some-dir became http://{slug}.test:8080/some-dir/. Give the vhost its public
# https name so they point at https://{slug}.test instead. APACHE_SERVER_NAME is
# set in docker-compose.yml; Apache expands ${...} from the environment.
RUN sed -i 's#<VirtualHost \*:8080>#&\n\tServerName https://${APACHE_SERVER_NAME}\n\tUseCanonicalName On#' \
        /etc/apache2/sites-available/000-default.conf

EOF
    append_composer_layer "$dir/Dockerfile"
    cat >> "$dir/Dockerfile" <<'EOF'
EXPOSE 8080

USER www-data
EOF

    cat > "$dir/docker-compose.yml" <<EOF
services:
  web:
    build: .
    container_name: ${slug}-web
    restart: unless-stopped
    volumes:
      - ./src:/var/www/html
    environment:
      # Public name for Apache's own redirects (see the Dockerfile)
      APACHE_SERVER_NAME: ${slug}.test
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}.rule=Host(\`${slug}.test\`)"
      - "traefik.http.routers.${slug}.entrypoints=websecure"
      - "traefik.http.routers.${slug}.tls=true"
      - "traefik.http.services.${slug}.loadbalancer.server.port=8080"
    networks:
      - proxy

networks:
  proxy:
    external: true
EOF

    cat > "$dir/.gitignore" <<'EOF'
.env
*.log
EOF

    # Starter page — displays PHP configuration for quick verification
    cat > "$dir/src/index.php" <<'EOF'
<?php phpinfo();
EOF
}

# ─── PHP / Nginx + FPM container ─────────────────────────────────────────────
# Two containers: nginx:alpine (web) + php:8.3-fpm (PHP processor).
# Nginx handles HTTP and forwards PHP requests to FPM via FastCGI.

create_php_nginx() {
    local slug="$1"
    local dir="$DEV_DIR/$slug"

    mkdir -p "$dir/src" "$dir/nginx"

    # PHP-FPM Dockerfile
    cat > "$dir/Dockerfile" <<'EOF'
FROM php:8.3-fpm

# Match www-data's UID/GID to the host user
RUN usermod -u 1000 www-data && groupmod -g 1000 www-data && \
    find / -path /proc -prune -o -user 33 -exec chown -h www-data {} \; && \
    find / -path /proc -prune -o -group 33 -exec chgrp -h www-data {} \;

# Enable common extensions for PHP development
RUN docker-php-ext-install pdo pdo_mysql mysqli

EOF
    append_composer_layer "$dir/Dockerfile"
    cat >> "$dir/Dockerfile" <<'EOF'
USER www-data
EOF

    # Nginx server configuration
    # $uri, $query_string, etc. are Nginx variables — not bash variables
    cat > "$dir/nginx/nginx.conf" <<'NGINX_EOF'
# Traefik reports the browser's original scheme here. This file is included
# inside http{}, which is the only level where map is allowed.
map $http_x_forwarded_proto $https_from_proxy {
    default '';
    https   on;
}

server {
    listen 80;
    # Nginx only sees Traefik's plain-HTTP hop, so its own redirects (e.g. adding a
    # directory's trailing slash) would point at http://. Keep them relative, so the
    # browser stays on https://{slug}.test.
    absolute_redirect off;
    root  /var/www/html;
    index index.php index.html;

    # Route requests: try file → directory → PHP front controller
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # Forward PHP requests to the php-fpm container on port 9000
    location ~ \.php$ {
        fastcgi_pass  php:9000;
        fastcgi_index index.php;
        include       fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO       $fastcgi_path_info;

        # Traefik terminates TLS and forwards plain HTTP, so PHP would otherwise
        # build http:// URLs for a site served over https:// — which WordPress
        # turns into a redirect loop on /wp-admin/. Pass the original scheme on.
        fastcgi_param HTTPS $https_from_proxy if_not_empty;
    }

    # Deny access to hidden files (.htaccess, .env, etc.)
    location ~ /\. {
        deny all;
    }
}
NGINX_EOF

    cat > "$dir/docker-compose.yml" <<EOF
services:

  # ── Nginx web server ─────────────────────────────────────────────────────────
  web:
    image: nginx:alpine
    container_name: ${slug}-web
    restart: unless-stopped
    depends_on:
      - php
    volumes:
      - ./src:/var/www/html:ro
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}.rule=Host(\`${slug}.test\`)"
      - "traefik.http.routers.${slug}.entrypoints=websecure"
      - "traefik.http.routers.${slug}.tls=true"
      - "traefik.http.services.${slug}.loadbalancer.server.port=80"
    networks:
      - proxy
      - internal

  # ── PHP-FPM processor ────────────────────────────────────────────────────────
  # Not directly reachable from outside — Nginx forwards requests to it
  php:
    build: .
    container_name: ${slug}-php
    restart: unless-stopped
    volumes:
      - ./src:/var/www/html
    networks:
      - internal

networks:
  proxy:
    external: true
  internal:
    driver: bridge
EOF

    cat > "$dir/.gitignore" <<'EOF'
.env
*.log
EOF

    cat > "$dir/src/index.php" <<'EOF'
<?php phpinfo();
EOF
}

# ─── WordPress / Apache container ────────────────────────────────────────────
# Single container: php:8.3-apache with all WordPress-required PHP extensions.
# WordPress is NOT installed — drop its files into src/ yourself.

create_wordpress_apache() {
    local slug="$1"
    local dir="$DEV_DIR/$slug"

    local db_name db_user
    db_name=$(db_identifier "$slug" db 64)
    db_user=$(db_identifier "$slug" user 32)
    local db_password
    local db_root_password
    db_password=$(gen_password)
    db_root_password=$(gen_password)

    mkdir -p "$dir/src"

    # .env — credentials for the MySQL container.
    # Use the same values in wp-config.php or Bedrock's src/.env.
    # DO NOT commit this file.
    cat > "$dir/.env" <<EOF
# Database credentials — generated automatically
# Use these values when configuring WordPress (wp-config.php or src/.env for Bedrock)
# The database host inside Docker is always: db
MYSQL_DATABASE=${db_name}
MYSQL_USER=${db_user}
MYSQL_PASSWORD=${db_password}
MYSQL_ROOT_PASSWORD=${db_root_password}
EOF

    cat > "$dir/.gitignore" <<'EOF'
.env
*.log
EOF

    # Dockerfile — PHP 8.3 + Apache with all WordPress-required extensions.
    # WordPress is NOT installed here — drop its files into src/ yourself.
    cat > "$dir/Dockerfile" <<'EOF'
FROM php:8.3-apache

# Match www-data's UID/GID to the host user, so files created by Apache
# inside the container are owned by you on the host, not by an unmapped UID.
RUN usermod -u 1000 www-data && groupmod -g 1000 www-data && \
    find / -path /proc -prune -o -user 33 -exec chown -h www-data {} \; && \
    find / -path /proc -prune -o -group 33 -exec chgrp -h www-data {} \;

# Install system libraries required by PHP extensions, plus the MySQL client.
# WP-CLI shells out to mysql/mysqldump for the `wp db` family — export, import,
# check, cli — so without the client those commands fail at the point of use.
RUN apt-get update && apt-get install -y \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev \
        libxml2-dev \
        libcurl4-openssl-dev \
        libssl-dev \
        libmagickwand-dev \
        libonig-dev \
        default-mysql-client \
        --no-install-recommends \
    && docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        gd \
        mysqli \
        pdo_mysql \
        mbstring \
        xml \
        zip \
        curl \
        intl \
        exif \
        opcache \
    && pecl install imagick \
    && docker-php-ext-enable imagick \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

# Install mhsendmail so PHP's mail() function is captured by MailHog.
# All outgoing email stays on your machine — nothing is sent to real addresses.
RUN curl -sL \
        https://github.com/mailhog/mhsendmail/releases/download/v0.2.0/mhsendmail_linux_amd64 \
        -o /usr/local/bin/mhsendmail \
    && chmod +x /usr/local/bin/mhsendmail

# Install WP-CLI — manage WordPress from the command line inside the container.
# www-data's home is /var/www, owned by root, so WP-CLI cannot create the
# download cache it keeps in $HOME/.wp-cli — every core/plugin fetch would warn
# and re-download. The directory is created up front and handed to www-data; it
# sits beside html/, so the ./src bind mount does not shadow it.
RUN curl -sL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp \
    && mkdir -p /var/www/.wp-cli/cache \
    && chown -R www-data:www-data /var/www/.wp-cli

# Debian's default-mysql-client is MariaDB's, whose client verifies the server
# certificate by default. MySQL 8 presents a self-signed one, so every `wp db`
# command dies with "TLS/SSL error: self-signed certificate in certificate
# chain". WP-CLI runs the client with --no-defaults, so no config file can carry
# the opt-out — these shims sit ahead of /usr/bin on PATH and append it. The
# connection is between two containers on a private network on your own machine.
RUN for b in mariadb mariadb-dump mariadb-check mysql mysqldump mysqlcheck; do \
        printf '#!/bin/sh\nexec /usr/bin/%s "$@" --ssl-verify-server-cert=0\n' "$b" \
            > /usr/local/bin/"$b" \
        && chmod +x /usr/local/bin/"$b"; \
    done

# PHP settings tuned for WordPress development. mhsendmail only takes
# --smtp-addr=host:port; written with a space it exits with "flag needs an
# argument" and mail() returns false for every message. The value is quoted
# because an unquoted = is a syntax error in php.ini.
RUN { \
        echo "upload_max_filesize = 64M"; \
        echo "post_max_size = 64M"; \
        echo "max_execution_time = 300"; \
        echo "memory_limit = 256M"; \
        echo 'sendmail_path = "/usr/local/bin/mhsendmail --smtp-addr=mailhog:1025"'; \
    } > /usr/local/etc/php/conf.d/wordpress.ini \
    && sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf \
    && sed -i 's/80/8080/g' /etc/apache2/ports.conf /etc/apache2/sites-available/000-default.conf

# Traefik terminates TLS and forwards plain HTTP here, so PHP sees no HTTPS and
# builds http:// URLs for a site served over https://. WordPress turns that into
# a redirect loop on /wp-admin/: it thinks the request is insecure and bounces to
# the https siteurl, which arrives looking insecure again. Translate Traefik's
# X-Forwarded-Proto into the flag PHP actually reads. Trusting the header is safe
# because the container is not published — Traefik is the only way in.
RUN printf 'SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on\n' \
        > /etc/apache2/conf-available/forwarded-proto.conf \
    && a2enconf forwarded-proto

# Apache builds its own redirects (e.g. mod_dir adding the trailing slash to
# /wp-admin) from how it was reached: plain HTTP on port 8080, behind Traefik. So
# /wp-admin became http://{slug}.test:8080/wp-admin/. Give the vhost its public
# https name so they point at https://{slug}.test instead. APACHE_SERVER_NAME is
# set in docker-compose.yml; Apache expands ${...} from the environment.
RUN sed -i 's#<VirtualHost \*:8080>#&\n\tServerName https://${APACHE_SERVER_NAME}\n\tUseCanonicalName On#' \
        /etc/apache2/sites-available/000-default.conf

EOF
    append_bedrock_docroot_layer "$dir/Dockerfile"
    append_composer_layer "$dir/Dockerfile"
    cat >> "$dir/Dockerfile" <<'EOF'
EXPOSE 8080

# Run Apache as www-data so files created inside the container are owned by the host user
USER www-data
EOF

    cat > "$dir/docker-compose.yml" <<EOF
services:

  # ── Web server ───────────────────────────────────────────────────────────────
  web:
    build: .
    container_name: ${slug}-web
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - ./src:/var/www/html
    environment:
      # DB_HOST is always "db" (the Docker service name) — not localhost
      DB_HOST: db
      # Public name for Apache's own redirects (see the Dockerfile)
      APACHE_SERVER_NAME: ${slug}.test
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}.rule=Host(\`${slug}.test\`)"
      - "traefik.http.routers.${slug}.entrypoints=websecure"
      - "traefik.http.routers.${slug}.tls=true"
      - "traefik.http.services.${slug}.loadbalancer.server.port=8080"
    networks:
      - proxy
      - internal

  # ── MySQL database ────────────────────────────────────────────────────────────
  db:
    image: mysql:8.0
    container_name: ${slug}-db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p\${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - internal

  # ── phpMyAdmin ────────────────────────────────────────────────────────────────
  phpmyadmin:
    image: phpmyadmin:latest
    container_name: ${slug}-phpmyadmin
    restart: unless-stopped
    depends_on:
      - db
    environment:
      PMA_HOST: db
      PMA_USER: \${MYSQL_USER}
      PMA_PASSWORD: \${MYSQL_PASSWORD}
      UPLOAD_LIMIT: 256M
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}-pma.rule=Host(\`${slug}-db.test\`)"
      - "traefik.http.routers.${slug}-pma.entrypoints=websecure"
      - "traefik.http.routers.${slug}-pma.tls=true"
      - "traefik.http.services.${slug}-pma.loadbalancer.server.port=80"
    networks:
      - proxy
      - internal

  # ── MailHog — captures all outgoing PHP mail ──────────────────────────────────
  mailhog:
    image: mailhog/mailhog:latest
    container_name: ${slug}-mailhog
    restart: unless-stopped
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}-mail.rule=Host(\`${slug}-mail.test\`)"
      - "traefik.http.routers.${slug}-mail.entrypoints=websecure"
      - "traefik.http.routers.${slug}-mail.tls=true"
      - "traefik.http.services.${slug}-mail.loadbalancer.server.port=8025"
    networks:
      - proxy
      - internal

volumes:
  db_data:

networks:
  proxy:
    external: true
  internal:
    driver: bridge
EOF

    # Bedrock gets its own .env and welcome page under src/web/ instead
    if [ "${use_bedrock:-n}" = "y" ]; then
        write_bedrock_files "$dir" "$slug" "$db_name" "$db_user" "$db_password"
        return
    fi

    # Welcome page — shown before WordPress is installed.
    # Delete or overwrite src/ when you drop in WordPress.
    cat > "$dir/src/index.php" <<'WELCOME'
<?php
$host = $_SERVER['HTTP_HOST'] ?? 'your-project.test';
$slug = explode('.', $host)[0];
?><!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Ready — <?= htmlspecialchars($host) ?></title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 600px; margin: 80px auto; padding: 0 24px; color: #1a1a1a; }
    h1   { font-size: 1.5rem; margin-bottom: 0.25rem; }
    p    { color: #555; margin: 0.4rem 0; }
    code { background: #f0f0f0; padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }
    pre  { background: #f0f0f0; padding: 12px; border-radius: 6px; overflow-x: auto; }
    .step { margin: 1.5rem 0 0.5rem; font-weight: 600; }
    a    { color: #2563eb; }
  </style>
</head>
<body>
  <h1>Your WordPress environment is ready.</h1>
  <p>PHP <?= phpversion() ?> &middot; <a href="https://<?= htmlspecialchars($slug) ?>-db.test" target="_blank">phpMyAdmin</a> &middot; <a href="https://<?= htmlspecialchars($slug) ?>-mail.test" target="_blank">MailHog</a></p>

  <p class="step">Option A &mdash; fresh WordPress install</p>
  <p>Extract WordPress into <code>src/</code>, or run:</p>
  <pre><code>docker exec <?= htmlspecialchars($slug) ?>-web sh -c "curl -sL https://wordpress.org/latest.tar.gz | tar xz --strip-components=1 -C /var/www/html"</code></pre>

  <p class="step">Option B &mdash; clone your existing repo</p>
  <pre><code>git clone https://github.com/you/your-repo.git src/</code></pre>

  <p style="margin-top:2rem;font-size:0.85rem;color:#999;">Delete or overwrite this file once WordPress is in place.</p>
</body>
</html>
WELCOME
}

# ─── WordPress / Nginx + FPM container ───────────────────────────────────────
# Two containers for PHP: nginx:alpine (web) + php:8.3-fpm (PHP processor).
# All WordPress-required extensions included. WordPress NOT pre-installed.

create_wordpress_nginx() {
    local slug="$1"
    local dir="$DEV_DIR/$slug"

    local db_name db_user
    db_name=$(db_identifier "$slug" db 64)
    db_user=$(db_identifier "$slug" user 32)
    local db_password
    local db_root_password
    db_password=$(gen_password)
    db_root_password=$(gen_password)

    mkdir -p "$dir/src" "$dir/nginx"

    cat > "$dir/.env" <<EOF
# Database credentials — generated automatically
# Use these values when configuring WordPress (wp-config.php or src/.env for Bedrock)
# The database host inside Docker is always: db
MYSQL_DATABASE=${db_name}
MYSQL_USER=${db_user}
MYSQL_PASSWORD=${db_password}
MYSQL_ROOT_PASSWORD=${db_root_password}
EOF

    cat > "$dir/.gitignore" <<'EOF'
.env
*.log
EOF

    # PHP-FPM Dockerfile with all WordPress-required extensions.
    # Uses php:8.3-fpm (not Apache) — Nginx handles HTTP, FPM handles PHP.
    cat > "$dir/Dockerfile" <<'EOF'
FROM php:8.3-fpm

# Match www-data's UID/GID to the host user, so files created by PHP-FPM
# inside the container are owned by you on the host, not by an unmapped UID.
RUN usermod -u 1000 www-data && groupmod -g 1000 www-data && \
    find / -path /proc -prune -o -user 33 -exec chown -h www-data {} \; && \
    find / -path /proc -prune -o -group 33 -exec chgrp -h www-data {} \;

# Install system libraries required by PHP extensions, plus the MySQL client.
# WP-CLI shells out to mysql/mysqldump for the `wp db` family — export, import,
# check, cli — so without the client those commands fail at the point of use.
RUN apt-get update && apt-get install -y \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev \
        libxml2-dev \
        libcurl4-openssl-dev \
        libssl-dev \
        libmagickwand-dev \
        libonig-dev \
        default-mysql-client \
        --no-install-recommends \
    && docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        gd \
        mysqli \
        pdo_mysql \
        mbstring \
        xml \
        zip \
        curl \
        intl \
        exif \
        opcache \
    && pecl install imagick \
    && docker-php-ext-enable imagick \
    && rm -rf /var/lib/apt/lists/*

# Install mhsendmail so PHP's mail() function is captured by MailHog.
RUN curl -sL \
        https://github.com/mailhog/mhsendmail/releases/download/v0.2.0/mhsendmail_linux_amd64 \
        -o /usr/local/bin/mhsendmail \
    && chmod +x /usr/local/bin/mhsendmail

# Install WP-CLI — manage WordPress from the command line inside the container.
# www-data's home is /var/www, owned by root, so WP-CLI cannot create the
# download cache it keeps in $HOME/.wp-cli — every core/plugin fetch would warn
# and re-download. The directory is created up front and handed to www-data; it
# sits beside html/, so the ./src bind mount does not shadow it.
RUN curl -sL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp \
    && mkdir -p /var/www/.wp-cli/cache \
    && chown -R www-data:www-data /var/www/.wp-cli

# Debian's default-mysql-client is MariaDB's, whose client verifies the server
# certificate by default. MySQL 8 presents a self-signed one, so every `wp db`
# command dies with "TLS/SSL error: self-signed certificate in certificate
# chain". WP-CLI runs the client with --no-defaults, so no config file can carry
# the opt-out — these shims sit ahead of /usr/bin on PATH and append it. The
# connection is between two containers on a private network on your own machine.
RUN for b in mariadb mariadb-dump mariadb-check mysql mysqldump mysqlcheck; do \
        printf '#!/bin/sh\nexec /usr/bin/%s "$@" --ssl-verify-server-cert=0\n' "$b" \
            > /usr/local/bin/"$b" \
        && chmod +x /usr/local/bin/"$b"; \
    done

# PHP settings tuned for WordPress development. mhsendmail only takes
# --smtp-addr=host:port; written with a space it exits with "flag needs an
# argument" and mail() returns false for every message. The value is quoted
# because an unquoted = is a syntax error in php.ini.
RUN { \
        echo "upload_max_filesize = 64M"; \
        echo "post_max_size = 64M"; \
        echo "max_execution_time = 300"; \
        echo "memory_limit = 256M"; \
        echo 'sendmail_path = "/usr/local/bin/mhsendmail --smtp-addr=mailhog:1025"'; \
    } > /usr/local/etc/php/conf.d/wordpress.ini

EOF
    append_composer_layer "$dir/Dockerfile"
    cat >> "$dir/Dockerfile" <<'EOF'
USER www-data
EOF

    # Nginx configuration for WordPress
    # $uri, $args, etc. are Nginx variables — not bash variables
    cat > "$dir/nginx/nginx.conf" <<'NGINX_EOF'
# Traefik reports the browser's original scheme here. This file is included
# inside http{}, which is the only level where map is allowed.
map $http_x_forwarded_proto $https_from_proxy {
    default '';
    https   on;
}

server {
    listen 80;
    # Nginx only sees Traefik's plain-HTTP hop, so its own redirects (e.g. adding a
    # directory's trailing slash) would point at http://. Keep them relative, so the
    # browser stays on https://{slug}.test.
    absolute_redirect off;
NGINX_EOF
    # Bedrock serves WordPress from web/, keeping .env, config/ and vendor/
    # outside the document root. SCRIPT_FILENAME below is built from $document_root,
    # and the php container mounts src/ at the same path, so it stays consistent.
    if [ "${use_bedrock:-n}" = "y" ]; then
        echo "    root  /var/www/html/web;" >> "$dir/nginx/nginx.conf"
    else
        echo "    root  /var/www/html;" >> "$dir/nginx/nginx.conf"
    fi
    cat >> "$dir/nginx/nginx.conf" <<'NGINX_EOF'
    index index.php index.html;

    # Nginx rejects request bodies over 1M by default, before PHP sees them, so
    # any media upload past that fails with 413. Match PHP's upload_max_filesize.
    client_max_body_size 64M;

    # WordPress permalink routing
    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    # Forward PHP requests to the php-fpm container on port 9000
    location ~ \.php$ {
        fastcgi_pass  php:9000;
        fastcgi_index index.php;
        include       fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO       $fastcgi_path_info;

        # Traefik terminates TLS and forwards plain HTTP, so PHP would otherwise
        # build http:// URLs for a site served over https:// — which WordPress
        # turns into a redirect loop on /wp-admin/. Pass the original scheme on.
        fastcgi_param HTTPS $https_from_proxy if_not_empty;
    }

    # Deny access to hidden files and sensitive WordPress paths
    location ~ /\. {
        deny all;
    }

    location ~* /(?:uploads|files)/.*\.php$ {
        deny all;
    }
}
NGINX_EOF

    cat > "$dir/docker-compose.yml" <<EOF
services:

  # ── Nginx web server ─────────────────────────────────────────────────────────
  web:
    image: nginx:alpine
    container_name: ${slug}-web
    restart: unless-stopped
    depends_on:
      - php
    volumes:
      - ./src:/var/www/html:ro
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}.rule=Host(\`${slug}.test\`)"
      - "traefik.http.routers.${slug}.entrypoints=websecure"
      - "traefik.http.routers.${slug}.tls=true"
      - "traefik.http.services.${slug}.loadbalancer.server.port=80"
    networks:
      - proxy
      - internal

  # ── PHP-FPM processor ────────────────────────────────────────────────────────
  php:
    build: .
    container_name: ${slug}-php
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - ./src:/var/www/html
    environment:
      # DB_HOST is always "db" (the Docker service name) — not localhost
      DB_HOST: db
    networks:
      - internal

  # ── MySQL database ────────────────────────────────────────────────────────────
  db:
    image: mysql:8.0
    container_name: ${slug}-db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p\${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - internal

  # ── phpMyAdmin ────────────────────────────────────────────────────────────────
  phpmyadmin:
    image: phpmyadmin:latest
    container_name: ${slug}-phpmyadmin
    restart: unless-stopped
    depends_on:
      - db
    environment:
      PMA_HOST: db
      PMA_USER: \${MYSQL_USER}
      PMA_PASSWORD: \${MYSQL_PASSWORD}
      UPLOAD_LIMIT: 256M
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}-pma.rule=Host(\`${slug}-db.test\`)"
      - "traefik.http.routers.${slug}-pma.entrypoints=websecure"
      - "traefik.http.routers.${slug}-pma.tls=true"
      - "traefik.http.services.${slug}-pma.loadbalancer.server.port=80"
    networks:
      - proxy
      - internal

  # ── MailHog — captures all outgoing PHP mail ──────────────────────────────────
  mailhog:
    image: mailhog/mailhog:latest
    container_name: ${slug}-mailhog
    restart: unless-stopped
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}-mail.rule=Host(\`${slug}-mail.test\`)"
      - "traefik.http.routers.${slug}-mail.entrypoints=websecure"
      - "traefik.http.routers.${slug}-mail.tls=true"
      - "traefik.http.services.${slug}-mail.loadbalancer.server.port=8025"
    networks:
      - proxy
      - internal

volumes:
  db_data:

networks:
  proxy:
    external: true
  internal:
    driver: bridge
EOF

    # Bedrock gets its own .env and welcome page under src/web/ instead
    if [ "${use_bedrock:-n}" = "y" ]; then
        write_bedrock_files "$dir" "$slug" "$db_name" "$db_user" "$db_password"
        return
    fi

    # Welcome page — shown before WordPress is installed.
    # Delete or overwrite src/ when you drop in WordPress.
    cat > "$dir/src/index.php" <<'WELCOME'
<?php
$host = $_SERVER['HTTP_HOST'] ?? 'your-project.test';
$slug = explode('.', $host)[0];
?><!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Ready — <?= htmlspecialchars($host) ?></title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 600px; margin: 80px auto; padding: 0 24px; color: #1a1a1a; }
    h1   { font-size: 1.5rem; margin-bottom: 0.25rem; }
    p    { color: #555; margin: 0.4rem 0; }
    code { background: #f0f0f0; padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }
    pre  { background: #f0f0f0; padding: 12px; border-radius: 6px; overflow-x: auto; }
    .step { margin: 1.5rem 0 0.5rem; font-weight: 600; }
    a    { color: #2563eb; }
  </style>
</head>
<body>
  <h1>Your WordPress environment is ready.</h1>
  <p>PHP <?= phpversion() ?> &middot; <a href="https://<?= htmlspecialchars($slug) ?>-db.test" target="_blank">phpMyAdmin</a> &middot; <a href="https://<?= htmlspecialchars($slug) ?>-mail.test" target="_blank">MailHog</a></p>

  <p class="step">Option A &mdash; fresh WordPress install</p>
  <p>Extract WordPress into <code>src/</code>, or run:</p>
  <pre><code>docker exec <?= htmlspecialchars($slug) ?>-php sh -c "curl -sL https://wordpress.org/latest.tar.gz | tar xz --strip-components=1 -C /var/www/html"</code></pre>

  <p class="step">Option B &mdash; clone your existing repo</p>
  <pre><code>git clone https://github.com/you/your-repo.git src/</code></pre>

  <p style="margin-top:2rem;font-size:0.85rem;color:#999;">Delete or overwrite this file once WordPress is in place.</p>
</body>
</html>
WELCOME
}

# ─── Remote DB (phpMyAdmin over an SSH tunnel) ───────────────────────────────
# phpMyAdmin for a MySQL server that only listens on the remote host's localhost.
# A small "tunnel" container keeps an SSH port forward open to it, so nothing new
# is exposed on the server and MySQL is never reachable from the host's network.
# Neither container restarts on boot: they run only between start-docker and
# stop-docker.

# Prints the remote host's key lines for the project's known_hosts: copied from the
# user's own known_hosts when the host is already trusted there, otherwise scanned
# and shown so the user can confirm the fingerprint (trust on first use).
remote_known_hosts() {
    local host="$1" port="$2" out="$3"
    local entry="$host"
    [ "$port" = "22" ] || entry="[$host]:$port"

    if [ -f "$HOME/.ssh/known_hosts" ] \
        && ssh-keygen -F "$entry" -f "$HOME/.ssh/known_hosts" 2>/dev/null | grep -v '^#' > "$out" \
        && [ -s "$out" ]; then
        success "Host key for ${entry} copied from ~/.ssh/known_hosts."
        return
    fi

    info "${entry} is not in ~/.ssh/known_hosts — scanning its host key..."
    ssh-keyscan -p "$port" "$host" 2>/dev/null > "$out" || true
    [ -s "$out" ] || die "Could not read the host key of ${entry}. Is the host reachable on port ${port}?"
    echo ""
    ssh-keygen -lf "$out" | sed 's/^/      /'
    echo ""
    read -rp "  Trust this host key? [y/N] " trust
    [[ "$trust" =~ ^[Yy]$ ]] || { rm -f "$out"; die "Host key not trusted. Aborted."; }
}

create_remote_db() {
    local slug="$1"
    local dir="$DEV_DIR/$slug"
    local user_host="${remote_user}@${remote_host}"

    mkdir -p "$dir/tunnel"

    remote_known_hosts "$remote_host" "$remote_ssh_port" "$dir/known_hosts"

    cat > "$dir/tunnel/Dockerfile" <<'EOF'
# SSH client for the tunnel to the remote MySQL server
FROM alpine:3.20
RUN apk add --no-cache openssh-client
EOF

    # How the tunnel authenticates: a read-only key file, or the host's SSH agent.
    # create_host_path: false stops Docker from creating an empty directory in place
    # of a missing key file or agent socket.
    local ssh_auth_opts ssh_auth_volume ssh_auth_env=""
    if [ "$remote_auth" = "agent" ]; then
        ssh_auth_opts=""
        ssh_auth_volume="      - type: bind
        source: \${SSH_AUTH_SOCK:?SSH_AUTH_SOCK is not set - start an SSH agent first}
        target: /run/ssh/agent.sock
        bind:
          create_host_path: false"
        ssh_auth_env="    environment:
      SSH_AUTH_SOCK: /run/ssh/agent.sock
"
    else
        ssh_auth_opts="-i /run/ssh/key -o IdentitiesOnly=yes "
        ssh_auth_volume="      - type: bind
        source: ${remote_key}
        target: /run/ssh/key
        read_only: true
        bind:
          create_host_path: false"
    fi

    cat > "$dir/docker-compose.yml" <<EOF
services:
  # ── SSH tunnel — forwards port 3306 here to MySQL on the remote host ─────────
  tunnel:
    build: ./tunnel
    container_name: ${slug}-tunnel
    restart: "no"
    command: >
      ssh -N -p ${remote_ssh_port} ${ssh_auth_opts}-o BatchMode=yes
      -o UserKnownHostsFile=/run/ssh/known_hosts -o StrictHostKeyChecking=yes
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3
      -L 0.0.0.0:3306:127.0.0.1:${remote_db_port} ${user_host}
${ssh_auth_env}    volumes:
${ssh_auth_volume}
      - ./known_hosts:/run/ssh/known_hosts:ro
    networks:
      - internal

  # ── phpMyAdmin — log in with a MySQL user of the remote server ───────────────
  phpmyadmin:
    image: phpmyadmin:latest
    container_name: ${slug}-phpmyadmin
    restart: "no"
    depends_on:
      - tunnel
    environment:
      PMA_HOST: tunnel
      PMA_PORT: 3306
      UPLOAD_LIMIT: 256M
    volumes:
      - ./config.user.inc.php:/etc/phpmyadmin/config.user.inc.php:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${slug}.rule=Host(\`${slug}.test\`)"
      - "traefik.http.routers.${slug}.entrypoints=websecure"
      - "traefik.http.routers.${slug}.tls=true"
      - "traefik.http.services.${slug}.loadbalancer.server.port=80"
    networks:
      - proxy
      - internal

networks:
  proxy:
    external: true
  internal:
    driver: bridge
EOF

    {
        echo "<?php"
        echo "// Name shown on the login page"
        echo "\$cfg['Servers'][1]['verbose'] = '${remote_host}';"
        if [ "$remote_tls" = "y" ]; then
            echo "// TLS to MySQL (needed when the server sets require_secure_transport)."
            echo "// The certificate is not verified: the SSH tunnel already authenticates the host."
            echo "\$cfg['Servers'][1]['ssl'] = true;"
            echo "\$cfg['Servers'][1]['ssl_verify'] = false;"
        fi
    } > "$dir/config.user.inc.php"
}


main() {
    print_header
    check_dependencies

    # ── Project slug ──────────────────────────────────────────────────────────
    if [ -n "${1:-}" ]; then
        slug="$1"
        echo -e "  ${BOLD}Project name:${RESET} $slug"
    else
        echo -e "  ${BOLD}Project name${RESET} (lowercase letters, numbers, hyphens only):"
        read -rp "  > " slug
    fi

    # Must start and end with a letter or digit; hyphens allowed in the middle
    if [[ ! "$slug" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        die "Invalid project name. Use lowercase letters, numbers, and hyphens. Must not start or end with a hyphen."
    fi

    if [ -d "$DEV_DIR/$slug" ]; then
        die "A project named '${slug}' already exists at $DEV_DIR/$slug"
    fi

    # ── Container type ────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Container type:${RESET}"
    PS3="  > "
    select choice in \
        "HTML       — nginx:alpine, static files only" \
        "PHP        — PHP 8.3, general PHP development" \
        "WordPress  — PHP 8.3 + MySQL + phpMyAdmin + MailHog" \
        "Remote DB  — phpMyAdmin for a remote MySQL server, over SSH"; do
        case $REPLY in
            1) container_type="html";      break ;;
            2) container_type="php";       break ;;
            3) container_type="wordpress"; break ;;
            4) container_type="remote";    break ;;
            *) warn "Please enter 1, 2, 3, or 4." ;;
        esac
    done

    # ── Remote DB settings ────────────────────────────────────────────────────
    if [ "$container_type" = "remote" ]; then
        command -v ssh-keyscan &>/dev/null || die "ssh-keyscan not found. Install the OpenSSH client."

        echo ""
        echo -e "  ${BOLD}SSH host${RESET} (user@host):"
        read -rp "  > " remote_target
        [[ "$remote_target" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$ ]] \
            || die "Invalid SSH host. Use user@host, e.g. deploy@203.0.113.10"
        remote_user="${remote_target%@*}"
        remote_host="${remote_target#*@}"

        read -rp "  SSH port [22]: " remote_ssh_port
        remote_ssh_port="${remote_ssh_port:-22}"
        [[ "$remote_ssh_port" =~ ^[0-9]+$ ]] || die "Invalid SSH port."

        echo ""
        echo -e "  ${BOLD}SSH authentication:${RESET}"
        select choice in \
            "Key file   — a private key file without passphrase" \
            "SSH agent  — the agent in SSH_AUTH_SOCK when the project starts"; do
            case $REPLY in
                1) remote_auth="key";   break ;;
                2) remote_auth="agent"; break ;;
                *) warn "Please enter 1 or 2." ;;
            esac
        done

        remote_key=""
        if [ "$remote_auth" = "key" ]; then
            read -rp "  Key file [~/.ssh/id_ed25519]: " remote_key
            remote_key="${remote_key:-~/.ssh/id_ed25519}"
            remote_key="${remote_key/#\~/$HOME}"
            [ -r "$remote_key" ] || die "Cannot read key file: $remote_key"
            # The tunnel runs unattended, so it cannot ask for a passphrase
            ssh-keygen -y -P "" -f "$remote_key" &>/dev/null \
                || die "The key has a passphrase. Load it in an SSH agent and choose 'SSH agent' instead."
        fi

        echo ""
        read -rp "  MySQL port on the server [3306]: " remote_db_port
        remote_db_port="${remote_db_port:-3306}"
        [[ "$remote_db_port" =~ ^[0-9]+$ ]] || die "Invalid MySQL port."

        read -rp "  Use TLS to MySQL? [Y/n] " tls_answer
        remote_tls="y"
        [[ "$tls_answer" =~ ^[Nn]$ ]] && remote_tls="n"
    fi

    # ── HTML project subtype ───────────────────────────────────────────────────
    html_type="static"  # default
    if [ "$container_type" = "html" ]; then
        echo ""
        echo -e "  ${BOLD}Project type:${RESET}"
        PS3="  > "
        select choice in \
            "Plain HTML/CSS    — static files in src/" \
            "Vite               — dev server proxy (React, Vue, Pandora, etc)"; do
            case $REPLY in
                1) html_type="static"; break ;;
                2) html_type="vite";   break ;;
                *) warn "Please enter 1 or 2." ;;
            esac
        done
    fi

    # ── Web server (PHP and WordPress only) ───────────────────────────────────
    server_type="nginx"  # HTML always uses nginx; this default covers it
    if [ "$container_type" = "php" ] || [ "$container_type" = "wordpress" ]; then
        echo ""
        echo -e "  ${BOLD}Web server:${RESET}"
        select choice in \
            "Apache + mod_php  — single container, simpler setup" \
            "Nginx + PHP-FPM   — separate containers, more flexible"; do
            case $REPLY in
                1) server_type="apache"; break ;;
                2) server_type="nginx";  break ;;
                *) warn "Please enter 1 or 2." ;;
            esac
        done
    fi

    # ── Bedrock (WordPress only) ──────────────────────────────────────────────
    use_bedrock="n"
    if [ "$container_type" = "wordpress" ]; then
        echo ""
        read -rp "  Use Bedrock? [y/N] " bedrock_answer
        if [[ "$bedrock_answer" =~ ^[Yy]$ ]]; then
            use_bedrock="y"
        fi
    fi

    # ── Composer (PHP and WordPress only) ─────────────────────────────────────
    # Bedrock is installed with Composer, so choosing it implies Composer.
    install_composer="n"
    if [ "$use_bedrock" = "y" ]; then
        install_composer="y"
    elif [ "$container_type" = "php" ] || [ "$container_type" = "wordpress" ]; then
        echo ""
        read -rp "  Install Composer? [y/N] " composer_answer
        if [[ "$composer_answer" =~ ^[Yy]$ ]]; then
            install_composer="y"
        fi
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Summary${RESET}"
    echo "  ─────────────────────────────────────"
    echo "  Project:   $slug"
    echo "  Type:      $container_type"
    if [ "$container_type" = "html" ]; then
        echo "  Subtype:   $html_type"
    elif [ "$container_type" = "remote" ]; then
        echo "  SSH:       ${remote_user}@${remote_host}:${remote_ssh_port}"
        if [ "$remote_auth" = "key" ]; then
            echo "  Auth:      key file $remote_key"
        else
            echo "  Auth:      SSH agent"
        fi
        echo "  MySQL:     port $remote_db_port on the server, TLS $([ "$remote_tls" = "y" ] && echo yes || echo no)"
    else
        echo "  Server:    $server_type"
        if [ "$container_type" = "wordpress" ]; then
            echo "  Bedrock:   $([ "$use_bedrock" = "y" ] && echo yes || echo no)"
        fi
        echo "  Composer:  $([ "$install_composer" = "y" ] && echo yes || echo no)"
    fi
    echo "  Location:  $DEV_DIR/$slug"
    if [ "$container_type" = "remote" ]; then
        echo "  DB admin:  https://${slug}.test"
    else
        echo "  URL:       https://${slug}.test"
    fi
    if [ "$container_type" = "wordpress" ]; then
        echo "  DB admin:  https://${slug}-db.test"
        echo "  Mail:      https://${slug}-mail.test"
    fi
    echo "  ─────────────────────────────────────"
    echo ""
    read -rp "  Proceed? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
    echo ""

    # ── Global proxy ──────────────────────────────────────────────────────────
    setup_proxy

    # ── Generate project files ────────────────────────────────────────────────
    info "Creating project at $DEV_DIR/$slug..."
    case "${container_type}/${html_type:-}/${server_type}" in
        html/static/*)    create_html             "$slug" ;;
        html/vite/*)      create_vite             "$slug" ;;
        php/*/apache)     create_php_apache       "$slug" ;;
        php/*/nginx)      create_php_nginx        "$slug" ;;
        wordpress/*/apache) create_wordpress_apache "$slug" ;;
        wordpress/*/nginx)  create_wordpress_nginx  "$slug" ;;
        remote/*/*)         create_remote_db        "$slug" ;;
    esac
    success "Project files created."

    # ── TLS certificate ───────────────────────────────────────────────────────
    generate_project_cert "$slug" "$container_type"

    # ── /etc/hosts entries ────────────────────────────────────────────────────
    echo ""
    add_hosts_entry "${slug}.test"
    if [ "$container_type" = "wordpress" ]; then
        add_hosts_entry "${slug}-db.test"
        add_hosts_entry "${slug}-mail.test"
    fi

    # ── Start containers ──────────────────────────────────────────────────────
    echo ""
    read -rp "  Start containers now? [Y/n] " start_now
    if [[ ! "$start_now" =~ ^[Nn]$ ]]; then
        info "Building and starting containers (this may take a few minutes on first run)..."
        docker compose -f "$DEV_DIR/$slug/docker-compose.yml" up -d --build
        success "Containers are running."
    else
        echo ""
        info "To start later:"
        echo "       cd $DEV_DIR/$slug && docker compose up -d --build"
    fi

    # ── Done ──────────────────────────────────────────────────────────────────
    echo ""
    echo "  ─────────────────────────────────────"
    echo -e "  ${GREEN}${BOLD}Ready!${RESET}"
    echo ""
    if [ "$container_type" = "remote" ]; then
        echo -e "  DB admin: ${BOLD}https://${slug}.test${RESET}"
        echo "  Log in with a MySQL user of ${remote_host}."
        echo ""
        echo -e "  Start: ${BOLD}start-docker ${slug}${RESET}   Stop: ${BOLD}stop-docker ${slug}${RESET}"
        echo "  Nothing starts on boot; the tunnel is open only while the project runs."
    else
        echo -e "  Site:     ${BOLD}https://${slug}.test${RESET}"
    fi
    if [ "$container_type" = "html" ] && [ "$html_type" = "vite" ]; then
        echo ""
        echo -e "  ${BOLD}Next steps:${RESET}"
        echo "  1. Clone your project into $DEV_DIR/$slug/src/"
        echo "  2. Vite dev server starts automatically with docker compose"
        echo "  3. Open https://${slug}.test in your browser"
        echo ""
        echo -e "  Container logs: ${BOLD}docker compose -f $DEV_DIR/$slug/docker-compose.yml logs -f${RESET}"
    elif [ "$container_type" = "html" ] && [ "$html_type" = "static" ]; then
        echo ""
        echo -e "  ${BOLD}Next steps:${RESET}"
        echo "  Add your files to $DEV_DIR/$slug/src/"
    fi
    if [ "$container_type" = "wordpress" ]; then
        echo -e "  DB admin: ${BOLD}https://${slug}-db.test${RESET}"
        echo -e "  Mail:     ${BOLD}https://${slug}-mail.test${RESET}"
        echo ""
        echo -e "  DB credentials → ${BOLD}$DEV_DIR/$slug/.env${RESET}"
        echo -e "  DB host (inside Docker) → ${BOLD}db${RESET}"
    fi
    if [ "$use_bedrock" = "y" ]; then
        echo -e "  Bedrock .env → ${BOLD}$DEV_DIR/$slug/src/.env${RESET} (ready to use)"
        echo -e "  Install Bedrock → the command is on ${BOLD}https://${slug}.test${RESET}"
    fi
    if [ "$install_composer" = "y" ]; then
        echo ""
        echo -e "  Composer → ${BOLD}composer ...${RESET} from the project folder (needs the composer wrapper on PATH)"
    fi
    echo "  ─────────────────────────────────────"
    echo ""
}

main "$@"
