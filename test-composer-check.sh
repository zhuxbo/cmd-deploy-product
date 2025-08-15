#!/bin/bash

# 测试 Composer 检查逻辑的脚本
# 用于调试版本检测和升级触发

set -e

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

# 版本比较函数（从主脚本复制）
version_compare() {
    local version1="$1"
    local version2="$2"
    
    # 移除 v 前缀和后缀信息
    version1=$(echo "$version1" | sed 's/^v//' | sed 's/-.*//')
    version2=$(echo "$version2" | sed 's/^v//' | sed 's/-.*//')
    
    # 调试信息
    log_info "[DEBUG] version_compare: 比较 $version1 >= $version2"
    
    # 使用 sort -V 进行版本比较
    if command -v sort >/dev/null 2>&1; then
        local sorted_versions=$(printf '%s\n%s' "$version1" "$version2" | sort -V)
        local lowest=$(echo "$sorted_versions" | head -n1)
        log_info "[DEBUG] sort -V 结果: 最低版本是 $lowest"
        if [ "$lowest" = "$version2" ]; then
            log_info "[DEBUG] $version1 >= $version2 返回 true (0)"
            return 0
        else
            log_info "[DEBUG] $version1 < $version2 返回 false (1)"
            return 1
        fi
    else
        # 降级到简单的数字比较
        local v1_major=$(echo "$version1" | cut -d. -f1)
        local v1_minor=$(echo "$version1" | cut -d. -f2)
        
        local v2_major=$(echo "$version2" | cut -d. -f1)
        local v2_minor=$(echo "$version2" | cut -d. -f2)
        
        log_info "[DEBUG] 使用简单比较: v1=$v1_major.$v1_minor vs v2=$v2_major.$v2_minor"
        
        if [ "$v1_major" -gt "$v2_major" ]; then
            log_info "[DEBUG] 主版本号 $v1_major > $v2_major 返回 true (0)"
            return 0
        elif [ "$v1_major" -lt "$v2_major" ]; then
            log_info "[DEBUG] 主版本号 $v1_major < $v2_major 返回 false (1)"
            return 1
        fi
        
        if [ "$v1_minor" -ge "$v2_minor" ]; then
            log_info "[DEBUG] 次版本号 $v1_minor >= $v2_minor 返回 true (0)"
            return 0
        else
            log_info "[DEBUG] 次版本号 $v1_minor < $v2_minor 返回 false (1)"
            return 1
        fi
    fi
}

# 测试主函数
main() {
    echo "========================================="
    echo "测试 Composer 版本检查逻辑"
    echo "========================================="
    echo
    
    # 测试版本比较函数
    log_info "测试版本比较函数..."
    echo
    
    local test_cases=(
        "2.0.0:2.8.0:应该返回false"
        "2.8.0:2.8.0:应该返回true"
        "2.9.0:2.8.0:应该返回true"
        "3.0.0:2.8.0:应该返回true"
        "1.9.9:2.8.0:应该返回false"
    )
    
    for test_case in "${test_cases[@]}"; do
        IFS=':' read -r v1 v2 expected <<< "$test_case"
        echo "---"
        log_info "测试: $v1 vs $v2 ($expected)"
        if version_compare "$v1" "$v2"; then
            log_success "结果: $v1 >= $v2 (返回true)"
        else
            log_warning "结果: $v1 < $v2 (返回false)"
        fi
        echo
    done
    
    echo "========================================="
    echo "检查当前 Composer 状态"
    echo "========================================="
    echo
    
    if command -v composer >/dev/null 2>&1; then
        log_info "Composer 已安装"
        log_info "Composer 路径: $(which composer)"
        
        # 获取原始输出（不过滤）
        log_info "获取原始输出（包含所有信息）..."
        local raw_output=$(timeout -k 3s 10s composer --version 2>&1)
        log_info "完整原始输出:"
        echo "$raw_output"
        echo "---"
        
        # 获取过滤后的版本
        local composer_output=$(echo "$raw_output" | grep -v "Deprecated\|Warning" | head -1)
        log_info "过滤后输出: $composer_output"
        
        # 尝试另一种方式获取版本
        local composer_output2=$(timeout -k 3s 10s composer --version 2>&1 | grep "Composer version")
        log_info "使用grep 'Composer version'的输出: $composer_output2"
        
        local composer_version=$(echo "$composer_output" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
        if [ -n "$composer_version" ]; then
            log_success "检测到版本: $composer_version"
            
            # 测试版本比较
            echo
            log_info "测试版本是否满足 2.8.0 要求..."
            if version_compare "2.8.0" "$composer_version"; then
                log_success "版本 $composer_version >= 2.8.0，满足要求"
                log_info "安装模式应该: 不触发升级"
            else
                log_warning "版本 $composer_version < 2.8.0，需要升级"
                log_info "安装模式应该: 触发自动升级"
            fi
        else
            log_error "无法提取版本号"
        fi
    else
        log_warning "Composer 未安装"
        log_info "安装模式应该: 触发自动安装"
    fi
    
    echo
    echo "========================================="
    echo "测试完成"
    echo "========================================="
}

# 执行主函数
main "$@"