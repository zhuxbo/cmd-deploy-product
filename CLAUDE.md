# 证书管理系统生产部署脚本 - Claude 上下文文件

## 项目概述

这是证书管理系统的生产环境部署脚本项目，负责在生产服务器上部署和维护证书管理系统。使用从 production-code 仓库获取的预构建代码进行部署。

## 核心功能

### 部署流程

1. **环境依赖安装**: 安装 PHP 8.3+、Redis、Supervisor 等运行环境
2. **初始部署**: 克隆生产代码、配置数据库、初始化 Laravel
3. **系统更新**: 拉取最新代码、保留用户配置、重启服务
4. **数据备份**: 备份数据库和配置文件

### 支持特性

- **多系统支持**: Ubuntu/Debian、CentOS/RHEL、Fedora
- **宝塔面板兼容**: 特殊处理宝塔环境
- **模块化更新**: 支持单独更新 api/admin/user/easy/nginx
- **文件保留**: 自动保留用户配置和数据（特别是 frontend/web 目录）
- **服务管理**: 非宝塔环境自动配置、宝塔环境提供手动指引

## 文件结构

```
cmd-deploy-product/
├── install.sh          # 首次安装脚本
├── install-deps.sh     # 依赖检查脚本（标准环境）
├── install-deps-bt.sh  # PHP配置脚本（宝塔环境）
├── setup-queue.sh      # 队列和定时任务设置脚本
├── update.sh           # 系统更新脚本
├── keeper.sh           # 备份管理脚本
├── claude.md           # 本文档（Claude 上下文）
└── readme.md           # 用户文档
```

## 核心脚本功能

### install.sh - 首次安装

**职责：**
- 克隆 production-code 仓库
- 备份现有系统（如果存在）
- 部署所有文件（包括 backend、frontend、nginx）
- frontend/web 目录从生产代码仓库复制
- 初始化 Laravel 应用
- 配置文件权限
- **专注于部署代码**，不处理队列和定时任务
- 提示用户：
  - 宝塔环境：手动配置队列和定时任务
  - 非宝塔环境：运行 setup-queue.sh

### install-deps.sh - 依赖检查（标准环境）

**职责：**
- 检测 PHP 8.3+ 和必需扩展
- 检测 MySQL、Redis、Nginx 服务
- 检测 Composer 安装状态
- **不自动安装**，仅提供安装指引
- 宝塔环境自动引导到 install-deps-bt.sh

### install-deps-bt.sh - PHP配置（宝塔环境）

**职责：**
- 检测并选择宝塔 PHP 版本
- 启用被禁用的 PHP 函数
- 检测和卸载冲突的系统 PHP
- 设置默认 PHP 版本链接
- 检查并修复 Composer

### setup-queue.sh - 队列和定时任务设置

**职责：**
- 检测运行环境（宝塔/标准）
- 宝塔环境：输出手动配置步骤
- 标准环境：自动配置 Supervisor 和 Crontab
- 使用站点名避免多站点冲突
- 独立于 install.sh，可单独运行

### update.sh - 系统更新

**职责：**
- 拉取最新生产代码
- 创建时间戳备份
- 保留重要文件
- **永不覆盖 frontend/web 目录**
- 部署新文件（仅更新 admin/user/easy）
- Laravel 缓存清理
- 服务重启
- 支持模块化更新
- 支持备份恢复

### keeper.sh - 备份管理

**职责：**
- 数据库备份（排除 _logs 表）
- 配置文件备份（.env）
- 轮转机制（默认保留 30 个备份）
- 备份验证
- 支持备份恢复
- 支持定时任务

## 关键配置

### 保留文件配置 (update-config.json)

```json
{
  "preserve_files": {
    "backend": {
      "env_file": ".env",
      "user_data": ["storage/app/public", "storage/logs"]
    },
    "frontend": {
      "admin": ["platform-config.json", "logo.svg"],
      "user": ["platform-config.json", "logo.svg", "qrcode.png", "favicon.ico"],
      "easy": ["config.json"],
      "web": ["*"] // 整个目录都保留，永不更新
    }
  },
  "services": {
    "nginx": {
      "restart_command": "sudo systemctl restart nginx"
    },
    "queue": {
      "restart_command": "sudo supervisorctl restart laravel-worker:*"
    }
  }
}
```

## 环境要求

### 系统支持

- **Ubuntu/Debian**: 完全支持
- **CentOS/RHEL**: 支持 7.x/8.x/9.x
- **Fedora**: 最新版本支持
- **宝塔面板**: 特殊适配处理

### 必需软件（需预先安装）

- **PHP 8.3+**: 包含必要扩展
  - **composer.json 明确要求**：bcmath, calendar, fileinfo, gd, iconv, intl, json, mbstring, openssl, pcntl, pdo, redis, zip
  - **Laravel 框架需要**：ctype, curl, dom, pdo_mysql, tokenizer, xml
  - **性能优化（推荐）**：opcache
- **Web 服务器**: Nginx
- **数据库**: MySQL 5.7+ 或 MariaDB 10.3+
- **缓存**: Redis 6.0+
- **队列**: Supervisor

## 使用方法

### 首次部署

```bash
# 1. 检查系统依赖（不会自动安装）
./install-deps.sh  # 标准环境
./install-deps-bt.sh  # 宝塔环境

# 2. 执行首次安装（会自动从生产代码仓库复制 frontend/web）
./install.sh

# 3. 配置 Nginx（手动）
# 在站点配置中引入：
# root /path/to/site;
# include /path/to/site/nginx/manager.conf;

# 4. 访问安装向导（会自动处理数据库配置）
# http://your-domain/install

# 5. 设置队列和定时任务
./setup-queue.sh  # 非宝塔环境自动配置
# 宝塔环境需手动配置
```

### 系统更新

```bash
# 更新所有模块
./update.sh

# 更新特定模块
./update.sh api      # 仅更新后端
./update.sh admin    # 仅更新管理端
./update.sh user     # 仅更新用户端
./update.sh easy     # 仅更新简易端

# 强制更新
FORCE_UPDATE=1 ./update.sh
```

### 数据备份

```bash
# 创建备份
./keeper.sh backup

# 列出备份
./keeper.sh list

# 恢复备份
./keeper.sh restore backup_20250806_143022
```

## 部署目录结构

```
部署根目录/
├── backend/             # Laravel 后端
│   ├── app/
│   ├── public/
│   ├── storage/
│   ├── .env             # 环境配置（保留）
│   └── ...
├── frontend/            # 前端文件
│   ├── admin/           # 管理端
│   │   ├── platform-config.json  # 保留
│   │   └── logo.svg              # 保留
│   ├── user/            # 用户端
│   │   ├── platform-config.json  # 保留
│   │   ├── logo.svg              # 保留
│   │   ├── qrcode.png            # 保留
│   │   └── favicon.ico           # 保留
│   ├── easy/            # 简易端
│   │   └── config.json           # 保留
│   └── web/             # 静态文件（永不更新）
│       ├── index.php    # 入口文件
│       └── favicon.ico  # 网站图标
├── nginx/               # Nginx 配置
├── backup/              # 备份目录
│   ├── install/         # 安装备份
│   ├── update/          # 更新备份
│   └── keeper/          # 数据备份
├── cmd-deploy-scripts/  # 部署脚本
│   └── source/          # 源码
└── config.json            # 构建信息（包含版本）
```

## 关键技术处理

### Shell 脚本错误处理（重要）

- **set -e 问题**: 所有脚本使用了 `set -e` 使错误时自动退出
- **函数返回值陷阱**: 
  - 某些函数使用非零返回值表示状态（如 `check_composer` 返回 2 表示需要升级）
  - 在 `set -e` 环境下，非零返回值会导致脚本意外退出
- **解决方案**:
  - 在主函数中使用 `set +e` 禁用错误退出
  - 在 `if` 语句中调用可能返回非零值的函数
  - 需要忽略错误时使用 `|| true`
- **经验教训**: 设计函数返回值时要考虑 `set -e` 的影响

### 宝塔面板支持

- **环境检测**: 自动检测宝塔环境和 PHP 版本
- **PHP 函数启用**: 自动修改 FPM 和 CLI 配置文件，启用必需的 PHP 函数
- **扩展自动安装**: 通过系统包管理器自动安装 16 个常用 PHP 扩展
  - 自动安装: bcmath, ctype, curl, dom, gd, iconv, intl, json, openssl, pcntl, pcre, pdo, pdo_mysql, tokenizer, xml, zip
  - 手动安装: calendar, fileinfo, mbstring, redis
- **Composer 管理**: 自动检查、安装和升级 Composer 到推荐版本
- **安装校验**: 扩展安装后重新检测，确保安装成功
- **服务重启**: 扩展安装后自动重启 PHP-FPM 服务
- **队列配置**: 提示手工设置守护进程和定时任务
- **兼容性处理**: 避免与面板管理冲突

### 文件保留机制

- 更新前保存重要文件到临时目录
- 完全清理部署目录避免残留
- 部署完成后恢复保留文件
- 支持复杂的目录结构保留

### 服务管理

- 自动检测 Nginx、队列运行状态
- 更新时停止相关服务
- 完成后重启服务
- 处理启动失败情况

### 输出格式规范

- **无图标设计**: 所有脚本输出均不使用 emoji 图标，确保服务器环境兼容性
- **状态指示器**: 使用文本标识替代图标
  - `[OK]` 表示成功/通过
  - `[FAIL]` 表示失败/错误
  - `[MISSING]` 表示缺失/需要安装
  - `[DISABLED]` 表示被禁用
- **清晰分组**: 功能检查按类型分组显示
  - PHP 函数检查（必需+可选）
  - 自动安装扩展检查
  - 手动安装扩展检查
- **简洁摘要**: 提供统计信息和操作建议

### 权限管理

- 自动检测 Web 用户（www-data/nginx）
- 正确设置 Laravel 目录权限
- 处理多用户环境权限问题

## Nginx 配置

### manager.conf 特点

- **手动引入配置**: 需要在站点配置中手动引入
- **路由优先级**: API > Admin/Easy > User
- **静态资源缓存**: 1 年有效期
- **HTML5 History**: 支持前端路由
- **根目录要求**: 必须在 server 块中设置 root 为站点目录

## 数据库管理

### 迁移策略

- 首次安装运行完整迁移
- 更新时运行增量迁移
- 支持回滚机制
- 备份验证数据完整性

### 备份轮转

- 自动删除过期备份
- 保留最新 N 个备份
- 压缩存储节省空间
- 备份文件完整性验证

## 监控和日志

### Laravel 日志

- 位置: `backend/storage/logs/`
- 轮转: 按日分割
- 级别: 可配置

### 系统服务日志

- Nginx: `/var/log/nginx/`
- PHP-FPM: `/var/log/php8.3-fpm/`
- Supervisor: `/var/log/supervisor/`

## 故障排查

### 常见问题

1. **权限错误**: 检查 storage、cache 目录权限
2. **扩展缺失**: 使用 install-deps.sh 安装
3. **数据库连接**: 检查 .env 配置
4. **队列不工作**: 检查 Supervisor 配置
5. **静态文件 404**: 检查 Nginx 配置路径

### 日志查看

```bash
# Laravel 错误日志
tail -f backend/storage/logs/laravel.log

# Nginx 错误日志
sudo tail -f /var/log/nginx/error.log

# 队列日志
sudo supervisorctl tail laravel-worker
```

## 与其他仓库关系

- **production-code 仓库**: 获取预构建的部署文件
- **build-script 仓库**: 生成部署所需的文件
- **源码仓库**: 间接关系，通过构建脚本

## 中国大陆镜像源配置

### APT 源（Ubuntu/Debian）

```bash
# 阿里云镜像源
deb http://mirrors.aliyun.com/ubuntu/ focal main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ focal-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ focal-security main restricted universe multiverse

# 清华镜像源（备选）
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal main restricted universe multiverse
```

### YUM/DNF 源（CentOS/RHEL/Rocky/AlmaLinux）

```bash
# 阿里云镜像
baseurl=http://mirrors.aliyun.com/centos/$releasever/os/$basearch/

# 清华镜像（备选）
baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos/$releasever/os/$basearch/
```

### Composer 源

```bash
# 设置阿里云 Composer 镜像
composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/

# 备选：腾讯云镜像
composer config -g repo.packagist composer https://mirrors.cloud.tencent.com/composer/
```

### JDK 下载源

- 优先使用清华镜像：https://mirrors.tuna.tsinghua.edu.cn/AdoptOpenJDK/
- 备选阿里云镜像：https://mirrors.aliyun.com/openjdk/

### NPM 源（如需要）

```bash
npm config set registry https://registry.npmmirror.com
```

## 命令行参数规范

### 参数格式统一
- **不使用双减号**：所有脚本参数统一不使用 `--`，直接使用参数名
- **帮助参数**：`-h` 或 `help`（不是 `--help`）
- **仓库选择**：`gitee` 或 `github`（不是 `--gitee` 或 `--github`）
- **其他参数**：`china`、`intl`、`diagnose`、`check` 等（不带 `--`）

### 参数示例
```bash
# 正确的参数格式
./install.sh gitee           # 不是 --gitee
./update.sh github           # 不是 --github
./install-deps.sh china      # 不是 --china
./install-deps-bt.sh diagnose  # 不是 --diagnose
./setup-queue.sh check       # 不是 --check

# 帮助参数
./script.sh -h               # 短格式
./script.sh help             # 长格式（不带 --）
```

## 最近更新

- **2025-12-10**: 部署脚本功能增强
  - install.sh 和 update.sh 均自动替换 `frontend/web/web.conf` 中的 `__PROJECT_ROOT__` 路径
  - update.sh 后端更新后自动运行 `php artisan migrate --force` 和 `php artisan db:seed --force`
  - 使用 `--force` 参数忽略 Laravel 生产模式提示

- **2025-08-23**: 重大架构调整
  - **依赖管理模式变更**: install-deps.sh 从安装改为仅检查，要求管理员预先安装服务
  - **Nginx 配置方式变更**: 取消自动配置，改为手动引入 manager.conf
  - **frontend/web 目录保护**: 更新时永不覆盖该目录，用于存放静态文件
  - **脚本职责分离**: install.sh 专注部署代码，setup-queue.sh 负责队列和定时任务
  - **访问路径简化**: 安装向导从 /install.php 改为 /install

- **2025-08-18**: 统一参数格式规范
  - 所有脚本参数去掉 `--` 双减号，统一使用简洁格式
  - install.sh 和 update.sh: `gitee`、`github` 参数
  - install-deps.sh 和 install-deps-bt.sh: `china`、`intl`、`diagnose` 参数
  - setup-queue.sh: `check` 参数
  - keeper.sh: 保持 `help`、`-h` 参数
  - 更新所有文档中的参数示例
- **2025-08-18**: 添加仓库源选择功能
  - install.sh 和 update.sh 添加 `gitee` 和 `github` 参数支持
  - 允许用户强制指定从特定仓库（Gitee 或 GitHub）拉取代码
  - 未指定时保持原有的自动切换逻辑（优先 Gitee，失败时自动切换到 GitHub）
  - 强制指定仓库时，如果指定仓库失败则直接报错，不会自动切换
- **2025-08-15**: 修复关键问题和优化
  - 修复 `set -e` 导致 Composer 升级不执行的问题
  - 修复海外腾讯云（如新加坡）被误判为中国服务器的问题  
  - 优化地理位置检测，所有网络操作限制 1 秒超时
  - 添加 `--china` 和 `--intl` 命令行参数支持
  - 改进下载验证流程，避免卡住
  - 更新文档记录 Shell 脚本错误处理经验
- **2025-08-09**: 重要更新和优化
  - 简化 install-deps-bt.sh，移除非宝塔相关代码（减少 65%）
  - 添加 JDK 17+ 自动检测和安装功能（宝塔和标准环境）
  - 改进诊断逻辑，实现针对性修复而非盲目执行
  - 添加 Composer wrapper 检测和修复功能
  - 添加系统 PHP 冲突检测和移除功能
  - update.sh 添加 jq 自动安装功能
  - JDK 模块独立化，与 Composer 分离
  - **所有脚本配置中国大陆镜像源**，提升下载速度和稳定性
- **2025-08-07**: 完善宝塔环境自动化处理和输出格式规范化
  - 实现 PHP 扩展自动安装功能，支持 16 个常用扩展
  - 宝塔环境自动处理 Composer 版本升级
  - 添加扩展安装后的校验逻辑，确保安装成功
  - 修复 PHP 版本格式处理和服务重启逻辑
  - 优化输出信息，减少重复提示
  - 规范化输出格式：移除所有 emoji 图标，使用文本状态标识
  - 增强校验详情：显示每个函数和扩展的检查结果
  - 优化 update.sh 的 Nginx 重载逻辑，新增 nginx 更新模块
- **2025-08-06**: 优化 Composer 更新机制，提高宝塔环境兼容性
- **2024-07-30**: 区分容器部署和脚本部署差异
- **2024-07-26**: 简化依赖管理，确保可靠性
- **2024-07-22**: 实现中心化配置管理
- **2024-07-21**: 统一文件保留和防残留部署机制
