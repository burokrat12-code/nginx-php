#!/bin/bash

# ============================================
# Скрипт анализа логов Nginx (инкрементальный)
# Добавление IP в список BAN_black_list на MikroTik
# Блокируем статусы 400 и 444
# Версия: 4.2 (финальная, с временем строк)
# ============================================

LOG_DIR="/var/log/nginx"
RSC_OUTPUT="/var/log/nginx/ban_ips.rsc"
TEMP_FILE="/tmp/suspicious_ips.txt"
CF_LIST_FILE="/tmp/cloudflare_ips.txt"
CF_LAST_UPDATE="/tmp/cloudflare_last_update"
LAST_TIME_FILE="/tmp/nginx_ban_last_time"
ADDRESS_LIST="BAN_black_list"

# Цветной вывод
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

update_cloudflare_ips() {
    local current_time=$(date +%s)
    local last_update=0
    local need_update=0
    
    if [ -f "$CF_LAST_UPDATE" ]; then
        last_update=$(cat "$CF_LAST_UPDATE")
        local days_since=$(( (current_time - last_update) / 86400 ))
        if [ $days_since -ge 7 ]; then
            need_update=1
            echo_info "Прошло $days_since дней с последнего обновления Cloudflare IP"
        else
            echo_info "Cloudflare IP актуальны (обновлены $days_since дней назад)"
        fi
    else
        need_update=1
        echo_info "Первое обновление списка Cloudflare IP"
    fi
    
    if [ $need_update -eq 1 ] || [ ! -s "$CF_LIST_FILE" ]; then
        echo_info "Загрузка актуальных списков Cloudflare IP..."
        {
            curl -s --connect-timeout 10 "https://www.cloudflare.com/ips-v4" 2>/dev/null
            curl -s --connect-timeout 10 "https://www.cloudflare.com/ips-v6" 2>/dev/null
        } > "$CF_LIST_FILE.tmp"
        
        if [ -s "$CF_LIST_FILE.tmp" ]; then
            mv "$CF_LIST_FILE.tmp" "$CF_LIST_FILE"
            echo "$current_time" > "$CF_LAST_UPDATE"
            echo_info "Cloudflare IP обновлены: $(wc -l < $CF_LIST_FILE) подсетей"
        else
            echo_warn "Не удалось загрузить Cloudflare IP, использую старый список"
            rm -f "$CF_LIST_FILE.tmp"
        fi
    fi
}

analyze_logs_incremental() {
    local last_time=0
    if [ -f "$LAST_TIME_FILE" ]; then
        last_time=$(cat "$LAST_TIME_FILE")
    fi
    
    > "$TEMP_FILE"
    
    if [ "$last_time" -eq 0 ]; then
        echo_info "Первый запуск - анализируем все логи"
    else
        echo_info "Инкрементальный анализ - обрабатываем строки после timestamp: $last_time"
    fi
    
    local log_files=$(find "$LOG_DIR" -name "access.log*" -type f 2>/dev/null | sort)
    
    if [ -z "$log_files" ]; then
        echo_warn "Нет файлов логов для анализа"
        return 1
    fi
    
    echo_info "Найдено файлов логов: $(echo "$log_files" | wc -w)"
    
    local max_time=$last_time
    
    for log in $log_files; do
        [ -z "$log" ] && continue
        echo_info "Анализируем: $(basename "$log")"
        
        while IFS= read -r line; do
            # Извлекаем timestamp [04/May/2026:23:19:50 +0300]
            local log_time=$(echo "$line" | grep -oE '\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\]' | head -1 | tr -d '[]')
            
            if [ -n "$log_time" ]; then
                # Конвертируем: 04/May/2026:23:19:50 +0300 -> 04 May 2026 23:19:50 +0300
                local cleaned=$(echo "$log_time" | sed 's/\// /g' | sed 's/:/ /' | sed 's/ \([+-]\)/ \1/')
                local log_timestamp=$(date -d "$cleaned" +%s 2>/dev/null)
                
                if [ -n "$log_timestamp" ] && [ "$log_timestamp" -gt "$last_time" ]; then
                    if echo "$line" | grep -E "(400|444)" > /dev/null 2>&1; then
                        echo "$line" | awk '{print $1}' >> "$TEMP_FILE"
                    fi
                    
                    if [ "$log_timestamp" -gt "$max_time" ]; then
                        max_time=$log_timestamp
                    fi
                fi
            fi
        done < "$log"
    done
    
    echo "$max_time" > "$LAST_TIME_FILE"
    
    if [ ! -s "$TEMP_FILE" ]; then
        echo_info "Нет новых записей со статусом 400/444"
        echo "0" > "${TEMP_FILE}_clean"
        return 0
    fi
    
    echo_info "Фильтрация IP-адресов..."
    sort -u "$TEMP_FILE" > "${TEMP_FILE}_uniq"
    
    if [ -f "$CF_LIST_FILE" ] && [ -s "$CF_LIST_FILE" ]; then
        grep -vE '^(127\.|192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)' "${TEMP_FILE}_uniq" | \
        grep -vFf "$CF_LIST_FILE" > "${TEMP_FILE}_clean"
    else
        grep -vE '^(127\.|192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)' "${TEMP_FILE}_uniq" > "${TEMP_FILE}_clean"
    fi
    
    local count=$(wc -l < "${TEMP_FILE}_clean")
    echo_info "Найдено новых IP (статус 400/444): $count"
    
    return 0
}

generate_rsc() {
    local count=$(wc -l < "${TEMP_FILE}_clean" 2>/dev/null || echo "0")
    
    if [ "$count" -eq 0 ]; then
        echo_warn "Нет новых IP для добавления"
        cat > "$RSC_OUTPUT" << EOF
# ============================================
# Auto-generated banned IP list for MikroTik
# Generated: $(date)
# ============================================
# Нет новых IP со статусом 400/444 для добавления в $ADDRESS_LIST
# ============================================
:log info "Нет новых IP со статусом 400/444 в логах nginx для $ADDRESS_LIST"
EOF
        echo_info "Создан пустой RSC файл"
        return
    fi
    
    echo_info "Генерация RSC файла..."
    
    cat > "$RSC_OUTPUT" << EOF
# ============================================
# Auto-generated banned IP list for MikroTik
# Target list: $ADDRESS_LIST
# Generated: $(date)
# ============================================
# Блокируем IP, которые получают статус 400 или 444
# IP удаляются автоматически через 7 дней
# Новых IP для добавления: $count
# ============================================

# Добавляем новые IP в список $ADDRESS_LIST
EOF

    local added=0
    local current_date=$(date +%Y-%m-%d)
    
    while read -r ip; do
        [ -z "$ip" ] && continue
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo ":do { /ip firewall address-list add list=\"$ADDRESS_LIST\" address=$ip timeout=7d comment=\"400/444: $current_date\" } on-error={ :log warning \"Failed to add IP: $ip\" }" >> "$RSC_OUTPUT"
            added=$((added + 1))
        fi
    done < "${TEMP_FILE}_clean"
    
    cat >> "$RSC_OUTPUT" << EOF

# Статистика
:local total [/ip firewall address-list print count-only where list="$ADDRESS_LIST"]
:local added $added
:log info "$ADDRESS_LIST обновлен: добавлено \$added новых IP (статус 400/444), всего \$total IP в списке"
:put "Всего IP: \$total (добавлено \$added новых)"
EOF

    echo_info "Готово! RSC файл: $RSC_OUTPUT"
    echo_info "Добавлено новых IP: $added"
}

cleanup() {
    rm -f "$TEMP_FILE" "${TEMP_FILE}_uniq" "${TEMP_FILE}_clean" 2>/dev/null
}

main() {
    echo_info "=== Запуск анализа логов Nginx (статус 400 и 444) ==="
    
    if [ ! -d "$LOG_DIR" ]; then
        echo_error "Директория $LOG_DIR не существует!"
        exit 1
    fi
    
    update_cloudflare_ips
    analyze_logs_incremental
    generate_rsc
    cleanup
    
    echo_info "=== Скрипт завершен ==="
    echo_info "Для загрузки на MikroTik: /import $RSC_OUTPUT"
}

main "$@"
