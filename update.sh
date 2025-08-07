#!/bin/bash

# 证书管理系统更新脚本
# 功能：从 production-code 仓库更新系统

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

# 获取脚本所在目录（deploy目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 获取站点根目录（site目录）
SITE_ROOT="$(dirname "$SCRIPT_DIR")"
# 源码目录
SOURCE_DIR="$SCRIPT_DIR/source"
# 备份目录
BACKUP_DIR="$SITE_ROOT/backup/update"
# 配置文件
CONFIG_FILE="$SCRIPT_DIR/update-config.json"

# 生产代码仓库（使用HTTPS地址，避免SSH密钥问题）
PRODUCTION_REPO="https://gitee.com/zhuxbo/production-code.git"

# 临时保留目录
TEMP_PRESERVE_DIR=""

# 清理函数
cleanup() {
    if [ -n "$TEMP_PRESERVE_DIR" ] && [ -d "$TEMP_PRESERVE_DIR" ]; then
        rm -rf "$TEMP_PRESERVE_DIR"
    fi
}

# 设置退出陷阱
trap cleanup EXIT INT TERM

# 更新模块
UPDATE_MODULE="${1:-all}"
VALID_MODULES=("api" "admin" "user" "easy" "all")

if [[ ! " ${VALID_MODULES[@]} " =~ " ${UPDATE_MODULE} " ]]; then
    log_error "无效的更新模块: $UPDATE_MODULE"
    log_info "有效的模块: ${VALID_MODULES[*]}"
    log_info "用法: $0 [all|api|admin|user|easy]"
    exit 1
fi

# 检查必要的命令
check_dependencies() {
    # 检查 jq 命令
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq 命令未安装，这是解析配置文件所必需的"
        log_info "请先安装 jq："
        log_info "  Ubuntu/Debian: sudo apt-get install jq"
        log_info "  CentOS/RHEL: sudo yum install jq"
        log_info "  其他系统: 请参考 https://stedolan.github.io/jq/download/"
        exit 1
    fi
}

# 检测宝塔面板
check_bt_panel() {
    if [ -f "/www/server/panel/BT-Panel" ] || \
       [ -f "/www/server/panel/class/panelPlugin.py" ] || \
       [ -d "/www/server/panel" ] && [ -f "/www/server/panel/data/port.pl" ]; then
        return 0  # 是宝塔环境
    fi
    return 1  # 非宝塔环境
}

# 加载配置
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        log_info "请确保 update-config.json 文件存在"
        exit 1
    fi
    
    # 验证配置文件格式
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log_error "配置文件格式错误，请检查 JSON 格式"
        exit 1
    fi
    
    log_success "配置文件加载成功"
}

# 拉取最新代码
pull_latest_code() {
    log_info "拉取最新生产代码..."
    
    mkdir -p "$SOURCE_DIR" "$BACKUP_DIR"
    cd "$SOURCE_DIR"
    
    if [ -d "production-code" ]; then
        cd production-code
        git fetch origin
        
        # 检查是否有更新
        LOCAL_COMMIT=$(git rev-parse HEAD)
        REMOTE_COMMIT=$(git rev-parse origin/main)
        
        if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
            log_info "已是最新版本"
            
            # 检查是否强制更新
            if [ "${FORCE_UPDATE:-0}" != "1" ]; then
                read -p "没有新版本，是否继续更新？(y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_info "更新已取消"
                    exit 0
                fi
            fi
        fi
        
        git reset --hard origin/main
    else
        log_info "克隆生产代码仓库..."
        git clone "$PRODUCTION_REPO" production-code
        cd production-code
    fi
    
    # 读取版本信息
    NEW_VERSION=$(jq -r '.version' info.json 2>/dev/null || echo "unknown")
    log_success "新版本: $NEW_VERSION"
    
    cd "$SCRIPT_DIR"
}

# 备份当前版本
backup_current() {
    log_info "备份当前版本..."
    
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/update_$BACKUP_TIMESTAMP"
    mkdir -p "$BACKUP_PATH"
    
    # 记录当前版本
    if [ -f "$SITE_ROOT/info.json" ]; then
        CURRENT_VERSION=$(jq -r '.version' "$SITE_ROOT/info.json" 2>/dev/null || echo "unknown")
        echo "原版本: $CURRENT_VERSION" > "$BACKUP_PATH/backup_info.txt"
    fi
    
    echo "备份时间: $(date)" >> "$BACKUP_PATH/backup_info.txt"
    echo "更新模块: $UPDATE_MODULE" >> "$BACKUP_PATH/backup_info.txt"
    echo "新版本: $NEW_VERSION" >> "$BACKUP_PATH/backup_info.txt"
    
    # 根据更新模块备份
    case "$UPDATE_MODULE" in
        all)
            for dir in backend frontend nginx; do
                if [ -d "$SITE_ROOT/$dir" ]; then
                    cp -r "$SITE_ROOT/$dir" "$BACKUP_PATH/"
                fi
            done
            ;;
        api)
            if [ -d "$SITE_ROOT/backend" ]; then
                cp -r "$SITE_ROOT/backend" "$BACKUP_PATH/"
            fi
            ;;
        admin|user|easy)
            if [ -d "$SITE_ROOT/frontend/$UPDATE_MODULE" ]; then
                mkdir -p "$BACKUP_PATH/frontend"
                cp -r "$SITE_ROOT/frontend/$UPDATE_MODULE" "$BACKUP_PATH/frontend/"
            fi
            ;;
    esac
    
    log_success "备份完成: $BACKUP_PATH"
}

# 保存需要保留的文件
save_preserve_files() {
    log_info "保存需要保留的文件..."
    
    TEMP_PRESERVE_DIR="/tmp/cert_manager_preserve_$$"
    mkdir -p "$TEMP_PRESERVE_DIR"
    
    # 保存后端文件
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        if [ -d "$SITE_ROOT/backend" ]; then
            # 读取需要保留的后端文件
            BACKEND_FILES=$(jq -r '.preserve_files.backend[]' "$CONFIG_FILE" 2>/dev/null)
            if [ -n "$BACKEND_FILES" ]; then
                while IFS= read -r file; do
                    if [ -e "$SITE_ROOT/backend/$file" ]; then
                        # 创建目标目录
                        TARGET_DIR="$TEMP_PRESERVE_DIR/backend/$(dirname "$file")"
                        mkdir -p "$TARGET_DIR"
                        # 复制文件或目录
                        cp -r "$SITE_ROOT/backend/$file" "$TARGET_DIR/"
                        log_info "保存: backend/$file"
                    fi
                done <<< "$BACKEND_FILES"
            fi
        fi
    fi
    
    # 保存前端配置文件
    for component in admin user easy; do
        if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "$component" ]; then
            if [ -d "$SITE_ROOT/frontend/$component" ]; then
                PRESERVE_FILES=$(jq -r ".preserve_files.frontend.$component[]" "$CONFIG_FILE" 2>/dev/null)
                if [ -n "$PRESERVE_FILES" ]; then
                    mkdir -p "$TEMP_PRESERVE_DIR/frontend/$component"
                    while IFS= read -r file; do
                        if [ -f "$SITE_ROOT/frontend/$component/$file" ]; then
                            cp "$SITE_ROOT/frontend/$component/$file" "$TEMP_PRESERVE_DIR/frontend/$component/"
                            log_info "保存: frontend/$component/$file"
                        fi
                    done <<< "$PRESERVE_FILES"
                fi
            fi
        fi
    done
    
    log_success "文件保存完成"
}

# 恢复保留的文件
restore_preserve_files() {
    log_info "恢复保留的文件..."
    
    if [ ! -d "$TEMP_PRESERVE_DIR" ]; then
        log_warning "没有需要恢复的文件"
        return
    fi
    
    # 恢复后端文件
    if [ -d "$TEMP_PRESERVE_DIR/backend" ]; then
        cp -r "$TEMP_PRESERVE_DIR/backend"/* "$SITE_ROOT/backend/" 2>/dev/null || true
        log_info "后端文件已恢复"
    fi
    
    # 恢复前端文件
    if [ -d "$TEMP_PRESERVE_DIR/frontend" ]; then
        for component in admin user easy; do
            if [ -d "$TEMP_PRESERVE_DIR/frontend/$component" ]; then
                cp -r "$TEMP_PRESERVE_DIR/frontend/$component"/* "$SITE_ROOT/frontend/$component/" 2>/dev/null || true
                log_info "前端 $component 文件已恢复"
            fi
        done
    fi
    
    log_success "文件恢复完成"
    log_info "临时文件将在脚本结束时自动清理"
}

# 部署新文件
deploy_new_files() {
    log_info "部署新文件..."
    
    SOURCE_PATH="$SOURCE_DIR/production-code"
    
    case "$UPDATE_MODULE" in
        all)
            # 删除并更新所有模块
            for dir in backend frontend nginx; do
                if [ -d "$SOURCE_PATH/$dir" ]; then
                    log_info "更新 $dir..."
                    rm -rf "$SITE_ROOT/$dir"
                    cp -r "$SOURCE_PATH/$dir" "$SITE_ROOT/"
                fi
            done
            
            # 复制构建信息文件
            cp "$SOURCE_PATH/info.json" "$SITE_ROOT/" 2>/dev/null || true
            ;;
            
        api)
            # 仅更新后端
            if [ -d "$SOURCE_PATH/backend" ]; then
                log_info "更新后端..."
                rm -rf "$SITE_ROOT/backend"
                cp -r "$SOURCE_PATH/backend" "$SITE_ROOT/"
            fi
            ;;
            
        admin|user|easy)
            # 更新特定前端
            if [ -d "$SOURCE_PATH/frontend/$UPDATE_MODULE" ]; then
                log_info "更新 $UPDATE_MODULE 前端..."
                rm -rf "$SITE_ROOT/frontend/$UPDATE_MODULE"
                mkdir -p "$SITE_ROOT/frontend"
                cp -r "$SOURCE_PATH/frontend/$UPDATE_MODULE" "$SITE_ROOT/frontend/"
            fi
            ;;
    esac
    
    log_success "文件部署完成"
}

# 执行后端优化
optimize_backend() {
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        log_info "执行后端优化..."
        
        cd "$SITE_ROOT/backend"
        
        # 检查PHP命令
        PHP_CMD="php"
        if check_bt_panel; then
            # 检查可用的宝塔PHP版本（83, 84, 85等）
            for ver in 85 84 83; do
                if [ -x "/www/server/php/$ver/bin/php" ]; then
                    PHP_CMD="/www/server/php/$ver/bin/php"
                    break
                fi
            done
        fi
        
        # 优化 Composer 自动加载（使用站点所有者执行）
        if command -v composer &> /dev/null; then
            log_info "优化 Composer 自动加载..."
            # 获取站点所有者
            SITE_OWNER=$(stat -c "%U" "$SITE_ROOT")
            if sudo -u "$SITE_OWNER" composer dump-autoload --optimize --no-dev 2>/dev/null; then
                log_success "自动加载优化完成（包发现已自动执行）"
            else
                log_warning "自动加载优化失败，但不影响应用运行"
                log_info "Laravel 将使用基础自动加载器，性能可能稍有影响"
                echo
                log_info "如需手动尝试优化，请执行以下命令："
                log_info "cd $SITE_ROOT/backend"
                log_info "sudo -u $SITE_OWNER composer dump-autoload --optimize --no-dev"
                echo
            fi
        else
            log_warning "Composer 未安装，跳过自动加载优化"
            log_info "Laravel 将使用基础自动加载器"
        fi
        
        # 清理并优化 Laravel 缓存
        log_info "清理并优化 Laravel 缓存..."
        $PHP_CMD artisan cache:clear
        $PHP_CMD artisan config:clear
        $PHP_CMD artisan route:clear
        $PHP_CMD artisan view:clear
        $PHP_CMD artisan optimize
        
        # 删除安装文件（如果存在）
        if [ -f "public/install.php" ]; then
            rm -f "public/install.php"
            log_info "已删除安装文件"
        fi
        
        cd "$SCRIPT_DIR"
        
        log_success "后端优化完成"
    fi
}

# 更新 Nginx 配置路径
update_nginx_config() {
    if [ "$UPDATE_MODULE" = "all" ] && [ -f "$SITE_ROOT/nginx/manager.conf" ]; then
        log_info "更新 Nginx 配置路径..."
        sed -i "s|__PROJECT_ROOT__|$SITE_ROOT|g" "$SITE_ROOT/nginx/manager.conf"
        log_success "Nginx 配置路径已更新"
    fi
}

# 设置文件权限
set_permissions() {
    log_info "设置文件权限..."
    
    # 获取站点目录的所有者信息
    SITE_OWNER=$(stat -c "%U" "$SITE_ROOT")
    SITE_GROUP=$(stat -c "%G" "$SITE_ROOT")
    
    log_info "站点目录所有者: $SITE_OWNER:$SITE_GROUP"
    log_info "站点目录即为Web用户目录，storage和cache保持一致权限"
    
    # 设置后端权限
    if [ -d "$SITE_ROOT/backend" ] && ([ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]); then
        log_info "设置后端目录权限..."
        
        # 整体保持与站点目录一致的所有者
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend"
        
        # 设置基础目录权限为755
        sudo chmod 755 "$SITE_ROOT/backend"
        
        # 代码文件设置为644（只读）- 合并多个find命令提高性能
        find "$SITE_ROOT/backend" -type f \( \
            -name "*.php" -o -name "*.js" -o -name "*.css" -o -name "*.xml" -o \
            -name "*.yml" -o -name "*.yaml" -o -name "*.md" -o -name "*.txt" -o \
            -name ".env*" \
        \) -not -path "$SITE_ROOT/backend/storage/*" -not -path "$SITE_ROOT/backend/bootstrap/cache/*" \
        -exec sudo chmod 644 {} +
        
        # JSON文件特殊处理 - 某些可能需要写入权限
        find "$SITE_ROOT/backend" -type f -name "*.json" \
        -not -path "$SITE_ROOT/backend/storage/*" -not -path "$SITE_ROOT/backend/bootstrap/cache/*" \
        -exec sudo chmod 644 {} +
        
        # Laravel 特殊文件处理
        if [ -f "$SITE_ROOT/backend/artisan" ]; then
            sudo chmod 755 "$SITE_ROOT/backend/artisan"  # artisan需要执行权限
        fi
        
        # Laravel 需要写入权限的目录 - 保持与站点目录一致的用户
        if [ -d "$SITE_ROOT/backend/storage" ]; then
            sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend/storage"
            sudo chmod -R 775 "$SITE_ROOT/backend/storage"
            # storage内的文件设置为664
            find "$SITE_ROOT/backend/storage" -type f -exec sudo chmod 664 {} +
        fi
        
        if [ -d "$SITE_ROOT/backend/bootstrap/cache" ]; then
            sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend/bootstrap/cache"
            sudo chmod -R 775 "$SITE_ROOT/backend/bootstrap/cache"
        fi
        
        # 其他目录设置为755
        find "$SITE_ROOT/backend" -type d -not -path "$SITE_ROOT/backend/storage*" -not -path "$SITE_ROOT/backend/bootstrap/cache*" -exec sudo chmod 755 {} +
        
        log_info "后端权限设置完成"
    fi
    
    # 设置前端权限
    for component in admin user easy; do
        if [ -d "$SITE_ROOT/frontend/$component" ] && ([ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "$component" ]); then
            log_info "设置 $component 前端权限..."
            
            # 前端保持与站点目录一致的所有者
            sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/frontend/$component"
            
            # 目录权限755
            find "$SITE_ROOT/frontend/$component" -type d -exec sudo chmod 755 {} +
            
            # 代码文件设置为644（只读）
            find "$SITE_ROOT/frontend/$component" -type f \( \
                -name "*.html" -o -name "*.js" -o -name "*.css" -o -name "*.json" -o \
                -name "*.svg" -o -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o \
                -name "*.gif" -o -name "*.ico" -o -name "*.xml" -o -name "*.txt" -o -name "*.md" \
            \) -exec sudo chmod 644 {} +
        fi
    done
    
    # 设置nginx目录权限（仅在全量更新时）
    if [ "$UPDATE_MODULE" = "all" ] && [ -d "$SITE_ROOT/nginx" ]; then
        log_info "设置nginx目录权限..."
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/nginx"
        sudo chmod -R 755 "$SITE_ROOT/nginx"
        find "$SITE_ROOT/nginx" -type f -exec sudo chmod 644 {} +
    fi
    
    log_success "权限设置完成"
    log_info "- 代码文件: 644 (只读)"
    log_info "- 目录: 755"
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        log_info "- Laravel写入目录: $SITE_OWNER:$SITE_GROUP 775"
    fi
    log_info "- 所有文件: $SITE_OWNER:$SITE_GROUP"
}

# 重载服务
reload_services() {
    log_info "重载服务..."
    
    if check_bt_panel; then
        log_warning "宝塔环境，请在面板中重载服务"
        log_warning "- 重载 Nginx"
        log_warning "- 重启 PHP-FPM"
        log_warning "- 重启队列守护进程"
    else
        # 重载 Nginx（在更新前端或全量更新时）
        if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "admin" ] || [ "$UPDATE_MODULE" = "user" ] || [ "$UPDATE_MODULE" = "easy" ]; then
            NGINX_RELOAD=$(jq -r '.services.nginx.reload_command' "$CONFIG_FILE")
            if eval "$NGINX_RELOAD" 2>/dev/null; then
                log_success "Nginx 已重载"
            else
                log_warning "Nginx 重载失败"
            fi
        fi
        
        # 重启 PHP-FPM（仅在更新后端时）
        if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
            PHP_RESTART=$(jq -r '.services."php-fpm".restart_command' "$CONFIG_FILE")
            if eval "$PHP_RESTART" 2>/dev/null; then
                log_success "PHP-FPM 已重启"
            else
                log_warning "PHP-FPM 重启失败"
            fi
        fi
        
        # 重启队列（仅在更新后端时）
        if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
            if command -v supervisorctl &> /dev/null; then
                SITE_NAME=$(basename "$SITE_ROOT")
                QUEUE_RESTART=$(jq -r '.services.queue.restart_command' "$CONFIG_FILE" | sed "s/{SITE_NAME}/$SITE_NAME/g")
                if eval "$QUEUE_RESTART" 2>/dev/null; then
                    log_success "队列已重启"
                else
                    log_warning "队列重启失败"
                fi
            fi
        fi
    fi
}

# 检查服务状态
check_services_status() {
    log_info "检查服务状态..."
    
    if check_bt_panel; then
        log_info "宝塔环境，请在面板中检查服务状态"
    else
        # 检查 Nginx
        NGINX_STATUS=$(jq -r '.services.nginx.status_command' "$CONFIG_FILE")
        if eval "$NGINX_STATUS" &>/dev/null; then
            log_success "Nginx: 运行中"
        else
            log_error "Nginx: 未运行"
        fi
        
        # 检查 PHP-FPM
        PHP_STATUS=$(jq -r '.services."php-fpm".status_command' "$CONFIG_FILE")
        if eval "$PHP_STATUS" &>/dev/null; then
            log_success "PHP-FPM: 运行中"
        else
            log_error "PHP-FPM: 未运行"
        fi
        
        # 检查队列
        if command -v supervisorctl &> /dev/null; then
            SITE_NAME=$(basename "$SITE_ROOT")
            QUEUE_STATUS=$(jq -r '.services.queue.status_command' "$CONFIG_FILE" | sed "s/{SITE_NAME}/$SITE_NAME/g")
            QUEUE_OUTPUT=$(eval "$QUEUE_STATUS" 2>/dev/null || echo "")
            if echo "$QUEUE_OUTPUT" | grep -q "RUNNING"; then
                log_success "队列进程: 运行中"
                echo "$QUEUE_OUTPUT"
            else
                log_warning "队列进程: 状态异常"
                echo "$QUEUE_OUTPUT"
            fi
        else
            log_info "队列: Supervisor 未安装"
        fi
    fi
}

# 主函数
main() {
    log_info "============================================"
    log_info "证书管理系统更新"
    log_info "更新模块: $UPDATE_MODULE"
    log_info "站点目录: $SITE_ROOT"
    log_info "============================================"
    
    # 检查依赖命令
    check_dependencies
    
    # 加载配置
    load_config
    
    # 拉取最新代码
    pull_latest_code
    
    # 备份当前版本
    backup_current
    
    # 保存需要保留的文件
    save_preserve_files
    
    # 部署新文件
    deploy_new_files
    
    # 恢复保留的文件
    restore_preserve_files
    
    # 执行后端优化
    optimize_backend
    
    # 更新 Nginx 配置路径
    update_nginx_config
    
    # 设置权限
    set_permissions
    
    # 重载服务
    reload_services
    
    # 检查服务状态
    check_services_status
    
    log_success "============================================"
    log_success "更新完成！"
    log_success "新版本: $NEW_VERSION"
    log_success "============================================"
    
    # 显示更新摘要
    echo
    log_info "更新摘要："
    log_info "- 更新模块: $UPDATE_MODULE"
    log_info "- 备份位置: $BACKUP_DIR"
    log_info "- 保留文件: 已按配置恢复"
    
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        log_info "- Laravel 缓存: 已清理并优化"
    fi
}

# 执行主函数
main "$@"