# 证书管理系统生产部署脚本

这是证书管理系统的生产环境部署脚本集，用于从 production-code 仓库部署和维护生产环境。

## 脚本说明

### 核心脚本文件列表

| 脚本文件           | 用途                              | 环境要求     |
| ------------------ | --------------------------------- | ------------ |
| install.sh         | 首次安装脚本                      | 通用         |
| install-deps-bt.sh | 宝塔环境依赖安装                  | 宝塔面板环境 |
| install-deps.sh    | 标准 Linux 环境依赖安装           | 非宝塔环境   |
| setup-queue.sh     | 标准 Linux 环境定时任务和队列设置 | 非宝塔环境   |
| update.sh          | 系统更新脚本                      | 通用         |
| keeper.sh          | 备份管理脚本                      | 通用         |

### 1. install.sh - 首次安装脚本

用于全新安装证书管理系统。

**功能特点：**

- 从 production-code 仓库拉取生产代码
- 自动备份现有部署（如果存在）
- 部署所有系统文件
- 初始化 Laravel 环境
- 设置正确的文件权限
- 自动配置定时任务和队列守护进程（使用站点名避免多站点冲突）
- 安装完成后提示是否执行依赖检查

**使用方法：**

```bash
./install.sh                # 自动选择最优仓库
./install.sh --gitee        # 强制从 Gitee 拉取代码
./install.sh --github       # 强制从 GitHub 拉取代码
```

**后续步骤：**

1. 编辑数据库配置：`vim backend/.env`
2. 配置 Nginx：将 nginx/manager.conf 链接到系统配置
3. 访问 `/install.php` 完成系统安装
4. 删除安装文件：`rm backend/public/install.php`

### 2. install-deps-bt.sh - 宝塔环境依赖安装脚本

专门用于宝塔面板环境的 PHP 依赖配置。

**功能特点：**

- 检测并选择宝塔 PHP 版本（8.3+）
- 自动启用被禁用的 PHP 函数（exec, putenv, proc_open 等）
- 检测和卸载冲突的系统 PHP 包
- 设置默认 PHP 版本链接
- 检查并修复 Composer wrapper 问题
- 深度诊断模式（-d 参数）

**使用方法：**

```bash
# 正常运行
sudo ./install-deps-bt.sh

# 诊断模式（排查问题）
sudo ./install-deps-bt.sh -d
```

**宝塔环境要求：**

- 已安装 PHP 8.3 或更高版本
- 手动安装以下扩展：calendar, fileinfo, mbstring, redis
- 其他扩展宝塔通常已预装

### 3. install-deps.sh - 标准 Linux 环境依赖安装脚本

专门用于标准 Linux 环境的 PHP 依赖安装。

**功能特点：**

- 自动检测系统类型（Ubuntu/Debian/CentOS/RHEL/Fedora/openSUSE）
- 安装 PHP 8.3+ 及所有必需扩展
- 配置 PHP 优化参数
- 安装 Redis、Nginx、Git 等附加依赖
- 安装并配置 Composer
- 自动检测宝塔环境并引导使用正确脚本

**使用方法：**

```bash
./install-deps.sh
```

**支持的系统：**

- Ubuntu 18.04+
- Debian 9+
- CentOS 7+
- RHEL 7+
- Fedora 30+
- openSUSE Leap 15+

### 4. setup-queue.sh - 自动设置定时任务和队列

宝塔环境输出设置方法，标准 Linux 环境自动设置。

**使用方法：**

```bash
./setup-queue.sh
```

### 5. update.sh - 系统更新脚本

用于更新已部署的系统到最新版本，支持备份恢复功能。

**功能特点：**

- 支持模块化更新（api/admin/user/easy/nginx/all）
- 自动备份当前版本
- 智能保留用户配置和数据
- 服务管理（停止/启动 Nginx 和队列）
- 版本检查和强制更新选项
- **备份恢复功能**：可恢复到之前的任何版本

**使用方法：**

```bash
# 更新操作
./update.sh                      # 更新所有模块（自动选择最优仓库）
./update.sh update api            # 仅更新后端
./update.sh update admin          # 仅更新管理端
./update.sh update user           # 仅更新用户端
./update.sh update easy           # 仅更新简易端
./update.sh update nginx          # 仅更新Nginx配置

# 指定仓库源
./update.sh --gitee              # 强制从 Gitee 拉取代码
./update.sh --github             # 强制从 GitHub 拉取代码
./update.sh --gitee update api   # 从 Gitee 更新后端

# 备份管理
./update.sh list                  # 列出所有备份
./update.sh restore update_20250809_143022  # 恢复指定备份

# 兼容旧版调用方式
./update.sh api                   # 等同于 ./update.sh update api

# 强制更新（跳过版本检查）
FORCE_UPDATE=1 ./update.sh
```

**恢复功能说明：**

- 每次更新前自动创建备份
- 恢复时会创建紧急备份，确保可以回滚
- 恢复包括系统文件、配置和权限设置
- 恢复后自动重载服务

**配置文件：**
更新脚本使用 `update-config.json` 配置文件，首次运行时自动创建。

### 6. keeper.sh - 备份管理脚本

专门备份 .env 文件和数据库，提供恢复功能。

**功能特点：**

- 备份 .env 配置文件
- 自动备份 MySQL 数据库（压缩存储）
- **自动排除 \_logs 后缀的日志表**
- 创建完整备份包（.tar.gz 格式）
- 智能清理旧备份（默认保留 30 份）
- 支持备份恢复和列表功能
- 磁盘空间检查（最少需要 1GB）
- 支持重试机制和备份验证
- 支持定时任务

**使用方法：**

```bash
# 执行备份（默认保留30份）
./keeper.sh backup

# 列出备份文件
./keeper.sh list

# 恢复备份
./keeper.sh restore backup_20250806_143022.tar.gz

# 清理过期备份
KEEP_BACKUPS=14 ./keeper.sh clean  # 保留14份
```

**设置定时任务：**

```bash
# 编辑 crontab
crontab -e

# 添加定时任务（每天凌晨2点备份）
0 2 * * * /path/to/keeper.sh >> /path/to/backup/keeper.log 2>&1
```

## 目录结构

部署后的目录结构（在站点根目录）：

```
site-root/               # 站点根目录
├── backend/              # Laravel 后端应用
│   ├── app/
│   ├── public/
│   ├── storage/         # 保持站点所有者权限
│   ├── bootstrap/cache/ # 保持站点所有者权限
│   ├── .env             # 配置文件（更新时保留）
│   └── ...
├── frontend/             # 前端应用
│   ├── admin/           # 管理端
│   │   └── platform-config.json  # 更新时保留
│   ├── user/            # 用户端
│   │   ├── platform-config.json
│   │   └── qrcode.png       # 更新时保留
│   └── easy/            # 简易端
│       └── config.json     # 更新时保留
├── nginx/               # Nginx 配置
├── cmd-deploy-scripts/  # 部署脚本目录
│   ├── source/          # 源码临时目录
│   ├── install.sh       # 安装脚本
│   ├── install-deps.sh  # 标准环境依赖脚本
│   ├── install-deps-bt.sh # 宝塔环境依赖脚本
│   ├── update.sh        # 更新脚本
│   ├── keeper.sh        # 备份脚本
│   ├── setup-queue.sh   # 设置定时任务和队列脚本
│   ├── detect-china-ip.sh # 检测中国大陆IP脚本
│   └── update-config.json # 更新配置
├── backup/              # 备份目录
│   ├── install/         # install.sh 的备份
│   ├── keeper/          # keeper.sh 的备份
│   └── update/          # update.sh 的备份
└── config.json            # 构建信息（包含版本）
```

## 典型部署流程

### 全新部署

```bash
# 1. 在站点根目录中克隆部署脚本
cd /path/to/{your-site}
git clone https://gitee.com/zhuxbo/cmd-deploy-product.git cmd-deploy-scripts
cd cmd-deploy-scripts

# 2. 安装系统（会自动检测环境并提示安装依赖）
./install.sh
# install.sh 会自动检测环境：
# - 宝塔环境：调用 install-deps-bt.sh
# - 标准环境：调用 install-deps.sh

# 3. 访问安装向导（非宝塔环境需配置 Nginx）
# http://your-domain/install.php

# 4. 设置定时任务和队列
./setup-queue.sh
```

### 日常维护

```bash
# 进入部署目录
cd /path/to/your-site/cmd-deploy-scripts

# 检查更新
./update.sh

# 手动备份
./keeper.sh backup

# 查看版本
jq -r '.version' ../config.json

# 查看备份列表
./keeper.sh list
```

## 注意事项

1. **权限要求**：部分操作需要 sudo 权限（如设置文件权限、重启服务）
2. **多站点支持**：使用站点目录名作为标识，支持多站点部署
3. **备份策略**：建议在更新前手动执行 keeper.sh 进行额外备份
4. **服务中断**：更新时会短暂停止 Web 服务，请选择合适时间
5. **配置保护**：更新过程会自动保护用户配置和数据
6. **版本兼容**：确保 PHP 版本 >= 8.3
7. **权限一致性**：storage 和 bootstrap/cache 保持与站点目录相同的所有者

## 故障排查

### 系统恢复

- **更新失败恢复**：使用 `./update.sh restore <备份名>` 恢复到之前版本
- **数据库恢复**：使用 `./keeper.sh restore <备份文件>` 恢复数据库和配置
- **查看可用备份**：
  - 系统备份：`./update.sh list`
  - 数据备份：`./keeper.sh list`

### 常见问题

- **安装失败**：检查 backup/install/ 目录中的备份进行恢复
- **更新失败**：使用 `./update.sh list` 查看备份，然后恢复
- **权限错误**：确保 Web 用户（站点目录所有者）对 storage 和 bootstrap/cache 有写权限
- **数据库连接**：检查 backend/.env 文件中的数据库配置
- **备份失败**：检查磁盘空间和数据库访问权限
- **队列不工作**：检查 Supervisor 配置中的站点名是否正确
- **定时任务冲突**：检查 crontab 中的站点名标识

## 技术支持

如遇问题，请检查：

1. 脚本执行日志
2. Laravel 日志：`backend/storage/logs/`
3. Nginx 错误日志：`/var/log/nginx/error.log`
