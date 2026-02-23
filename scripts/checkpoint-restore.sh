#!/bin/bash
#
# 容器快照/恢复实验脚本
# 用于复现 Binder 句柄失效问题
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 配置
CONTAINER_NAME="${REDROID_CONTAINER_NAME:-redroid-experiment}"
ADB_PORT="${REDROID_ADB_PORT:-5555}"
ADB_DEVICE="localhost:${ADB_PORT}"
CHECKPOINT_DIR="${PROJECT_DIR}/checkpoints"
LOG_DIR="${PROJECT_DIR}/logs"
TEST_APP_PACKAGE="com.experiment.bindertest"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

log_result() {
    echo -e "${CYAN}[RESULT]${NC} $1"
}

ensure_dirs() {
    mkdir -p "${CHECKPOINT_DIR}"
    mkdir -p "${LOG_DIR}"
}

check_container_running() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "容器 ${CONTAINER_NAME} 未运行"
        log_info "请先运行: ./redroid-manage.sh start"
        exit 1
    fi
}

check_adb_connected() {
    if ! adb devices | grep -q "${ADB_DEVICE}"; then
        log_info "连接 ADB..."
        adb connect ${ADB_DEVICE}
        sleep 2
    fi
}

check_test_app_installed() {
    if ! adb -s ${ADB_DEVICE} shell pm list packages | grep -q "${TEST_APP_PACKAGE}"; then
        log_error "测试应用未安装: ${TEST_APP_PACKAGE}"
        log_info "请先构建并安装测试应用"
        return 1
    fi
    return 0
}

# ============================================
# Docker Checkpoint/Restore (需要 CRIU)
# ============================================

check_criu_support() {
    log_info "检查 CRIU 支持..."
    
    # 检查 CRIU 是否安装
    if ! command -v criu &> /dev/null; then
        log_warn "CRIU 未安装"
        return 1
    fi
    
    # 检查 Docker 是否支持 checkpoint
    if ! docker checkpoint --help &> /dev/null; then
        log_warn "Docker 不支持 checkpoint 功能"
        return 1
    fi
    
    log_info "CRIU 支持检查通过"
    return 0
}

create_docker_checkpoint() {
    local checkpoint_name="${1:-checkpoint-$(date +%Y%m%d-%H%M%S)}"
    
    log_step "创建 Docker Checkpoint: ${checkpoint_name}"
    
    check_container_running
    
    # 创建 checkpoint（不停止容器）
    docker checkpoint create --leave-running ${CONTAINER_NAME} ${checkpoint_name} || {
        log_error "创建 checkpoint 失败"
        log_info "这可能是因为内核不支持或 CRIU 配置问题"
        return 1
    }
    
    log_info "Checkpoint 已创建: ${checkpoint_name}"
    
    # 列出所有 checkpoints
    log_info "所有 checkpoints:"
    docker checkpoint ls ${CONTAINER_NAME}
}

restore_docker_checkpoint() {
    local checkpoint_name="$1"
    
    if [[ -z "$checkpoint_name" ]]; then
        log_error "请指定 checkpoint 名称"
        log_info "可用 checkpoints:"
        docker checkpoint ls ${CONTAINER_NAME}
        exit 1
    fi
    
    log_step "从 Checkpoint 恢复: ${checkpoint_name}"
    
    # 停止容器
    docker stop ${CONTAINER_NAME} 2>/dev/null || true
    
    # 从 checkpoint 恢复
    docker start --checkpoint ${checkpoint_name} ${CONTAINER_NAME}
    
    log_info "已从 checkpoint 恢复"
}

# ============================================
# 简化版快照（Docker Commit）
# ============================================

create_commit_snapshot() {
    local snapshot_name="${1:-snapshot-$(date +%Y%m%d-%H%M%S)}"
    
    log_step "创建镜像快照: ${snapshot_name}"
    
    check_container_running
    
    # 使用 docker commit 创建快照
    docker commit ${CONTAINER_NAME} "${CONTAINER_NAME}:${snapshot_name}"
    
    log_info "快照已创建: ${CONTAINER_NAME}:${snapshot_name}"
}

restore_commit_snapshot() {
    local snapshot_name="$1"
    
    if [[ -z "$snapshot_name" ]]; then
        log_error "请指定快照名称"
        log_info "可用快照:"
        docker images | grep ${CONTAINER_NAME} | grep -v latest
        exit 1
    fi
    
    log_step "从镜像快照恢复: ${snapshot_name}"
    
    local image="${CONTAINER_NAME}:${snapshot_name}"
    
    # 检查镜像是否存在
    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${image}$"; then
        log_error "快照不存在: ${image}"
        exit 1
    fi
    
    # 保存当前容器配置
    local data_dir=$(docker inspect ${CONTAINER_NAME} --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')
    
    # 停止并删除当前容器
    docker stop ${CONTAINER_NAME} 2>/dev/null || true
    docker rm ${CONTAINER_NAME} 2>/dev/null || true
    
    # 从快照启动新容器
    docker run -itd \
        --name ${CONTAINER_NAME} \
        --privileged \
        -v "${data_dir}:/data" \
        -p ${ADB_PORT}:5555 \
        "${image}"
    
    # 等待启动
    sleep 5
    adb connect ${ADB_DEVICE}
    
    log_info "已从快照恢复"
}

# ============================================
# 实验流程
# ============================================

collect_binder_state() {
    local output_file="$1"
    local label="$2"
    
    log_info "收集 Binder 状态 (${label})..."
    
    {
        echo "=========================================="
        echo "Binder 状态 - ${label}"
        echo "时间: $(date)"
        echo "=========================================="
        echo ""
        
        echo "--- /proc/binder/state ---"
        adb -s ${ADB_DEVICE} shell cat /proc/binder/state 2>/dev/null || echo "无法读取"
        echo ""
        
        echo "--- /proc/binder/stats ---"
        adb -s ${ADB_DEVICE} shell cat /proc/binder/stats 2>/dev/null || echo "无法读取"
        echo ""
        
        echo "--- /proc/binder/transactions ---"
        adb -s ${ADB_DEVICE} shell cat /proc/binder/transactions 2>/dev/null || echo "无法读取"
        echo ""
        
        echo "--- Service Manager 服务列表 ---"
        adb -s ${ADB_DEVICE} shell service list 2>/dev/null | head -50 || echo "无法读取"
        echo ""
        
        echo "--- 测试 App 进程信息 ---"
        local pid=$(adb -s ${ADB_DEVICE} shell pidof ${TEST_APP_PACKAGE} 2>/dev/null | tr -d '\r')
        if [[ -n "$pid" ]]; then
            echo "PID: $pid"
            echo ""
            echo "--- /proc/${pid}/fd (Binder FDs) ---"
            adb -s ${ADB_DEVICE} shell "ls -la /proc/${pid}/fd 2>/dev/null | grep binder" || echo "无 binder fd"
            echo ""
            echo "--- /proc/${pid}/maps (Binder mappings) ---"
            adb -s ${ADB_DEVICE} shell "cat /proc/${pid}/maps 2>/dev/null | grep binder" || echo "无 binder mapping"
        else
            echo "测试 App 未运行"
        fi
        echo ""
        
    } > "${output_file}"
    
    log_info "Binder 状态已保存到: ${output_file}"
}

test_binder_functionality() {
    local label="$1"
    local result_file="${LOG_DIR}/binder_test_${label}_$(date +%Y%m%d-%H%M%S).log"
    
    log_info "测试 Binder 功能 (${label})..."
    
    {
        echo "=========================================="
        echo "Binder 功能测试 - ${label}"
        echo "时间: $(date)"
        echo "=========================================="
        echo ""
        
        # 测试系统服务
        echo "--- 测试 ActivityManager ---"
        if adb -s ${ADB_DEVICE} shell am broadcast -a android.intent.action.TIME_TICK 2>&1; then
            echo "结果: 成功"
        else
            echo "结果: 失败"
        fi
        echo ""
        
        echo "--- 测试 PackageManager ---"
        if adb -s ${ADB_DEVICE} shell pm list packages -s 2>&1 | head -5; then
            echo "结果: 成功"
        else
            echo "结果: 失败"
        fi
        echo ""
        
        echo "--- 测试 ServiceManager ---"
        if adb -s ${ADB_DEVICE} shell service check activity 2>&1; then
            echo "结果: 成功"
        else
            echo "结果: 失败"
        fi
        echo ""
        
        # 测试应用 Binder
        if check_test_app_installed; then
            echo "--- 测试应用 Binder 调用 ---"
            # 发送广播触发测试
            adb -s ${ADB_DEVICE} shell am broadcast \
                -a com.experiment.bindertest.TEST_BINDER \
                -n ${TEST_APP_PACKAGE}/.BinderTestReceiver 2>&1 || echo "广播发送失败"
            
            sleep 2
            
            # 获取测试结果
            echo ""
            echo "--- 测试应用日志 ---"
            adb -s ${ADB_DEVICE} logcat -d -t 50 | grep -E "(BinderTest|DeadObjectException)" || echo "无相关日志"
        fi
        
    } > "${result_file}"
    
    log_info "测试结果已保存到: ${result_file}"
    
    # 显示摘要
    echo ""
    log_result "测试结果摘要 (${label}):"
    grep -E "(成功|失败|DeadObjectException)" "${result_file}" || echo "  无明确结果"
}

run_full_experiment() {
    log_step "开始完整实验流程..."
    
    ensure_dirs
    check_container_running
    check_adb_connected
    
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local experiment_dir="${LOG_DIR}/experiment_${timestamp}"
    mkdir -p "${experiment_dir}"
    
    echo ""
    echo "========================================"
    echo "  Binder 句柄失效实验"
    echo "  时间: $(date)"
    echo "========================================"
    echo ""
    
    # 阶段 1: 快照前状态
    log_step "阶段 1: 收集快照前状态"
    
    # 启动测试应用
    if check_test_app_installed; then
        log_info "启动测试应用..."
        adb -s ${ADB_DEVICE} shell am start -n ${TEST_APP_PACKAGE}/.MainActivity
        sleep 3
    fi
    
    collect_binder_state "${experiment_dir}/binder_state_before.log" "快照前"
    test_binder_functionality "before"
    
    # 阶段 2: 创建快照
    log_step "阶段 2: 创建快照"
    
    local snapshot_name="experiment_${timestamp}"
    
    # 尝试 CRIU checkpoint
    if check_criu_support; then
        log_info "使用 CRIU checkpoint..."
        create_docker_checkpoint "${snapshot_name}" || {
            log_warn "CRIU checkpoint 失败，使用 docker commit 替代"
            create_commit_snapshot "${snapshot_name}"
        }
    else
        log_warn "CRIU 不可用，使用 docker commit"
        create_commit_snapshot "${snapshot_name}"
    fi
    
    # 阶段 3: 停止容器
    log_step "阶段 3: 停止容器"
    docker stop ${CONTAINER_NAME}
    sleep 2
    
    # 阶段 4: 恢复容器
    log_step "阶段 4: 从快照恢复"
    
    if check_criu_support && docker checkpoint ls ${CONTAINER_NAME} 2>/dev/null | grep -q "${snapshot_name}"; then
        restore_docker_checkpoint "${snapshot_name}"
    else
        restore_commit_snapshot "${snapshot_name}"
    fi
    
    # 等待系统稳定
    log_info "等待系统稳定..."
    sleep 10
    check_adb_connected
    
    # 阶段 5: 恢复后状态
    log_step "阶段 5: 收集恢复后状态"
    
    collect_binder_state "${experiment_dir}/binder_state_after.log" "恢复后"
    test_binder_functionality "after"
    
    # 阶段 6: 分析结果
    log_step "阶段 6: 分析结果"
    
    analyze_results "${experiment_dir}"
    
    echo ""
    echo "========================================"
    echo "  实验完成"
    echo "  结果目录: ${experiment_dir}"
    echo "========================================"
}

analyze_results() {
    local experiment_dir="$1"
    
    log_info "分析实验结果..."
    
    local analysis_file="${experiment_dir}/analysis.log"
    
    {
        echo "=========================================="
        echo "实验结果分析"
        echo "=========================================="
        echo ""
        
        echo "--- Binder 状态变化 ---"
        if [[ -f "${experiment_dir}/binder_state_before.log" ]] && \
           [[ -f "${experiment_dir}/binder_state_after.log" ]]; then
            diff "${experiment_dir}/binder_state_before.log" \
                 "${experiment_dir}/binder_state_after.log" || echo "存在差异"
        fi
        echo ""
        
        echo "--- Binder 错误检测 ---"
        local errors_found=false
        
        # 检查 DeadObjectException
        if grep -r "DeadObjectException" "${LOG_DIR}" 2>/dev/null; then
            echo "发现 DeadObjectException - Binder 句柄失效"
            errors_found=true
        fi
        
        # 检查 TransactionTooLargeException
        if grep -r "TransactionTooLargeException" "${LOG_DIR}" 2>/dev/null; then
            echo "发现 TransactionTooLargeException"
            errors_found=true
        fi
        
        # 检查 Binder 事务失败
        if grep -r "binder transaction failed" "${LOG_DIR}" 2>/dev/null; then
            echo "发现 Binder 事务失败"
            errors_found=true
        fi
        
        if [[ "$errors_found" == false ]]; then
            echo "未检测到明显的 Binder 错误"
        fi
        
        echo ""
        echo "--- 结论 ---"
        if [[ "$errors_found" == true ]]; then
            echo "实验成功复现了 Binder 句柄失效问题"
        else
            echo "可能需要更多测试用例或不同的快照方式"
        fi
        
    } > "${analysis_file}"
    
    cat "${analysis_file}"
}

# 快速测试（不做完整快照）
quick_test() {
    log_step "执行快速 Binder 测试..."
    
    check_container_running
    check_adb_connected
    ensure_dirs
    
    test_binder_functionality "quick"
    collect_binder_state "${LOG_DIR}/binder_state_quick.log" "快速测试"
}

print_usage() {
    echo "容器快照/恢复实验脚本"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "命令:"
    echo "  run-experiment       运行完整实验流程"
    echo "  quick-test           快速测试 Binder 功能"
    echo "  checkpoint [name]    创建 CRIU checkpoint"
    echo "  restore-cp <name>    从 checkpoint 恢复"
    echo "  snapshot [name]      创建镜像快照"
    echo "  restore-snap <name>  从镜像快照恢复"
    echo "  collect-state        收集当前 Binder 状态"
    echo "  test-binder          测试 Binder 功能"
    echo "  analyze              分析最近的实验结果"
    echo ""
    echo "示例:"
    echo "  $0 run-experiment    # 运行完整实验"
    echo "  $0 quick-test        # 快速测试"
    echo "  $0 snapshot test1    # 创建名为 test1 的快照"
}

main() {
    case "${1:-help}" in
        run-experiment)
            run_full_experiment
            ;;
        quick-test)
            quick_test
            ;;
        checkpoint)
            create_docker_checkpoint "$2"
            ;;
        restore-cp)
            restore_docker_checkpoint "$2"
            ;;
        snapshot)
            create_commit_snapshot "$2"
            ;;
        restore-snap)
            restore_commit_snapshot "$2"
            ;;
        collect-state)
            ensure_dirs
            check_container_running
            check_adb_connected
            collect_binder_state "${LOG_DIR}/binder_state_$(date +%Y%m%d-%H%M%S).log" "手动收集"
            ;;
        test-binder)
            ensure_dirs
            check_container_running
            check_adb_connected
            test_binder_functionality "manual"
            ;;
        analyze)
            local latest_dir=$(ls -td "${LOG_DIR}"/experiment_* 2>/dev/null | head -1)
            if [[ -n "$latest_dir" ]]; then
                analyze_results "$latest_dir"
            else
                log_error "未找到实验结果"
            fi
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
