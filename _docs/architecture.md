# Architecture overview

This document explains the internal mechanics of `create-docker`: how the pieces fit together and why they are designed the way they are.

## The port 443 problem

HTTPS uses port 443. A port can only be bound by one process at a time. If you start two containers that both try to bind to port 443 on your machine, the second one will fail.

The naive solution — running each project on a different port — works but is ugly: you end up with URLs like `https://project1.test:4430` and `https://project2.test:4431`.

The real solution is a **reverse proxy**.

## Traefik as a global reverse proxy

Traefik is a container that:

1. Binds to ports 80 and 443 on your machine
2. Watches Docker for new containers via the Docker API
3. Reads labels on those containers to learn their hostname routing rules
4. Forwards each incoming request to the right container based on the `Host` header

```
Browser
  │
  │  https://project-a.test        https://project-b.test
  │
  ▼
Traefik (port 443)
  ├── project-a.test  →  project-a-web container
  └── project-b.test  →  project-b-web container
```

Traefik runs in `~/Dev/.proxy/` and starts automatically on first `create-docker` run. It is shared across all projects and only needs to run once.

### Docker socket access

Traefik discovers containers by reading from `/var/run/docker.sock`. It is mounted **read-only** (`ro`) inside the Traefik container to limit its access to the Docker API.

### Opting in with labels

By default, Traefik ignores all containers (`exposedByDefault: false` in `traefik.yml`). A container is only exposed when it has the label:

```yaml
traefik.enable=true
```

Each project container also carries labels that tell Traefik which hostname to route to it and on which entrypoint (HTTP or HTTPS):

```yaml
- "traefik.enable=true"
- "traefik.http.routers.my-project.rule=Host(`my-project.test`)"
- "traefik.http.routers.my-project.entrypoints=websecure"
- "traefik.http.routers.my-project.tls=true"
- "traefik.http.services.my-project.loadbalancer.server.port=80"
```

The last label is necessary because the container itself still uses port 80 internally — Traefik handles the TLS termination and forwards plain HTTP traffic to the container.

## mkcert and trusted TLS certificates

By default, browsers reject self-signed certificates with a security warning. `mkcert` solves this by:

1. Creating a private **local Certificate Authority (CA)** on your machine
2. Registering that CA in the system's trusted certificate store (so the OS and browsers trust it)
3. Generating certificates signed by that CA — which browsers therefore trust without warnings

`create-docker` runs `mkcert -install` once to register the CA, then generates a **per-project certificate** for each new project:

```bash
mkcert -cert-file my-project.pem -key-file my-project-key.pem \
    "my-project.test" "my-project-db.test" "my-project-mail.test"
```

Each certificate lists only the exact hostnames for that project as Subject Alternative Names (SANs). Wildcard certificates like `*.test` are rejected by modern TLS stacks (OpenSSL, BoringSSL/Chrome) for two-label domains — a wildcard would effectively cover the entire `.test` TLD, which is not permitted.

Certificates are stored at `~/Dev/.proxy/certs/` and mounted read-only into the Traefik container. A companion config file is written to `~/Dev/.proxy/conf/<project>.yml`:

```yaml
tls:
  certificates:
    - certFile: /certs/my-project.pem
      keyFile: /certs/my-project-key.pem
```

Traefik's file provider watches the `conf/` directory (`watch: true`) and picks up new certificates automatically — no restart needed.

### Chrome 120+ on Linux

Chrome 120+ uses its own built-in root store instead of the system NSS database, so `mkcert -install` alone is not enough to trust the CA in Chrome. During the first-run setup, `create-docker` writes a machine-level enterprise policy that instructs Chrome to trust the mkcert CA:

```
/etc/opt/chrome/policies/managed/mkcert-trust.json
```

This requires `sudo` and is a one-time operation. Chrome reads this file at startup and trusts all certificates signed by the mkcert CA. Restart Chrome after running `setup_proxy()` for the first time.

## Docker networks

Each WordPress project uses **two Docker networks**:

```
┌─────────────────────────────────┐
│  proxy  (external, shared)      │
│                                 │
│  traefik ◄──── web              │
│                │                │
└────────────────│────────────────┘
                 │
┌────────────────▼────────────────┐
│  internal  (project-scoped)     │
│                                 │
│  web ◄───── db                  │
│  web ◄───── phpmyadmin          │
│  web ◄───── mailhog             │
│  phpmyadmin ◄── db              │
└─────────────────────────────────┘
```

**`proxy`** is a single external network created once. Traefik and all project web/service containers that need to receive public traffic connect to it.

**`internal`** is a per-project bridge network. The database container only joins `internal` — it is never reachable from the `proxy` network or from other projects. This means the MySQL port is not exposed on your host machine and is not accessible by Traefik or by any container from another project.

HTML and PHP projects use only the `proxy` network since they have no database.

## /etc/hosts

Browsers resolve `my-project.test` using DNS. There is no public DNS record for `.test` domains, so the script adds a line to `/etc/hosts` that maps each project domain to `127.0.0.1` (localhost):

```
127.0.0.1 my-project.test
127.0.0.1 my-project-db.test
127.0.0.1 my-project-mail.test
```

This requires `sudo` because `/etc/hosts` is a system file. The script adds only the specific entries needed for each project and never removes or modifies existing entries.

## First-run flow

```
create-docker
     │
     ├─ check_dependencies()
     │     └─ docker, docker compose, mkcert — exit if missing
     │
     ├─ Interactive prompts (slug, type, confirm)
     │
     ├─ setup_proxy()
     │     ├─ Already running?  → skip
     │     ├─ Config exists?    → docker compose up -d
     │     └─ First run:
     │           ├─ mkcert -install  (NSS, Firefox)
     │           ├─ write Chrome enterprise policy  (requires sudo)
     │           ├─ docker network create proxy
     │           ├─ write traefik.yml  (file provider → conf/)
     │           ├─ write docker-compose.yml
     │           └─ docker compose up -d
     │
     ├─ create_{html|php|wordpress}()
     │     └─ write docker-compose.yml, Dockerfile, .env, .gitignore, starter file
     │
     ├─ generate_project_cert()
     │     ├─ mkcert <slug>.test [<slug>-db.test <slug>-mail.test]  → certs/
     │     └─ write conf/<slug>.yml  (Traefik picks up automatically)
     │
     ├─ add_hosts_entry() × 1–3  (requires sudo)
     │
     └─ docker compose up -d --build  (optional)
```

## Project folder structure

By default everything lives under `~/Dev/`. Override with the `CREATE_DOCKER_DIR` environment variable:

```bash
export CREATE_DOCKER_DIR=~/projects  # add to ~/.bashrc or equivalent
```

```
$CREATE_DOCKER_DIR/   # ~/Dev/ by default
├── .proxy/                     # Global — shared by all projects
│   ├── docker-compose.yml
│   ├── traefik.yml
│   ├── certs/                  # Per-project TLS certificates
│   │   ├── my-project.pem
│   │   ├── my-project-key.pem
│   │   └── ...                 # One pair per project
│   └── conf/                   # Per-project Traefik dynamic configs
│       ├── my-project.yml      # Tells Traefik which cert to use
│       └── ...
│
├── my-html-project/
│   ├── docker-compose.yml
│   └── src/                    # Web root
│
├── my-php-project/
│   ├── docker-compose.yml
│   ├── Dockerfile
│   ├── .gitignore
│   └── src/                    # Web root
│
└── my-wp-project/
    ├── docker-compose.yml
    ├── Dockerfile
    ├── .env                    # DB credentials (gitignored)
    ├── .gitignore
    └── src/                    # Web root — place WordPress files here
```
