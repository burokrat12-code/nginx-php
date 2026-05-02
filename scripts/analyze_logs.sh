#!/bin/bash
# scripts/analyze_logs.sh - скрипт анализа 444 статуса
# Запускается из MikroTik через /container/shell

LOG_DIR="/var/log/nginx"
RSC_OUTPUT="/var/log/nginx/ban_ips.rsc"
TEMP_FILE="/tmp/suspicious_ips.txt"
CF_LIST_FILE="/tmp/cloudflare_ips.txt"
LAST_RUN_FILE="/tmp/nginx_ban_last_run"
ADDRESS_LIST="BAN_black_list"

# Цветной вывод
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Инкрементальный анализ логов
analyze_logs() {
    local last_run=0
    [ -f "$LAST_RUN_FILE" ] && last_run=$(cat "$LAST_RUN_FILE")
    
    > "$TEMP_FILE"
    
    if [ "$last_run" -eq 0 ]; then
        echo_info "Первый запуск - анализ всех логов"
        local log_files=$(find "$LOG_DIR" -name "access.log*" -type f 2>/dev/null)
    else
        echo_info "Инкрементальный анализ после: $(date -d "@$last_run" '+%Y-%m-%d %H:%M:%S')"
        local log_files=$(find "$LOG_DIR" -name "access.log*" -type f -newer "$LAST_RUN_FILE" 2>/dev/null)
    fi
    
    if [ -z "$log_files" ]; then
        echo_warn "Нет новых логов"
        echo "$(date +%s)" > "$LAST_RUN_FILE"
        return 1
    fi
    
    echo_info "Найдено файлов: $(echo "$log_files" | wc -w)"
    
    # Поиск IP со статусом 444
    for log in $log_files; do
        grep -h "444" "$log" 2>/dev/null | awk '{print $1}' >> "$TEMP_FILE"
    done
    
    echo "$(date +%s)" > "$LAST_RUN_FILE"
    
    # Фильтрация и сортировка
    local total=$(sort -u "$TEMP_FILE" | wc -l)
    echo_info "Найдено уникальных IP с 444: $total"
    
    sort -u "$TEMP_FILE" > "${TEMP_FILE}_uniq"
    
    # Исключаем локальные и Cloudflare IP
    if [ -f "$CF_LIST_FILE" ] && [ -s "$CF_LIST_FILE" ]; then
        grep -vE '^(127\.|192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)' "${TEMP_FILE}_uniq" | \
        grep -vFf "$CF_LIST_FILE" > "${TEMP_FILE}_clean"
    else
        echo_warn "Файл Cloudflare IP не найден, фильтруем только локальные"
        grep -vE '^(127\.|192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)' "${TEMP_FILE}_uniq" > "${TEMP_FILE}_clean"
    fi
    
    local count=$(wc -l < "${TEMP_FILE}_clean")
    local filtered=$((total - count))
    echo_info "Отфильтровано (локальные/Cloudflare): $filtered"
    echo_info "Новых IP для блокировки: $count"
    
    return 0
}

# Генерация RSC файла для MikroTik
generate_rsc() {
    local count=$(wc -l < "${TEMP_FILE}_clean" 2>/dev/null || echo "0")
    
    if [ "$count" -eq 0 ]; then
        echo_warn "Нет новых IP для добавления"
        cat > "$RSC_OUTPUT" << EOF
# No new IPs with status 444 - $(date)
EOF
        return
    fi
    
    echo_info "Генерация RSC файла ($count IP)..."
    
    cat > "$RSC_OUTPUT" << EOF
# ============================================
# Auto-generated banned IP list for MikroTik
# Target list: $ADDRESS_LIST
# Generated: $(date)
# Total new IPs: $count
# ============================================

EOF

    local added=0
    local current_date=$(date +%Y-%m-%d)
    
    while read -r ip; do
        [ -z "$ip" ] && continue
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo ":do { /ip firewall address-list add list=\"$ADDRESS_LIST\" address=$ip timeout=7d comment=\"444: $current_date\" } on-error={ }" >> "$RSC_OUTPUT"
            added=$((added + 1))
        fi
    done < "${TEMP_FILE}_clean"
    
    cat >> "$RSC_OUTPUT" << EOF

# ============================================
# Statistics
# ============================================
:local total [/ip firewall address-list print count-only where list="$ADDRESS_LIST"]
:log info "$ADDRESS_LIST updated: added $added new IPs (status 444), total \$total IPs"
EOF

    echo_info "Готово! Добавлено $added IP"
    echo_info "RSC файл: $RSC_OUTPUT"
}

# Очистка
cleanup() {
    rm -f "$TEMP_FILE" "${TEMP_FILE}_uniq" "${TEMP_FILE}_clean" 2>/dev/null
}

# Основная функция
main() {
    echo_info "=== Запуск анализа логов Nginx (статус 444) ==="
    echo_info "Время запуска: $(date)"
    analyze_logs
    generate_rsc
    cleanup
    echo_info "=== Готово ==="
}

main "$@"
