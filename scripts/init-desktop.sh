#!/bin/bash
# scripts/init-desktop.sh

# 配置 VNC 密码
mkdir -p ~/.vnc
echo "mypassword" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# 启动 VNC 服务器（XFCE 桌面）
vncserver :1 -geometry 1280x720 -depth 24 -localhost no \
    -xstartup /usr/bin/xfce4-session

# 配置 PulseAudio 音频（可选）
pulseaudio --start --exit-idle-time=-1