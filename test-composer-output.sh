#!/bin/bash

# 测试获取 Composer 版本的不同方法

echo "========================================="
echo "测试 Composer 输出获取方法"
echo "========================================="
echo

echo "方法1: 直接执行 composer --version"
echo "---"
composer --version 2>&1
echo

echo "方法2: 执行并获取前3行"
echo "---"
composer --version 2>&1 | head -3
echo

echo "方法3: 只获取包含 'Composer version' 的行"
echo "---"
composer --version 2>&1 | grep "Composer version"
echo

echo "方法4: 过滤掉 Deprecated 警告"
echo "---"
composer --version 2>&1 | grep -v "^PHP Deprecated\|^Deprecated"
echo

echo "方法5: 提取版本号"
echo "---"
VERSION=$(composer --version 2>&1 | grep "Composer version" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
echo "提取的版本号: $VERSION"
echo

echo "方法6: 使用 COMPOSER_NO_INTERACTION 环境变量"
echo "---"
COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1 composer --version 2>&1
echo

echo "方法7: 使用 --no-interaction 参数"
echo "---"
COMPOSER_ALLOW_SUPERUSER=1 composer --version --no-interaction 2>&1
echo

echo "方法8: 使用 echo n 自动响应"
echo "---"
echo 'n' | composer --version 2>&1
echo

echo "方法9: 以 www 用户执行（如果存在）"
echo "---"
if id -u www >/dev/null 2>&1; then
    sudo -u www composer --version 2>&1
else
    echo "www 用户不存在"
fi
echo

echo "方法10: 检查 composer 文件类型"
echo "---"
COMPOSER_PATH=$(which composer)
echo "Composer 路径: $COMPOSER_PATH"
file "$COMPOSER_PATH"
echo

echo "方法11: 查看 composer 文件前几行（如果是脚本）"
echo "---"
head -5 "$COMPOSER_PATH"
echo

echo "方法12: 直接用PHP执行composer（如果是phar）"
echo "---"
if [ -f "$COMPOSER_PATH" ]; then
    php "$COMPOSER_PATH" --version 2>&1
fi
echo

echo "========================================="
echo "测试完成"
echo "========================================="