#!/bin/bash

# 检测服务器是否在中国大陆的独立脚本

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# 方法1: 检测到中国镜像站的延迟
check_by_latency() {
    log_info "方法1: 检测网络延迟..."
    
    # 测试几个中国大陆的镜像站点
    local china_hosts=(
        "mirrors.aliyun.com"
        "mirrors.tencent.com"
        "mirrors.huaweicloud.com"
    )
    
    local low_latency_count=0
    
    for host in "${china_hosts[@]}"; do
        if ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
            local avg_time=$(ping -c 3 -W 2 "$host" 2>/dev/null | grep "avg" | awk -F'/' '{print $5}')
            if [ -n "$avg_time" ]; then
                # 去掉小数点，转为整数比较
                local avg_ms=${avg_time%.*}
                log_info "  到 $host 的延迟: ${avg_time}ms"
                
                # 延迟小于50ms，很可能在中国大陆
                if [ "$avg_ms" -lt 50 ]; then
                    low_latency_count=$((low_latency_count + 1))
                fi
            fi
        fi
    done
    
    if [ $low_latency_count -ge 2 ]; then
        log_success "延迟测试: 可能在中国大陆（低延迟）"
        return 0
    else
        log_info "延迟测试: 可能不在中国大陆（高延迟）"
        return 1
    fi
}

# 方法2: 使用免费的IP地理位置API
check_by_api() {
    log_info "方法2: 查询IP地理位置API..."
    
    # 尝试多个免费API服务
    local apis=(
        "http://ip-api.com/json/?fields=country,countryCode"
        "https://ipapi.co/json/"
        "http://ip.jsontest.com/"
    )
    
    for api in "${apis[@]}"; do
        local response=$(timeout 5 curl -s "$api" 2>/dev/null)
        if [ -n "$response" ]; then
            # 检查是否包含中国相关标识
            if echo "$response" | grep -qiE '"country":\s*"China"|"countryCode":\s*"CN"|"country_code":\s*"CN"'; then
                log_success "API检测: 确认在中国大陆"
                return 0
            elif echo "$response" | grep -qiE '"country":|"countryCode":|"country_code":'; then
                local country=$(echo "$response" | grep -oE '"country":\s*"[^"]+"|"country_name":\s*"[^"]+"' | cut -d'"' -f4)
                log_info "API检测: 位于 $country"
                return 1
            fi
        fi
    done
    
    log_warning "API检测: 无法确定位置"
    return 2
}

# 方法3: 检查时区
check_by_timezone() {
    log_info "方法3: 检查系统时区..."
    
    if [ -f /etc/timezone ]; then
        local tz=$(cat /etc/timezone)
    else
        local tz=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
    fi
    
    if [ -n "$tz" ]; then
        log_info "  系统时区: $tz"
        if echo "$tz" | grep -qE "Asia/(Shanghai|Beijing|Chongqing|Harbin|Urumqi)"; then
            log_success "时区检测: 使用中国时区"
            return 0
        fi
    fi
    
    log_info "时区检测: 非中国时区"
    return 1
}

# 方法4: 检查云服务商元数据（阿里云、腾讯云等）
check_by_cloud_metadata() {
    log_info "方法4: 检查云服务商..."
    
    # 检查阿里云
    if curl -s -m 2 "http://100.100.100.200/latest/meta-data/region-id" 2>/dev/null | grep -qE "^cn-|^china-"; then
        log_success "云服务商检测: 阿里云中国区域"
        return 0
    fi
    
    # 检查腾讯云
    if curl -s -m 2 "http://metadata.tencentyun.com/latest/meta-data/region" 2>/dev/null | grep -qE "^ap-beijing|^ap-shanghai|^ap-guangzhou|^ap-chengdu"; then
        log_success "云服务商检测: 腾讯云中国区域"
        return 0
    fi
    
    # 检查华为云
    if curl -s -m 2 "http://169.254.169.254/latest/meta-data/region-id" 2>/dev/null | grep -qE "^cn-"; then
        log_success "云服务商检测: 华为云中国区域"
        return 0
    fi
    
    log_info "云服务商检测: 非中国云服务商或海外区域"
    return 1
}

# 综合判断函数
is_china_server() {
    local china_score=0
    local total_checks=0
    
    # 执行各种检测
    if check_by_latency; then
        china_score=$((china_score + 2))  # 延迟测试权重高
    fi
    total_checks=$((total_checks + 2))
    
    echo
    
    if check_by_api; then
        china_score=$((china_score + 3))  # API最准确，权重最高
    fi
    total_checks=$((total_checks + 3))
    
    echo
    
    if check_by_timezone; then
        china_score=$((china_score + 1))  # 时区权重低
    fi
    total_checks=$((total_checks + 1))
    
    echo
    
    if check_by_cloud_metadata; then
        china_score=$((china_score + 2))  # 云服务商权重较高
    fi
    total_checks=$((total_checks + 2))
    
    echo
    echo "========================================="
    log_info "检测得分: $china_score / $total_checks"
    
    # 如果得分超过总分的50%，认为在中国
    if [ $china_score -ge $((total_checks / 2)) ]; then
        log_success "判定结果: 服务器在中国大陆，建议使用中国镜像源"
        return 0
    else
        log_warning "判定结果: 服务器不在中国大陆，建议使用默认源"
        return 1
    fi
}

# 主函数
main() {
    echo "========================================="
    echo "服务器地理位置检测"
    echo "========================================="
    echo
    
    if is_china_server; then
        echo
        log_success "建议配置："
        echo "  - APT源: mirrors.aliyun.com"
        echo "  - Composer源: mirrors.aliyun.com/composer"
        echo "  - NPM源: registry.npmmirror.com"
        exit 0
    else
        echo
        log_warning "建议配置："
        echo "  - 使用官方默认源"
        echo "  - 避免使用中国镜像源（可能更慢）"
        exit 1
    fi
}

# 如果直接运行脚本，执行主函数
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi

# 导出函数供其他脚本使用
export -f is_china_server