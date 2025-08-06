#!/bin/bash

# 证书管理系统备份脚本
# 功能：备份数据库和关键配置文件

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

# 脚本根目录
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$SCRIPT_ROOT"
BACKUP_DIR="$DEPLOY_ROOT/backup/keeper"
ENV_FILE="$DEPLOY_ROOT/backend/.env"

# 默认保留备份数
KEEP_BACKUPS=${KEEP_BACKUPS:-7}

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# 读取数据库配置
read_db_config() {
    if [ ! -f "$ENV_FILE" ]; then
        log_error "找不到 .env 文件: $ENV_FILE"
        exit 1
    fi
    
    # 从 .env 文件读取数据库配置
    DB_HOST=$(grep "^DB_HOST=" "$ENV_FILE" | cut -d'=' -f2)
    DB_PORT=$(grep "^DB_PORT=" "$ENV_FILE" | cut -d'=' -f2)
    DB_DATABASE=$(grep "^DB_DATABASE=" "$ENV_FILE" | cut -d'=' -f2)
    DB_USERNAME=$(grep "^DB_USERNAME=" "$ENV_FILE" | cut -d'=' -f2)
    DB_PASSWORD=$(grep "^DB_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)
    
    # 设置默认值
    DB_HOST=${DB_HOST:-localhost}
    DB_PORT=${DB_PORT:-3306}
    
    # 验证必要配置
    if [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ]; then
        log_error "数据库配置不完整，请检查 .env 文件"
        exit 1
    fi
    
    log_info "数据库: $DB_DATABASE@$DB_HOST:$DB_PORT"
}

# 备份数据库
backup_database() {
    log_info "开始备份数据库..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    DB_BACKUP_FILE="$BACKUP_DIR/db_${DB_DATABASE}_${TIMESTAMP}.sql"
    
    # 构建 mysqldump 命令
    DUMP_CMD="mysqldump -h $DB_HOST -P $DB_PORT -u $DB_USERNAME"
    
    # 如果有密码，添加密码参数
    if [ -n "$DB_PASSWORD" ]; then
        export MYSQL_PWD="$DB_PASSWORD"
    fi
    
    # 执行备份
    if $DUMP_CMD --single-transaction --routines --triggers --events "$DB_DATABASE" > "$DB_BACKUP_FILE" 2>/dev/null; then
        # 压缩备份文件
        gzip "$DB_BACKUP_FILE"
        DB_BACKUP_FILE="${DB_BACKUP_FILE}.gz"
        
        # 获取文件大小
        FILE_SIZE=$(du -h "$DB_BACKUP_FILE" | cut -f1)
        log_success "数据库备份完成: $(basename "$DB_BACKUP_FILE") ($FILE_SIZE)"
    else
        log_error "数据库备份失败"
        rm -f "$DB_BACKUP_FILE"
        return 1
    fi
    
    # 清除密码环境变量
    unset MYSQL_PWD
}

# 备份配置文件
backup_config() {
    log_info "开始备份配置文件..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CONFIG_BACKUP_FILE="$BACKUP_DIR/config_${TIMESTAMP}.tar.gz"
    
    # 创建临时目录
    TEMP_DIR="/tmp/cert_manager_backup_$$"
    mkdir -p "$TEMP_DIR/backend"
    mkdir -p "$TEMP_DIR/frontend"
    
    # 复制后端配置
    if [ -f "$DEPLOY_ROOT/backend/.env" ]; then
        cp "$DEPLOY_ROOT/backend/.env" "$TEMP_DIR/backend/"
    fi
    
    # 复制前端配置
    for component in admin user easy; do
        FRONTEND_DIR="$DEPLOY_ROOT/frontend/$component"
        if [ -d "$FRONTEND_DIR" ]; then
            # 复制配置文件
            [ -f "$FRONTEND_DIR/platform-config.json" ] && cp "$FRONTEND_DIR/platform-config.json" "$TEMP_DIR/frontend/${component}_platform-config.json"
            [ -f "$FRONTEND_DIR/config.json" ] && cp "$FRONTEND_DIR/config.json" "$TEMP_DIR/frontend/${component}_config.json"
            [ -f "$FRONTEND_DIR/logo.svg" ] && cp "$FRONTEND_DIR/logo.svg" "$TEMP_DIR/frontend/${component}_logo.svg"
            [ -f "$FRONTEND_DIR/qrcode.png" ] && cp "$FRONTEND_DIR/qrcode.png" "$TEMP_DIR/frontend/${component}_qrcode.png"
        fi
    done
    
    # 创建备份信息文件
    cat > "$TEMP_DIR/backup_info.txt" <<EOF
备份时间: $(date)
备份类型: 配置文件备份
系统版本: $(cat "$DEPLOY_ROOT/VERSION" 2>/dev/null || echo "未知")

包含文件:
- backend/.env (数据库和系统配置)
- frontend/*/platform-config.json (前端平台配置)
- frontend/*/config.json (前端配置)
- frontend/*/logo.svg (Logo文件)
- frontend/*/qrcode.png (二维码文件)

恢复方法:
1. 解压备份文件: tar -xzf $(basename "$CONFIG_BACKUP_FILE")
2. 恢复后端配置: cp backend/.env $DEPLOY_ROOT/backend/
3. 恢复前端配置: 根据文件名恢复到对应目录
EOF
    
    # 打包备份
    cd "$TEMP_DIR"
    tar -czf "$CONFIG_BACKUP_FILE" .
    cd "$SCRIPT_ROOT"
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
    
    # 获取文件大小
    FILE_SIZE=$(du -h "$CONFIG_BACKUP_FILE" | cut -f1)
    log_success "配置备份完成: $(basename "$CONFIG_BACKUP_FILE") ($FILE_SIZE)"
}

# 清理旧备份
cleanup_old_backups() {
    log_info "清理旧备份文件 (保留最近 $KEEP_BACKUPS 份)..."
    
    # 清理数据库备份
    DB_BACKUPS=$(find "$BACKUP_DIR" -name "db_*.sql.gz" -type f | sort -r)
    DB_COUNT=$(echo "$DB_BACKUPS" | wc -l)
    
    if [ "$DB_COUNT" -gt "$KEEP_BACKUPS" ]; then
        echo "$DB_BACKUPS" | tail -n +$((KEEP_BACKUPS + 1)) | while read -r file; do
            log_info "删除旧数据库备份: $(basename "$file")"
            rm -f "$file"
        done
    fi
    
    # 清理配置备份
    CONFIG_BACKUPS=$(find "$BACKUP_DIR" -name "config_*.tar.gz" -type f | sort -r)
    CONFIG_COUNT=$(echo "$CONFIG_BACKUPS" | wc -l)
    
    if [ "$CONFIG_COUNT" -gt "$KEEP_BACKUPS" ]; then
        echo "$CONFIG_BACKUPS" | tail -n +$((KEEP_BACKUPS + 1)) | while read -r file; do
            log_info "删除旧配置备份: $(basename "$file")"
            rm -f "$file"
        done
    fi
    
    log_success "备份清理完成"
}

# 显示备份列表
list_backups() {
    log_info "当前备份列表:"
    
    echo
    echo "数据库备份:"
    find "$BACKUP_DIR" -name "db_*.sql.gz" -type f -exec ls -lh {} \; | awk '{print "  - " $9 " (" $5 ")"}'
    
    echo
    echo "配置文件备份:"
    find "$BACKUP_DIR" -name "config_*.tar.gz" -type f -exec ls -lh {} \; | awk '{print "  - " $9 " (" $5 ")"}'
    echo
}

# 主函数
main() {
    log_info "============================================"
    log_info "证书管理系统备份"
    log_info "保留备份数: $KEEP_BACKUPS"
    log_info "============================================"
    
    # 读取数据库配置
    read_db_config
    
    # 执行备份
    backup_database
    backup_config
    
    # 清理旧备份
    cleanup_old_backups
    
    # 显示备份列表
    list_backups
    
    log_success "============================================"
    log_success "备份任务完成！"
    log_success "备份目录: $BACKUP_DIR"
    log_success "============================================"
    
    # 提示定时任务设置
    echo
    log_info "设置定时备份 (每天凌晨2点):"
    log_info "0 2 * * * $SCRIPT_ROOT/keeper.sh >> $BACKUP_DIR/keeper.log 2>&1"
    echo
    log_info "设置环境变量控制保留数量:"
    log_info "KEEP_BACKUPS=14 $SCRIPT_ROOT/keeper.sh  # 保留14天"
}

# 执行主函数
main "$@"