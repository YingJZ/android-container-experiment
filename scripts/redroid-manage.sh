#!/bin/bash
#
# ReDroid 容器管理脚本
#

set -e

# 配置
CONTAINER_NAME="${REDROID_CONTAINER_NAME:-redroid-experiment}"
IMAGE_NAME="${REDROID_IMAGE:-redroid/redroid:12.0.0_64only-latest}"
ADB_PORT="${REDROID_ADB_PORT:-5555}"
DATA_DIR="${REDROID_DATA_DIR:-$HOME/redroid-data}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker 未安装，请先运行 setup-env.sh"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker 服务未运行"
        exit 1
    fi
}

check_kernel_modules() {
    if ! lsmod | grep -q "^binder"; then
        log_error "binder 内核模块未加载"
        log_info "请运行: sudo modprobe binder_linux devices='binder,hwbinder,vndbinder'"
        exit 1
    fi
}

start_container() {
    log_step "启动 ReDroid 容器..."
    
    check_docker
    check_kernel_modules
    
    # 检查容器是否已存在
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            log_info "容器 ${CONTAINER_NAME} 已在运行"
            return 0
        else
            log_info "启动已存在的容器..."
            docker start ${CONTAINER_NAME}
            wait_for_boot
            return 0
        fi
    fi
    
    # 创建数据目录
    mkdir -p "${DATA_DIR}"
    
    log_info "拉取镜像: ${IMAGE_NAME}"
    docker pull ${IMAGE_NAME}
    
    log_info "启动新容器..."
    docker run -itd \
        --name ${CONTAINER_NAME} \
        --privileged \
        -v "${DATA_DIR}:/data" \
        -p ${ADB_PORT}:5555 \
        ${IMAGE_NAME} \
        androidboot.redroid_width=720 \
        androidboot.redroid_height=1280 \
        androidboot.redroid_dpi=320 \
        androidboot.redroid_fps=30
    
    log_info "容器已启动"
    wait_for_boot
}

stop_container() {
    log_step "停止 ReDroid 容器..."
    
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker stop ${CONTAINER_NAME}
        log_info "容器已停止"
    else
        log_warn "容器 ${CONTAINER_NAME} 未在运行"
    fi
}

restart_container() {
    log_step "重启 ReDroid 容器..."
    stop_container
    sleep 2
    start_container
}

remove_container() {
    log_step "删除 ReDroid 容器..."
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker rm -f ${CONTAINER_NAME}
        log_info "容器已删除"
    else
        log_warn "容器 ${CONTAINER_NAME} 不存在"
    fi
}

wait_for_boot() {
    log_info "等待 Android 系统启动..."
    
    local max_attempts=60
    local attempt=0
    
    # 等待 ADB 可用
    while [[ $attempt -lt $max_attempts ]]; do
        if adb connect localhost:${ADB_PORT} 2>&1 | grep -q "connected"; then
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
        echo -ne "\r等待中... (${attempt}/${max_attempts})"
    done
    echo ""
    
    if [[ $attempt -ge $max_attempts ]]; then
        log_error "ADB 连接超时"
        return 1
    fi
    
    # 等待系统完全启动
    log_info "等待系统完全启动..."
    attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        local boot_completed=$(adb -s localhost:${ADB_PORT} shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        if [[ "$boot_completed" == "1" ]]; then
            log_info "Android 系统已启动完成"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
        echo -ne "\r启动中... (${attempt}/${max_attempts})"
    done
    echo ""
    
    log_warn "系统启动可能未完成，请检查日志"
}

connect_adb() {
    log_step "连接 ADB..."
    
    adb connect localhost:${ADB_PORT}
    adb -s localhost:${ADB_PORT} wait-for-device
    
    log_info "ADB 已连接"
    adb -s localhost:${ADB_PORT} devices
}

disconnect_adb() {
    log_step "断开 ADB..."
    adb disconnect localhost:${ADB_PORT}
    log_info "ADB 已断开"
}

install_apk() {
    local apk_path="$1"
    
    if [[ -z "$apk_path" ]]; then
        log_error "请指定 APK 文件路径"
        exit 1
    fi
    
    if [[ ! -f "$apk_path" ]]; then
        log_error "APK 文件不存在: $apk_path"
        exit 1
    fi
    
    log_step "安装 APK: $apk_path"
    adb -s localhost:${ADB_PORT} install -r "$apk_path"
    log_info "APK 安装完成"
}

uninstall_app() {
    local package_name="$1"
    
    if [[ -z "$package_name" ]]; then
        log_error "请指定包名"
        exit 1
    fi
    
    log_step "卸载应用: $package_name"
    adb -s localhost:${ADB_PORT} uninstall "$package_name"
    log_info "应用已卸载"
}

shell() {
    log_step "进入 Android Shell..."
    adb -s localhost:${ADB_PORT} shell "$@"
}

logcat() {
    log_step "查看日志..."
    adb -s localhost:${ADB_PORT} logcat "$@"
}

status() {
    echo ""
    echo "========================================"
    echo "        ReDroid 容器状态"
    echo "========================================"
    
    # 容器状态
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "容器状态:        ${GREEN}运行中${NC}"
        
        # 获取容器信息
        local container_id=$(docker ps -q -f name=${CONTAINER_NAME})
        local uptime=$(docker ps --format '{{.Status}}' -f name=${CONTAINER_NAME})
        echo "容器 ID:         ${container_id:0:12}"
        echo "运行时间:        ${uptime}"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "容器状态:        ${YELLOW}已停止${NC}"
    else
        echo -e "容器状态:        ${RED}不存在${NC}"
    fi
    
    # ADB 状态
    if adb devices 2>/dev/null | grep -q "localhost:${ADB_PORT}"; then
        echo -e "ADB 连接:        ${GREEN}已连接${NC}"
        
        # 获取 Android 信息
        local android_version=$(adb -s localhost:${ADB_PORT} shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
        local sdk_version=$(adb -s localhost:${ADB_PORT} shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
        echo "Android 版本:    ${android_version} (SDK ${sdk_version})"
    else
        echo -e "ADB 连接:        ${RED}未连接${NC}"
    fi
    
    echo ""
    echo "配置信息:"
    echo "  容器名称:      ${CONTAINER_NAME}"
    echo "  镜像:          ${IMAGE_NAME}"
    echo "  ADB 端口:      ${ADB_PORT}"
    echo "  数据目录:      ${DATA_DIR}"
    echo "========================================"
    echo ""
}

logs() {
    log_step "查看容器日志..."
    docker logs ${CONTAINER_NAME} "$@"
}

exec_cmd() {
    docker exec -it ${CONTAINER_NAME} "$@"
}

# 创建容器快照（用于实验）
create_snapshot() {
    local snapshot_name="${1:-snapshot-$(date +%Y%m%d-%H%M%S)}"
    
    log_step "创建容器快照: $snapshot_name"
    
    # 方法1: Docker commit (保存文件系统状态)
    log_info "使用 docker commit 创建镜像快照..."
    docker commit ${CONTAINER_NAME} "${CONTAINER_NAME}:${snapshot_name}"
    
    log_info "快照已创建: ${CONTAINER_NAME}:${snapshot_name}"
    docker images | grep ${CONTAINER_NAME}
}

# 从快照恢复
restore_snapshot() {
    local snapshot_name="$1"
    
    if [[ -z "$snapshot_name" ]]; then
        log_error "请指定快照名称"
        log_info "可用快照:"
        docker images | grep ${CONTAINER_NAME}
        exit 1
    fi
    
    log_step "从快照恢复: $snapshot_name"
    
    # 停止并删除当前容器
    remove_container
    
    # 从快照启动新容器
    log_info "从快照启动新容器..."
    docker run -itd \
        --name ${CONTAINER_NAME} \
        --privileged \
        -v "${DATA_DIR}:/data" \
        -p ${ADB_PORT}:5555 \
        "${CONTAINER_NAME}:${snapshot_name}"
    
    wait_for_boot
    log_info "已从快照恢复"
}

print_usage() {
    echo "ReDroid 容器管理工具"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "命令:"
    echo "  start              启动容器"
    echo "  stop               停止容器"
    echo "  restart            重启容器"
    echo "  remove             删除容器"
    echo "  status             查看状态"
    echo "  connect            连接 ADB"
    echo "  disconnect         断开 ADB"
    echo "  install <apk>      安装 APK"
    echo "  uninstall <pkg>    卸载应用"
    echo "  shell [cmd]        进入/执行 Shell"
    echo "  logcat [args]      查看 Android 日志"
    echo "  logs [args]        查看容器日志"
    echo "  exec <cmd>         在容器中执行命令"
    echo "  snapshot [name]    创建快照"
    echo "  restore <name>     从快照恢复"
    echo ""
    echo "环境变量:"
    echo "  REDROID_CONTAINER_NAME  容器名称 (默认: redroid-experiment)"
    echo "  REDROID_IMAGE           镜像名称 (默认: redroid/redroid:12.0.0_64only-latest)"
    echo "  REDROID_ADB_PORT        ADB 端口 (默认: 5555)"
    echo "  REDROID_DATA_DIR        数据目录 (默认: ~/redroid-data)"
}

main() {
    case "${1:-help}" in
        start)
            start_container
            ;;
        stop)
            stop_container
            ;;
        restart)
            restart_container
            ;;
        remove)
            remove_container
            ;;
        status)
            status
            ;;
        connect)
            connect_adb
            ;;
        disconnect)
            disconnect_adb
            ;;
        install)
            install_apk "$2"
            ;;
        uninstall)
            uninstall_app "$2"
            ;;
        shell)
            shift
            shell "$@"
            ;;
        logcat)
            shift
            logcat "$@"
            ;;
        logs)
            shift
            logs "$@"
            ;;
        exec)
            shift
            exec_cmd "$@"
            ;;
        snapshot)
            create_snapshot "$2"
            ;;
        restore)
            restore_snapshot "$2"
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "未知命令: $1"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
