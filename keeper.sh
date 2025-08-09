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
KEEP_BACKUPS=${KEEP_BACKUPS:-30}

# 操作模式
ACTION="${1:-backup}"

# 临时目录变量
TEMP_DIR=""

# 清理函数
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# 设置退出陷阱
trap cleanup EXIT INT TERM

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
    echo "  check           检查数据库大小和优化建议"
    echo "  help            显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  KEEP_BACKUPS    保留的备份数量（默认：30）"
    echo ""
    echo "示例:"
    echo "  $0                                    # 备份"
    echo "  $0 restore backup_20231201_120000.tar.gz   # 恢复备份"
    echo "  $0 list                              # 列出备份"
    echo "  $0 check                             # 检查数据库"
    echo "  KEEP_BACKUPS=14 $0 clean            # 保留14个备份"
    echo ""
    echo "大数据库优化:"
    echo "  - 自动排除 _logs 后缀表"
    echo "  - 使用 --quick 避免内存缓存"
    echo "  - 支持压缩传输和存储"
    echo "  - 显示进度提示（安装 pv 命令可视化进度）"
}

# 检查数据库大小和提供优化建议
check_database() {
    log_info "检查数据库状态和大小..."
    
    # 验证环境
    if [ ! -f "$ENV_FILE" ]; then
        log_error ".env 文件不存在"
        exit 1
    fi
    
    # 读取数据库配置
    read_db_config
    
    # 设置密码环境变量（如果有密码）
    if [ -n "$DB_PASSWORD" ]; then
        export MYSQL_PWD="$DB_PASSWORD"
    fi
    
    echo
    log_info "=== 数据库统计信息 ==="
    
    # 获取数据库总大小
    TOTAL_SIZE=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" "$DB_DATABASE" \
        -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size_MB' \
            FROM information_schema.tables WHERE table_schema='$DB_DATABASE';" \
        -s 2>/dev/null | tail -1 || echo "0")
    
    log_info "数据库总大小: ${TOTAL_SIZE}MB"
    
    # 获取表统计
    echo
    log_info "各表大小统计:"
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" "$DB_DATABASE" \
        -e "SELECT 
            table_name AS 'Table',
            ROUND(((data_length + index_length) / 1024 / 1024), 2) AS 'Size_MB',
            table_rows AS 'Rows'
            FROM information_schema.tables 
            WHERE table_schema = '$DB_DATABASE' 
            ORDER BY (data_length + index_length) DESC
            LIMIT 10;" 2>/dev/null || log_error "无法获取表统计信息"
    
    # 统计日志表
    echo
    log_info "日志表统计（将被排除）:"
    LOG_TABLES=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" "$DB_DATABASE" \
        -e "SELECT table_name FROM information_schema.tables 
            WHERE table_schema = '$DB_DATABASE' AND table_name LIKE '%_logs';" \
        -s 2>/dev/null | grep -v "^table_name$" || echo "")
    
    if [ -n "$LOG_TABLES" ]; then
        while IFS= read -r table; do
            if [ -n "$table" ]; then
                SIZE=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" "$DB_DATABASE" \
                    -e "SELECT ROUND(((data_length + index_length) / 1024 / 1024), 2) \
                        FROM information_schema.tables 
                        WHERE table_schema = '$DB_DATABASE' AND table_name = '$table';" \
                    -s 2>/dev/null | tail -1 || echo "0")
                log_info "  - $table: ${SIZE}MB"
            fi
        done <<< "$LOG_TABLES"
    else
        log_info "  无日志表"
    fi
    
    # 提供优化建议
    echo
    log_info "=== 优化建议 ==="
    
    if [ "${TOTAL_SIZE%.*}" -gt 1000 ] 2>/dev/null; then
        log_warning "数据库较大（超过1GB），建议："
        log_info "1. 定期清理日志表数据"
        log_info "2. 考虑增加备份磁盘空间"
        log_info "3. 使用定时任务在低峰期备份"
        log_info "4. 安装 pv 命令以显示备份/恢复进度："
        log_info "   Ubuntu/Debian: sudo apt install pv"
        log_info "   CentOS/RHEL: sudo yum install pv"
    elif [ "${TOTAL_SIZE%.*}" -gt 100 ] 2>/dev/null; then
        log_info "数据库大小适中，当前配置可以良好处理"
    else
        log_info "数据库较小，备份恢复会很快完成"
    fi
    
    # 检查磁盘空间
    echo
    check_disk_space
    
    # 估算备份大小（压缩后约为原始大小的20-30%）
    if command -v bc >/dev/null 2>&1; then
        ESTIMATED_BACKUP=$(echo "$TOTAL_SIZE * 0.25" | bc 2>/dev/null || echo "0")
    else
        # 没有bc命令，使用整数运算
        TOTAL_INT=${TOTAL_SIZE%.*}
        if [ -n "$TOTAL_INT" ] && [ "$TOTAL_INT" -gt 0 ] 2>/dev/null; then
            ESTIMATED_BACKUP=$((TOTAL_INT / 4))
        else
            ESTIMATED_BACKUP="未知"
        fi
    fi
    
    if [ "$ESTIMATED_BACKUP" != "未知" ]; then
        log_info "预计备份文件大小: 约${ESTIMATED_BACKUP}MB（压缩后）"
    fi
    
    # 清除密码环境变量
    unset MYSQL_PWD
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
    
    # 检查磁盘空间（至少需要1GB可用空间）
    check_disk_space
    
    # 检查MySQL客户端工具版本（用于大数据处理）
    if command -v mysql >/dev/null 2>&1; then
        MYSQL_VERSION=$(mysql --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_info "MySQL客户端版本: $MYSQL_VERSION"
    fi
}

# 检查磁盘空间
check_disk_space() {
    local MIN_SPACE_MB=1024  # 最小需要1GB
    local AVAILABLE_SPACE_KB=$(df "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    local AVAILABLE_SPACE_MB=$((AVAILABLE_SPACE_KB / 1024))
    
    if [ "$AVAILABLE_SPACE_MB" -lt "$MIN_SPACE_MB" ]; then
        log_error "磁盘空间不足！"
        log_error "可用空间: ${AVAILABLE_SPACE_MB}MB"
        log_error "最小需要: ${MIN_SPACE_MB}MB"
        log_info "请清理磁盘空间或使用 '$0 clean' 清理旧备份"
        exit 1
    else
        log_info "磁盘空间检查通过（可用: ${AVAILABLE_SPACE_MB}MB）"
    fi
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
    
    # 返回文件路径（使用全局变量而不是echo）
    RETURN_ENV_BACKUP="$ENV_BACKUP_FILE"
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
    
    # 设置密码环境变量（如果有密码）
    if [ -n "$DB_PASSWORD" ]; then
        export MYSQL_PWD="$DB_PASSWORD"
    fi
    
    # 获取所有_logs后缀的表，用于排除
    log_info "分析数据表结构..."
    ALL_TABLES=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" "$DB_DATABASE" \
        -e "SHOW TABLES;" -s 2>/dev/null | grep -v "^Tables_in_" || true)
    
    if [ -z "$ALL_TABLES" ]; then
        log_error "数据库中没有找到任何表"
        exit 1
    fi
    
    # 分离出需要排除的日志表
    LOG_TABLES=$(echo "$ALL_TABLES" | grep "_logs$" || true)
    NORMAL_TABLES=$(echo "$ALL_TABLES" | grep -v "_logs$" || true)
    
    # 统计表数量
    TOTAL_COUNT=$(echo "$ALL_TABLES" | wc -l)
    LOG_COUNT=$(echo "$LOG_TABLES" | grep -c . || echo 0)
    NORMAL_COUNT=$(echo "$NORMAL_TABLES" | grep -c . || echo 0)
    
    log_info "数据库共有 $TOTAL_COUNT 个表"
    log_info "将备份 $NORMAL_COUNT 个业务表，排除 $LOG_COUNT 个日志表"
    
    # 构建mysqldump基础命令，添加防超时和优化参数
    DUMP_CMD="mysqldump -h $DB_HOST -P $DB_PORT -u $DB_USERNAME"
    
    # 重要参数说明：
    # --single-transaction: 确保InnoDB表的一致性备份
    # --quick: 不缓存查询，直接输出（处理大表）
    # --lock-tables=false: 不锁表，避免影响业务
    # --skip-lock-tables: 跳过LOCK TABLES语句
    # --compress: 压缩客户端/服务器协议
    # --max_allowed_packet=1024M: 允许大数据包
    # --net_buffer_length=32K: 网络缓冲区大小
    DUMP_OPTIONS="--single-transaction --quick --lock-tables=false --skip-lock-tables"
    DUMP_OPTIONS="$DUMP_OPTIONS --routines --triggers --events --hex-blob"
    DUMP_OPTIONS="$DUMP_OPTIONS --default-character-set=utf8mb4"
    DUMP_OPTIONS="$DUMP_OPTIONS --max_allowed_packet=1024M --net_buffer_length=32K"
    DUMP_OPTIONS="$DUMP_OPTIONS --compress"
    
    # 构建--ignore-table参数列表
    IGNORE_TABLES=""
    if [ -n "$LOG_TABLES" ]; then
        while IFS= read -r table; do
            if [ -n "$table" ]; then
                IGNORE_TABLES="$IGNORE_TABLES --ignore-table=$DB_DATABASE.$table"
            fi
        done <<< "$LOG_TABLES"
    fi
    
    # 显示将要排除的表（如果有）
    if [ -n "$LOG_TABLES" ] && [ "$LOG_COUNT" -gt 0 ]; then
        log_info "排除的日志表（共 $LOG_COUNT 个）:"
        echo "$LOG_TABLES" | while IFS= read -r table; do
            [ -n "$table" ] && log_info "  - $table"
        done
    fi
    
    # 执行备份，添加重试机制
    log_info "开始导出数据库 $DB_DATABASE..."
    
    # 获取数据库大小估算
    DB_SIZE=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" \
        -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) AS 'DB Size in MB' \
            FROM information_schema.tables WHERE table_schema='$DB_DATABASE';" \
        -s 2>/dev/null | tail -1 || echo "unknown")
    
    if [ "$DB_SIZE" != "unknown" ]; then
        log_info "数据库大小: ${DB_SIZE}MB"
        
        # 如果数据库超过100MB，给出提示
        if [ "${DB_SIZE%.*}" -gt 100 ] 2>/dev/null; then
            log_warning "数据库较大，备份可能需要较长时间..."
        fi
    fi
    
    RETRY_COUNT=0
    MAX_RETRIES=3
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if [ $RETRY_COUNT -gt 0 ]; then
            log_warning "第 $RETRY_COUNT 次重试..."
            sleep 5
        fi
        
        # 执行备份命令（带进度提示）
        if [ "${DB_SIZE%.*}" -gt 100 ] 2>/dev/null || [ "$DB_SIZE" = "unknown" ]; then
            # 大数据库或未知大小，显示进度提示
            log_info "正在导出数据..."
            (
                while true; do
                    echo -n "."
                    sleep 3
                done
            ) &
            PROGRESS_PID=$!
            
            if $DUMP_CMD $DUMP_OPTIONS $IGNORE_TABLES "$DB_DATABASE" > "$DB_BACKUP_FILE" 2>/tmp/mysqldump_error.log; then
                kill $PROGRESS_PID 2>/dev/null
                echo  # 换行
                BACKUP_SUCCESS=1
            else
                kill $PROGRESS_PID 2>/dev/null
                echo  # 换行
                BACKUP_SUCCESS=0
            fi
        else
            # 小数据库，直接导出
            if $DUMP_CMD $DUMP_OPTIONS $IGNORE_TABLES "$DB_DATABASE" > "$DB_BACKUP_FILE" 2>/tmp/mysqldump_error.log; then
                BACKUP_SUCCESS=1
            else
                BACKUP_SUCCESS=0
            fi
        fi
        
        if [ $BACKUP_SUCCESS -eq 1 ]; then
            # 备份成功，验证文件
            if [ -f "$DB_BACKUP_FILE" ] && [ -s "$DB_BACKUP_FILE" ]; then
                # 验证SQL文件完整性（检查是否有完整的结束标记）
                if tail -n 10 "$DB_BACKUP_FILE" | grep -q "Dump completed"; then
                    log_success "数据库导出成功"
                    break
                else
                    log_warning "备份文件可能不完整，重新尝试"
                    rm -f "$DB_BACKUP_FILE"
                    RETRY_COUNT=$((RETRY_COUNT + 1))
                fi
            else
                log_error "备份文件为空或不存在"
                RETRY_COUNT=$((RETRY_COUNT + 1))
            fi
        else
            # 显示错误信息
            if [ -f /tmp/mysqldump_error.log ]; then
                ERROR_MSG=$(cat /tmp/mysqldump_error.log | head -3)
                [ -n "$ERROR_MSG" ] && log_error "错误信息: $ERROR_MSG"
            fi
            RETRY_COUNT=$((RETRY_COUNT + 1))
        fi
    done
    
    # 检查是否成功
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        log_error "数据库备份失败（已重试 $MAX_RETRIES 次）"
        log_error "请检查："
        log_error "1. 数据库连接是否正常"
        log_error "2. 用户权限是否足够"
        log_error "3. 磁盘空间是否充足"
        [ -f "$DB_BACKUP_FILE" ] && rm -f "$DB_BACKUP_FILE"
        [ -f /tmp/mysqldump_error.log ] && rm -f /tmp/mysqldump_error.log
        exit 1
    fi
    
    # 压缩备份文件
    log_info "压缩备份文件..."
    gzip -9 "$DB_BACKUP_FILE"
    DB_BACKUP_FILE="${DB_BACKUP_FILE}.gz"
    
    # 验证压缩文件
    if ! gzip -t "$DB_BACKUP_FILE" 2>/dev/null; then
        log_error "压缩文件验证失败"
        exit 1
    fi
    
    # 获取文件大小和表统计
    FILE_SIZE=$(du -h "$DB_BACKUP_FILE" | cut -f1)
    log_success "数据库备份完成: $(basename "$DB_BACKUP_FILE") ($FILE_SIZE)"
    log_success "成功备份 $NORMAL_COUNT 个业务表，排除了 $LOG_COUNT 个日志表"
    
    # 清理临时文件
    [ -f /tmp/mysqldump_error.log ] && rm -f /tmp/mysqldump_error.log
    
    # 清除密码环境变量
    unset MYSQL_PWD
    
    # 返回文件路径（使用全局变量而不是echo）
    RETURN_DB_BACKUP="$DB_BACKUP_FILE"
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
系统版本: $(jq -r '.version' "$SITE_ROOT/info.json" 2>/dev/null || echo "未知")
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
    
    # 删除单独的备份文件
    rm -f "$env_backup" "$db_backup"
    
    # 获取包大小
    PACKAGE_SIZE=$(du -h "$BACKUP_PACKAGE" | cut -f1)
    log_success "备份包创建完成: $(basename "$BACKUP_PACKAGE") ($PACKAGE_SIZE)"
    
    # 返回文件路径（使用全局变量而不是echo）
    RETURN_BACKUP_PACKAGE="$BACKUP_PACKAGE"
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
    backup_env
    ENV_BACKUP="$RETURN_ENV_BACKUP"
    
    # 备份数据库
    backup_database
    DB_BACKUP="$RETURN_DB_BACKUP"
    
    # 创建备份包
    create_backup_package "$ENV_BACKUP" "$DB_BACKUP"
    BACKUP_PACKAGE="$RETURN_BACKUP_PACKAGE"
    
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
            # 从文件名提取时间戳（兼容性更好的方法）
            TIMESTAMP=$(echo "$FILENAME" | sed -n 's/.*backup_\([0-9]\{8\}_[0-9]\{6\}\).*/\1/p')
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
        exit 1
    fi
    
    # 验证备份内容
    if [ ! -f "$TEMP_DIR/env.backup" ] || [ ! -f "$TEMP_DIR/database.sql.gz" ]; then
        log_error "备份文件内容不完整"
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
        exit 1
    fi
    
    # 设置密码环境变量（如果有密码）
    if [ -n "$DB_PASSWORD" ]; then
        export MYSQL_PWD="$DB_PASSWORD"
    fi
    
    # 恢复数据库（优化大数据处理）
    log_info "开始恢复数据库（可能需要较长时间）..."
    
    # 构建mysql命令，添加优化参数
    MYSQL_CMD="mysql -h $DB_HOST -P $DB_PORT -u $DB_USERNAME"
    # 优化参数：
    # --max_allowed_packet=1024M: 支持大数据包
    # --connect-timeout=60: 连接超时60秒
    # --compress: 使用压缩协议
    MYSQL_OPTIONS="--max_allowed_packet=1024M --connect-timeout=60 --compress"
    
    # 显示文件大小
    FILE_SIZE=$(du -h "$TEMP_DIR/database.sql.gz" | cut -f1)
    log_info "备份文件大小: $FILE_SIZE"
    
    # 恢复数据库，添加进度提示
    if command -v pv >/dev/null 2>&1; then
        # 如果有pv命令，显示进度
        log_info "正在恢复数据库（显示进度）..."
        if pv "$TEMP_DIR/database.sql.gz" | zcat | $MYSQL_CMD $MYSQL_OPTIONS "$DB_DATABASE" 2>/tmp/mysql_restore_error.log; then
            log_success "数据库恢复完成"
        else
            RESTORE_ERROR=1
        fi
    else
        # 没有pv命令，使用普通方式但添加提示
        log_info "正在恢复数据库..."
        log_info "提示：安装 pv 命令可以显示恢复进度 (apt install pv)"
        
        # 使用后台进程显示点号表示进度
        (
            while true; do
                echo -n "."
                sleep 2
            done
        ) &
        PROGRESS_PID=$!
        
        if zcat "$TEMP_DIR/database.sql.gz" | $MYSQL_CMD $MYSQL_OPTIONS "$DB_DATABASE" 2>/tmp/mysql_restore_error.log; then
            kill $PROGRESS_PID 2>/dev/null
            echo  # 换行
            log_success "数据库恢复完成"
        else
            kill $PROGRESS_PID 2>/dev/null
            echo  # 换行
            RESTORE_ERROR=1
        fi
    fi
    
    # 处理恢复错误
    if [ "${RESTORE_ERROR:-0}" -eq 1 ]; then
        log_error "数据库恢复失败"
        
        # 显示错误信息
        if [ -f /tmp/mysql_restore_error.log ]; then
            ERROR_MSG=$(head -5 /tmp/mysql_restore_error.log)
            [ -n "$ERROR_MSG" ] && log_error "错误信息: $ERROR_MSG"
            rm -f /tmp/mysql_restore_error.log
        fi
        
        log_error "可能的原因："
        log_error "1. 数据库连接配置错误"
        log_error "2. 用户权限不足"
        log_error "3. 磁盘空间不足"
        log_error "4. 数据库文件过大导致超时"
        
        # 恢复原来的 .env 文件
        if [ -f "$RESTORE_BACKUP_DIR/env.backup" ]; then
            cp "$RESTORE_BACKUP_DIR/env.backup" "$ENV_FILE"
            log_info "已恢复原始 .env 文件"
        fi
        exit 1
    fi
    
    # 清除密码环境变量
    unset MYSQL_PWD
    
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
        check)
            check_database
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