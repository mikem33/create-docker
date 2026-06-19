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

create_vite() {
    local slug="$1"
    local dir="$DEV_DIR/$slug"

    mkdir -p "$dir/nginx"

    cat > "$dir/nginx/nginx.conf" <<'NGINX_EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://host.docker.internal:5173;
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
  web:
    image: nginx:alpine
    container_name: ${slug}-web
    restart: unless-stopped
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

networks:
  proxy:
    external: true
EOF
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

USER www-data
EOF

    # Nginx server configuration
    # $uri, $query_string, etc. are Nginx variables — not bash variables
    cat > "$dir/nginx/nginx.conf" <<'NGINX_EOF'
server {
    listen 80;
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

    # MySQL identifiers cannot contain hyphens — replace with underscores
    local db_name="${slug//-/_}_db"
    local db_user="${slug//-/_}_user"
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

# Install system libraries required by PHP extensions
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

# Install WP-CLI — manage WordPress from the command line inside the container
RUN curl -sL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp

# PHP settings tuned for WordPress development
RUN { \
        echo "upload_max_filesize = 64M"; \
        echo "post_max_size = 64M"; \
        echo "max_execution_time = 300"; \
        echo "memory_limit = 256M"; \
        echo "sendmail_path = /usr/local/bin/mhsendmail --smtp-addr mailhog:1025"; \
    } > /usr/local/etc/php/conf.d/wordpress.ini \
    && sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf \
    && sed -i 's/80/8080/g' /etc/apache2/ports.conf /etc/apache2/sites-available/000-default.conf

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
  <p>PHP <?= phpversion() ?> &middot; <a href="https://<?= htmlspecialchars($host) ?>-db.test" target="_blank">phpMyAdmin</a> &middot; <a href="https://<?= htmlspecialchars($host) ?>-mail.test" target="_blank">MailHog</a></p>

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

    local db_name="${slug//-/_}_db"
    local db_user="${slug//-/_}_user"
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

# Install system libraries required by PHP extensions
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

# Install WP-CLI — manage WordPress from the command line inside the container
RUN curl -sL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp

# PHP settings tuned for WordPress development
RUN { \
        echo "upload_max_filesize = 64M"; \
        echo "post_max_size = 64M"; \
        echo "max_execution_time = 300"; \
        echo "memory_limit = 256M"; \
        echo "sendmail_path = /usr/local/bin/mhsendmail --smtp-addr mailhog:1025"; \
    } > /usr/local/etc/php/conf.d/wordpress.ini

USER www-data
EOF

    # Nginx configuration for WordPress
    # $uri, $args, etc. are Nginx variables — not bash variables
    cat > "$dir/nginx/nginx.conf" <<'NGINX_EOF'
server {
    listen 80;
    root  /var/www/html;
    index index.php index.html;

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
  <p>PHP <?= phpversion() ?> &middot; <a href="https://<?= htmlspecialchars($host) ?>-db.test" target="_blank">phpMyAdmin</a> &middot; <a href="https://<?= htmlspecialchars($host) ?>-mail.test" target="_blank">MailHog</a></p>

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
        "WordPress  — PHP 8.3 + MySQL + phpMyAdmin + MailHog"; do
        case $REPLY in
            1) container_type="html";      break ;;
            2) container_type="php";       break ;;
            3) container_type="wordpress"; break ;;
            *) warn "Please enter 1, 2, or 3." ;;
        esac
    done

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
    if [ "$container_type" != "html" ]; then
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

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Summary${RESET}"
    echo "  ─────────────────────────────────────"
    echo "  Project:   $slug"
    echo "  Type:      $container_type"
    if [ "$container_type" = "html" ]; then
        echo "  Subtype:   $html_type"
    elif [ "$container_type" != "html" ]; then
        echo "  Server:    $server_type"
    fi
    echo "  Location:  $DEV_DIR/$slug"
    echo "  URL:       https://${slug}.test"
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
    echo -e "  Site:     ${BOLD}https://${slug}.test${RESET}"
    if [ "$container_type" = "html" ] && [ "$html_type" = "vite" ]; then
        echo ""
        echo -e "  ${BOLD}Next steps:${RESET}"
        echo "  1. Clone your project into $DEV_DIR/$slug/"
        echo "  2. Run: cd $DEV_DIR/$slug && pnpm install"
        echo "  3. Run: pnpm dev"
        echo "  4. Open https://${slug}.test in your browser"
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
    echo "  ─────────────────────────────────────"
    echo ""
}

main "$@"
