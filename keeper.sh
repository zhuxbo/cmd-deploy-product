#!/bin/bash

# 证书管理系统备份脚本
# 功能：备份 .env 文件和数据库，提供恢复和清理功能

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
# 后端目录
BACKEND_DIR="$SITE_ROOT/backend"
# 备份目录
BACKUP_DIR="$SITE_ROOT/backup/keeper"
# .env 文件路径
ENV_FILE="$BACKEND_DIR/.env"

# 默认保留备份数
KEEP_BACKUPS=${KEEP_BACKUPS:-7}

# 操作模式
ACTION="${1:-backup}"

# 显示使用帮助
show_usage() {
    echo "证书管理系统备份工具"
    echo ""
    echo "用法: $0 [操作] [选项]"
    echo ""
    echo "操作:"
    echo "  backup          备份数据库和配置文件（默认）"
    echo "  restore <文件>  恢复指定的备份文件"
    echo "  list            列出所有备份文件"
    echo "  clean           清理过期的备份文件"
    echo "  help            显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  KEEP_BACKUPS    保留的备份数量（默认：7）"
    echo ""
    echo "示例:"
    echo "  $0                                    # 备份"
    echo "  $0 restore backup_20231201_120000.tar.gz   # 恢复备份"
    echo "  $0 list                              # 列出备份"
    echo "  KEEP_BACKUPS=14 $0 clean            # 保留14个备份"
}

# 验证环境
validate_environment() {
    # 检查后端目录
    if [ ! -d "$BACKEND_DIR" ]; then
        log_error "后端目录不存在: $BACKEND_DIR"
        exit 1
    fi
    
    # 检查 .env 文件
    if [ ! -f "$ENV_FILE" ]; then
        log_error ".env 文件不存在: $ENV_FILE"
        log_info "请确保系统已正确安装"
        exit 1
    fi
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR"
}

# 读取数据库配置
read_db_config() {
    log_info "读取数据库配置..."
    
    # 从 .env 文件读取数据库配置
    DB_CONNECTION=$(grep "^DB_CONNECTION=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' || echo "mysql")
    DB_HOST=$(grep "^DB_HOST=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' || echo "localhost")
    DB_PORT=$(grep "^DB_PORT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' || echo "3306")
    DB_DATABASE=$(grep "^DB_DATABASE=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"')
    DB_USERNAME=$(grep "^DB_USERNAME=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"')
    DB_PASSWORD=$(grep "^DB_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"')
    
    # 验证必要配置
    if [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ]; then
        log_error "数据库配置不完整"
        log_error "请检查 .env 文件中的 DB_DATABASE 和 DB_USERNAME"
        exit 1
    fi
    
    # 验证数据库连接类型
    if [ "$DB_CONNECTION" != "mysql" ]; then
        log_error "当前仅支持 MySQL 数据库备份"
        log_error "检测到数据库类型: $DB_CONNECTION"
        exit 1
    fi
    
    log_success "数据库配置: $DB_DATABASE@$DB_HOST:$DB_PORT"
}

# 备份 .env 文件
backup_env() {
    log_info "备份 .env 配置文件..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    ENV_BACKUP_FILE="$BACKUP_DIR/env_${TIMESTAMP}.backup"
    
    # 复制 .env 文件
    cp "$ENV_FILE" "$ENV_BACKUP_FILE"
    
    # 获取文件大小
    FILE_SIZE=$(du -h "$ENV_BACKUP_FILE" | cut -f1)
    log_success ".env 备份完成: $(basename "$ENV_BACKUP_FILE") ($FILE_SIZE)"
    
    echo "$ENV_BACKUP_FILE"
}

# 备份数据库
backup_database() {
    log_info "备份数据库..."
    
    # 检查 mysqldump 命令
    if ! command -v mysqldump &> /dev/null; then
        log_error "mysqldump 命令未找到"
        log_error "请安装 MySQL 客户端: apt-get install mysql-client"
        exit 1
    fi
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    DB_BACKUP_FILE="$BACKUP_DIR/db_${DB_DATABASE}_${TIMESTAMP}.sql"
    
    # 构建 mysqldump 命令
    DUMP_CMD="mysqldump -h $DB_HOST -P $DB_PORT -u $DB_USERNAME"
    
    # 设置密码环境变量（如果有密码）
    if [ -n "$DB_PASSWORD" ]; then
        export MYSQL_PWD="$DB_PASSWORD"
    fi
    
    # 执行备份
    log_info "导出数据库 $DB_DATABASE..."
    if $DUMP_CMD --single-transaction --routines --triggers --events --hex-blob --default-character-set=utf8mb4 "$DB_DATABASE" > "$DB_BACKUP_FILE" 2>/dev/null; then
        # 压缩备份文件
        log_info "压缩备份文件..."
        gzip "$DB_BACKUP_FILE"
        DB_BACKUP_FILE="${DB_BACKUP_FILE}.gz"
        
        # 获取文件大小
        FILE_SIZE=$(du -h "$DB_BACKUP_FILE" | cut -f1)
        log_success "数据库备份完成: $(basename "$DB_BACKUP_FILE") ($FILE_SIZE)"
    else
        log_error "数据库备份失败"
        log_error "请检查数据库连接配置和权限"
        rm -f "$DB_BACKUP_FILE"
        exit 1
    fi
    
    # 清除密码环境变量
    unset MYSQL_PWD
    
    echo "$DB_BACKUP_FILE"
}

# 创建完整备份包
create_backup_package() {
    local env_backup="$1"
    local db_backup="$2"
    
    log_info "创建备份包..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PACKAGE="$BACKUP_DIR/backup_${TIMESTAMP}.tar.gz"
    
    # 创建临时目录
    TEMP_DIR="/tmp/cert_manager_backup_$$"
    mkdir -p "$TEMP_DIR"
    
    # 复制备份文件到临时目录
    cp "$env_backup" "$TEMP_DIR/env.backup"
    cp "$db_backup" "$TEMP_DIR/database.sql.gz"
    
    # 创建备份信息文件
    cat > "$TEMP_DIR/backup_info.txt" <<EOF
备份时间: $(date)
备份类型: 完整备份
系统版本: $(cat "$SITE_ROOT/VERSION" 2>/dev/null || echo "未知")
数据库: $DB_DATABASE

包含文件:
- env.backup        (.env 配置文件)
- database.sql.gz   (数据库备份)

恢复方法:
$0 restore $(basename "$BACKUP_PACKAGE")
EOF
    
    # 创建压缩包
    cd "$TEMP_DIR"
    tar -czf "$BACKUP_PACKAGE" .
    cd - > /dev/null
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
    
    # 删除单独的备份文件
    rm -f "$env_backup" "$db_backup"
    
    # 获取包大小
    PACKAGE_SIZE=$(du -h "$BACKUP_PACKAGE" | cut -f1)
    log_success "备份包创建完成: $(basename "$BACKUP_PACKAGE") ($PACKAGE_SIZE)"
    
    echo "$BACKUP_PACKAGE"
}

# 执行备份
do_backup() {
    log_info "============================================"
    log_info "开始备份"
    log_info "保留备份数: $KEEP_BACKUPS"
    log_info "============================================"
    
    # 验证环境
    validate_environment
    
    # 读取数据库配置
    read_db_config
    
    # 备份 .env 文件
    ENV_BACKUP=$(backup_env)
    
    # 备份数据库
    DB_BACKUP=$(backup_database)
    
    # 创建备份包
    BACKUP_PACKAGE=$(create_backup_package "$ENV_BACKUP" "$DB_BACKUP")
    
    log_success "============================================"
    log_success "备份完成！"
    log_success "备份文件: $(basename "$BACKUP_PACKAGE")"
    log_success "备份大小: $(du -h "$BACKUP_PACKAGE" | cut -f1)"
    log_success "============================================"
}

# 列出备份文件
list_backups() {
    log_info "当前备份文件:"
    echo
    
    # 查找备份文件
    BACKUP_FILES=$(find "$BACKUP_DIR" -name "backup_*.tar.gz" -type f | sort -r)
    
    if [ -z "$BACKUP_FILES" ]; then
        log_warning "没有找到备份文件"
        return
    fi
    
    # 显示备份文件列表
    echo "文件名                        大小      创建时间"
    echo "--------------------------------------------------------"
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            FILENAME=$(basename "$file")
            SIZE=$(du -h "$file" | cut -f1)
            # 从文件名提取时间戳
            TIMESTAMP=$(echo "$FILENAME" | grep -oP 'backup_\K\d{8}_\d{6}')
            if [ -n "$TIMESTAMP" ]; then
                DATE_PART=$(echo "$TIMESTAMP" | cut -d'_' -f1)
                TIME_PART=$(echo "$TIMESTAMP" | cut -d'_' -f2)
                FORMATTED_DATE="${DATE_PART:0:4}-${DATE_PART:4:2}-${DATE_PART:6:2}"
                FORMATTED_TIME="${TIME_PART:0:2}:${TIME_PART:2:2}:${TIME_PART:4:2}"
                printf "%-28s %-8s %s %s\\n" "$FILENAME" "$SIZE" "$FORMATTED_DATE" "$FORMATTED_TIME"
            else
                printf "%-28s %-8s %s\\n" "$FILENAME" "$SIZE" "未知时间"
            fi
        fi
    done <<< "$BACKUP_FILES"
    echo
}

# 恢复备份
restore_backup() {
    local backup_file="$1"
    
    if [ -z "$backup_file" ]; then
        log_error "请指定要恢复的备份文件"
        log_info "用法: $0 restore <备份文件名>"
        log_info "使用 '$0 list' 查看可用的备份文件"
        exit 1
    fi
    
    # 检查备份文件路径
    if [[ ! "$backup_file" = /* ]]; then
        # 相对路径，添加备份目录
        backup_file="$BACKUP_DIR/$backup_file"
    fi
    
    if [ ! -f "$backup_file" ]; then
        log_error "备份文件不存在: $backup_file"
        exit 1
    fi
    
    log_warning "============================================"
    log_warning "警告：恢复备份将覆盖当前的配置和数据！"
    log_warning "备份文件: $(basename "$backup_file")"
    log_warning "============================================"
    
    read -p "确定要继续恢复吗？(y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "恢复已取消"
        exit 0
    fi
    
    log_info "开始恢复备份..."
    
    # 创建临时目录
    TEMP_DIR="/tmp/cert_manager_restore_$$"
    mkdir -p "$TEMP_DIR"
    
    # 解压备份文件
    log_info "解压备份文件..."
    if ! tar -xzf "$backup_file" -C "$TEMP_DIR"; then
        log_error "解压备份文件失败"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 验证备份内容
    if [ ! -f "$TEMP_DIR/env.backup" ] || [ ! -f "$TEMP_DIR/database.sql.gz" ]; then
        log_error "备份文件内容不完整"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 显示备份信息
    if [ -f "$TEMP_DIR/backup_info.txt" ]; then
        echo
        log_info "备份信息:"
        cat "$TEMP_DIR/backup_info.txt"
        echo
    fi
    
    # 备份当前文件到keeper目录的restore子目录
    RESTORE_BACKUP_DIR="$BACKUP_DIR/restore_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$RESTORE_BACKUP_DIR"
    
    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "$RESTORE_BACKUP_DIR/env.backup"
        log_info "当前 .env 文件已备份到: $RESTORE_BACKUP_DIR"
    fi
    
    # 恢复 .env 文件
    log_info "恢复 .env 文件..."
    cp "$TEMP_DIR/env.backup" "$ENV_FILE"
    log_success ".env 文件已恢复"
    
    # 读取恢复后的数据库配置
    read_db_config
    
    # 恢复数据库
    log_info "恢复数据库..."
    
    # 检查 mysql 命令
    if ! command -v mysql &> /dev/null; then
        log_error "mysql 命令未找到"
        log_error "请安装 MySQL 客户端: apt-get install mysql-client"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 设置密码环境变量（如果有密码）
    if [ -n "$DB_PASSWORD" ]; then
        export MYSQL_PWD="$DB_PASSWORD"
    fi
    
    # 恢复数据库
    if zcat "$TEMP_DIR/database.sql.gz" | mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" "$DB_DATABASE"; then
        log_success "数据库恢复完成"
    else
        log_error "数据库恢复失败"
        log_error "请检查数据库连接配置和权限"
        # 恢复原来的 .env 文件
        if [ -f "$RESTORE_BACKUP_DIR/env.backup" ]; then
            cp "$RESTORE_BACKUP_DIR/env.backup" "$ENV_FILE"
            log_info "已恢复原始 .env 文件"
        fi
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 清除密码环境变量
    unset MYSQL_PWD
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
    
    log_success "============================================"
    log_success "恢复完成！"
    log_success "原始文件备份位置: $RESTORE_BACKUP_DIR"
    log_success "============================================"
}

# 清理旧备份
clean_backups() {
    log_info "清理过期备份文件（保留最近 $KEEP_BACKUPS 份）..."
    
    # 清理主备份文件
    BACKUP_FILES=$(find "$BACKUP_DIR" -name "backup_*.tar.gz" -type f | sort -r)
    BACKUP_COUNT=$(echo "$BACKUP_FILES" | wc -l)
    
    if [ "$BACKUP_COUNT" -gt "$KEEP_BACKUPS" ]; then
        echo "$BACKUP_FILES" | tail -n +$((KEEP_BACKUPS + 1)) | while read -r file; do
            if [ -f "$file" ]; then
                log_info "删除过期备份: $(basename "$file")"
                rm -f "$file"
            fi
        done
    fi
    
    # 清理零散的备份文件
    find "$BACKUP_DIR" -name "env_*.backup" -type f -mtime +$KEEP_BACKUPS -delete 2>/dev/null || true
    find "$BACKUP_DIR" -name "db_*.sql.gz" -type f -mtime +$KEEP_BACKUPS -delete 2>/dev/null || true
    
    log_success "备份清理完成"
}

# 主函数
main() {
    case "$ACTION" in
        backup)
            do_backup
            # 自动清理旧备份
            clean_backups
            ;;
        restore)
            restore_backup "$2"
            ;;
        list)
            list_backups
            ;;
        clean)
            clean_backups
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "无效的操作: $ACTION"
            echo
            show_usage
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"