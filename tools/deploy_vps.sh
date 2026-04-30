#!/usr/bin/env bash
set -Eeuo pipefail

# Ironclash one-shot VPS deploy/bootstrap script.
# Target OS: Ubuntu/Debian with systemd + apt.
#
# Usage on the VPS from the repo root:
#   sudo bash tools/deploy_vps.sh
#
# Common overrides:
#   DOMAIN=ironclash.xyz EMAIL=egor4042007@gmail.com sudo -E bash tools/deploy_vps.sh
#   APP_DIR=/opt/ironclash SERVER_PORT=9080 sudo -E bash tools/deploy_vps.sh
#   BUILD_GODOT_EXPORT=0 sudo -E bash tools/deploy_vps.sh

DOMAIN="${DOMAIN:-ironclash.xyz}"
EMAIL="${EMAIL:-egor4042007@gmail.com}"
DOMAINS="${DOMAINS:-$DOMAIN}"
APP_DIR="${APP_DIR:-/opt/ironclash}"
RUN_USER="${RUN_USER:-ironclash}"
SERVICE_NAME="${SERVICE_NAME:-ironclash-server}"
SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
SERVER_PORT="${SERVER_PORT:-9080}"
NODE_MAJOR="${NODE_MAJOR:-22}"
ENABLE_SSL="${ENABLE_SSL:-1}"
ENABLE_UFW="${ENABLE_UFW:-0}"
BUILD_GODOT_EXPORT="${BUILD_GODOT_EXPORT:-1}"
INSTALL_GODOT="${INSTALL_GODOT:-1}"
GODOT_VERSION="${GODOT_VERSION:-4.3}"
GODOT_RELEASE="${GODOT_RELEASE:-stable}"
GODOT_BIN="${GODOT_BIN:-}"
if [[ -z "${WS_PUBLIC_URL:-}" ]]; then
	if (( ENABLE_SSL == 1 )); then
		WS_PUBLIC_URL="wss://${DOMAIN}/ws"
	else
		WS_PUBLIC_URL="ws://${DOMAIN}/ws"
	fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
NGINX_SITE="/etc/nginx/sites-available/ironclash.conf"
NGINX_LINK="/etc/nginx/sites-enabled/ironclash.conf"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
GODOT_TEMPLATE_VERSION="${GODOT_VERSION}.${GODOT_RELEASE}"
GODOT_TAG="${GODOT_VERSION}-${GODOT_RELEASE}"

log() {
	printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

on_error() {
	local line="$1"
	echo "ERROR: deploy failed near line $line" >&2
	echo "Try: journalctl -u ${SERVICE_NAME} -n 120 --no-pager" >&2
	echo "Try: nginx -t" >&2
}
trap 'on_error $LINENO' ERR

require_root() {
	if [[ "${EUID}" -ne 0 ]]; then
		die "Run as root: sudo -E bash tools/deploy_vps.sh"
	fi
}

check_repo() {
	[[ -f "$REPO_DIR/server/package.json" ]] || die "Missing server/package.json. Set REPO_DIR or run from repo."
	[[ -f "$REPO_DIR/web/ui/package.json" ]] || die "Missing web/ui/package.json. Set REPO_DIR or run from repo."
	[[ -f "$REPO_DIR/project.godot" ]] || die "Missing project.godot. Set REPO_DIR or run from repo."
}

domain_args() {
	local normalized="${DOMAINS//,/ }"
	local args=()
	for d in $normalized; do
		[[ -n "$d" ]] && args+=("-d" "$d")
	done
	printf '%s\n' "${args[@]}"
}

server_names() {
	local normalized="${DOMAINS//,/ }"
	printf '%s' "$normalized"
}

apt_install_base() {
	log "Installing system packages"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y \
		ca-certificates curl gnupg unzip rsync git build-essential \
		nginx certbot python3-certbot-nginx ufw \
		libfontconfig1 libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libgl1
}

install_node_if_needed() {
	local current_major="0"
	if command -v node >/dev/null 2>&1; then
		current_major="$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)"
	fi
	if [[ "$current_major" =~ ^[0-9]+$ ]] && (( current_major >= NODE_MAJOR )); then
		log "Node $(node --version) is already installed"
		return
	fi

	log "Installing Node.js ${NODE_MAJOR}.x from NodeSource"
	install -d -m 0755 /etc/apt/keyrings
	rm -f /etc/apt/keyrings/nodesource.gpg
	curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
		| gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
	chmod 0644 /etc/apt/keyrings/nodesource.gpg
	cat >/etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main
EOF
	apt-get update
	apt-get install -y nodejs
	log "Installed Node $(node --version), npm $(npm --version)"
}

ensure_user() {
	if id -u "$RUN_USER" >/dev/null 2>&1; then
		return
	fi
	log "Creating system user $RUN_USER"
	useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$RUN_USER"
}

sync_repo() {
	log "Syncing repo to $APP_DIR"
	install -d -m 0755 "$APP_DIR"
	rsync -a --delete \
		--exclude '.git/' \
		--exclude '.godot/' \
		--exclude '.claude/' \
		--exclude 'node_modules/' \
		--exclude 'server/node_modules/' \
		--exclude 'web/ui/node_modules/' \
		--exclude 'web/ui/dist/' \
		--exclude '*.log' \
		--exclude '*.zip' \
		--exclude '*.7z' \
		"$REPO_DIR/" "$APP_DIR/"
	chown -R root:root "$APP_DIR"
	find "$APP_DIR" -type d -exec chmod 0755 {} +
}

patch_network_config() {
	local cfg="$APP_DIR/assets/data/network/default_network_config.tres"
	[[ -f "$cfg" ]] || die "Missing network config at $cfg"
	log "Setting Godot client websocket URL to $WS_PUBLIC_URL"
	sed -i -E "s#client_url = \".*\"#client_url = \"$WS_PUBLIC_URL\"#" "$cfg"
	sed -i -E "s#server_port = [0-9]+#server_port = $SERVER_PORT#" "$cfg"
}

install_godot_if_needed() {
	if [[ -n "$GODOT_BIN" && -x "$GODOT_BIN" ]]; then
		log "Using GODOT_BIN=$GODOT_BIN"
	else
		if command -v godot >/dev/null 2>&1 && godot --version 2>/dev/null | grep -q "^${GODOT_VERSION}"; then
			GODOT_BIN="$(command -v godot)"
			log "Using existing Godot at $GODOT_BIN"
		elif (( INSTALL_GODOT == 1 )); then
			log "Installing Godot ${GODOT_TAG} CLI"
			local tmp
			tmp="$(mktemp -d)"
			curl -fL "https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/Godot_v${GODOT_TAG}_linux.x86_64.zip" \
				-o "$tmp/godot.zip"
			unzip -q "$tmp/godot.zip" -d "$tmp"
			install -m 0755 "$tmp/Godot_v${GODOT_TAG}_linux.x86_64" /usr/local/bin/godot
			GODOT_BIN="/usr/local/bin/godot"
			rm -rf "$tmp"
		else
			die "Godot not found. Set GODOT_BIN=/path/to/godot or INSTALL_GODOT=1."
		fi
	fi

	local templates_dir="/root/.local/share/godot/export_templates/${GODOT_TEMPLATE_VERSION}"
	if [[ -f "$templates_dir/web_release.zip" ]]; then
		log "Godot export templates already installed at $templates_dir"
		return
	fi
	if (( INSTALL_GODOT != 1 )); then
		die "Godot export templates missing at $templates_dir. Set INSTALL_GODOT=1."
	fi

	log "Installing Godot ${GODOT_TAG} export templates"
	local tmp
	tmp="$(mktemp -d)"
	curl -fL "https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/Godot_v${GODOT_TAG}_export_templates.tpz" \
		-o "$tmp/templates.tpz"
	unzip -q "$tmp/templates.tpz" -d "$tmp"
	install -d -m 0755 "$templates_dir"
	cp -a "$tmp/templates/." "$templates_dir/"
	rm -rf "$tmp"
}

build_godot_export() {
	if (( BUILD_GODOT_EXPORT != 1 )); then
		log "Skipping Godot export because BUILD_GODOT_EXPORT=0"
		return
	fi
	install_godot_if_needed
	log "Building Godot Web export"
	install -d -m 0755 "$APP_DIR/web/godot-export"
	"$GODOT_BIN" --headless --path "$APP_DIR" --export-release Web "$APP_DIR/web/godot-export/Ironclash4.3.html"
}

install_node_deps_and_build_ui() {
	log "Installing server npm dependencies"
	(cd "$APP_DIR/server" && npm ci)

	log "Installing UI npm dependencies"
	(cd "$APP_DIR/web/ui" && npm ci)

	log "Building React UI"
	(cd "$APP_DIR/web/ui" && npm run build)
}

ensure_godot_export_exists() {
	local pck_count
	pck_count="$(find "$APP_DIR/web/godot-export" -maxdepth 1 -type f -name '*.pck' 2>/dev/null | wc -l)"
	[[ "$pck_count" -gt 0 ]] || die "No .pck found in $APP_DIR/web/godot-export. Run Godot Web export or keep BUILD_GODOT_EXPORT=1."
}

generate_godot_manifest() {
	log "Generating /godot/_manifest.json"
	local godot_dir="$APP_DIR/web/godot-export"
	local pck base html out
	pck="$(find "$godot_dir" -maxdepth 1 -type f -name '*.pck' | head -n 1)"
	[[ -n "$pck" ]] || die "Cannot generate manifest: no .pck in $godot_dir"
	base="$(basename "$pck" .pck)"
	html="$godot_dir/${base}.html"
	out="$godot_dir/_manifest.json"
	MANIFEST_BASE="$base" MANIFEST_HTML="$html" MANIFEST_OUT="$out" node --input-type=module <<'NODE'
import fs from "node:fs";

const base = process.env.MANIFEST_BASE;
const htmlPath = process.env.MANIFEST_HTML;
const out = process.env.MANIFEST_OUT;
let godotConfig = null;

if (htmlPath && fs.existsSync(htmlPath)) {
	const html = fs.readFileSync(htmlPath, "utf8");
	const match = /const\s+GODOT_CONFIG\s*=\s*(\{[^;]*?\})\s*;/m.exec(html);
	if (match) {
		try {
			godotConfig = JSON.parse(match[1]);
		} catch (err) {
			console.warn("[manifest] Failed to parse GODOT_CONFIG:", err);
		}
	}
}

fs.writeFileSync(out, JSON.stringify({ base, godotConfig }, null, 2) + "\n");
NODE
}

write_systemd_service() {
	log "Writing systemd service $SERVICE_NAME"
	cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Ironclash authoritative WebSocket server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${APP_DIR}/server
Environment=NODE_ENV=production
Environment=IRONCLASH_HOST=${SERVER_HOST}
Environment=IRONCLASH_PORT=${SERVER_PORT}
ExecStart=/bin/bash -lc 'exec ./node_modules/.bin/tsx src/index.ts'
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable "$SERVICE_NAME"
	systemctl restart "$SERVICE_NAME"
	sleep 1
	systemctl is-active --quiet "$SERVICE_NAME" || {
		journalctl -u "$SERVICE_NAME" -n 120 --no-pager >&2 || true
		die "$SERVICE_NAME failed to start"
	}
}

nginx_locations() {
	cat <<EOF
	root ${APP_DIR}/web/ui/dist;
	index index.html;
	client_max_body_size 256m;

	add_header Cross-Origin-Opener-Policy "same-origin" always;
	add_header Cross-Origin-Embedder-Policy "require-corp" always;
	add_header Cross-Origin-Resource-Policy "cross-origin" always;

	location /ws {
		proxy_pass http://${SERVER_HOST}:${SERVER_PORT};
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection \$connection_upgrade;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
		proxy_read_timeout 3600s;
		proxy_send_timeout 3600s;
		proxy_buffering off;
	}

	location /godot/ {
		alias ${APP_DIR}/web/godot-export/;
		default_type application/octet-stream;
		types {
			text/html html;
			application/javascript js;
			application/wasm wasm;
			application/octet-stream pck;
			image/png png;
			image/jpeg jpg jpeg;
			text/plain txt;
		}
		add_header Cross-Origin-Opener-Policy "same-origin" always;
		add_header Cross-Origin-Embedder-Policy "require-corp" always;
		add_header Cross-Origin-Resource-Policy "cross-origin" always;
		add_header Cache-Control "no-store, max-age=0" always;
	}

	location ^~ /.well-known/acme-challenge/ {
		root ${APP_DIR}/web/ui/dist;
		default_type "text/plain";
	}

	location / {
		try_files \$uri \$uri/ /index.html;
	}
EOF
}

write_nginx_config() {
	local ssl_enabled="$1"
	local names
	names="$(server_names)"
	log "Writing nginx config (ssl=${ssl_enabled})"
	cat >"$NGINX_SITE" <<EOF
map \$http_upgrade \$connection_upgrade {
	default upgrade;
	'' close;
}

EOF
	if [[ "$ssl_enabled" == "1" ]]; then
		cat >>"$NGINX_SITE" <<EOF
server {
	listen 80;
	listen [::]:80;
	server_name ${names};

	location ^~ /.well-known/acme-challenge/ {
		root ${APP_DIR}/web/ui/dist;
		default_type "text/plain";
	}

	location / {
		return 301 https://\$host\$request_uri;
	}
}

server {
	listen 443 ssl http2;
	listen [::]:443 ssl http2;
	server_name ${names};

	ssl_certificate ${CERT_DIR}/fullchain.pem;
	ssl_certificate_key ${CERT_DIR}/privkey.pem;
	ssl_trusted_certificate ${CERT_DIR}/chain.pem;
	ssl_session_cache shared:ironclash_ssl:10m;
	ssl_session_timeout 1d;
	ssl_session_tickets off;

EOF
		nginx_locations >>"$NGINX_SITE"
		cat >>"$NGINX_SITE" <<EOF
}
EOF
	else
		cat >>"$NGINX_SITE" <<EOF
server {
	listen 80;
	listen [::]:80;
	server_name ${names};

EOF
		nginx_locations >>"$NGINX_SITE"
		cat >>"$NGINX_SITE" <<EOF
}
EOF
	fi

	ln -sfn "$NGINX_SITE" "$NGINX_LINK"
	rm -f /etc/nginx/sites-enabled/default
	nginx -t
	systemctl enable nginx
	systemctl reload nginx || systemctl restart nginx
}

configure_ssl() {
	if (( ENABLE_SSL != 1 )); then
		write_nginx_config 0
		return
	fi

	if [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
		write_nginx_config 0
		log "Requesting Let's Encrypt certificate for $(server_names)"
		local args=()
		mapfile -t args < <(domain_args)
		certbot certonly --webroot \
			-w "$APP_DIR/web/ui/dist" \
			--email "$EMAIL" \
			--agree-tos \
			--non-interactive \
			--keep-until-expiring \
			--expand \
			"${args[@]}"
	fi

	[[ -f "${CERT_DIR}/fullchain.pem" ]] || die "SSL certificate was not created at ${CERT_DIR}"
	write_nginx_config 1
	systemctl enable certbot.timer >/dev/null 2>&1 || true
	systemctl start certbot.timer >/dev/null 2>&1 || true
}

configure_firewall() {
	if ! command -v ufw >/dev/null 2>&1; then
		return
	fi
	log "Configuring UFW rules"
	ufw allow OpenSSH >/dev/null || true
	ufw allow 'Nginx Full' >/dev/null || true
	if (( ENABLE_UFW == 1 )); then
		ufw --force enable >/dev/null
	else
		if ufw status | grep -q "Status: active"; then
			log "UFW is active; rules were updated"
		else
			log "UFW is installed but inactive. Set ENABLE_UFW=1 to enable it."
		fi
	fi
}

verify_deploy() {
	log "Verifying deployment"
	systemctl is-active --quiet "$SERVICE_NAME" || die "$SERVICE_NAME is not active"
	nginx -t
	if (( ENABLE_SSL == 1 )); then
		curl -fsS --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/godot/_manifest.json" >/dev/null
	else
		curl -fsS -H "Host: $DOMAIN" "http://127.0.0.1/godot/_manifest.json" >/dev/null
	fi

	(cd "$APP_DIR/server" && SERVER_HOST_NODE="$SERVER_HOST" SERVER_PORT_NODE="$SERVER_PORT" node --input-type=module <<'NODE'
import fs from "node:fs";
import { WebSocket } from "ws";
const shared = fs.readFileSync("../shared/protocol.ts", "utf8");
const match = shared.match(/export\s+const\s+PROTOCOL_VERSION\s*=\s*["']([^"']+)["']/);
const expected = match?.[1];
if (!expected) {
	console.error("Could not read PROTOCOL_VERSION from shared/protocol.ts");
	process.exit(1);
}
const host = process.env.SERVER_HOST_NODE;
const port = process.env.SERVER_PORT_NODE;
const ws = new WebSocket(`ws://${host}:${port}`);
const timer = setTimeout(() => {
	console.error("websocket smoke test timed out");
	process.exit(1);
}, 5000);
ws.once("open", () => {
	ws.send(JSON.stringify({
		t: "hello",
		client_version: "deploy-smoke",
		protocol_version: expected,
	}));
});
ws.on("message", (data) => {
	let msg;
	try {
		msg = JSON.parse(data.toString());
	} catch {
		return;
	}
	if (msg.t === "welcome") {
		clearTimeout(timer);
		if (msg.protocol_version !== expected) {
			console.error("protocol mismatch after deploy: expected=" + expected + " server=" + msg.protocol_version);
			ws.close();
			process.exit(1);
		}
		ws.close();
		process.exit(0);
	}
	if (msg.t === "kicked") {
		clearTimeout(timer);
		console.error("server kicked deploy smoke client: " + msg.reason);
		ws.close();
		process.exit(1);
	}
});
ws.once("error", (err) => {
	clearTimeout(timer);
	console.error(err);
	process.exit(1);
});
NODE
	)
	log "OK: https://${DOMAIN}/ -> UI, https://${DOMAIN}/godot/ -> Godot export, wss://${DOMAIN}/ws -> game server"
}

main() {
	require_root
	check_repo
	apt_install_base
	install_node_if_needed
	ensure_user
	sync_repo
	patch_network_config
	build_godot_export
	ensure_godot_export_exists
	generate_godot_manifest
	install_node_deps_and_build_ui
	write_systemd_service
	configure_ssl
	configure_firewall
	verify_deploy
	log "Done"
}

main "$@"
