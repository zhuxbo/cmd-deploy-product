# 证书管理系统生产部署脚本

这是证书管理系统的生产环境部署脚本集，用于从 production-code 仓库部署和维护生产环境。

## 脚本说明

### 1. install.sh - 首次安装脚本

用于全新安装证书管理系统。

**功能特点：**
- 从 production-code 仓库拉取生产代码
- 自动备份现有部署（如果存在）
- 部署所有系统文件
- 初始化 Laravel 环境
- 设置正确的文件权限

**使用方法：**
```bash
./install.sh
```

**后续步骤：**
1. 编辑数据库配置：`vim backend/.env`
2. 配置 Nginx：将 nginx/manager.conf 链接到系统配置
3. 访问 `/install.php` 完成系统安装
4. 删除安装文件：`rm backend/public/install.php`

### 2. install-deps.sh - 依赖安装脚本

安装运行证书管理系统所需的 PHP 环境。

**功能特点：**
- 自动检测系统类型（Ubuntu/Debian/CentOS/RHEL）
- 安装 PHP 8.3+ 及所有必需扩展
- 智能识别宝塔面板环境
- 配置 PHP 优化参数
- 安装 Redis 等附加依赖

**使用方法：**
```bash
./install-deps.sh
```

**支持的系统：**
- Ubuntu 18.04+
- Debian 9+
- CentOS 7+
- RHEL 7+
- 宝塔面板环境（需手动在面板中安装）

### 3. update.sh - 系统更新脚本

用于更新已部署的系统到最新版本。

**功能特点：**
- 支持模块化更新（api/admin/user/easy/all）
- 自动备份当前版本
- 智能保留用户配置和数据
- 服务管理（停止/启动 Nginx 和队列）
- 版本检查和强制更新选项

**使用方法：**
```bash
# 更新所有模块
./update.sh

# 更新特定模块
./update.sh api      # 仅更新后端
./update.sh admin    # 仅更新管理端
./update.sh user     # 仅更新用户端
./update.sh easy     # 仅更新简易端

# 强制更新（跳过版本检查）
FORCE_UPDATE=1 ./update.sh
```

**配置文件：**
更新脚本使用 `update-config.json` 配置文件，首次运行时自动创建。

### 4. keeper.sh - 备份管理脚本

定期备份数据库和配置文件。

**功能特点：**
- 自动备份 MySQL 数据库
- 备份所有配置文件（.env、前端配置等）
- 自动压缩备份文件
- 智能清理旧备份（保留指定数量）
- 支持定时任务

**使用方法：**
```bash
# 执行备份（默认保留7份）
./keeper.sh

# 自定义保留数量
KEEP_BACKUPS=14 ./keeper.sh  # 保留14份
```

**设置定时任务：**
```bash
# 编辑 crontab
crontab -e

# 添加定时任务（每天凌晨2点备份）
0 2 * * * /path/to/keeper.sh >> /path/to/backup/keeper.log 2>&1
```

## 目录结构

部署后的目录结构：
```
cmd-deploy-product/
├── backend/              # 后端应用
├── frontend/             # 前端应用
│   ├── admin/           # 管理端
│   ├── user/            # 用户端
│   └── easy/            # 简易端
├── nginx/               # Nginx配置
├── source/              # 源码临时目录
├── backup/              # 备份目录
│   ├── keeper/          # keeper.sh 的备份
│   ├── backup_*/        # install.sh 的备份
│   └── update_*/        # update.sh 的备份
├── install.sh           # 安装脚本
├── install-deps.sh      # 依赖安装脚本
├── update.sh           # 更新脚本
├── keeper.sh           # 备份脚本
├── update-config.json  # 更新配置（自动生成）
├── VERSION             # 当前版本号
└── BUILD_INFO.json     # 构建信息
```

## 典型部署流程

### 全新部署
```bash
# 1. 克隆部署脚本
git clone git@gitee.com:zhuxbo/cmd-deploy-product.git
cd cmd-deploy-product

# 2. 安装系统依赖
./install-deps.sh

# 3. 安装系统
./install.sh

# 4. 配置系统
vim backend/.env  # 配置数据库等

# 5. 配置Web服务器
sudo ln -sf $(pwd)/nginx/manager.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 6. 完成安装向导
# 访问 http://your-domain/install.php

# 7. 设置定时备份
crontab -e
# 添加: 0 2 * * * /path/to/keeper.sh
```

### 日常维护
```bash
# 检查更新
./update.sh

# 手动备份
./keeper.sh

# 查看版本
cat VERSION
```

## 注意事项

1. **权限要求**：部分操作需要 sudo 权限（如设置文件权限、重启服务）
2. **备份策略**：建议在更新前手动执行 keeper.sh 进行额外备份
3. **服务中断**：更新时会短暂停止 Web 服务，请选择合适时间
4. **配置保护**：更新过程会自动保护用户配置和数据
5. **版本兼容**：确保 PHP 版本 >= 8.3

## 故障排查

- **更新失败**：检查 backup/update_* 目录中的备份进行恢复
- **权限错误**：确保 Web 用户对 storage 和 bootstrap/cache 有写权限
- **数据库连接**：检查 .env 文件中的数据库配置
- **备份失败**：检查磁盘空间和数据库访问权限

## 技术支持

如遇问题，请检查：
1. 脚本执行日志
2. Laravel 日志：`backend/storage/logs/`
3. Nginx 错误日志：`/var/log/nginx/error.log`