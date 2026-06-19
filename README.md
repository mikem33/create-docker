# create-docker

A Bash script that spins up local web development environments with a single command. Creates a project folder under `~/Dev/`, generates a `docker-compose.yml`, configures a `.test` domain, and enables HTTPS automatically — no manual configuration needed.

## Features

- **Four ready-to-use environments**: HTML (Nginx), PHP 8.3 (Apache/Nginx), Vite (dev server), and WordPress (PHP + MySQL + phpMyAdmin + MailHog)
- **Automatic HTTPS** with trusted local certificates via [mkcert](https://github.com/FiloSottile/mkcert)
- **Custom `.test` domains** — access your project at `https://my-project.test`
- **Multiple projects simultaneously** — a shared Traefik reverse proxy routes traffic by hostname
- **Secure by default** — database passwords are auto-generated, never hardcoded
- **Smart user mapping** — container UID/GID match your host user for seamless file permissions

## Requirements

| Tool | Purpose | Install |
|---|---|---|
| [Docker Engine](https://docs.docker.com/engine/install/) | Container runtime | See distro instructions |
| [Docker Compose plugin](https://docs.docker.com/compose/install/) | Multi-container orchestration | Bundled with Docker Desktop / `docker-compose-plugin` package |
| [mkcert](https://github.com/FiloSottile/mkcert) | Trusted local TLS certificates | [Install instructions](https://github.com/FiloSottile/mkcert#installation) |

The script checks for all three on startup and prints installation instructions if anything is missing.

## Installation

```bash
# Clone the repository
git clone https://github.com/your-username/create-docker.git ~/Dev/create-docker

# Make the scripts executable
chmod +x ~/Dev/create-docker/scripts/create-docker.sh
chmod +x ~/Dev/create-docker/scripts/delete-docker.sh
chmod +x ~/Dev/create-docker/scripts/start-docker.sh
chmod +x ~/Dev/create-docker/scripts/stop-docker.sh

# Add to PATH (assuming ~/.local/bin is in your PATH)
ln -s ~/Dev/create-docker/scripts/create-docker.sh ~/.local/bin/create-docker
ln -s ~/Dev/create-docker/scripts/delete-docker.sh ~/.local/bin/delete-docker
ln -s ~/Dev/create-docker/scripts/start-docker.sh ~/.local/bin/start-docker
ln -s ~/Dev/create-docker/scripts/stop-docker.sh ~/.local/bin/stop-docker
```

> **Note:** If `~/.local/bin` is not in your PATH, add `export PATH="$HOME/.local/bin:$PATH"` to your shell config (`~/.bashrc`, `~/.zshrc`, `~/.config/fish/config.fish`).

## Usage

Run `create-docker` from any directory and follow the prompts:

```bash
create-docker              # interactive — asks for project name first
create-docker my-project   # skips the project name prompt
```

To remove a project, use `delete-docker`:

```bash
delete-docker              # lists projects and prompts for selection
delete-docker my-project   # skips the selection prompt
```

The delete script stops all containers, removes volumes and project-specific images, deletes the project folder, TLS certificate, Traefik config, and `/etc/hosts` entries. Shared base images (MySQL, Nginx, etc.) are left untouched.

To start or stop a project without removing it:

```bash
start-docker              # lists projects and prompts for selection
start-docker my-project   # starts directly

stop-docker               # lists projects and prompts for selection
stop-docker my-project    # stops directly
```

`stop-docker` uses `docker compose stop` — containers and volumes are preserved. Run `start-docker` to bring them back up.

```
  create-docker  — local web development environment creator
  ─────────────────────────────────────────────────────

  Project name (lowercase letters, numbers, hyphens only):
  > my-project

  Container type:
  1) HTML       — nginx:alpine, static files only
  2) PHP        — PHP 8.3, general PHP development
  3) WordPress  — PHP 8.3 + MySQL + phpMyAdmin + MailHog
  > 3

  Web server:
  1) Apache + mod_php  — single container, simpler setup
  2) Nginx + PHP-FPM   — separate containers, more flexible
  > 2

  Summary
  ─────────────────────────────────────
  Project:   my-project
  Type:      wordpress
  Server:    nginx
  Location:  /home/user/Dev/my-project
  URL:       https://my-project.test
  DB admin:  https://my-project-db.test
  Mail:      https://my-project-mail.test
  ─────────────────────────────────────

  Proceed? [y/N] y
```

The script will:

1. Check dependencies
2. Set up the global Traefik proxy (first run only — takes ~30 seconds)
3. Create the project folder and all configuration files
4. Add the `.test` domain(s) to `/etc/hosts` (requires `sudo`)
5. Optionally build and start the containers

## Container types

### HTML — static files

| Detail | Value |
|---|---|
| Image | `nginx:alpine` |
| Site URL | `https://{slug}.test` |
| Web root | `~/Dev/{slug}/src/` |

A starter `index.html` is created in `src/`. Drop your files there.

### Vite — modern frontend development

| Detail | Value |
|---|---|
| Image | Node.js with Vite and your framework of choice |
| Site URL | `https://{slug}.test` |
| Dev server | Running inside Docker with HMR via Traefik proxy |
| Web root | `~/Dev/{slug}/src/` |

The Vite dev server runs inside Docker and is proxied through Traefik, enabling:
- Hot Module Replacement (HMR) across the HTTPS proxy
- Consistent environment between dev and CI/CD
- Support for React, Vue, Svelte, and other frameworks
- Auto-generated `vite.config.js` configured for the Docker environment

### PHP 8.3

You choose the web server when creating the project:

| Server | Stack | Extras |
|---|---|---|
| **Apache** | `php:8.3-apache` (single container) | `mod_rewrite`, `AllowOverride All` |
| **Nginx + FPM** | `nginx:alpine` + `php:8.3-fpm` (two containers) | FastCGI, front-controller routing |

Both variants install `pdo`, `pdo_mysql`, and `mysqli`. A `phpinfo()` page is created at `src/index.php` to confirm the environment is working.

### WordPress environment

You choose the web server when creating the project (Apache or Nginx + FPM). Both variants include:

| Service | Image | URL |
|---|---|---|
| Web | Apache or Nginx (custom build) | `https://{slug}.test` |
| Database | `mysql:8.0` | Internal only |
| phpMyAdmin | `phpmyadmin:latest` | `https://{slug}-db.test` |
| MailHog | `mailhog/mailhog:latest` | `https://{slug}-mail.test` |

> **WordPress is not pre-installed.** The environment is ready to run it — download WordPress (or Bedrock) into `src/` yourself. See [_docs/containers.md](_docs/containers.md) for step-by-step instructions.

PHP extensions included: `gd`, `mysqli`, `pdo_mysql`, `mbstring`, `xml`, `zip`, `curl`, `intl`, `exif`, `opcache`, `imagick`.

Outgoing PHP mail is automatically captured by MailHog — no emails leave your machine.

## Generated project structure

```
~/Dev/{slug}/
├── docker-compose.yml
├── .env                # WordPress only — DB credentials (gitignored)
├── .gitignore          # PHP / WordPress only
├── Dockerfile          # PHP / WordPress only
└── src/                # Your web files go here
```

The global reverse proxy lives at `~/Dev/.proxy/` and is shared across all projects — it is not tied to any individual project.

## Connecting WordPress to the database

Database credentials are auto-generated and stored in `~/Dev/{slug}/.env`. Use them when WordPress asks for connection details.

**Standard WordPress** (`wp-config.php`):

```php
define( 'DB_NAME',     'my_project_db' );
define( 'DB_USER',     'my_project_user' );
define( 'DB_PASSWORD', '<value from .env>' );
define( 'DB_HOST',     'db' );  // Docker service name — not localhost
```

**Bedrock** (`src/.env`):

```
DB_NAME=my_project_db
DB_USER=my_project_user
DB_PASSWORD=<value from .env>
DB_HOST=db
```

The database host is always `db` — the name of the MySQL Docker service — not `localhost`.

## Firefox HTTPS note

mkcert registers its CA in the system certificate store, which Chrome, Chromium, and most desktop apps trust automatically. **Firefox uses its own certificate store** and may show a security warning. To fix this, import the mkcert CA into Firefox:

1. Find the CA certificate: run `mkcert -CAROOT` to get the folder path
2. In Firefox: Settings → Privacy & Security → View Certificates → Authorities → Import
3. Select `rootCA.pem` from that folder and check "Trust this CA to identify websites"

## Security notes

- Database passwords are generated with `openssl rand` and are unique per project
- The `.env` file (containing credentials) is listed in `.gitignore` and should never be committed
- TLS certificates are stored in `~/Dev/.proxy/certs/` — they are local to your machine and are not part of this repository
- The database container is on an isolated internal Docker network and is not directly reachable from outside the containers
- This tooling is intended for **local development only** — do not expose these containers to the public internet

## Documentation

- [Architecture overview](_docs/architecture.md) — how Traefik, mkcert, and Docker networks work together
- [Container reference](_docs/containers.md) — detailed breakdown of each container type

## License

MIT
