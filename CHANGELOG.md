# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Remote DB** — a fourth container type: phpMyAdmin for a MySQL server on another machine,
  through an SSH tunnel; served at `https://{slug}.test` and managed with `start-docker` /
  `stop-docker` / `delete-docker` like any project
  - A `tunnel` container (alpine + openssh-client, built locally) keeps `ssh -N -L` open to the
    server's `127.0.0.1`; nothing new is exposed on the server
  - Authenticates with a key file without passphrase (mounted alone, read-only) or with the SSH
    agent in `SSH_AUTH_SOCK`; both mounts use `create_host_path: false`, and a missing
    `SSH_AUTH_SOCK` stops `start-docker` with a clear message
  - The server's host key is pinned in the project's own `known_hosts`, copied from
    `~/.ssh/known_hosts` or scanned and confirmed at creation
  - Optional TLS to MySQL for servers with `require_secure_transport=ON`
  - Both containers use `restart: "no"`, so nothing starts on boot

- **Optional Composer** — PHP and WordPress projects (Apache and Nginx + FPM) can include
  Composer 2 in the PHP container; `create-docker` asks `Install Composer? [y/N]`
  - Copied from the official `composer:2` image, with `git` and `unzip` for source and dist
    packages; nothing needs to be installed on the host
  - `COMPOSER_HOME` is `/var/www/.composer`, owned by `www-data`, so the cache is writable and
    files Composer creates are owned by the host user
  - A `composer` wrapper on the host PATH runs it in the right container and mirrors your
    location under `src/`, like the `wp` wrapper
  - Declining leaves the generated `Dockerfile` byte-for-byte unchanged

- **Bedrock-ready WordPress** — WordPress projects (Apache and Nginx + FPM) can be prepared for
  Bedrock; `create-docker` asks `Use Bedrock? [y/N]` before the Composer question
  - Composer is included automatically, since Bedrock is installed with it
  - The site is served from `src/web/` (`DocumentRoot` on Apache, `root` on Nginx), keeping
    `.env`, `config/` and `vendor/` out of the document root
  - `src/.env` is written with the project's database credentials, `DB_HOST='db'`,
    `WP_HOME=https://{slug}.test`, `WP_SITEURL` ending in `/wp`, and random keys and salts
  - Bedrock is not installed: a welcome page in `src/web/` shows a command that runs
    `composer create-project` in `/tmp` and copies the result into `src/`, because
    create-project refuses a non-empty directory; the prepared `.env` survives
  - Declining leaves every generated file byte-for-byte unchanged

### Changed
- **Bedrock install docs** — `_docs/containers.md` no longer tells you to run Composer on the
  host and fill in `src/.env` by hand

### Fixed
- **Welcome page links** — the WordPress welcome page linked phpMyAdmin and MailHog to
  `{slug}.test-db.test` and `{slug}.test-mail.test`, built from the full host name; they now
  point at `{slug}-db.test` and `{slug}-mail.test`
- **WordPress on Nginx: download command** — the welcome page ran the WordPress download in
  `{slug}-web`, which is `nginx:alpine` with `src/` mounted read-only, so `tar` failed on every
  file. It now runs in `{slug}-php`
- **WordPress on Nginx: uploads over 1 MB** — Nginx's default `client_max_body_size` of 1M
  rejected larger media uploads with 413 before PHP saw them. It is now 64M, matching PHP's
  `upload_max_filesize`
- **WordPress mail never reached MailHog** — `sendmail_path` passed `--smtp-addr mailhog:1025`,
  but mhsendmail only accepts `--smtp-addr=mailhog:1025`; with the space it exited with "flag
  needs an argument" and `mail()` / `wp_mail()` returned false on both web servers. The value is
  now written with `=`, and quoted, since an unquoted `=` is a syntax error in `php.ini`.
  Existing projects need the same change in their `Dockerfile` and a rebuild
- **Apache: directory redirects to :8080** — on Apache projects (PHP and WordPress), a directory
  without its trailing slash, such as `/wp-admin`, redirected to
  `http://{slug}.test:8080/wp-admin/`: Apache built the URL from the plain-HTTP hop it gets from
  Traefik on port 8080. The vhost now has `ServerName https://${APACHE_SERVER_NAME}` and
  `UseCanonicalName On`, with `APACHE_SERVER_NAME={slug}.test` set in `docker-compose.yml`, so
  the redirect goes to `https://{slug}.test/wp-admin/`. Existing projects need both changes
  (the `RUN sed` line in their `Dockerfile` and the variable in `docker-compose.yml`) and a rebuild
- **Nginx: redirects to http://** — Nginx's own redirects were absolute `http://` URLs, since it
  only sees Traefik's plain-HTTP hop; Traefik then bounced them back to https. The PHP,
  WordPress and Vite Nginx configs now set `absolute_redirect off`, so redirects stay relative
  and the browser keeps `https://{slug}.test`

## [1.1.0] - 2026-09-23

### Added
- **Vite container type** — New modern frontend development environment
  - Runs Vite dev server inside Docker with HMR proxy via Traefik
  - Supports React, Vue, Svelte, and other Vite-compatible frameworks
  - Auto-configured for secure HTTPS access via `.test` domain
  - No need to manage Node.js locally — everything runs in containers

- **WP-CLI support** — WordPress containers now include WP-CLI for command-line WordPress management
  - A `wp` wrapper on the host PATH runs it in the right container, so `wp plugin list` works
    from a project directory as if WordPress were installed locally
  - Finds the project by walking up from the working directory and mirrors your location, so
    running it under `src/` puts WP-CLI in the matching directory inside the container
  - `docker exec {slug}-web wp ...` (or `{slug}-php` on the Nginx variant) still works directly

- **PHPMyAdmin upload limit configuration** — Added `UPLOAD_LIMIT` parameter for phpMyAdmin
  - Configurable database dump file size limits
  - Easier import of large database backups

### Changed
- **Improved file permissions** — Container UID/GID now match the host user by default
  - No more permission issues when editing files created inside containers
  - Files created by containers are immediately editable on the host

- **Apache port changed to 8080** — Better separation between Traefik (443) and app containers
  - Reduced port conflicts on development machines
  - Cleaner network architecture

- **Vite dev server now runs inside Docker** — Previously proxied from host process
  - More consistent environment between development and production
  - Eliminates node_modules conflicts between host and container
  - Faster, more reliable builds

- **pnpm cache isolation** — Uses named Docker volume for pnpm cache
  - Prevents cache conflicts between projects
  - Cleaner project deletion (cache removed with named volume)

### Fixed
- **Redirect loop on `/wp-admin/`** — Traefik terminates TLS and forwards plain HTTP, so PHP saw
  no `HTTPS` and WordPress judged the request insecure. With `siteurl` on `https://` it redirected
  to itself indefinitely (`NS_ERROR_REDIRECT_LOOP`). The PHP images now translate Traefik's
  `X-Forwarded-Proto` into `HTTPS=on` — via `SetEnvIf` on Apache, a `fastcgi_param` on Nginx —
  so PHP sees the browser's original scheme
- **`wp db` commands unusable** — WP-CLI shells out to the MySQL client, which the WordPress
  images did not carry, so `wp db export`, `import`, `check` and `cli` failed on a missing
  binary. Debian's client is MariaDB's and verifies the server certificate, which MySQL 8
  self-signs; since WP-CLI invokes it with `--no-defaults`, no config file can opt out, so the
  images add the client plus PATH shims that pass `--ssl-verify-server-cert=0`
- **WP-CLI cache directory** — WP-CLI keeps its download cache in `$HOME/.wp-cli`, and
  `www-data`'s home is `/var/www`, owned by root. Every core or plugin fetch warned
  `Failed to create directory '/var/www/.wp-cli/cache/'` and re-downloaded from scratch. The
  image now creates the directory owned by `www-data`
- **MySQL user name length** — A project slug long enough to push `{slug}_user` past MySQL's
  32-character cap made the image's entrypoint abort on `CREATE USER`. The container then
  restarted onto an already initialized data directory and reported healthy with no application
  user, surfacing only as `dependency failed to start: container {slug}-db is unhealthy`.
  Long names now shed trailing words until they fit
- Docker gateway IP detection — Uses Docker gateway instead of desktop URL for better compatibility
- Host entry matching — Fixed hostname resolution for `.test` domains
- Project folder creation — Ensured `src` folder is properly created for Vite projects
- VITE environment variable detection — Correctly identifies Vite project type

### Infrastructure
- **Script reorganization** — All scripts moved to `scripts/` directory for better organization
  - `create-docker.sh` — Create new projects
  - `delete-docker.sh` — Remove projects completely
  - `start-docker.sh` — Start stopped projects
  - `stop-docker.sh` — Stop running projects without deletion
  - `wp.sh` — Run WP-CLI against the enclosing project (symlink as `wp`)

### Documentation
- Updated feature list to include Vite container type
- Added Vite container type documentation
- Container reference guide remains in `_docs/containers.md`

## [1.0.0] - Initial release

### Added
- **create-docker** CLI tool for spinning up local web development environments
- Three container types: HTML (Nginx), PHP 8.3 (Apache/Nginx), WordPress (PHP + MySQL + phpMyAdmin + MailHog)
- Automatic HTTPS with mkcert for trusted local certificates
- Custom `.test` domains for all projects
- Shared Traefik reverse proxy for routing multiple projects
- Auto-generated Docker Compose files with sensible defaults
- Database credentials auto-generation for secure setups
- Project lifecycle management (create, delete, start, stop)
- Comprehensive documentation and architecture overview
- Security hardening with isolated database networks
