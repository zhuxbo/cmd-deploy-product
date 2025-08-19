#!/bin/bash

# SSL证书管理系统 - 队列和定时任务配置脚本
# 功能：独立配置supervisor队列和cron定时任务
# 依赖：需要在install.php安装完成后运行

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_prompt() { echo -n -e "${YELLOW}[PROMPT]${NC} $1"; }

# 项目根目录
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 检查是否有环境变量指定部署目录
if [ -n "$DEPLOY_TARGET_DIR" ] && [ -d "$DEPLOY_TARGET_DIR" ]; then
    PROJECT_ROOT="$DEPLOY_TARGET_DIR"
    log_info "使用环境变量指定的部署目录: $PROJECT_ROOT"
else
    # 如果当前在 cmd-deploy-scripts 目录，部署到同级的 cmd-deploy 目录
    if [[ "$SCRIPT_ROOT" == *"cmd-deploy-scripts"* ]]; then
        PROJECT_ROOT="$(dirname "$SCRIPT_ROOT")/cmd-deploy"
        log_info "检测到脚本目录，部署到: $PROJECT_ROOT"
    else
        PROJECT_ROOT="$SCRIPT_ROOT"
    fi
fi

BACKEND_DIR="$PROJECT_ROOT/backend"

# 检测宝塔面板环境
detect_bt_environment() {
    # 检查宝塔面板进程
    if pgrep -f "BT-Panel" >/dev/null 2>&1; then
        return 0
    fi
    
    # 检查宝塔安装目录
    if [ -d "/www/server/panel" ]; then
        return 0
    fi
    
    return 1
}

# 检查宝塔supervisor插件
check_bt_supervisor() {
    # 优先检查宝塔插件路径
    local bt_plugin_paths=(
        "/www/server/panel/plugin/supervisor"
        "/www/server/supervisor"
    )
    
    for path in "${bt_plugin_paths[@]}"; do
        if [ -d "$path" ]; then
            # 检查配置目录
            if [ -d "$path/profile" ] || [ -d "$path/conf.d" ]; then
                return 0
            fi
        fi
    done
    
    # 检查supervisor命令是否可用（系统级别）
    if command -v supervisorctl >/dev/null 2>&1; then
        if supervisorctl version >/dev/null 2>&1; then
            # 检查是否有配置目录
            if [ -d "/etc/supervisor/conf.d" ]; then
                return 0
            fi
        fi
    fi
    
    return 1
}

# 环境检测和策略选择
environment_check() {
    log_info "==============================================="
    log_info "SSL证书管理系统 - 队列和定时任务配置"
    log_info "==============================================="
    echo
    
    log_info "检测运行环境..."
    
    # 检查后端目录是否存在
    if [ ! -d "$BACKEND_DIR" ]; then
        log_error "后端目录不存在: $BACKEND_DIR"
        log_error "请先运行 install.sh 部署系统"
        exit 1
    fi
    
    # 检查artisan命令是否可用
    if [ ! -f "$BACKEND_DIR/artisan" ]; then
        log_error "Laravel项目未正确安装: $BACKEND_DIR/artisan"
        log_error "请确保已完成 install.php 的安装配置"
        exit 1
    fi
    
    # 检测宝塔环境
    if detect_bt_environment; then
        log_warning "================================================"
        log_warning " 检测到宝塔面板环境"
        log_warning "================================================"
        echo
        log_info "宝塔环境下需要手动配置队列和定时任务"
        log_info "因为宝塔面板的定时任务和进程守护需要写入面板数据库"
        echo
        log_info "==============================================="
        log_info "宝塔面板手动配置指南"
        log_info "==============================================="
        echo
        log_info "📋 1. 定时任务配置（在 宝塔面板 -> 计划任务 中添加）："
        log_info "   任务类型: Shell脚本"
        log_info "   任务名称: SSL证书管理系统定时任务"
        log_info "   执行周期: 每分钟 (N分钟)"
        log_info "   脚本内容: cd $BACKEND_DIR && php artisan schedule:run"
        echo
        log_info "📋 2. 队列配置（安装并配置 Supervisor管理器 插件）："
        log_info "   2.1 在 软件商店 -> 系统工具 中安装 'Supervisor管理器'"
        log_info "   2.2 在 Supervisor管理器 中添加守护进程："
        log_info "       名称: ssl-cert-queue"
        log_info "       启动命令: php artisan queue:work --queue Task --tries 3 --delay 5 --max-jobs 1000 --max-time 3600 --memory 128 --timeout 60 --sleep 3"
        log_info "       运行目录: $BACKEND_DIR"
        log_info "       运行用户: www"
        log_info "       进程数量: 1"
        log_info "       自动重启: 是"
        echo
        log_info "📋 3. PHP扩展配置（确保以下扩展已安装）："
        log_info "   在 软件商店 -> PHP-8.3 -> 安装扩展 中检查："
        log_info "   - redis (必需)"
        log_info "   - mbstring (必需)"
        log_info "   - fileinfo (必需)"
        log_info "   - calendar (必需)"
        echo
        exit 0
    else
        log_info "未检测到宝塔环境，使用系统方式管理"
        export IS_BT_ENV=false
    fi
}

# 安装系统supervisor
install_system_supervisor() {
    if ! command -v supervisord >/dev/null 2>&1; then
        log_warning "Supervisor未安装，尝试自动安装..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y supervisor
            sudo systemctl enable supervisor
            sudo systemctl start supervisor
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y supervisor
            sudo systemctl enable supervisord
            sudo systemctl start supervisord
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y supervisor
            sudo systemctl enable supervisord
            sudo systemctl start supervisord
        else
            log_error "无法自动安装Supervisor，请手动安装"
            log_info "Ubuntu/Debian: sudo apt-get install supervisor"
            log_info "CentOS/RHEL: sudo yum install supervisor"
            log_info "然后重新运行此脚本"
            exit 1
        fi
        log_success "Supervisor安装完成"
    else
        log_info "Supervisor已安装"
    fi
}

# 设置定时任务
setup_cron_job() {
    log_info "设置Laravel定时任务..."
    
    # 获取项目根目录所有者作为运行用户
    local DEPLOY_OWNER=""
    if [ -d "$PROJECT_ROOT" ]; then
        DEPLOY_OWNER=$(stat -c %U "$PROJECT_ROOT" 2>/dev/null || stat -f %Su "$PROJECT_ROOT" 2>/dev/null)
    elif [ -d "$BACKEND_DIR" ]; then
        DEPLOY_OWNER=$(stat -c %U "$BACKEND_DIR" 2>/dev/null || stat -f %Su "$BACKEND_DIR" 2>/dev/null)
    fi
    
    if [ -z "$DEPLOY_OWNER" ]; then
        log_warning "无法获取部署目录所有者，跳过定时任务设置"
        return
    fi
    
    log_info "定时任务运行用户: $DEPLOY_OWNER"
    
    # 创建定时任务命令，包含具体路径以支持多实例
    local CRON_CMD="* * * * * cd $BACKEND_DIR && /usr/bin/php artisan schedule:run >> /dev/null 2>&1"
    local CRON_COMMENT="# SSL Cert Manager - $BACKEND_DIR"
    
    # 检查是否已存在该具体项目的定时任务
    if sudo -u "$DEPLOY_OWNER" crontab -l 2>/dev/null | grep -q "$BACKEND_DIR.*schedule:run"; then
        log_info "该项目的定时任务已存在，跳过"
    else
        # 添加定时任务
        log_info "添加定时任务..."
        (
            sudo -u "$DEPLOY_OWNER" crontab -l 2>/dev/null | grep -v "^#$"
            echo "$CRON_COMMENT"
            echo "$CRON_CMD"
        ) | sudo -u "$DEPLOY_OWNER" crontab -
        if [ $? -eq 0 ]; then
            log_success "定时任务添加成功"
        else
            log_warning "定时任务添加失败，请手动添加："
            log_info "  $CRON_CMD"
        fi
    fi
}

# 设置Supervisor队列
setup_supervisor_queue() {
    log_info "设置Supervisor队列..."
    
    # 非宝塔环境，安装supervisor
    if [ "$IS_BT_ENV" = "false" ]; then
        install_system_supervisor
    fi
    
    # 获取项目根目录所有者作为运行用户
    local DEPLOY_OWNER=""
    if [ -d "$PROJECT_ROOT" ]; then
        DEPLOY_OWNER=$(stat -c %U "$PROJECT_ROOT" 2>/dev/null || stat -f %Su "$PROJECT_ROOT" 2>/dev/null)
    elif [ -d "$BACKEND_DIR" ]; then
        DEPLOY_OWNER=$(stat -c %U "$BACKEND_DIR" 2>/dev/null || stat -f %Su "$BACKEND_DIR" 2>/dev/null)
    fi
    
    if [ -z "$DEPLOY_OWNER" ]; then
        log_warning "无法获取部署目录所有者，跳过Supervisor设置"
        return
    fi
    
    log_info "队列运行用户: $DEPLOY_OWNER"
    
    # 使用项目路径的哈希作为唯一标识
    local PROJECT_HASH=$(echo "$BACKEND_DIR" | md5sum | cut -c1-8)
    local QUEUE_NAME="cert-manager-queue-$PROJECT_HASH"
    
    # 根据环境选择配置文件路径
    local SUPERVISOR_CONF
    if [ "$IS_BT_ENV" = "true" ]; then
        # 宝塔环境优先检查插件路径
        if [ -d "/www/server/panel/plugin/supervisor/profile" ]; then
            SUPERVISOR_CONF="/www/server/panel/plugin/supervisor/profile/$QUEUE_NAME.ini"
        elif [ -d "/www/server/supervisor/conf" ]; then
            SUPERVISOR_CONF="/www/server/supervisor/conf/$QUEUE_NAME.conf"
        else
            SUPERVISOR_CONF="/etc/supervisor/conf.d/$QUEUE_NAME.conf"
        fi
    else
        SUPERVISOR_CONF="/etc/supervisor/conf.d/$QUEUE_NAME.conf"
    fi
    
    # 检查是否已存在该项目的队列配置
    if [ -f "$SUPERVISOR_CONF" ]; then
        log_info "该项目的队列配置已存在，跳过"
        return
    fi
    
    # 创建临时配置文件
    local temp_conf="/tmp/$QUEUE_NAME.conf"
    if [[ "$SUPERVISOR_CONF" == *.ini ]]; then
        # 宝塔格式(.ini)
        cat > "$temp_conf" << EOF
[program:$QUEUE_NAME]
command=/usr/bin/php $BACKEND_DIR/artisan queue:work --queue Task --tries 3 --delay 5 --max-jobs 1000 --max-time 3600 --memory 128 --timeout 60 --sleep 3
directory=$BACKEND_DIR
user=$DEPLOY_OWNER
autorestart=true
redirect_stderr=true
stdout_logfile=$BACKEND_DIR/storage/logs/queue.log
stdout_logfile_maxbytes=100MB
stdout_logfile_backups=3
stopwaitsecs=3600
EOF
    else
        # 标准格式(.conf)
        cat > "$temp_conf" << EOF
[program:$QUEUE_NAME]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php $BACKEND_DIR/artisan queue:work --queue Task --tries 3 --delay 5 --max-jobs 1000 --max-time 3600 --memory 128 --timeout 60 --sleep 3
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=$DEPLOY_OWNER
numprocs=1
redirect_stderr=true
stdout_logfile=$BACKEND_DIR/storage/logs/queue.log
stopwaitsecs=3600
EOF
    fi
    
    # 复制配置文件
    if sudo cp "$temp_conf" "$SUPERVISOR_CONF" 2>/dev/null; then
        log_success "Supervisor配置文件创建成功: $SUPERVISOR_CONF"
        
        # 根据环境重新加载配置
        if [ "$IS_BT_ENV" = "true" ]; then
            log_info "宝塔环境：请在面板中重新载入Supervisor配置"
            log_info "或尝试自动重载..."
        fi
        
        # 尝试重新加载supervisor配置
        if sudo supervisorctl reread >/dev/null 2>&1 && sudo supervisorctl update >/dev/null 2>&1; then
            log_success "Supervisor配置已更新"
            
            # 启动队列
            if sudo supervisorctl start "$QUEUE_NAME:*" >/dev/null 2>&1 || sudo supervisorctl start "$QUEUE_NAME" >/dev/null 2>&1; then
                log_success "队列已启动"
            else
                log_warning "队列启动失败，请手动检查或在宝塔面板中启动"
            fi
        else
            log_warning "Supervisor配置更新失败"
            if [ "$IS_BT_ENV" = "true" ]; then
                log_info "请在宝塔面板 -> Supervisor管理器中手动添加或重载配置"
            else
                log_info "请手动执行："
                log_info "  sudo supervisorctl reread"
                log_info "  sudo supervisorctl update"
            fi
        fi
    else
        log_warning "无法创建Supervisor配置文件: $SUPERVISOR_CONF"
        log_info "配置内容："
        cat "$temp_conf"
        if [ "$IS_BT_ENV" = "true" ]; then
            log_info "请将上述配置在宝塔面板中手动添加"
        fi
    fi
    
    rm -f "$temp_conf"
}

# 检查配置状态
check_status() {
    log_info "==============================================="
    log_info "检查配置状态"
    log_info "==============================================="
    echo
    
    # 获取运行用户
    local DEPLOY_OWNER=""
    if [ -d "$PROJECT_ROOT" ]; then
        DEPLOY_OWNER=$(stat -c %U "$PROJECT_ROOT" 2>/dev/null || stat -f %Su "$PROJECT_ROOT" 2>/dev/null)
    fi
    
    if [ -z "$DEPLOY_OWNER" ]; then
        log_warning "无法获取部署目录所有者"
        return
    fi
    
    # 检查定时任务
    log_info "检查定时任务..."
    if sudo -u "$DEPLOY_OWNER" crontab -l 2>/dev/null | grep -q "$BACKEND_DIR.*schedule:run"; then
        log_success "✅ 定时任务配置正常"
    else
        log_warning "❌ 未找到定时任务配置"
    fi
    
    # 检查队列配置
    log_info "检查队列配置..."
    local PROJECT_HASH=$(echo "$BACKEND_DIR" | md5sum | cut -c1-8)
    local QUEUE_NAME="cert-manager-queue-$PROJECT_HASH"
    
    # 检查配置文件
    local config_found=false
    local config_paths=(
        "/www/server/panel/plugin/supervisor/profile/$QUEUE_NAME.ini"
        "/www/server/supervisor/conf/$QUEUE_NAME.conf"
        "/etc/supervisor/conf.d/$QUEUE_NAME.conf"
    )
    
    for conf_path in "${config_paths[@]}"; do
        if [ -f "$conf_path" ]; then
            log_success "✅ 队列配置文件存在: $conf_path"
            config_found=true
            break
        fi
    done
    
    if [ "$config_found" = false ]; then
        log_warning "❌ 未找到队列配置文件"
        return
    fi
    
    # 检查supervisor状态
    if sudo supervisorctl status >/dev/null 2>&1; then
        if sudo supervisorctl status | grep -q "$QUEUE_NAME"; then
            log_success "✅ 队列进程正在运行"
            # 显示队列状态
            local queue_status=$(sudo supervisorctl status 2>/dev/null | grep "$QUEUE_NAME")
            if [ -n "$queue_status" ]; then
                echo "   $queue_status"
            fi
        else
            log_warning "❌ 队列进程未运行，但配置文件存在"
        fi
    else
        log_warning "❌ Supervisor未运行"
    fi
}

# 主函数
main() {
    # 环境检测
    environment_check
    
    echo
    log_info "开始配置队列和定时任务..."
    echo
    
    # 设置定时任务
    setup_cron_job
    echo
    
    # 设置队列
    setup_supervisor_queue
    echo
    
    # 检查状态
    check_status
    
    echo
    log_success "==============================================="
    log_success "队列和定时任务配置完成！"
    log_success "==============================================="
    echo
    log_info "💡 管理提示："
    
    if [ "$IS_BT_ENV" = "true" ]; then
        log_info "• 宝塔环境下可通过面板管理："
        log_info "  - 定时任务：宝塔面板 -> 计划任务"
        log_info "  - 队列管理：宝塔面板 -> Supervisor管理器"
    else
        log_info "• 系统环境下可通过命令管理："
        log_info "  - 查看定时任务：crontab -l"
        log_info "  - 查看队列状态：sudo supervisorctl status"
        log_info "  - 重启队列：sudo supervisorctl restart cert-manager-queue-*"
    fi
    
    echo
    log_info "如遇问题，请检查："
    log_info "• 确保已完成install.php的数据库配置"
    log_info "• 检查文件权限和目录所有者"
    log_info "• 查看日志：$BACKEND_DIR/storage/logs/"
    echo
}

# 显示帮助
show_help() {
    cat << EOF
SSL证书管理系统 - 队列和定时任务配置脚本

用法:
    $0 [选项]

选项:
    -h, help       显示此帮助信息
    check          仅检查当前配置状态
    
功能:
    - 自动检测宝塔面板环境
    - 配置Laravel定时任务 (schedule:run)
    - 配置Supervisor队列处理 (queue:work)
    - 支持多实例部署

注意:
    - 需要在install.php安装完成后运行
    - 宝塔环境建议使用面板管理
    - 非宝塔环境会自动安装supervisor

EOF
}

# 参数处理
case "${1:-}" in
    -h|help)
        show_help
        exit 0
        ;;
    check)
        environment_check >/dev/null 2>&1 || true
        check_status
        exit 0
        ;;
    *)
        main
        ;;
esac
