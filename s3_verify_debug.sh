#!/bin/bash
#===============================================================================
# Script: s3_verify_debug.sh
# Module: Verification & Debug
# Description: Kiem tra, debug, quan ly va bao tri SIEM ELK Stack 9.4.2
#              Bao gom: health check, log analysis, performance monitoring,
#              backup/restore, certificate management, index management
# Version: 9.4.2
# Author: PhD. Le Toan Thang
#===============================================================================

set -euo pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================
DOMAIN="${DOMAIN:-siem.example.com}"
ES_HTTP_PORT="${ES_HTTP_PORT:-9200}"
KIBANA_PORT="${KIBANA_PORT:-5601}"
LOGSTASH_BEATS_PORT="${LOGSTASH_BEATS_PORT:-5044}"
APM_SERVER_PORT="${APM_SERVER_PORT:-8200}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-}"
CERT_PATH="${CERT_PATH:-/etc/elasticsearch/certs}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/siem}"
LOG_DIR="${LOG_DIR:-/var/log/siem}"
DSIEM_HOME="${DSIEM_HOME:-/opt/dsiem}"

RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; CYAN='\e[36m'; RESET='\e[0m'
log_info()    { echo -e "${GREEN}[INFO]${RESET} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }

#===============================================================================
# LOAD CREDENTIALS
#===============================================================================
load_credentials() {
    if [[ -f /root/siem-credentials.txt ]]; then
        source /root/siem-credentials.txt 2>/dev/null || true
        [[ -z "$ELASTIC_PASSWORD" ]] && ELASTIC_PASSWORD=$(grep ELASTIC_PASSWORD /root/siem-credentials.txt | cut -d= -f2)
    fi
    if [[ -z "$ELASTIC_PASSWORD" ]]; then
        read -rsp "Nhap Elasticsearch password: " ELASTIC_PASSWORD
        echo ""
    fi
}

#===============================================================================
# HEALTH CHECKS
#===============================================================================
check_es() {
    echo -n "Elasticsearch: "
    local res
    res=$(curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "https://localhost:${ES_HTTP_PORT}" 2>/dev/null)
    local ver
    ver=$(echo "$res" | jq -r '.version.number' 2>/dev/null || echo "FAIL")
    if [[ "$ver" != "FAIL" ]]; then
        local status
        status=$(curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
            "https://localhost:${ES_HTTP_PORT}/_cluster/health" 2>/dev/null | \
            jq -r '.status' 2>/dev/null)
        echo -e "${GREEN}OK${RESET} (v$ver, status: $status)"
    else
        echo -e "${RED}FAIL${RESET}"
        return 1
    fi
}

check_kibana() {
    echo -n "Kibana: "
    local status
    status=$(curl -sk "https://localhost:${KIBANA_PORT}/api/status" 2>/dev/null | \
        jq -r '.status.overall.level' 2>/dev/null || echo "FAIL")
    if [[ "$status" != "FAIL" ]]; then
        echo -e "${GREEN}OK${RESET} ($status)"
    else
        echo -e "${RED}FAIL${RESET}"
        return 1
    fi
}

check_service() {
    local name="$1"
    echo -n "$name: "
    if systemctl is-active --quiet "$name" 2>/dev/null; then
        echo -e "${GREEN}RUNNING${RESET}"
    else
        echo -e "${RED}STOPPED${RESET}"
        return 1
    fi
}

check_logstash() { check_service "logstash"; }
check_filebeat() { check_service "filebeat"; }
check_metricbeat() { check_service "metricbeat"; }
check_nginx() { check_service "nginx"; }
check_apm() { check_service "apm-server"; }

check_ssl() {
    echo -n "SSL Certificate: "
    local cert_file="$CERT_PATH/fullchain.pem"
    if [[ ! -f "$cert_file" ]]; then
        cert_file="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    fi
    if [[ -f "$cert_file" ]]; then
        local expires
        expires=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
        local days_left
        days_left=$(openssl x509 -in "$cert_file" -noout -checkend 2592000 2>/dev/null && echo ">30" || echo "<30")
        echo -e "${GREEN}VALID${RESET} (expires: $expires, days left: $days_left)"
    else
        echo -e "${RED}NOT FOUND${RESET}"
        return 1
    fi
}

check_disk() {
    echo -n "Disk Usage: "
    local used
    used=$(df -h / | awk 'NR==2 {print $5}')
    local pct
    pct=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    if [[ $pct -gt 90 ]]; then
        echo -e "${RED}CRITICAL${RESET} ($used)"
    elif [[ $pct -gt 75 ]]; then
        echo -e "${YELLOW}WARNING${RESET} ($used)"
    else
        echo -e "${GREEN}OK${RESET} ($used)"
    fi
}

check_ram() {
    echo -n "Memory: "
    local total used pct
    total=$(free -h | awk '/^Mem:/{print $2}')
    used=$(free -h | awk '/^Mem:/{print $3}')
    pct=$(free | awk '/^Mem:/{printf "%.0f", $3/$2 * 100}')
    if [[ $pct -gt 90 ]]; then
        echo -e "${RED}CRITICAL${RESET} (${used}/${total})"
    elif [[ $pct -gt 75 ]]; then
        echo -e "${YELLOW}WARNING${RESET} (${used}/${total})"
    else
        echo -e "${GREEN}OK${RESET} (${used}/${total})"
    fi
}

check_load() {
    echo -n "Load Average: "
    local load
    load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local cores
    cores=$(nproc)
    local load1
    load1=$(echo "$load" | awk -F', ' '{print $1}')
    if (($(echo "$load1 > $cores * 2" | bc -l 2>/dev/null || echo 0))); then
        echo -e "${RED}HIGH${RESET} ($load / $cores cores)"
    else
        echo -e "${GREEN}OK${RESET} ($load / $cores cores)"
    fi
}

check_indices() {
    echo -n "Elasticsearch Indices: "
    local count
    count=$(curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "https://localhost:${ES_HTTP_PORT}/_cat/indices?h=index&s=index" 2>/dev/null | wc -l)
    local size
    size=$(curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "https://localhost:${ES_HTTP_PORT}/_cat/indices?h=store.size&s=store.size:desc" 2>/dev/null | \
        awk '{sum+=$1} END{printf "%.1f GB", sum/1024}' 2>/dev/null || echo "0 GB")
    echo "$count indices, ${size}"
}

check_dsiem() {
    echo -n "DSIEM: "
    if systemctl is-active --quiet dsiem 2>/dev/null; then
        echo -e "${GREEN}RUNNING${RESET}"
    elif command -v docker &>/dev/null && docker ps 2>/dev/null | grep -q dsiem; then
        echo -e "${GREEN}DOCKER${RESET}"
    elif [[ -f "$DSIEM_HOME/bin/dsiem" ]]; then
        echo -e "${YELLOW}INSTALLED (not running)${RESET}"
    else
        echo -e "${YELLOW}NOT INSTALLED${RESET}"
    fi
}

health_check() {
    echo ""
    echo "==================== SIEM ELK HEALTH CHECK ===================="
    echo "Host: $(hostname) | Date: $(date)"
    echo "================================================================"
    echo ""
    check_es      || true
    check_kibana  || true
    check_logstash || true
    check_filebeat || true
    check_metricbeat || true
    check_nginx   || true
    check_apm     || true
    check_dsiem   || true
    check_ssl     || true
    echo "---"
    check_indices || true
    check_disk    || true
    check_ram     || true
    check_load    || true
    echo ""
    echo "================================================================"
}

#===============================================================================
# LOGS
#===============================================================================
view_logs() {
    local service="${1:-all}"
    local lines="${2:-50}"
    case "$service" in
        elasticsearch) journalctl -u elasticsearch --no-pager -n "$lines" -f ;;
        kibana)        journalctl -u kibana --no-pager -n "$lines" -f ;;
        logstash)      journalctl -u logstash --no-pager -n "$lines" -f ;;
        filebeat)      journalctl -u filebeat --no-pager -n "$lines" -f ;;
        nginx)         tail -f /var/log/nginx/access.log /var/log/nginx/error.log ;;
        apm)           journalctl -u apm-server --no-pager -n "$lines" -f ;;
        dsiem)         tail -f "$DSIEM_HOME/log/dsiem.log" ;;
        all)
            echo "--- Elasticsearch ---"
            journalctl -u elasticsearch --no-pager -n 20
            echo "--- Kibana ---"
            journalctl -u kibana --no-pager -n 20
            echo "--- Logstash ---"
            journalctl -u logstash --no-pager -n 20
            echo "--- Filebeat ---"
            journalctl -u filebeat --no-pager -n 10
            echo "--- Nginx ---"
            tail -n 10 /var/log/nginx/error.log 2>/dev/null || echo "(no nginx logs)"
            ;;
    esac
}

#===============================================================================
# INDEX MANAGEMENT
#===============================================================================
list_indices() {
    echo "=== Elasticsearch Indices ==="
    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "https://localhost:${ES_HTTP_PORT}/_cat/indices?v&s=creation.date:desc" 2>/dev/null | \
        awk '{printf "%-50s %-10s %-15s %s\n", $3, $7, $6, $8}'
}

delete_old_indices() {
    local days="${1:-365}"
    log_info "Xoa indices cu hon ${days} ngay..."
    local cutoff
    cutoff=$(date -d "-${days} days" +%Y.%m.%d)
    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "https://localhost:${ES_HTTP_PORT}/_cat/indices?h=i" 2>/dev/null | \
        grep -E '[0-9]{4}\.[0-9]{2}\.[0-9]{2}' | while read -r index; do
        local index_date
        index_date=$(echo "$index" | grep -oE '[0-9]{4}\.[0-9]{2}\.[0-9]{2}')
        if [[ "$index_date" < "$cutoff" ]]; then
            log_info "Xoa index: $index"
            curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
                -X DELETE "https://localhost:${ES_HTTP_PORT}/$index" 2>/dev/null
        fi
    done
    log_success "Index cleanup complete"
}

force_merge() {
    local max_num_segments="${1:-1}"
    log_info "Force merging indices (${max_num_segments} segments)..."
    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -X POST "https://localhost:${ES_HTTP_PORT}/_forcemerge?max_num_segments=${max_num_segments}" \
        2>/dev/null | jq '.'
    log_success "Force merge complete"
}

#===============================================================================
# BACKUP & RESTORE
#===============================================================================
create_backup() {
    local snapshot_name="${1:-siem-backup-$(date +%Y%m%d-%H%M%S)}"
    log_info "Tao snapshot: $snapshot_name"

    mkdir -p "$BACKUP_DIR"

    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -X PUT "https://localhost:${ES_HTTP_PORT}/_snapshot/siem_backup" \
        -H 'Content-Type: application/json' \
        -d "{\"type\":\"fs\",\"settings\":{\"location\":\"${BACKUP_DIR}\"}}" \
        2>/dev/null || true

    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -X PUT "https://localhost:${ES_HTTP_PORT}/_snapshot/siem_backup/${snapshot_name}?wait_for_completion=true" \
        -H 'Content-Type: application/json' \
        -d '{"indices":"*,-.ds-*","ignore_unavailable":true}' 2>/dev/null | jq '.'

    log_success "Backup created: $snapshot_name"
}

list_backups() {
    echo "=== Snapshots ==="
    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "https://localhost:${ES_HTTP_PORT}/_snapshot/siem_backup/_all" 2>/dev/null | \
        jq -r '.snapshots[] | "\(.snapshot) \(.state) \(.end_time)"' 2>/dev/null || \
        echo "(no snapshots)"
}

restore_backup() {
    local snapshot_name="$1"
    if [[ -z "$snapshot_name" ]]; then
        list_backups
        read -rp "Nhap ten snapshot de restore: " snapshot_name
    fi
    log_info "Restoring snapshot: $snapshot_name..."
    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -X POST "https://localhost:${ES_HTTP_PORT}/_snapshot/siem_backup/${snapshot_name}/_restore" \
        -H 'Content-Type: application/json' \
        -d '{"indices":"*,-.ds-*","ignore_unavailable":true}' 2>/dev/null | jq '.'
    log_success "Restore initiated"
}

#===============================================================================
# CERTIFICATE MANAGEMENT
#===============================================================================
renew_certificate() {
    log_info "Renew SSL certificate..."
    if [[ -d /etc/letsencrypt/live/$DOMAIN ]]; then
        certbot renew --force-renewal --post-hook "systemctl reload elasticsearch; systemctl reload kibana; systemctl reload nginx" 2>&1
        cp /etc/letsencrypt/live/"$DOMAIN"/{fullchain.pem,privkey.pem} "$CERT_PATH/"
        chown elasticsearch:elasticsearch "$CERT_PATH"/*.pem
        chmod 640 "$CERT_PATH"/*.pem
        log_success "Certificate renewed"
    else
        log_error "Let's Encrypt certs not found for $DOMAIN"
    fi
}

#===============================================================================
# PERFORMANCE
#===============================================================================
perf_stats() {
    echo "=== Performance Statistics ==="
    echo ""
    echo "--- Cluster Health ---"
    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "https://localhost:${ES_HTTP_PORT}/_cluster/health?pretty" 2>/dev/null | jq '{status, timed_out, number_of_nodes, number_of_data_nodes, active_primary_shards, active_shards, relocating_shards, initializing_shards, unassigned_shards, pending_tasks}'
    echo ""
    echo "--- Node Stats ---"
    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "https://localhost:${ES_HTTP_PORT}/_nodes/stats/process,jvm,indices?pretty" 2>/dev/null | \
        jq '.nodes | to_entries[] | {name: .value.name, uptime: .value.jvm.uptime, heap_used: .value.jvm.mem.heap_used_percent, open_files: .value.process.open_file_descriptors}'
    echo ""
    echo "--- Indexing Rate ---"
    curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "https://localhost:${ES_HTTP_PORT}/_nodes/stats/indices?pretty" 2>/dev/null | \
        jq '{indexing: .nodes | to_entries[].value.indices.indexing, search: .nodes | to_entries[].value.indices.search}'
}

#===============================================================================
# SERVICE MANAGEMENT
#===============================================================================
restart_all() {
    log_info "Restarting all SIEM services..."
    for svc in elasticsearch kibana logstash filebeat metricbeat auditbeat packetbeat apm-server nginx; do
        if systemctl list-units --type=service 2>/dev/null | grep -q "$svc"; then
            systemctl restart "$svc" 2>/dev/null || true
            log_info "Restarted $svc"
        fi
    done
    log_success "All services restarted"
}

stop_all() {
    log_warn "Stopping all SIEM services..."
    for svc in kibana logstash filebeat metricbeat auditbeat packetbeat apm-server nginx elasticsearch; do
        systemctl stop "$svc" 2>/dev/null || true
    done
    log_warn "All services stopped"
}

status_all() {
    echo "=== Service Status ==="
    for svc in elasticsearch kibana logstash filebeat metricbeat auditbeat packetbeat heartbeat-elastic apm-server nginx nats-server dsiem; do
        if systemctl list-units --type=service 2>/dev/null | grep -q "$svc"; then
            local s
            s=$(systemctl is-active "$svc" 2>/dev/null)
            printf "%-25s [%s]\n" "$svc" "$s"
        fi
    done
}

#===============================================================================
# MAIN MENU
#===============================================================================
show_help() {
    echo ""
    echo "SIEM ELK $ELASTIC_VERSION Management Script"
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  health              - Health check tat ca services"
    echo "  status              - Xem trang thai services"
    echo "  restart             - Restart tat ca services"
    echo "  stop                - Stop tat ca services"
    echo "  logs [service] [n]  - Xem logs (services: es|kibana|logstash|filebeat|nginx|apm|dsiem)"
    echo "  indices             - Liet ke indices"
    echo "  delete-old <days>   - Xoa indices cu hon <days> ngay"
    echo "  force-merge [n]     - Merge indices (mac dinh 1 segment)"
    echo "  backup [name]       - Tao snapshot backup"
    echo "  list-backups        - Liet ke snapshots"
    echo "  restore [name]      - Restore snapshot"
    echo "  renew-cert          - Renew SSL certificate"
    echo "  perf                - Performance statistics"
    echo ""
    echo "Examples:"
    echo "  $0 health"
    echo "  $0 logs kibana 100"
    echo "  $0 delete-old 90"
    echo "  $0 backup pre-upgrade-$(date +%Y%m%d)"
    echo ""
}

main() {
    load_credentials

    case "${1:-help}" in
        health|check)
            health_check ;;
        status)
            status_all ;;
        restart)
            restart_all ;;
        stop)
            stop_all ;;
        logs|log)
            view_logs "${2:-all}" "${3:-50}" ;;
        indices|index)
            list_indices ;;
        delete-old|cleanup)
            delete_old_indices "${2:-365}" ;;
        force-merge|merge)
            force_merge "${2:-1}" ;;
        backup|snapshot)
            create_backup "${2:-}" ;;
        list-backups|snapshots)
            list_backups ;;
        restore)
            restore_backup "${2:-}" ;;
        renew-cert|ssl)
            renew_certificate ;;
        perf|performance)
            perf_stats ;;
        help|--help|-h|*)
            show_help ;;
    esac
}

main "$@"
