#!/bin/bash
#===============================================================================
# Script: s1_install_elk_siem.sh
# Module: Main Installer
# Description: Cài đặt SIEM ELK Stack 9.4.2 (Elasticsearch, Logstash, Kibana,
#              Filebeat, Metricbeat, Auditbeat, Packetbeat, Heartbeat, APM Server)
#              tren Ubuntu 24.04 LTS - Mo hinh StandAlone All-in-one
#              Kem SSL/TLS Certbot cho HTTPS domain
# Version: 9.4.2
# Author: PhD. Le Toan Thang
# Ref: https://github.com/PhDLeToanThang/siem
#      https://github.com/PhDLeToanThang/automation/issues/30
#      https://github.com/PhDLeToanThang/pentesting_it-audit/issues/8
#===============================================================================

set -euo pipefail

#===============================================================================
# CONFIGURATION - CHINH SUA THEO MOI TRUONG
#===============================================================================
DOMAIN="${DOMAIN:-siem.example.com}"
EMAIL="${EMAIL:-admin@example.com}"
ELASTIC_VERSION="${ELASTIC_VERSION:-9.4.2}"
ELASTIC_MAJOR="${ELASTIC_VERSION%%.*}"
SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}')}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:-}"
LOGSTASH_PASSWORD="${LOGSTASH_PASSWORD:-}"
BEATS_PASSWORD="${BEATS_PASSWORD:-}"
APM_PASSWORD="${APM_PASSWORD:-}"

ES_HTTP_PORT=9200
ES_TRANSPORT_PORT=9300
KIBANA_PORT=5601
LOGSTASH_BEATS_PORT=5044
APM_SERVER_PORT=8200
CERT_PATH="/etc/elasticsearch/certs"
LOG_DIR="/var/log/siem"
BACKUP_DIR="/var/backups/siem"

#===============================================================================
# FUNCTIONS
#===============================================================================
log_info()    { echo -e "\e[32m[INFO]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn()    { echo -e "\e[33m[WARN]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error()   { echo -e "\e[31m[ERROR]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_success() { echo -e "\e[32m[SUCCESS]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_step()    { echo -e "\e[36m[STEP]\e[0m $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

pre_flight_checks() {
    log_step "Pre-flight checks..."
    if [[ $EUID -ne 0 ]]; then
        log_error "Chay script voi sudo hoac root"
        exit 1
    fi
    if [[ ! -f /etc/os-release ]] || ! grep -qi "ubuntu" /etc/os-release; then
        log_error "Chi ho tro Ubuntu"
        exit 1
    fi
    UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "unknown")
    if [[ "$UBUNTU_VER" != "24.04" ]]; then
        log_warn "Ubuntu $UBUNTU_VER phat hien. Khuyen nghi Ubuntu 24.04 LTS"
    fi
    RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $RAM_GB -lt 4 ]]; then
        log_error "Toi thieu 4GB RAM. Hien tai: ${RAM_GB}GB"
        exit 1
    fi
    DISK_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ $DISK_GB -lt 20 ]]; then
        log_error "Toi thieu 20GB trong. Hien tai: ${DISK_GB}GB"
        exit 1
    fi
    hash dig 2>/dev/null || apt-get install -y dnsutils >/dev/null 2>&1
    if ! dig +short "$DOMAIN" 2>/dev/null | grep -q "$SERVER_IP"; then
        log_warn "Domain $DOMAIN chua tro ve IP $SERVER_IP - Certbot co the fail"
    fi
    log_success "Pre-flight checks passed"
}

prepare_system() {
    log_step "Chuan bi he thong..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y \
        curl wget gnupg2 apt-transport-https \
        openssl ca-certificates \
        openjdk-21-jdk-headless \
        certbot python3-certbot-nginx \
        nginx ufw jq net-tools \
        dnsutils software-properties-common \
        tree unzip zip git \
        >/dev/null 2>&1
    java -version 2>&1 | head -1 || log_warn "Java chua duoc cai dat dung cach"
    systemctl stop nginx 2>/dev/null || true
    log_success "System prepared"
}

setup_firewall() {
    log_step "Cau hinh UFW firewall..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP-Certbot'
    ufw allow 443/tcp comment 'HTTPS-Kibana'
    ufw allow "$ES_HTTP_PORT"/tcp comment 'Elasticsearch-HTTP'
    ufw allow "$ES_TRANSPORT_PORT"/tcp comment 'Elasticsearch-Transport'
    ufw allow "$KIBANA_PORT"/tcp comment 'Kibana'
    ufw allow "$APM_SERVER_PORT"/tcp comment 'APM-Server'
    ufw --force enable
    ufw status verbose
    log_success "Firewall configured"
}

add_elastic_repo() {
    log_step "Them Elastic $ELASTIC_MAJOR.x repository..."
    curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
        gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/${ELASTIC_MAJOR}.x/apt stable main" | \
        tee /etc/apt/sources.list.d/elastic-${ELASTIC_MAJOR}.x.list >/dev/null
    apt-get update -qq
    log_success "Elastic repository added"
}

configure_limits() {
    log_step "Cau hinh he thong limits cho Elasticsearch..."
    cat >/etc/security/limits.d/99-elasticsearch.conf <<'LIMITS'
elasticsearch  -  nofile  65535
elasticsearch  -  memlock unlimited
LIMITS
    cat >/etc/sysctl.d/99-elasticsearch.conf <<'SYSCTL'
vm.max_map_count=262144
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
SYSCTL
    sysctl -p /etc/sysctl.d/99-elasticsearch.conf >/dev/null 2>&1
    log_success "System limits configured"
}

install_elasticsearch() {
    log_step "Cai dat Elasticsearch $ELASTIC_VERSION..."
    apt-get install -y elasticsearch=$ELASTIC_VERSION >/dev/null 2>&1

    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    HEAP_SIZE=$((TOTAL_RAM_MB / 2))
    HEAP_SIZE=$((HEAP_SIZE > 31744 ? 31744 : HEAP_SIZE))

    cat >/etc/elasticsearch/jvm.options.d/heap.options <<HEAP
-Xms${HEAP_SIZE}m
-Xmx${HEAP_SIZE}m
HEAP

    cp /etc/elasticsearch/elasticsearch.yml /etc/elasticsearch/elasticsearch.yml.bak

    cat >/etc/elasticsearch/elasticsearch.yml <<ESYML
# ===== SIEM Cluster =====
cluster.name: siem-cluster
node.name: siem-node-01
node.roles: [master, data, ingest, transform]
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

# ===== Network =====
network.host: 0.0.0.0
http.port: ${ES_HTTP_PORT}
transport.port: ${ES_TRANSPORT_PORT}

# ===== Discovery =====
discovery.type: single-node

# ===== Security =====
xpack.security.enabled: true
xpack.security.enrollment.enabled: false
xpack.security.authc.api_key.enabled: true

# ===== HTTP SSL =====
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.key: /etc/elasticsearch/certs/privkey.pem
xpack.security.http.ssl.certificate: /etc/elasticsearch/certs/fullchain.pem
xpack.security.http.ssl.certificate_authorities: /etc/elasticsearch/certs/fullchain.pem

# ===== Transport SSL =====
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.key: /etc/elasticsearch/certs/privkey.pem
xpack.security.transport.ssl.certificate: /etc/elasticsearch/certs/fullchain.pem
xpack.security.transport.ssl.certificate_authorities: /etc/elasticsearch/certs/fullchain.pem
xpack.security.transport.ssl.verification_mode: certificate

# ===== Monitoring =====
xpack.monitoring.collection.enabled: true
xpack.monitoring.exporters.my_local:
  type: local

# ===== Audit =====
xpack.security.audit.enabled: true
xpack.security.audit.logfile.events.include: [access_denied, access_granted, authentication_failed, connection_denied, security_config_change]
ESYML

    mkdir -p "$CERT_PATH" /etc/kibana/certs /etc/logstash/certs /etc/filebeat/certs
    chown -R elasticsearch:elasticsearch "$CERT_PATH"
    chmod 750 "$CERT_PATH"

    systemctl daemon-reload
    systemctl enable elasticsearch --now 2>/dev/null || true

    wait_for_elasticsearch() {
        local max_attempts=60
        local attempt=0
        log_info "Doi Elasticsearch khoi dong (toi da ${max_attempts}s)..."
        while [[ $attempt -lt $max_attempts ]]; do
            if curl -sk "https://localhost:${ES_HTTP_PORT}" 2>/dev/null | grep -q "missing authentication"; then
                log_success "Elasticsearch san sang"
                return 0
            fi
            attempt=$((attempt + 1))
            sleep 2
        done
        log_error "Elasticsearch khong the khoi dong"
        journalctl -u elasticsearch --no-pager -n 50
        return 1
    }
    wait_for_elasticsearch
}

generate_passwords() {
    log_step "Sinh va thiet lap passwords..."
    if [[ -z "$ELASTIC_PASSWORD" ]]; then
        ELASTIC_PASSWORD=$(openssl rand -base64 32)
    fi
    # Dat password cho elastic user
    /usr/share/elasticsearch/bin/elasticsearch-reset-password \
        -u elastic -i -b -s <<<"$ELASTIC_PASSWORD" 2>/dev/null || true

    # Tao passwords cho service accounts
    KIBANA_PASSWORD=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system -s 2>/dev/null || echo "kibana_$(openssl rand -base64 16)")
    LOGSTASH_PASSWORD=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u logstash_system -s 2>/dev/null || echo "logstash_$(openssl rand -base64 16)")
    BEATS_PASSWORD=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u beats_system -s 2>/dev/null || echo "beats_$(openssl rand -base64 16)")
    APM_PASSWORD=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u apm_system -s 2>/dev/null || echo "apm_$(openssl rand -base64 16)")

    # Tao role cho logstash writer
    curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
        -X POST "https://localhost:${ES_HTTP_PORT}/_security/role/logstash_writer" \
        -H 'Content-Type: application/json' \
        -d '{"cluster":["manage_index_templates","monitor"],"indices":[{"names":["*"],"privileges":["write","create_index","auto_configure"]}]}' \
        2>/dev/null || true

    # Tao user logstash_writer
    LSW_PASS=$(openssl rand -base64 32)
    curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
        -X POST "https://localhost:${ES_HTTP_PORT}/_security/user/logstash_writer" \
        -H 'Content-Type: application/json' \
        -d "{\"password\":\"${LSW_PASS}\",\"roles\":[\"logstash_writer\"]}" \
        2>/dev/null || true

    log_success "Passwords generated"
}

setup_ssl() {
    log_step "Cau hinh SSL/TLS Certbot..."
    local ssl_choice
    read -rp "Dung Let's Encrypt Certbot (y) hay Self-signed (n)? [Y/n]: " ssl_choice
    ssl_choice="${ssl_choice:-y}"

    if [[ "$ssl_choice" =~ ^[Yy]$ ]]; then
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone \
            --agree-tos --email "$EMAIL" -d "$DOMAIN" \
            --non-interactive --keep-until-expiring \
            --rsa-key-size 4096 2>&1 || {
            log_warn "Certbot failed. Trying self-signed fallback..."
            create_self_signed_cert
        }
        if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
            cp /etc/letsencrypt/live/"$DOMAIN"/{privkey.pem,fullchain.pem} "$CERT_PATH/"
            cat >/etc/letsencrypt/renewal-hooks/post/elastic-reload.sh <<'HOOK'
#!/bin/bash
systemctl reload elasticsearch 2>/dev/null || true
systemctl reload kibana 2>/dev/null || true
systemctl reload nginx 2>/dev/null || true
HOOK
            chmod +x /etc/letsencrypt/renewal-hooks/post/elastic-reload.sh
        fi
    else
        create_self_signed_cert
    fi

    chown elasticsearch:elasticsearch "$CERT_PATH"/*.pem 2>/dev/null || true
    chmod 640 "$CERT_PATH"/*.pem 2>/dev/null || true

    # Copy certs cho cac component khac
    cp "$CERT_PATH"/{fullchain.pem,privkey.pem} /etc/kibana/certs/ 2>/dev/null || true
    cp "$CERT_PATH"/fullchain.pem /etc/logstash/certs/ 2>/dev/null || true
    cp "$CERT_PATH"/fullchain.pem /etc/filebeat/certs/ 2>/dev/null || true
    chown -R kibana:kibana /etc/kibana/certs 2>/dev/null || true
    chown -R logstash:logstash /etc/logstash/certs 2>/dev/null || true
    chown -R root:root /etc/filebeat/certs 2>/dev/null || true

    log_success "SSL/TLS configured"
}

create_self_signed_cert() {
    log_info "Tao self-signed certificate cho $DOMAIN..."
    openssl req -x509 -nodes -days 3650 \
        -subj "/C=VN/ST=HaNoi/L=HaNoi/O=SIEM/OU=IT/CN=${DOMAIN}" \
        -keyout "$CERT_PATH/privkey.pem" \
        -out "$CERT_PATH/fullchain.pem" \
        2>/dev/null
    log_success "Self-signed certificate created"
}

install_kibana() {
    log_step "Cai dat Kibana $ELASTIC_VERSION..."
    apt-get install -y kibana=$ELASTIC_VERSION >/dev/null 2>&1

    cat >/etc/kibana/kibana.yml <<KIBYML
# ===== Server =====
server.port: ${KIBANA_PORT}
server.host: "0.0.0.0"
server.publicBaseUrl: "https://${DOMAIN}"
server.name: "SIEM-Kibana"

# ===== SSL =====
server.ssl.enabled: true
server.ssl.certificate: /etc/kibana/certs/fullchain.pem
server.ssl.key: /etc/kibana/certs/privkey.pem

# ===== Elasticsearch =====
elasticsearch.hosts: ["https://localhost:${ES_HTTP_PORT}"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_PASSWORD}"
elasticsearch.ssl.certificateAuthorities: ["/etc/kibana/certs/fullchain.pem"]
elasticsearch.ssl.verificationMode: certificate

# ===== Security =====
xpack.security.enabled: true
xpack.encryptedSavedObjects.encryptionKey: "$(openssl rand -hex 32)"
xpack.reporting.encryptionKey: "$(openssl rand -hex 32)"
xpack.security.encryptionKey: "$(openssl rand -hex 32)"

# ===== SIEM Features =====
xpack.siem.enabled: true
xpack.securitySolution.enabled: true
xpack.endpoint.enabled: true

# ===== Monitoring =====
monitoring.ui.container.elasticsearch.enabled: true
xpack.monitoring.enabled: true

# ===== Logging =====
logging.dest: /var/log/kibana/kibana.log
logging.root.level: info
KIBYML

    mkdir -p /var/log/kibana
    chown kibana:kibana /var/log/kibana

    systemctl enable kibana --now 2>/dev/null || true
    wait_for_service "Kibana" "https://localhost:${KIBANA_PORT}/api/status" 60
}

install_logstash() {
    log_step "Cai dat Logstash $ELASTIC_VERSION..."
    apt-get install -y logstash=$ELASTIC_VERSION >/dev/null 2>&1

    # Convert cert cho Logstash Beats input
    openssl pkcs8 -in /etc/logstash/certs/fullchain.pem -topk8 -nocrypt \
        -out /etc/logstash/certs/logstash.pkcs8.key 2>/dev/null

    cat >/etc/logstash/logstash.yml <<LSYML
node.name: siem-logstash
path.config: /etc/logstash/conf.d/*.conf
path.logs: /var/log/logstash
xpack.monitoring.enabled: true
xpack.monitoring.elasticsearch.username: logstash_system
xpack.monitoring.elasticsearch.password: "${LOGSTASH_PASSWORD}"
xpack.monitoring.elasticsearch.hosts: ["https://localhost:${ES_HTTP_PORT}"]
xpack.monitoring.elasticsearch.ssl.certificate_authority: "/etc/logstash/certs/fullchain.pem"
LSYML

    cat >/etc/logstash/conf.d/01-syslog-input.conf <<LSCONF1
input {
  syslog {
    type => "syslog"
    port => 5514
  }
  beats {
    port => ${LOGSTASH_BEATS_PORT}
    ssl => true
    ssl_certificate => "/etc/logstash/certs/fullchain.pem"
    ssl_key => "/etc/logstash/certs/logstash.pkcs8.key"
    ssl_verify_mode => "none"
  }
}
LSCONF1

    cat >/etc/logstash/conf.d/10-siem-filter.conf <<LSCONF2
filter {
  if [type] == "syslog" {
    grok {
      match => { "message" => "%{SYSLOG5424PRI:syslog_pri}%{SYSLOG5424LINE:message}" }
      overwrite => ["message"]
    }
    date {
      match => [ "timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
    }
  }
  if [event_type] {
    mutate {
      rename => { "event_type" => "siem_event_type" }
    }
  }
}
LSCONF2

    cat >/etc/logstash/conf.d/30-elasticsearch-output.conf <<LSCONF3
output {
  elasticsearch {
    hosts => ["https://localhost:${ES_HTTP_PORT}"]
    cacert => "/etc/logstash/certs/fullchain.pem"
    user => "logstash_writer"
    password => "${LSW_PASS}"
    index => "siem-logs-%{+YYYY.MM.dd}"
    template_name => "siem-template"
    template_overwrite => true
  }
}
LSCONF3

    mkdir -p /var/log/logstash
    chown -R logstash:logstash /etc/logstash

    if /usr/share/logstash/bin/logstash --path.settings /etc/logstash -t >/dev/null 2>&1; then
        log_success "Logstash config valid"
    else
        log_error "Logstash config invalid"
        /usr/share/logstash/bin/logstash --path.settings /etc/logstash -t 2>&1
    fi

    systemctl enable logstash --now 2>/dev/null || true
}

install_beats() {
    log_step "Cai dat Elastic Beats $ELASTIC_VERSION..."

    # Filebeat
    log_info "Cai dat Filebeat..."
    apt-get install -y filebeat=$ELASTIC_VERSION >/dev/null 2>&1
    cat >/etc/filebeat/filebeat.yml <<FBYML
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/*.log
    - /var/log/syslog
    - /var/log/auth.log
    - /var/log/kern.log
  fields:
    event_module: system
- type: log
  enabled: true
  paths:
    - /var/log/nginx/*.log
  fields:
    event_module: nginx
output.logstash:
  hosts: ["localhost:${LOGSTASH_BEATS_PORT}"]
  ssl.certificate_authorities: ["/etc/filebeat/certs/fullchain.pem"]
setup.kibana:
  host: "https://localhost:${KIBANA_PORT}"
  username: "kibana_system"
  password: "${KIBANA_PASSWORD}"
  ssl.certificate_authorities: ["/etc/filebeat/certs/fullchain.pem"]
filebeat.config.modules:
  path: \${path.config}/modules.d/*.yml
  reload.enabled: true
logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat.log
FBYML
    filebeat modules enable system nginx elasticsearch kibana logstash 2>/dev/null || true
    systemctl enable filebeat --now 2>/dev/null || true

    # Metricbeat
    log_info "Cai dat Metricbeat..."
    apt-get install -y metricbeat=$ELASTIC_VERSION >/dev/null 2>&1
    cat >/etc/metricbeat/metricbeat.yml <<MBYML
metricbeat.config.modules:
  path: \${path.config}/modules.d/*.yml
  reload.enabled: true
output.elasticsearch:
  hosts: ["https://localhost:9200"]
  username: "elastic"
  password: "${ELASTIC_PASSWORD}"
  ssl.certificate_authorities: ["/etc/filebeat/certs/fullchain.pem"]
setup.kibana:
  host: "https://localhost:${KIBANA_PORT}"
  username: "kibana_system"
  password: "${KIBANA_PASSWORD}"
  ssl.certificate_authorities: ["/etc/filebeat/certs/fullchain.pem"]
MBYML
    metricbeat modules enable system elasticsearch kibana logstash nginx 2>/dev/null || true
    systemctl enable metricbeat --now 2>/dev/null || true

    # Auditbeat
    log_info "Cai dat Auditbeat..."
    apt-get install -y auditbeat=$ELASTIC_VERSION >/dev/null 2>&1
    systemctl enable auditbeat --now 2>/dev/null || true

    # Packetbeat
    log_info "Cai dat Packetbeat..."
    apt-get install -y packetbeat=$ELASTIC_VERSION >/dev/null 2>&1
    systemctl enable packetbeat --now 2>/dev/null || true

    # Heartbeat
    log_info "Cai dat Heartbeat..."
    apt-get install -y heartbeat-elastic=$ELASTIC_VERSION >/dev/null 2>&1
    cat >/etc/heartbeat/heartbeat.yml <<HBYML
heartbeat.monitors:
- type: http
  enabled: true
  urls: ["https://localhost:${ES_HTTP_PORT}", "https://localhost:${KIBANA_PORT}"]
  schedule: '@every 10s'
- type: icmp
  enabled: true
  hosts: ["localhost", "${SERVER_IP}"]
  schedule: '@every 30s'
output.elasticsearch:
  hosts: ["https://localhost:9200"]
  username: "elastic"
  password: "${ELASTIC_PASSWORD}"
  ssl.certificate_authorities: ["/etc/filebeat/certs/fullchain.pem"]
setup.kibana:
  host: "https://localhost:${KIBANA_PORT}"
  username: "kibana_system"
  password: "${KIBANA_PASSWORD}"
  ssl.certificate_authorities: ["/etc/filebeat/certs/fullchain.pem"]
HBYML
    systemctl enable heartbeat-elastic --now 2>/dev/null || true

    log_success "All Beats installed"
}

install_apm_server() {
    log_step "Cai dat APM Server $ELASTIC_VERSION..."
    apt-get install -y apm-server=$ELASTIC_VERSION >/dev/null 2>&1
    cat >/etc/apm-server/apm-server.yml <<APMYML
apm-server:
  host: "0.0.0.0:${APM_SERVER_PORT}"
  secret_token: "$(openssl rand -hex 32)"
  ssl.enabled: true
  ssl.certificate: /etc/kibana/certs/fullchain.pem
  ssl.key: /etc/kibana/certs/privkey.pem
output.elasticsearch:
  hosts: ["https://localhost:${ES_HTTP_PORT}"]
  username: "elastic"
  password: "${ELASTIC_PASSWORD}"
  ssl.certificate_authorities: ["/etc/kibana/certs/fullchain.pem"]
setup.kibana:
  host: "https://localhost:${KIBANA_PORT}"
  username: "kibana_system"
  password: "${KIBANA_PASSWORD}"
  ssl.certificate_authorities: ["/etc/kibana/certs/fullchain.pem"]
APMYML
    systemctl enable apm-server --now 2>/dev/null || true
    log_success "APM Server installed"
}

install_elasticsearch_hadoop() {
    log_step "Cai dat Elasticsearch Hadoop $ELASTIC_VERSION..."
    mkdir -p /opt/elasticsearch-hadoop
    cd /opt/elasticsearch-hadoop
    curl -sL "https://artifacts.elastic.co/downloads/elasticsearch-hadoop/elasticsearch-hadoop-${ELASTIC_VERSION}.zip" \
        -o "elasticsearch-hadoop-${ELASTIC_VERSION}.zip" 2>/dev/null || {
        log_warn "Khong the tai ES Hadoop. Bo qua."
        return 0
    }
    unzip -q "elasticsearch-hadoop-${ELASTIC_VERSION}.zip"
    ln -sf "/opt/elasticsearch-hadoop/elasticsearch-hadoop-${ELASTIC_VERSION}" /opt/elasticsearch-hadoop/current
    log_success "Elasticsearch Hadoop installed at /opt/elasticsearch-hadoop"
}

setup_nginx_proxy() {
    log_step "Cau hinh Nginx reverse proxy cho Kibana..."

    rm -f /etc/nginx/sites-enabled/default

    cat >/etc/nginx/sites-available/kibana <<NGINX
upstream kibana_upstream {
    server localhost:${KIBANA_PORT};
    keepalive 32;
}

server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    client_max_body_size 100m;
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    location / {
        proxy_pass https://kibana_upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90s;
        proxy_send_timeout 90s;
    }

    location /api/status {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
NGINX

    ln -sf /etc/nginx/sites-available/kibana /etc/nginx/sites-enabled/
    nginx -t 2>/dev/null || {
        log_error "Nginx config invalid"
        return 1
    }
    systemctl enable nginx --now 2>/dev/null || true
    log_success "Nginx proxy configured"
}

setup_siem_indices() {
    log_step "Thiet lap SIEM index templates va ILM policies..."
    
    # ILM Policy
    curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
        -X PUT "https://localhost:${ES_HTTP_PORT}/_ilm/policy/siem-policy" \
        -H 'Content-Type: application/json' \
        -d '{
            "policy": {
                "phases": {
                    "hot": {"min_age":"0ms","actions":{"rollover":{"max_size":"50gb","max_age":"30d"}}},
                    "warm": {"min_age":"30d","actions":{"forcemerge":{"max_num_segments":1},"shrink":{"number_of_shards":1}}},
                    "cold": {"min_age":"90d","actions":{"searchable_snapshot":{"snapshot_repository":"siem-backup"}}},
                    "delete": {"min_age":"365d","actions":{"delete":{}}}
                }
            }
        }' 2>/dev/null || true

    # Component template for SIEM
    curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
        -X PUT "https://localhost:${ES_HTTP_PORT}/_component_template/siem-settings" \
        -H 'Content-Type: application/json' \
        -d '{
            "template": {
                "settings": {
                    "number_of_shards": 3,
                    "number_of_replicas": 1,
                    "index.lifecycle.name": "siem-policy"
                }
            }
        }' 2>/dev/null || true

    # Index template
    curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
        -X PUT "https://localhost:${ES_HTTP_PORT}/_index_template/siem-logs" \
        -H 'Content-Type: application/json' \
        -d '{
            "index_patterns": ["siem-logs-*"],
            "template": {
                "settings": {"number_of_shards": 3},
                "mappings": {
                    "properties": {
                        "@timestamp": {"type": "date"},
                        "siem_event_type": {"type": "keyword"},
                        "source.ip": {"type": "ip"},
                        "destination.ip": {"type": "ip"},
                        "event.action": {"type": "keyword"},
                        "event.category": {"type": "keyword"},
                        "user.name": {"type": "keyword"}
                    }
                }
            },
            "composed_of": ["siem-settings"],
            "priority": 500
        }' 2>/dev/null || true

    log_success "SIEM indices configured"
}

wait_for_service() {
    local name="$1" url="$2" max_attempts="${3:-60}" attempt=0
    log_info "Doi $name san sang (toi da ${max_attempts}s)..."
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sk -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q "200\|401\|403"; then
            log_success "$name san sang"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    log_warn "$name co the chua san sang"
    return 1
}

verify_installation() {
    log_step "Xac thuc cai dat..."
    local errors=0

    echo ""
    echo "==================== VERIFICATION ===================="

    # Elasticsearch
    ES_STATUS=$(curl -sk -u "elastic:${ELASTIC_PASSWORD}" "https://localhost:${ES_HTTP_PORT}" 2>/dev/null)
    ES_VERSION=$(echo "$ES_STATUS" | jq -r '.version.number' 2>/dev/null || echo "unknown")
    if [[ -n "$ES_VERSION" && "$ES_VERSION" != "unknown" ]]; then
        echo "[PASS] Elasticsearch $ES_VERSION"
    else
        echo "[FAIL] Elasticsearch"
        ((errors++))
    fi

    # Kibana
    KIB_STATUS=$(curl -sk "https://localhost:${KIBANA_PORT}/api/status" 2>/dev/null)
    KIB_LEVEL=$(echo "$KIB_STATUS" | jq -r '.status.overall.level' 2>/dev/null || echo "unknown")
    if [[ "$KIB_LEVEL" == "available" || "$KIB_LEVEL" == "degraded" ]]; then
        echo "[PASS] Kibana ($KIB_LEVEL)"
    else
        echo "[FAIL] Kibana"
        ((errors++))
    fi

    # Logstash
    if systemctl is-active --quiet logstash; then
        echo "[PASS] Logstash"
    else
        echo "[FAIL] Logstash"
        ((errors++))
    fi

    # Beats
    for beat in filebeat metricbeat auditbeat packetbeat heartbeat-elastic; do
        if systemctl is-active --quiet "$beat" 2>/dev/null; then
            echo "[PASS] $beat"
        else
            echo "[WARN] $beat khong chay (co the chua duoc cai)"
        fi
    done

    # APM Server
    if systemctl is-active --quiet apm-server 2>/dev/null; then
        echo "[PASS] APM Server"
    else
        echo "[WARN] APM Server khong chay"
    fi

    # SSL
    if openssl x509 -in "$CERT_PATH/fullchain.pem" -checkend 2592000 -noout 2>/dev/null; then
        echo "[PASS] SSL certificate (con hieu luc >30 ngay)"
    else
        echo "[WARN] SSL certificate sap het han hoac khong hop le"
    fi

    # Nginx
    if systemctl is-active --quiet nginx; then
        echo "[PASS] Nginx"
    else
        echo "[FAIL] Nginx"
        ((errors++))
    fi

    echo "====================================================="
    echo ""

    if [[ $errors -gt 0 ]]; then
        log_error "Xac thuc voi $errors loi"
        return 1
    fi
    log_success "Tat ca services hoat dong!"
    return 0
}

print_summary() {
    echo ""
    echo "================================================================================"
    echo "  SIEM ELK $ELASTIC_VERSION INSTALLATION COMPLETE"
    echo "================================================================================"
    echo ""
    echo "  Access URLs:"
    echo "    Kibana UI:     https://${DOMAIN}"
    echo "    Elasticsearch: https://${DOMAIN}:${ES_HTTP_PORT}"
    echo "    APM Server:    https://${DOMAIN}:${APM_SERVER_PORT}"
    echo ""
    echo "  Credentials:"
    echo "    elastic user:       ${ELASTIC_PASSWORD}"
    echo "    kibana_system:      ${KIBANA_PASSWORD}"
    echo "    logstash_writer:    ${LSW_PASS}"
    echo ""
    echo "  Services Status:"
    systemctl is-active --quiet elasticsearch && echo "    elasticsearch   [RUNNING]" || echo "    elasticsearch   [STOPPED]"
    systemctl is-active --quiet kibana && echo "    kibana          [RUNNING]" || echo "    kibana          [STOPPED]"
    systemctl is-active --quiet logstash && echo "    logstash        [RUNNING]" || echo "    logstash        [STOPPED]"
    systemctl is-active --quiet nginx && echo "    nginx           [RUNNING]" || echo "    nginx           [STOPPED]"
    echo ""
    echo "  Useful Commands:"
    echo "    sudo systemctl status elasticsearch kibana logstash nginx"
    echo "    sudo journalctl -u elasticsearch -n 50 --no-pager"
    echo "    curl -sk -u elastic https://${DOMAIN}:${ES_HTTP_PORT}/_cluster/health"
    echo "    sudo certbot renew --dry-run"
    echo ""
    echo "  Backup your credentials: /root/siem-credentials.txt"
    echo "================================================================================"
    echo ""

    # Save credentials
    cat >/root/siem-credentials.txt <<CRED
# ===== SIEM ELK $ELASTIC_VERSION Credentials =====
# Generated: $(date)
DOMAIN=${DOMAIN}
ELASTIC_USER=elastic
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
KIBANA_SYSTEM_PASSWORD=${KIBANA_PASSWORD}
LOGSTASH_WRITER_PASSWORD=${LSW_PASS}
# ===== KEEP THIS FILE SECURE! =====
CRED
    chmod 600 /root/siem-credentials.txt
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo "================================================================================"
    echo "  SIEM ELK Stack $ELASTIC_VERSION Installer for Ubuntu 24.04 LTS"
    echo "  Mo hinh: StandAlone All-in-one + SSL/TLS Certbot"
    echo "  Author: PhD. Le Toan Thang"
    echo "================================================================================"
    echo ""

    pre_flight_checks
    prepare_system
    setup_firewall
    add_elastic_repo
    configure_limits
    install_elasticsearch
    generate_passwords
    setup_ssl
    install_kibana
    install_logstash
    install_beats
    install_apm_server
    install_elasticsearch_hadoop
    setup_nginx_proxy
    setup_siem_indices
    verify_installation
    print_summary

    log_success "Cai dat hoan tat! Truy cap https://${DOMAIN} de bat dau."
}

main "$@"
