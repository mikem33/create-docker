# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Vite container type** — New modern frontend development environment
  - Runs Vite dev server inside Docker with HMR proxy via Traefik
  - Supports React, Vue, Svelte, and other Vite-compatible frameworks
  - Auto-configured for secure HTTPS access via `.test` domain
  - No need to manage Node.js locally — everything runs in containers

- **WP-CLI support** — WordPress containers now include WP-CLI for command-line WordPress management
  - Run WP commands inside the container: `docker compose exec wp wp post list`
  - Useful for scripting WordPress operations and bulk updates

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
