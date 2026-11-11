# create-docker

A Bash script that spins up local web development environments with a single command. Creates a project folder under `~/Dev/`, generates a `docker-compose.yml`, configures a `.test` domain, and enables HTTPS automatically — no manual configuration needed.

## Features

- **Four ready-to-use environments**: HTML (Nginx), PHP 8.3 (Apache/Nginx, optional MySQL + phpMyAdmin), Vite (dev server), and WordPress (PHP + MySQL + phpMyAdmin + MailHog)
- **Remote DB** — phpMyAdmin for a MySQL server on another machine, through an SSH tunnel
- **Automatic HTTPS** with trusted local certificates via [mkcert](https://github.com/FiloSottile/mkcert)
- **Custom `.test` domains** — access your project at `https://my-project.test`
- **Multiple projects simultaneously** — a shared Traefik reverse proxy routes traffic by hostname
- **Secure by default** — database passwords are auto-generated, never hardcoded
- **Smart user mapping** — container UID/GID match your host user for seamless file permissions
- **Optional Composer** — PHP and WordPress containers can include Composer 2, no PHP needed on the host
- **Bedrock-ready WordPress** — serves `src/web/`, with Bedrock's `.env` already filled in

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

# Link the commands into ~/.local/bin (safe to run again; --dry shows what it would do)
~/Dev/create-docker/install.sh
```

> **Note:** `install.sh` links `create-docker`, `delete-docker`, `start-docker`, `stop-docker`, `wp`, `composer` and `pnpm`. If one of those names is already taken in `~/.local/bin` (e.g. your own `wp`), it leaves it alone, skips that command and says so. `wp` and `composer` act inside PHP / WordPress projects, `pnpm` inside Vite projects; outside a Vite project created by `create-docker`, `pnpm` hands over to the host's pnpm unchanged, so `~/.local/bin` must come before it on your PATH (the script warns otherwise).

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
  4) Remote DB  — phpMyAdmin for a remote MySQL server, over SSH
  > 3

  Web server:
  1) Apache + mod_php  — single container, simpler setup
  2) Nginx + PHP-FPM   — separate containers, more flexible
  > 2

  Use Bedrock? [y/N] n

  Install Composer? [y/N] y

  Summary
  ─────────────────────────────────────
  Project:   my-project
  Type:      wordpress
  Server:    nginx
  Bedrock:   no
  Composer:  yes
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
| Image | `node:lts-alpine` + corepack/pnpm (built), runs as your host user |
| Site URL | `https://{slug}.test` |
| Dev server | Your project's own Vite, started by you inside Docker, with HMR via Traefik |
| Project folder | `~/Dev/{slug}/src/` (left empty — clone your project into it) |

The container brings Node and pnpm, not Vite: Vite and its config come from your project. The container runs nothing by itself; with the `pnpm` wrapper on your PATH you work as you would locally, and the output stays in your terminal:

```bash
git clone https://github.com/you/your-repo.git ~/Dev/my-project/src
cd ~/Dev/my-project/src
pnpm install
pnpm dev        # Ctrl+C stops it; closing the terminal stops it too
```

Your project must bring:
- a `dev` script in `package.json` that starts the Vite dev server;
- a dev server listening on `0.0.0.0` (`server.host`) on port 5173 (Vite's default), and accepting the `{slug}.test` host (`server.allowedHosts`) — otherwise nginx cannot reach it or Vite rejects the request.

`pnpm release` and `pnpm prod` are the exception: they commit and push, so the wrapper runs them on the host, where git and your SSH keys are; the container has neither.

Files pnpm creates in `src/` (`node_modules/`, the lockfile, build output) are owned by your host user. Without the wrapper, use `docker compose exec vite pnpm …`. See [_docs/containers.md](_docs/containers.md#vite--modern-frontend-development).

### PHP 8.3

You choose the web server when creating the project:

| Server | Stack | Extras |
|---|---|---|
| **Apache** | `php:8.3-apache` (single container) | `mod_rewrite`, `AllowOverride All` |
| **Nginx + FPM** | `nginx:alpine` + `php:8.3-fpm` (two containers) | FastCGI, front-controller routing |

Both variants install `pdo`, `pdo_mysql`, and `mysqli`. A `phpinfo()` page is created at `src/index.php` to confirm the environment is working.

`create-docker` then asks `Add a MySQL database? [y/N]`. With `y`, the project gets the same `mysql:8.0` and phpMyAdmin (`https://{slug}-db.test`) as WordPress, credentials in `.env`, and the PHP container receives them as environment variables — see [Connecting to the database](#connecting-to-the-database).

### WordPress environment

You choose the web server when creating the project (Apache or Nginx + FPM). Both variants include:

| Service | Image | URL |
|---|---|---|
| Web | Apache or Nginx (custom build) | `https://{slug}.test` |
| Database | `mysql:8.0` | Internal only |
| phpMyAdmin | `phpmyadmin:latest` | `https://{slug}-db.test` |
| MailHog | `mailhog/mailhog:latest` | `https://{slug}-mail.test` |

> **WordPress is not pre-installed.** The environment is ready to run it — download WordPress into `src/` yourself, or choose Bedrock (below). See [_docs/containers.md](_docs/containers.md) for step-by-step instructions.

PHP extensions included: `gd`, `mysqli`, `pdo_mysql`, `mbstring`, `xml`, `zip`, `curl`, `intl`, `exif`, `opcache`, `imagick`.

Outgoing PHP mail is automatically captured by MailHog — no emails leave your machine.

### Bedrock (optional)

Answer `y` to `Use Bedrock? [y/N]` to prepare a WordPress project for [Bedrock](https://roots.io/bedrock/), on either web server:

- Composer is included (the Composer question is skipped)
- The site is served from `src/web/`, so `.env`, `config/` and `vendor/` stay out of the document root
- `src/.env` is written with the project's database credentials, `DB_HOST='db'`, `WP_HOME=https://{slug}.test` and fresh keys and salts

Bedrock itself is not installed: the welcome page at `https://{slug}.test` shows the command, which installs `roots/bedrock` (or any Bedrock-based package) without touching the prepared `.env`. See [_docs/containers.md](_docs/containers.md#installing-bedrock).

### Remote DB — phpMyAdmin over SSH

phpMyAdmin for a MySQL server on another machine, reached through an SSH tunnel that runs in a container. Nothing is opened on the server, and nothing starts on boot.

| Service | Image | URL |
|---|---|---|
| SSH tunnel | `alpine` + `openssh-client` (built) | Internal only |
| phpMyAdmin | `phpmyadmin:latest` | `https://{slug}.test` |

`create-docker` asks for the SSH host (`user@host`), the SSH port, how to authenticate (a key file without passphrase, or the SSH agent in `SSH_AUTH_SOCK`), the MySQL port on the server and whether to use TLS. Only the key file is mounted, read-only, and the server's host key is pinned in the project's own `known_hosts`. Use it like any project: `start-docker {slug}`, log in at `https://{slug}.test` with a MySQL user of the server, `stop-docker {slug}`. See [_docs/containers.md](_docs/containers.md#remote-db--phpmyadmin-over-ssh).

### Composer (optional)

PHP and WordPress projects can include Composer 2 in the PHP container — answer `y` to `Install Composer?` when creating the project. Nothing needs to be installed on the host. With the `composer` wrapper on your PATH, run it from anywhere in the project as if it were local:

```bash
cd ~/Dev/my-project/src
composer require vendor/package
```

Without the wrapper, use `docker compose exec web composer …` (Apache) or `docker compose exec php composer …` (Nginx + FPM). Files Composer creates are owned by your host user. See [_docs/containers.md](_docs/containers.md#composer) for details, including how to add Composer to an existing project.

## Generated project structure

```
~/Dev/{slug}/
├── docker-compose.yml
├── .env                # WordPress, or PHP with a database — DB credentials (gitignored)
├── .gitignore          # PHP / WordPress only
├── Dockerfile          # PHP / WordPress / Vite
└── src/                # Your web files go here
```

The global reverse proxy lives at `~/Dev/.proxy/` and is shared across all projects — it is not tied to any individual project.

## Connecting to the database

Database credentials are auto-generated and stored in `~/Dev/{slug}/.env`.

**PHP with a database** — the PHP container gets them as environment variables; read them in your code instead of hardcoding values:

```php
$pdo = new PDO(
    'mysql:host=' . getenv('DB_HOST') . ';dbname=' . getenv('DB_NAME'),
    getenv('DB_USER'),
    getenv('DB_PASSWORD'),
);
```

**WordPress** — use them when WordPress asks for connection details.

**Standard WordPress** (`wp-config.php`):

```php
define( 'DB_NAME',     'my_project_db' );
define( 'DB_USER',     'my_project_user' );
define( 'DB_PASSWORD', '<value from .env>' );
define( 'DB_HOST',     'db' );  // Docker service name — not localhost
```

**Bedrock** (`src/.env`) — written for you when you choose Bedrock; otherwise set:

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
