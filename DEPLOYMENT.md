# Lumainus Deployment Guide

Deployment to dev.lumainus.com (production environment, no releases).

## Prerequisites

- Server accessible via `ssh lu`
- Elixir/Erlang installed on server
- Git access configured on server
- PostgreSQL installed on server

## Initial Server Setup (One Time)

### 1. Update Repository URL

Edit `scripts/server_setup.sh` and set your repo URL:
```bash
REPO_URL="git@github.com:YOUR_USERNAME/lumainus.git"
```

### 2. Run Server Setup

From your local machine:
```bash
ssh lu 'bash -s' < scripts/server_setup.sh
```

This will:
- Create `lumainus` user
- Clone repository to `/var/www/lumainus`
- Install PostgreSQL and Postfix
- Create database and user
- Generate environment file
- Install dependencies
- Compile assets
- Run migrations
- Create and start systemd service

### 3. Configure Environment

SSH to server and edit environment:
```bash
ssh lu
sudo nano /var/www/lumainus/.env.prod
```

Update:
```bash
# Generate new secret: mix phx.gen.secret
SECRET_KEY_BASE=your_actual_secret

# Update database password (use ecto:// scheme so Ecto parses it correctly)
DATABASE_URL=ecto://lumainus:STRONG_PASSWORD@localhost/lumainus_prod

# Set correct host
PHX_HOST=dev.lumainus.com
```

### 4. Restart Service

```bash
sudo systemctl restart lumainus
```

### 5. Create Admin Account

```bash
cd /var/www/lumainus
source .env.prod
mix run priv/repo/seeds.exs
```

## Deploying Updates

From your local machine:

```bash
./scripts/deploy.sh
```

This will:
1. Reset the server checkout to `origin/main` (discarding any local-only changes)
2. Install prod dependencies (`MIX_ENV=prod`)
3. Compile assets
4. Run migrations with the environment exported from `.env.prod`
5. Restart the `lumainus` systemd unit and show its status

> **Tip:** The script executes all app commands as the `lumainus` user, so file permissions stay consistent and git never complains about ownership.

## Viewing Logs

```bash
./scripts/logs.sh
```

Or on server:
```bash
ssh lu
sudo journalctl -u lumainus -f
```

## Service Management

### Start/Stop/Restart

```bash
ssh lu
sudo systemctl start lumainus
sudo systemctl stop lumainus
sudo systemctl restart lumainus
```

### Check Status

```bash
ssh lu
sudo systemctl status lumainus
```

### Enable/Disable Auto-start

```bash
ssh lu
sudo systemctl enable lumainus   # Start on boot
sudo systemctl disable lumainus  # Don't start on boot
```

## Database Management

### SSH to Server

```bash
ssh lu
cd /var/www/lumainus
source .env.prod
```

### Run Migrations

```bash
mix ecto.migrate
```

### Rollback Migration

```bash
mix ecto.rollback
```

### Reset Database (DANGER!)

```bash
mix ecto.reset
```

### Database Console

```bash
psql lumainus_prod lumainus
```

## Email Configuration

### Local SMTP (Default)

Uses server's Postfix for sending emails:
```bash
SMTP_RELAY=localhost
SMTP_PORT=25
```

### External SMTP (Optional)

Edit `/var/www/lumainus/.env.prod`:
```bash
SMTP_RELAY=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=your_username
SMTP_PASSWORD=your_password
```

Then restart:
```bash
sudo systemctl restart lumainus
```

## Nginx/Caddy Reverse Proxy (Recommended)

### Caddy (Simplest)

Install Caddy:
```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
```

Create Caddyfile:
```bash
sudo nano /etc/caddy/Caddyfile
```

```
dev.lumainus.com {
    reverse_proxy localhost:4000
}
```

Reload:
```bash
sudo systemctl reload caddy
```

### Nginx

```nginx
server {
    listen 80;
    server_name dev.lumainus.com;

    location / {
        proxy_pass http://localhost:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Troubleshooting

### Service Won't Start

Check logs:
```bash
sudo journalctl -u lumainus -n 100
```

Common issues:
- Database not running: `sudo systemctl start postgresql`
- Port in use: `sudo lsof -i:4000`
- Environment file: Check `/var/www/lumainus/.env.prod`

### Database Connection Errors

```bash
# Check PostgreSQL is running
sudo systemctl status postgresql

# Test connection
psql -U lumainus -d lumainus_prod -h localhost
```

### Assets Not Loading

```bash
cd /var/www/lumainus
source .env.prod
mix assets.deploy
sudo systemctl restart lumainus
```

### Email Not Sending

Check Postfix:
```bash
sudo systemctl status postfix
sudo tail -f /var/log/mail.log
```

## File Locations

```
/var/www/lumainus/              # Application directory
/var/www/lumainus/.env.prod     # Environment variables
/etc/systemd/system/lumainus.service  # Systemd service file
/var/log/syslog                 # General system logs
```

## Quick Commands Reference

| Action | Command |
|--------|---------|
| Deploy updates | `./scripts/deploy.sh` |
| View logs | `./scripts/logs.sh` |
| Restart service | `ssh lu 'sudo systemctl restart lumainus'` |
| Check status | `ssh lu 'sudo systemctl status lumainus'` |
| SSH to server | `ssh lu` |
| Run migrations | `ssh lu 'cd /var/www/lumainus && source .env.prod && mix ecto.migrate'` |

## Security Checklist

- [ ] Strong SECRET_KEY_BASE generated
- [ ] Strong database password set
- [ ] Firewall configured (UFW)
- [ ] SSL/TLS enabled (via Caddy/Nginx)
- [ ] PostgreSQL only listening on localhost
- [ ] Regular backups configured
- [ ] fail2ban installed and configured
