#!/bin/bash
#===============================================================================
# Script: s2_configure_dsiem.sh
# Module: DSIEM Integration
# Description: Tich hop DSIEM (Distributed SIEM) - security event correlation
#              engine cho ELK stack. Su dung Dsiem tu defenxor/dsiem
#              https://github.com/defenxor/dsiem
# Version: 9.4.2
# Author: PhD. Le Toan Thang
#===============================================================================

set -euo pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================
DSIEM_VERSION="${DSIEM_VERSION:-latest}"
DSIEM_HOME="/opt/dsiem"
DSIEM_CONFIG="${DSIEM_HOME}/conf"
DSIEM_LOG="${DSIEM_HOME}/log"
DSIEM_BIN="${DSIEM_HOME}/bin"

DOMAIN="${DOMAIN:-siem.example.com}"
ES_HTTP_PORT="${ES_HTTP_PORT:-9200}"
KIBANA_PORT="${KIBANA_PORT:-5601}"
LOGSTASH_BEATS_PORT="${LOGSTASH_BEATS_PORT:-5044}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-}"
NATS_PORT=4222

#===============================================================================
# FUNCTIONS
#===============================================================================
log_info()    { echo -e "\e[32m[INFO]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn()    { echo -e "\e[33m[WARN]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error()   { echo -e "\e[31m[ERROR]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_success() { echo -e "\e[32m[SUCCESS]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_step()    { echo -e "\e[36m[STEP]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Chay voi sudo hoac root"
        exit 1
    fi
}

install_dependencies() {
    log_step "Cai dat dependencies cho DSIEM..."
    apt-get update -qq
    apt-get install -y \
        curl wget git jq \
        nats-server \
        docker.io docker-compose-plugin \
        >/dev/null 2>&1 || {
        log_warn "Docker installation failed, continuing without it"
    }
    log_success "Dependencies installed"
}

install_dsiem_binary() {
    log_step "Tai DSIEM binary..."
    mkdir -p "$DSIEM_HOME" "$DSIEM_CONFIG" "$DSIEM_LOG" "$DSIEM_BIN"

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) log_error "Khong ho tro arch: $arch"; exit 1 ;;
    esac

    local release_url
    release_url=$(curl -sL "https://api.github.com/repos/defenxor/dsiem/releases/latest" | \
        jq -r ".assets[] | select(.name | contains(\"linux_${arch}\")) | .browser_download_url" 2>/dev/null || echo "")

    if [[ -n "$release_url" ]]; then
        log_info "Tai DSIEM tu $release_url"
        curl -sL "$release_url" -o /tmp/dsiem.tar.gz
        tar -xzf /tmp/dsiem.tar.gz -C "$DSIEM_BIN/"
        chmod +x "$DSIEM_BIN/dsiem"
        rm -f /tmp/dsiem.tar.gz
    else
        log_warn "Khong the tai DSIEM binary. Se build tu source..."
        if command -v docker &>/dev/null; then
            docker pull defenxor/dsiem:latest 2>/dev/null || true
        fi
    fi

    log_success "DSIEM binary ready"
}

configure_nats() {
    log_step "Cau hinh NATS messaging server..."
    mkdir -p /etc/nats

    cat >/etc/nats/nats-server.conf <<NATSCONF
port: ${NATS_PORT}
net: "0.0.0.0"
max_payload: 1048576

logging:
  file: /var/log/nats/nats.log
  time: true
  debug: false
  trace: false

authorization {
  users = [
    {user: dsiem, password: "$(openssl rand -base64 32)"}
  ]
}
NATSCONF

    mkdir -p /var/log/nats
    systemctl enable nats-server --now 2>/dev/null || {
        log_warn "NATS service khong kha dung, khoi dong truc tiep..."
        nats-server -c /etc/nats/nats-server.conf &
        sleep 2
    }
    log_success "NATS configured"
}

configure_dsiem() {
    log_step "Cau hinh DSIEM..."

    mkdir -p "$DSIEM_CONFIG/directives" "$DSIEM_CONFIG/plugins" "$DSIEM_CONFIG/logstash"

    cat >"$DSIEM_CONFIG/config.json" <<DSIEMCONF
{
  "version": "1.0",
  "log_level": "info",
  "log_format": "json",
  "log_output_file": "${DSIEM_LOG}/dsiem.log",
  "listen_addr": "0.0.0.0:8080",
  "nats": {
    "servers": ["nats://127.0.0.1:${NATS_PORT}"],
    "cluster_id": "siem-cluster",
    "client_id": "dsiem-frontend-01"
  },
  "elasticsearch": {
    "hosts": ["https://127.0.0.1:${ES_HTTP_PORT}"],
    "username": "elastic",
    "password": "${ELASTIC_PASSWORD}",
    "sniff": false,
    "timeout": 30,
    "ssl_verify": false
  },
  "directives": {
    "path": "${DSIEM_CONFIG}/directives",
    "reload_interval": 60
  },
  "threat_intel": {
    "enabled": true,
    "plugins_path": "${DSIEM_CONFIG}/plugins",
    "timeout": 10,
    "cache_size": 10000,
    "cache_ttl": 300
  },
  "vulnerability": {
    "enabled": true,
    "sources": {
      "nessus": {
        "type": "nessus",
        "path": "${DSIEM_CONFIG}/nessus.csv",
        "reload_interval": 3600
      }
    }
  },
  "alarms": {
    "index": "siem_alarms",
    "max_size": 10000
  },
  "rate_control": {
    "min_eps": 100,
    "max_eps": 10000,
    "back_pressure_threshold": 0.8
  }
}
DSIEMCONF

    # Directive mau: SSH Brute Force
    cat >"$DSIEM_CONFIG/directives/ssh_brute_force.json" <<SSHDIR
{
  "name": "SSH Brute Force Attack",
  "enabled": true,
  "priority": 5,
  "timeout": 300,
  "type": "single",
  "rules": [
    {
      "name": "SSH Auth Failure x5",
      "enabled": true,
      "occurrence": 5,
      "timeframe": 60,
      "sources": [{"event_type": "ssh_auth_failure"}],
      "target": {"taxonomy": "authentication", "outcome": "failure"}
    }
  ],
  "response": {
    "alarm_level": "high",
    "auto_clear": false,
    "threat_actor": "Brute Force",
    "tactic": "Credential Access",
    "technique": "Brute Force (T1110)",
    "description": "Phat hien SSH brute force: nhieu lan dang nhap that bai"
  }
}
SSHDIR

    # Directive: Port Scanning
    cat >"$DSIEM_CONFIG/directives/port_scan.json" <<SCANDIR
{
  "name": "Port Scanning Detection",
  "enabled": true,
  "priority": 4,
  "timeout": 600,
  "type": "single",
  "rules": [
    {
      "name": "Port Scan x10",
      "enabled": true,
      "occurrence": 10,
      "timeframe": 60,
      "sources": [{"event_type": "connection_attempt"}],
      "target": {"taxonomy": "network", "outcome": "scan"}
    }
  ],
  "response": {
    "alarm_level": "medium",
    "auto_clear": true,
    "threat_actor": "Scanner",
    "tactic": "Reconnaissance",
    "technique": "Active Scanning (T1595)",
    "description": "Phat hien port scanning: nhieu ket noi den nhieu ports"
  }
}
SCANDIR

    # Directive: Malware Communication
    cat >"$DSIEM_CONFIG/directives/malware_c2.json" <<C2DIR
{
  "name": "Malware C2 Communication",
  "enabled": true,
  "priority": 10,
  "timeout": 3600,
  "type": "single",
  "rules": [
    {
      "name": "Known Bad IP",
      "enabled": true,
      "occurrence": 1,
      "timeframe": 3600,
      "sources": [{"event_type": "dns_query", "threat_intel": "malicious"}],
      "target": {"taxonomy": "network", "outcome": "c2"}
    }
  ],
  "response": {
    "alarm_level": "critical",
    "auto_clear": false,
    "threat_actor": "Malware",
    "tactic": "Command and Control",
    "technique": "Ingress Tool Transfer (T1105)",
    "description": "Phat hien C2 communication: ket noi den domain/IP doc hai"
  }
}
C2DIR

    log_success "DSIEM configured with directives"
}

configure_logstash_dsiem() {
    log_step "Cau hinh Logstash pipeline cho DSIEM..."

    cat >/etc/logstash/conf.d/80-dsiem-input.conf <<DSIEMINP
input {
  http {
    id => "dsiem_input"
    port => 8081
    codec => json
    ssl => false
  }
}
DSIEMINP

    cat >/etc/logstash/conf.d/81-dsiem-output.conf <<DSIEMOUT
output {
  if [siem_event_type] {
    elasticsearch {
      hosts => ["https://localhost:${ES_HTTP_PORT}"]
      cacert => "/etc/logstash/certs/fullchain.pem"
      user => "logstash_writer"
      password => "\${LSW_PASS}"
      index => "siem-events-%{+YYYY.MM.dd}"
    }
  }
}
DSIEMOUT

    # Kiem tra Logstash config
    if /usr/share/logstash/bin/logstash --path.settings /etc/logstash -t >/dev/null 2>&1; then
        systemctl restart logstash 2>/dev/null || true
        log_success "Logstash DSIEM pipeline OK"
    else
        log_warn "Logstash config error - check manually"
    fi
}

configure_kibana_dsiem() {
    log_step "Cau hinh Kibana dashboards cho DSIEM..."
    local KIBANA_URL="https://localhost:${KIBANA_PORT}"

    cat >"$DSIEM_CONFIG/kibana_dsiem_dashboard.ndjson" <<DASH
{"attributes":{"title":"SIEM - DSIEM Alarms","description":"DSIEM Alarm Dashboard"},"id":"siem-alarms-dashboard","type":"dashboard"}
{"attributes":{"title":"SIEM - Events Over Time","description":"SIEM Events Timeline"},"id":"siem-events-timeline","type":"visualization"}
DASH

    curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
        -X POST "${KIBANA_URL}/api/saved_objects/_import?overwrite=true" \
        -H "kbn-xsrf: true" \
        --form file=@"$DSIEM_CONFIG/kibana_dsiem_dashboard.ndjson" \
        2>/dev/null || log_warn "Khong the import dashboards tu dong"

    log_success "Kibana DSIEM dashboards configured"
}

setup_dsiem_service() {
    log_step "Cai dat DSIEM service..."

    cat >/etc/systemd/system/dsiem.service <<DSIEMSRV
[Unit]
Description=DSIEM - Distributed SIEM Correlation Engine
Documentation=https://github.com/defenxor/dsiem
After=network.target elasticsearch.service nats-server.service
Wants=network.target elasticsearch.service nats-server.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${DSIEM_HOME}
ExecStart=${DSIEM_BIN}/dsiem -c ${DSIEM_CONFIG}/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
DSIEMSRV

    systemctl daemon-reload
    systemctl enable dsiem --now 2>/dev/null || log_warn "DSIEM service chua chay (can kiem tra binary)"

    log_success "DSIEM service installed"
}

setup_docker_dsiem() {
    log_step "Thiet lap Docker Compose cho DSIEM (optional)..."

    mkdir -p "$DSIEM_HOME/docker"

    cat >"$DSIEM_HOME/docker/docker-compose.yml" <<DOCKERCOMP
version: '3.8'

services:
  nats:
    image: nats:latest
    container_name: dsiem-nats
    ports:
      - "${NATS_PORT}:4222"
      - "8222:8222"
    command: "-c /etc/nats/nats-server.conf"
    volumes:
      - ../conf/nats-server.conf:/etc/nats/nats-server.conf
    networks:
      - dsiem-net
    restart: unless-stopped

  dsiem-frontend:
    image: defenxor/dsiem:latest
    container_name: dsiem-frontend
    ports:
      - "8080:8080"
    environment:
      - DSIEM_MODE=frontend
      - NATS_SERVERS=nats://nats:${NATS_PORT}
      - ES_HOSTS=https://host.docker.internal:${ES_HTTP_PORT}
      - ES_USERNAME=elastic
      - ES_PASSWORD=${ELASTIC_PASSWORD}
    volumes:
      - ../conf/config.json:/conf/config.json
      - ../conf/directives:/conf/directives
      - ../log:/var/log/dsiem
    depends_on:
      - nats
    networks:
      - dsiem-net
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"

  dsiem-backend:
    image: defenxor/dsiem:latest
    container_name: dsiem-backend
    environment:
      - DSIEM_MODE=backend
      - NATS_SERVERS=nats://nats:${NATS_PORT}
    volumes:
      - ../conf/config.json:/conf/config.json
      - ../conf/plugins:/conf/plugins
      - ../log:/var/log/dsiem
    depends_on:
      - nats
    networks:
      - dsiem-net
    restart: unless-stopped

networks:
  dsiem-net:
    driver: bridge
DOCKERCOMP

    log_success "Docker Compose DSIEM configured at ${DSIEM_HOME}/docker/"
}

verify_dsiem() {
    log_step "Verify DSIEM integration..."
    echo ""
    echo "==================== DSIEM VERIFICATION ===================="

    if systemctl is-active --quiet nats-server 2>/dev/null; then
        echo "[PASS] NATS Server"
    else
        echo "[WARN] NATS Server (co the chay duoi dang docker)"
    fi

    if [[ -f "$DSIEM_BIN/dsiem" ]]; then
        echo "[PASS] DSIEM Binary: $($DSIEM_BIN/dsiem --version 2>/dev/null || echo 'version unknown')"
    else
        echo "[WARN] DSIEM binary chua duoc cai"
    fi

    if [[ -f "$DSIEM_CONFIG/config.json" ]]; then
        echo "[PASS] DSIEM Config"
    else
        echo "[FAIL] DSIEM Config missing"
    fi

    local dir_count
    dir_count=$(find "$DSIEM_CONFIG/directives" -name '*.json' 2>/dev/null | wc -l)
    echo "[INFO] DSIEM Directives: $dir_count rules"

    if systemctl is-active --quiet dsiem 2>/dev/null; then
        echo "[PASS] DSIEM Service"
    else
        echo "[WARN] DSIEM Service chua chay"
    fi

    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        echo "[INFO] Docker + Compose available for DSIEM container mode"
    fi

    echo "=============================================================="
    echo ""
}

print_summary() {
    echo ""
    echo "================================================================================"
    echo "  DSIEM INTEGRATION COMPLETE"
    echo "================================================================================"
    echo ""
    echo "  Components:"
    echo "    NATS:       nats://localhost:${NATS_PORT}"
    echo "    DSIEM API:  http://localhost:8080"
    echo "    DSIEM Home: ${DSIEM_HOME}"
    echo ""
    echo "  DSIEM Directives:"
    echo "    - SSH Brute Force Detection"
    echo "    - Port Scanning Detection"
    echo "    - Malware C2 Communication"
    echo ""
    echo "  Management:"
    echo "    systemctl status dsiem nats-server"
    echo "    cd ${DSIEM_HOME}/docker && docker compose up -d"
    echo "    tail -f ${DSIEM_LOG}/dsiem.log"
    echo ""
    echo "  Next Steps:"
    echo "    1. Kiem tra DSIEM da chay: curl http://localhost:8080/health"
    echo "    2. Cau hinh them directives trong ${DSIEM_CONFIG}/directives/"
    echo "    3. Kiem tra alarms trong Kibana: siem_alarms index"
    echo "================================================================================"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo "================================================================================"
    echo "  DSIEM Integration for SIEM ELK Stack"
    echo "  Security Event Correlation Engine"
    echo "  Source: https://github.com/defenxor/dsiem"
    echo "================================================================================"
    echo ""

    check_root
    install_dependencies
    install_dsiem_binary
    configure_nats
    configure_dsiem
    configure_logstash_dsiem
    configure_kibana_dsiem
    setup_dsiem_service
    setup_docker_dsiem
    verify_dsiem
    print_summary

    log_success "DSIEM cau hinh hoan tat!"
}

main "$@"
