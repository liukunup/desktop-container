#!/bin/bash
# docker/entrypoint.sh

# 初始化桌面环境
/usr/local/bin/init-desktop.sh

# 启动 XRDP
service xrdp start

# 启动 NoVNC（可选）
/opt/novnc/utils/novnc_proxy --vnc localhost:5901 --listen 6080 &

# 保持容器运行
tail -f /dev/null