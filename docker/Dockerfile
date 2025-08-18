# docker/Dockerfile
FROM ubuntu:22.04

# 基础工具
RUN apt-get update && apt-get install -y \
    xfce4 \                     # 轻量级桌面
    xrdp \                      # 远程桌面协议
    firefox \                    # 浏览器
    libreoffice \                # 办公套件
    code-server \                # VS Code 网页版（开发）
    pulseaudio \                 # 音频支持
    tightvncserver \             # VNC 服务
    && apt-get clean

# 配置 XRDP
COPY docker/config/xrdp/xrdp.ini /etc/xrdp/
COPY docker/config/xrdp/sesman.ini /etc/xrdp/

# NoVNC 支持（可选）
RUN git clone https://github.com/novnc/noVNC.git /opt/novnc \
    && cp /opt/novnc/vnc.html /opt/novnc/index.html

# 初始化脚本
COPY scripts/init-desktop.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-desktop.sh

# 启动入口
COPY docker/entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]
