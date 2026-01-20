#!/bin/bash

# ===================== 核心配置 =====================
# 自动获取脚本所在的绝对路径（处理软链接）
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
# RTSP服务端口（和ffserver.conf中的RTSPPort保持一致）
RTSP_PORT=5454
# 自动获取服务器内网IP（优先取eth0/ens开头的网卡IP，也可手动指定）
SERVER_IP=$(ip addr | grep -E 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | grep -v '::1' | awk '{print $2}' | cut -d '/' -f1 | grep -E '172|192|10' | head -n 1)
# RTSP地址输出文件路径（新增配置）
RTSP_OUTPUT_FILE="${SCRIPT_DIR}/rtsp_addresses.txt"

# 如果自动获取IP失败，手动指定（可取消注释并修改）
# SERVER_IP="172.20.26.189"

# ===================== 架构识别与ffserver路径选择 =====================
# 识别系统架构
detect_arch() {
    echo -e "\n🔍 正在识别系统架构..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            echo "✅ 识别到系统架构：AMD64 (x86_64)"
            FF_ARCH="amd64"
            ;;
        aarch64|arm64)
            echo "✅ 识别到系统架构：ARM64 (aarch64)"
            FF_ARCH="arm64"
            ;;
        *)
            echo "❌ 错误：不支持的系统架构！当前架构：$ARCH"
            echo "   仅支持 AMD64(x86_64) 和 ARM64(aarch64) 架构"
            exit 1
            ;;
    esac
    # 拼接对应架构的ffserver路径
    FFSERVER_BIN="${SCRIPT_DIR}/ffserver_${FF_ARCH}"
}

# ===================== 固定配置 =====================
GLOBAL_CONFIG=$(cat << EOF
HTTPPort 8098 
HTTPBindAddress 0.0.0.0
RTSPPort ${RTSP_PORT}
RTSPBindAddress 0.0.0.0
MaxHTTPConnections 2000
MaxClients 1000
MaxBandwidth 1000

EOF
)

# 配置文件输出路径
OUTPUT_FILE="${SCRIPT_DIR}/ffserver.conf"
# nohup输出日志路径
NOHUP_LOG="${SCRIPT_DIR}/ffserver_nohup.log"

# ===================== 工具函数 =====================
# 停止已运行的ffserver进程
stop_ffserver() {
    echo -e "\n🔧 正在检查并停止已运行的ffserver进程..."
    # 查找对应架构ffserver的进程ID（排除grep自身）
    FF_PID=$(ps aux | grep "${FFSERVER_BIN} -f" | grep -v grep | awk '{print $2}')
    
    if [ -n "$FF_PID" ]; then
        echo "🔌 找到ffserver进程ID：$FF_PID，正在终止..."
        kill -9 "$FF_PID" >/dev/null 2>&1
        # 等待进程退出
        sleep 2
        # 再次检查是否终止成功
        if ps -p "$FF_PID" >/dev/null 2>&1; then
            echo "❌ 警告：ffserver进程 $FF_PID 终止失败！"
        else
            echo "✅ ffserver进程已成功终止"
        fi
    else
        echo "ℹ️  未找到运行中的ffserver进程"
    fi
}

# 启动ffserver（后台运行，使用对应架构的二进制文件）
start_ffserver() {
    echo -e "\n🚀 正在启动ffserver（后台运行，架构：${FF_ARCH}）..."
    # 启动命令：使用对应架构的ffserver，nohup后台运行，输出日志到指定文件
    nohup "${FFSERVER_BIN}" -f "$OUTPUT_FILE" > "$NOHUP_LOG" 2>&1 &
    # 等待进程启动
    sleep 3
    # 检查是否启动成功
    NEW_FF_PID=$(ps aux | grep "${FFSERVER_BIN} -f $OUTPUT_FILE" | grep -v grep | awk '{print $2}')
    if [ -n "$NEW_FF_PID" ]; then
        echo "✅ ffserver启动成功！进程ID：$NEW_FF_PID"
        echo "📜 日志文件路径：$NOHUP_LOG"
        echo "🔧 使用的ffserver路径：${FFSERVER_BIN}"
    else
        echo "❌ ffserver启动失败！请查看日志：$NOHUP_LOG"
        exit 1
    fi
}

# 写入RTSP地址到文件（新增函数）
write_rtsp_to_file() {
    echo -e "\n📝 正在将RTSP地址写入文件：$RTSP_OUTPUT_FILE"
    # 先清空文件（避免旧内容残留）
    > "$RTSP_OUTPUT_FILE"
    # 遍历RTSP地址列表，逐行写入文件
    for addr in "${rtsp_addresses[@]}"; do
        echo "$addr" >> "$RTSP_OUTPUT_FILE"
    done
    # 检查写入是否成功
    if [ -f "$RTSP_OUTPUT_FILE" ] && [ -s "$RTSP_OUTPUT_FILE" ]; then
        echo "✅ RTSP地址已成功写入文件！"
    else
        echo "⚠️  警告：RTSP地址文件写入失败或文件为空！"
    fi
}

# ===================== 前置检查 =====================
# 1. 检查脚本目录是否存在
if [ ! -d "$SCRIPT_DIR" ]; then
    echo "❌ 错误：脚本所在目录 $SCRIPT_DIR 不存在！"
    exit 1
fi

# 2. 检查是否获取到服务器IP
if [ -z "$SERVER_IP" ]; then
    echo "❌ 错误：无法自动获取服务器IP，请手动指定SERVER_IP变量！"
    exit 1
fi

# 3. 识别系统架构并设置ffserver路径
detect_arch

# 4. 检查对应架构的ffserver是否存在
if [ ! -f "${FFSERVER_BIN}" ]; then
    echo "❌ 错误：当前目录未找到${FF_ARCH}架构的ffserver文件！"
    echo "   期望路径：${FFSERVER_BIN}"
    echo "   请确认文件已放在脚本目录，文件名应为：ffserver_amd64 或 ffserver_arm64"
    exit 1
fi

# 5. 检查ffserver是否有执行权限
if [ ! -x "${FFSERVER_BIN}" ]; then
    echo "⚠️  警告：${FF_ARCH}架构的ffserver文件无执行权限，正在尝试添加..."
    chmod +x "${FFSERVER_BIN}"
    # 再次检查权限
    if [ ! -x "${FFSERVER_BIN}" ]; then
        echo "❌ 错误：无法为${FF_ARCH}架构的ffserver添加执行权限！"
        echo "   请手动执行：chmod +x ${FFSERVER_BIN}"
        exit 1
    fi
fi

# ===================== 生成配置文件 =====================
# 写入全局配置
echo "$GLOBAL_CONFIG" > "$OUTPUT_FILE"

# 遍历视频文件并生成流配置
echo -e "\n🔍 开始扫描脚本所在目录：$SCRIPT_DIR"
echo "🔍 查找mp4/mov格式视频文件..."
file_count=0
# 存储RTSP地址列表
rtsp_addresses=()

for file in "$SCRIPT_DIR"/*.{mp4,mov}; do
    [ -f "$file" ] || continue
    
    # 获取纯文件名
    filename=$(basename "$file")
    # 拼接完整文件路径
    full_file_path="${SCRIPT_DIR}/${filename}"
    
    # 生成Stream配置块
    cat << EOF >> "$OUTPUT_FILE"
<Stream $filename>
File "$full_file_path"
Format rtp
</Stream>

EOF
    # 生成RTSP地址并保存
    rtsp_addr="rtsp://${SERVER_IP}:${RTSP_PORT}/${filename}"
    rtsp_addresses+=("$rtsp_addr")
    
    echo "✅ 已添加流配置：$filename"
    ((file_count++))
done

# 检查是否有视频文件
if [ $file_count -eq 0 ]; then
    echo -e "\n⚠️  警告：脚本目录下未找到任何mp4/mov文件！"
    echo "   请确认视频文件已放在：$SCRIPT_DIR"
    exit 1
fi

# ===================== 进程管理与启动 =====================
# 停止旧进程
stop_ffserver

# 启动新进程
start_ffserver

# ===================== 输出结果 =====================
echo -e "\n======================================"
echo "✅ 全部操作完成！"
echo "📄 配置文件路径：$OUTPUT_FILE"
echo "📂 视频文件目录：$SCRIPT_DIR"
echo "🖥️  系统架构：${FF_ARCH}"
echo "🔧 使用的ffserver路径：${FFSERVER_BIN}"
echo "📊 共生成 $file_count 个视频流配置"
echo "======================================"

# 输出RTSP访问地址到控制台
echo -e "\n📡 以下是可直接访问的RTSP地址："
echo "--------------------------------------"
for addr in "${rtsp_addresses[@]}"; do
    echo "$addr"
done
echo "--------------------------------------"

# 调用函数将RTSP地址写入文件（新增逻辑）
write_rtsp_to_file

echo -e "\n💡 提示：可使用VLC/ffplay打开上述RTSP地址播放视频"
echo "💡 RTSP地址文件路径：$RTSP_OUTPUT_FILE"  # 新增提示
echo "💡 停止ffserver命令：kill -9 $NEW_FF_PID"
echo "💡 查看日志命令：tail -f $NOHUP_LOG"
echo "💡 手动启动命令：nohup ${FFSERVER_BIN} -f $OUTPUT_FILE > $NOHUP_LOG 2>&1 &"
