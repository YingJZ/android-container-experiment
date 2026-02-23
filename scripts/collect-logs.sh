#!/bin/bash
#
# 日志收集脚本
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

CONTAINER_NAME="${REDROID_CONTAINER_NAME:-redroid-experiment}"
ADB_PORT="${REDROID_ADB_PORT:-5555}"
ADB_DEVICE="localhost:${ADB_PORT}"
OUTPUT_DIR="${PROJECT_DIR}/logs/debug_$(date +%Y%m%d-%H%M%S)"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

collect_all() {
    mkdir -p "${OUTPUT_DIR}"
    
    echo "========================================"
    echo "  收集调试信息"
    echo "  输出目录: ${OUTPUT_DIR}"
    echo "========================================"
    echo ""
    
    # 1. 系统信息
    log_info "收集系统信息..."
    {
        echo "=== 主机信息 ==="
        uname -a
        echo ""
        echo "=== 内核模块 ==="
        lsmod | grep -E "(binder|ashmem)" || echo "未找到相关模块"
        echo ""
        echo "=== Docker 版本 ==="
        docker version
        echo ""
        echo "=== CRIU 版本 ==="
        criu --version 2>/dev/null || echo "CRIU 未安装"
    } > "${OUTPUT_DIR}/host_info.txt"
    
    # 2. 容器信息
    log_info "收集容器信息..."
    {
        echo "=== 容器状态 ==="
        docker ps -a | grep ${CONTAINER_NAME} || echo "容器不存在"
        echo ""
        echo "=== 容器详情 ==="
        docker inspect ${CONTAINER_NAME} 2>/dev/null || echo "无法获取"
    } > "${OUTPUT_DIR}/container_info.txt"
    
    # 3. 容器日志
    log_info "收集容器日志..."
    docker logs ${CONTAINER_NAME} > "${OUTPUT_DIR}/docker_logs.txt" 2>&1 || log_warn "无法获取容器日志"
    
    # 4. dmesg（内核日志）
    log_info "收集内核日志..."
    {
        echo "=== Binder 相关内核日志 ==="
        dmesg | grep -i binder | tail -100 || echo "无 binder 相关日志"
        echo ""
        echo "=== 最近的内核日志 ==="
        dmesg | tail -200
    } > "${OUTPUT_DIR}/dmesg.txt" 2>&1
    
    # 5. Android 日志
    if adb devices | grep -q "${ADB_DEVICE}"; then
        log_info "收集 Android 日志..."
        
        # logcat
        adb -s ${ADB_DEVICE} logcat -d > "${OUTPUT_DIR}/logcat.txt" 2>&1 || log_warn "无法获取 logcat"
        
        # Binder 相关 logcat
        adb -s ${ADB_DEVICE} logcat -d | grep -iE "(binder|service|dead)" > "${OUTPUT_DIR}/logcat_binder.txt" 2>&1 || true
        
        # 系统属性
        log_info "收集系统属性..."
        adb -s ${ADB_DEVICE} shell getprop > "${OUTPUT_DIR}/getprop.txt" 2>&1 || log_warn "无法获取"
        
        # dumpsys
        log_info "收集 dumpsys..."
        {
            echo "=== dumpsys activity ==="
            adb -s ${ADB_DEVICE} shell dumpsys activity 2>/dev/null | head -200 || echo "无法获取"
            echo ""
            echo "=== dumpsys meminfo ==="
            adb -s ${ADB_DEVICE} shell dumpsys meminfo 2>/dev/null | head -100 || echo "无法获取"
        } > "${OUTPUT_DIR}/dumpsys.txt"
        
        # Binder 状态
        log_info "收集 Binder 状态..."
        {
            echo "=== /proc/binder/state ==="
            adb -s ${ADB_DEVICE} shell cat /proc/binder/state 2>/dev/null || echo "无法读取"
            echo ""
            echo "=== /proc/binder/stats ==="
            adb -s ${ADB_DEVICE} shell cat /proc/binder/stats 2>/dev/null || echo "无法读取"
            echo ""
            echo "=== /proc/binder/transactions ==="
            adb -s ${ADB_DEVICE} shell cat /proc/binder/transactions 2>/dev/null || echo "无法读取"
            echo ""
            echo "=== service list ==="
            adb -s ${ADB_DEVICE} shell service list 2>/dev/null || echo "无法读取"
        } > "${OUTPUT_DIR}/binder_state.txt"
        
        # 进程列表
        log_info "收集进程列表..."
        adb -s ${ADB_DEVICE} shell ps -A > "${OUTPUT_DIR}/processes.txt" 2>&1 || log_warn "无法获取"
        
    else
        log_warn "ADB 未连接，跳过 Android 日志收集"
    fi
    
    # 6. 创建摘要
    log_info "创建摘要..."
    {
        echo "=========================================="
        echo "调试信息摘要"
        echo "收集时间: $(date)"
        echo "=========================================="
        echo ""
        echo "文件列表:"
        ls -la "${OUTPUT_DIR}"
        echo ""
        echo "--- 关键错误 ---"
        grep -riE "(error|exception|failed|crash)" "${OUTPUT_DIR}"/*.txt 2>/dev/null | head -50 || echo "未发现明显错误"
        echo ""
        echo "--- Binder 相关错误 ---"
        grep -riE "(DeadObjectException|binder.*failed|transaction.*failed)" "${OUTPUT_DIR}"/*.txt 2>/dev/null | head -20 || echo "未发现 Binder 错误"
    } > "${OUTPUT_DIR}/SUMMARY.txt"
    
    echo ""
    echo "========================================"
    echo "  收集完成"
    echo "  输出目录: ${OUTPUT_DIR}"
    echo "========================================"
    echo ""
    echo "关键文件:"
    echo "  - SUMMARY.txt         摘要"
    echo "  - binder_state.txt    Binder 状态"
    echo "  - logcat_binder.txt   Binder 相关日志"
    echo "  - docker_logs.txt     容器日志"
    
    # 可选：创建压缩包
    if command -v tar &> /dev/null; then
        local archive="${OUTPUT_DIR}.tar.gz"
        tar -czf "${archive}" -C "$(dirname "${OUTPUT_DIR}")" "$(basename "${OUTPUT_DIR}")"
        echo ""
        echo "压缩包: ${archive}"
    fi
}

# 快速收集（仅关键信息）
quick_collect() {
    mkdir -p "${OUTPUT_DIR}"
    
    log_info "快速收集关键信息..."
    
    if adb devices | grep -q "${ADB_DEVICE}"; then
        # Binder 状态
        adb -s ${ADB_DEVICE} shell cat /proc/binder/state > "${OUTPUT_DIR}/binder_state.txt" 2>&1
        
        # 最近日志
        adb -s ${ADB_DEVICE} logcat -d -t 500 > "${OUTPUT_DIR}/logcat_recent.txt" 2>&1
        
        # Binder 相关日志
        grep -iE "(binder|dead|exception)" "${OUTPUT_DIR}/logcat_recent.txt" > "${OUTPUT_DIR}/logcat_binder.txt" 2>/dev/null || true
    fi
    
    log_info "输出目录: ${OUTPUT_DIR}"
}

case "${1:-all}" in
    all)
        collect_all
        ;;
    quick)
        quick_collect
        ;;
    *)
        echo "用法: $0 [all|quick]"
        echo "  all   - 收集所有调试信息"
        echo "  quick - 仅收集关键信息"
        ;;
esac
