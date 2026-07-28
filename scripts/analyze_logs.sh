#!/bin/bash

# ============================================
# Скрипт анализа логов Nginx (инкрементальный)
# Добавление IP в список BAN_black_list на MikroTik
# Блокируем статусы 400 и 444
# Версия: 4.27 (Fast Python Engine - High Performance)
# ============================================

export LC_ALL=C
export TZ=UTC

LOG_DIR="/var/log/nginx"
RSC_OUTPUT="/var/log/nginx/ban_ips.rsc"
TEMP_FILE="/tmp/suspicious_ips_$$"
LAST_TIME_FILE="/tmp/nginx_ban_last_time"
LOCK_FILE="/tmp/nginx_ban_script.lock"
ADDRESS_LIST="BAN_black_list"

MY_IPS_CONF="/etc/nginx/my_custom_ips.conf"
CF_IPS_CONF="/etc/nginx/cloudflare_real_ips.conf"
GOOGLE_IPS_CONF="/etc/nginx/google_ips.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

analyze_logs_incremental() {
    local last_time=0
    if [ -f "$LAST_TIME_FILE" ]; then
        last_time=$(cat "$LAST_TIME_FILE" 2>/devnull || echo "0")
    fi
    
    > "${TEMP_FILE}_raw"
    > "${TEMP_FILE}_clean"
    
    if [ "$last_time" -eq 0 ]; then
        echo_info "Первый запуск - анализируем все логи"
    else
        echo_info "Инкрементальный анализ - обрабатываем строки после timestamp: $last_time"
    fi
    
    local log_files
    log_files=$( {
        find "$LOG_DIR" -maxdepth 1 -name "*access*.log.*.gz" -not -name "._*" -type f 2>/devnull | sort -V
        find "$LOG_DIR" -maxdepth 1 -name "*access*.log.1" -not -name "._*" -type f 2>/devnull
        find "$LOG_DIR" -maxdepth 1 -name "*access*.log" -not -name "._*" -type f 2>/devnull
    } )
    
    if [ -z "$log_files" ]; then
        echo_warn "Нет файлов логов для анализа"
        return 1
    fi
    
    local max_time=$last_time

    for log in $log_files; do
        [ -f "$log" ] || continue
        echo_info "Анализируем: $(basename "$log")"
        
        LOG_PATH="$log" LAST_TS="$last_time" python3 -c '
import sys, gzip, os, re, time
from datetime import datetime, timezone

log_path = os.getenv("LOG_PATH")
last_ts = int(os.getenv("LAST_TS", 0))

months = {"Jan":1, "Feb":2, "Mar":3, "Apr":4, "May":5, "Jun":6, 
          "Jul":7, "Aug":8, "Sep":9, "Oct":10, "Nov":11, "Dec":12}

ip_regex = re.compile(r"^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})")
date_regex = re.compile(r"\[(\d{2})/([A-Za-z]{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2})")
status_regex = re.compile(r"\"\s+(400|444)\s+")

def open_log(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="ignore")
    return open(path, "rt", encoding="utf-8", errors="ignore")

current_buf = ""
current_ip = None
max_ts_file = 0

try:
    with open_log(log_path) as f:
        for line in f:
            ip_match = ip_regex.match(line)
            if ip_match:
                if current_buf and current_ip:
                    # Process completed record
                    d_match = date_regex.search(current_buf)
                    if d_match:
                        day, mon, yr, hr, mn, sc = d_match.groups()
                        try:
                            dt = datetime(int(yr), months[mon], int(day), int(hr), int(mn), int(sc), tzinfo=timezone.utc)
                            ts = int(dt.timestamp())
                            if ts > max_ts_file:
                                max_ts_file = ts
                            if ts > last_ts and status_regex.search(current_buf):
                                print(f"{current_ip} {ts}")
                        except Exception:
                            pass
                current_ip = ip_match.group(1)
                current_buf = line.strip()
            else:
                if current_buf:
                    current_buf += " " + line.strip()

        # Last record
        if current_buf and current_ip:
            d_match = date_regex.search(current_buf)
            if d_match:
                day, mon, yr, hr, mn, sc = d_match.groups()
                try:
                    dt = datetime(int(yr), months[mon], int(day), int(hr), int(mn), int(sc), tzinfo=timezone.utc)
                    ts = int(dt.timestamp())
                    if ts > max_ts_file:
                        max_ts_file = ts
                    if ts > last_ts and status_regex.search(current_buf):
                        print(f"{current_ip} {ts}")
                except Exception:
                    pass

    if max_ts_file > 0:
        print(f"TS_MARKER {max_ts_file}")

except Exception as e:
    pass
' >> "${TEMP_FILE}_raw"

    done
    
    if [ -s "${TEMP_FILE}_raw" ]; then
        local found_max
        local now_ts
        now_ts=$(date +%s)
        found_max=$(awk 'NF==2 && $1=="TS_MARKER" {if($2>m) m=$2} END{print m}' "${TEMP_FILE}_raw")
        
        if [ -n "$found_max" ] && [ "$found_max" -gt "$max_time" ]; then
            if [ "$found_max" -le $((now_ts + 86400)) ]; then
                max_time=$found_max
            fi
        fi
        grep -v "^TS_MARKER" "${TEMP_FILE}_raw" | awk '{print $1}' > "$TEMP_FILE"
        rm -f "${TEMP_FILE}_raw"
    fi
    
    echo "$max_time" > "$LAST_TIME_FILE"
    
    if [ ! -s "$TEMP_FILE" ]; then
        echo_info "Нет новых записей со статусом 400/444"
        return 0
    fi
    
    echo_info "Фильтрация IP-адресов..."
    sort -u "$TEMP_FILE" > "${TEMP_FILE}_uniq"
    
    local my_ips=""
    if [ -f "$MY_IPS_CONF" ]; then
        my_ips=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$MY_IPS_CONF" | sort -u | paste -sd '|' - | sed 's/\./\\./g')
    fi

    local priv_nets="^(127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)"
    if [ -n "$my_ips" ]; then
        grep -vE "${priv_nets}|^(${my_ips})$" "${TEMP_FILE}_uniq" > "${TEMP_FILE}_step1"
    else
        grep -vE "${priv_nets}" "${TEMP_FILE}_uniq" > "${TEMP_FILE}_step1"
    fi

    if command -v python3 &>/devnull; then
        CF_CONF="$CF_IPS_CONF" GOOGLE_CONF="$GOOGLE_IPS_CONF" IN_FILE="${TEMP_FILE}_step1" OUT_FILE="${TEMP_FILE}_clean" python3 -c '
import ipaddress, re, os, sys

def load_nets(conf_path):
    nets = []
    if not conf_path or not os.path.isfile(conf_path):
        return nets
    try:
        with open(conf_path) as f:
            for line in f:
                match = re.search(r"((?:[0-9]{1,3}\.){3}[0-9]{1,3}(?:/[0-9]{1,2})?)", line)
                if match:
                    try:
                        nets.append(ipaddress.ip_network(match.group(1), strict=False))
                    except ValueError:
                        pass
    except Exception:
        pass
    return nets

whitelist = load_nets(os.getenv("CF_CONF")) + load_nets(os.getenv("GOOGLE_CONF"))

in_file = os.getenv("IN_FILE")
out_file = os.getenv("OUT_FILE")

if in_file and os.path.isfile(in_file):
    with open(in_file) as f_in, open(out_file, "w") as f_out:
        for line in f_in:
            ip_str = line.strip()
            try:
                ip_obj = ipaddress.ip_address(ip_str)
                if ip_obj.version == 4 and not any(ip_obj in net for net in whitelist):
                    f_out.write(ip_str + "\n")
            except ValueError:
                pass
'
    else
        cp "${TEMP_FILE}_step1" "${TEMP_FILE}_clean"
    fi

    rm -f "${TEMP_FILE}_step1"
    
    local count
    count=$(grep -cE '^([0-9]{1,3}\.){3}[0-9]{1,3}' "${TEMP_FILE}_clean" 2>/devnull | head -n 1 | tr -d '[:space:]')
    [ -z "$count" ] && count=0
    echo_info "Найдено новых IP для блокировки (статус 400/444): $count"
    
    return 0
}

generate_rsc() {
    local count
    count=$(grep -cE '^([0-9]{1,3}\.){3}[0-9]{1,3}' "${TEMP_FILE}_clean" 2>/devnull | head -n 1 | tr -d '[:space:]')
    [ -z "$count" ] && count=0
    
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
    local current_date
    current_date=$(date +%Y-%m-%d)
    
    while read -r ip; do
        [ -z "$ip" ] && continue
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
            if [ "$i1" -le 255 ] && [ "$i2" -le 255 ] && [ "$i3" -le 255 ] && [ "$i4" -le 255 ]; then
                echo ":do { /ip firewall address-list add list=\"$ADDRESS_LIST\" address=$ip timeout=7d comment=\"400/444: $current_date\" } on-error={ :log warning \"Failed to add IP: $ip\" }" >> "$RSC_OUTPUT"
                added=$((added + 1))
            fi
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
    rm -f "${TEMP_FILE}"* 2>/devnull
}

main() {
    echo_info "=== Запуск анализа логов Nginx (статус 400 и 444) ==="
    
    if [ ! -d "$LOG_DIR" ]; then
        echo_error "Директория $LOG_DIR не существует!"
        exit 1
    fi
    
    analyze_logs_incremental
    generate_rsc
    cleanup
    
    echo_info "=== Скрипт завершен ==="
    echo_info "Для загрузки на MikroTik: /import $RSC_OUTPUT"
}

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo_warn "Скрипт уже выполняется в другом процессе. Выход."
    exit 0
fi

main "$@"
