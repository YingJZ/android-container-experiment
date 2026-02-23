#!/bin/bash
#
# 环境设置脚本 - 安装 ReDroid 所需的依赖和内核模块
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

check_kernel_version() {
    log_info "检查内核版本..."
    KERNEL_VERSION=$(uname -r)
    log_info "当前内核版本: $KERNEL_VERSION"
    
    # 检查是否 >= 5.0
    MAJOR_VERSION=$(echo $KERNEL_VERSION | cut -d. -f1)
    if [[ $MAJOR_VERSION -lt 5 ]]; then
        log_warn "内核版本较低，可能不支持所需模块。建议升级到 5.4+"
    fi
}

install_docker() {
    log_info "检查 Docker 安装状态..."
    
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version)
        log_info "Docker 已安装: $DOCKER_VERSION"
    else
        log_info "安装 Docker..."
        
        # 安装依赖
        apt-get update
        apt-get install -y \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        # 添加 Docker GPG 密钥
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        
        # 添加 Docker 仓库
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # 安装 Docker
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        
        log_info "Docker 安装完成"
    fi
    
    # 确保 Docker 服务运行
    systemctl enable docker
    systemctl start docker
}

install_kernel_modules() {
    log_info "安装内核模块..."
    
    # 获取当前内核版本
    KERNEL_VERSION=$(uname -r)
    
    # 安装 linux-modules-extra（包含 binder 和 ashmem 模块）
    apt-get update
    apt-get install -y linux-modules-extra-${KERNEL_VERSION} || {
        log_warn "无法安装 linux-modules-extra-${KERNEL_VERSION}"
        log_info "尝试使用 DKMS 方式安装..."
        install_modules_dkms
        return
    }
    
    log_info "内核模块安装完成"
}

install_modules_dkms() {
    log_info "使用 DKMS 方式安装 binder 和 ashmem 模块..."
    
    apt-get install -y dkms git
    
    # 克隆 anbox-modules
    if [[ ! -d /usr/src/anbox-modules ]]; then
        git clone https://github.com/AsteroidOS/anbox-modules.git /usr/src/anbox-modules
    fi
    
    cd /usr/src/anbox-modules
    
    # 安装 ashmem
    if [[ -d ashmem ]]; then
        cp -r ashmem /usr/src/ashmem-1
        dkms install ashmem/1 || log_warn "ashmem DKMS 安装失败"
    fi
    
    # 安装 binder
    if [[ -d binder ]]; then
        cp -r binder /usr/src/binder-1
        dkms install binder/1 || log_warn "binder DKMS 安装失败"
    fi
}

load_kernel_modules() {
    log_info "加载内核模块..."
    
    # 加载 binder 模块
    if lsmod | grep -q "^binder"; then
        log_info "binder 模块已加载"
    else
        log_info "加载 binder_linux 模块..."
        modprobe binder_linux devices="binder,hwbinder,vndbinder" || {
            log_error "无法加载 binder_linux 模块"
            log_info "请检查内核模块是否正确安装"
            return 1
        }
    fi
    
    # 加载 ashmem 模块（可选，新版本可用 memfd 替代）
    if lsmod | grep -q "^ashmem"; then
        log_info "ashmem 模块已加载"
    else
        log_info "加载 ashmem_linux 模块..."
        modprobe ashmem_linux || {
            log_warn "无法加载 ashmem_linux 模块"
            log_info "将使用 memfd 作为替代方案"
        }
    fi
    
    # 验证 binder 设备
    log_info "验证 binder 设备..."
    if [[ -c /dev/binder ]]; then
        log_info "✓ /dev/binder 存在"
    else
        log_error "✗ /dev/binder 不存在"
    fi
    
    if [[ -c /dev/hwbinder ]]; then
        log_info "✓ /dev/hwbinder 存在"
    else
        log_warn "✗ /dev/hwbinder 不存在"
    fi
    
    if [[ -c /dev/vndbinder ]]; then
        log_info "✓ /dev/vndbinder 存在"
    else
        log_warn "✗ /dev/vndbinder 不存在"
    fi
}

setup_modules_autoload() {
    log_info "设置模块开机自动加载..."
    
    # 创建模块配置文件
    cat > /etc/modules-load.d/redroid.conf << EOF
# ReDroid 所需内核模块
binder_linux
ashmem_linux
EOF
    
    # 创建模块参数配置
    cat > /etc/modprobe.d/redroid.conf << EOF
# Binder 设备配置
options binder_linux devices="binder,hwbinder,vndbinder"
EOF
    
    log_info "模块自动加载配置完成"
}

install_adb() {
    log_info "安装 ADB 工具..."
    
    if command -v adb &> /dev/null; then
        ADB_VERSION=$(adb --version | head -n1)
        log_info "ADB 已安装: $ADB_VERSION"
    else
        apt-get install -y android-tools-adb android-tools-fastboot
        log_info "ADB 安装完成"
    fi
}

install_scrcpy() {
    log_info "安装 scrcpy（屏幕镜像工具）..."
    
    if command -v scrcpy &> /dev/null; then
        log_info "scrcpy 已安装"
    else
        apt-get install -y scrcpy || {
            log_warn "无法从仓库安装 scrcpy"
            log_info "可以手动安装: https://github.com/Genymobile/scrcpy"
        }
    fi
}

install_criu() {
    log_info "安装 CRIU（Checkpoint/Restore）..."
    
    if command -v criu &> /dev/null; then
        CRIU_VERSION=$(criu --version | head -n1)
        log_info "CRIU 已安装: $CRIU_VERSION"
    else
        # 尝试从默认仓库安装
        if apt-get install -y criu 2>/dev/null; then
            log_info "CRIU 安装完成"
        else
            log_warn "无法从默认仓库安装 CRIU"
            log_info "尝试从其他源安装..."
            
            # 尝试从 PPA 安装（适用于 Ubuntu）
            if command -v add-apt-repository &> /dev/null; then
                add-apt-repository -y ppa:criu/ppa 2>/dev/null || true
                apt-get update 2>/dev/null || true
                
                if apt-get install -y criu 2>/dev/null; then
                    log_info "CRIU 从 PPA 安装完成"
                else
                    log_warn "CRIU 安装失败（这不影响实验，可使用 docker commit 替代）"
                    return 0
                fi
            else
                log_warn "CRIU 安装失败（这不影响实验，可使用 docker commit 替代）"
                return 0
            fi
        fi
    fi
    
    # 验证 CRIU 功能
    if command -v criu &> /dev/null; then
        log_info "验证 CRIU 功能..."
        criu check || log_warn "CRIU 检查未完全通过，部分功能可能不可用"
    fi
}

verify_environment() {
    log_info "验证环境配置..."
    
    echo ""
    echo "========================================"
    echo "        环境验证结果"
    echo "========================================"
    
    # Docker
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        echo -e "Docker:          ${GREEN}✓${NC}"
    else
        echo -e "Docker:          ${RED}✗${NC}"
    fi
    
    # Binder 模块
    if lsmod | grep -q "^binder"; then
        echo -e "Binder 模块:     ${GREEN}✓${NC}"
    else
        echo -e "Binder 模块:     ${RED}✗${NC}"
    fi
    
    # Binder 设备
    if [[ -c /dev/binder ]]; then
        echo -e "/dev/binder:     ${GREEN}✓${NC}"
    else
        echo -e "/dev/binder:     ${RED}✗${NC}"
    fi
    
    # ADB
    if command -v adb &> /dev/null; then
        echo -e "ADB:             ${GREEN}✓${NC}"
    else
        echo -e "ADB:             ${RED}✗${NC}"
    fi
    
    # CRIU
    if command -v criu &> /dev/null; then
        echo -e "CRIU:            ${GREEN}✓${NC}"
    else
        echo -e "CRIU:            ${YELLOW}✗ (可选)${NC}"
    fi
    
    echo "========================================"
    echo ""
}

print_usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --all          安装所有组件（默认）"
    echo "  --docker       仅安装 Docker"
    echo "  --modules      仅安装和加载内核模块"
    echo "  --tools        仅安装工具（ADB, scrcpy, CRIU）"
    echo "  --verify       仅验证环境"
    echo "  --help         显示此帮助信息"
}

main() {
    echo "========================================"
    echo "  Android 容器实验环境设置"
    echo "========================================"
    echo ""
    
    check_root
    
    case "${1:-all}" in
        --all|all)
            check_kernel_version
            install_docker
            install_kernel_modules
            load_kernel_modules
            setup_modules_autoload
            install_adb
            install_scrcpy
            install_criu
            verify_environment
            ;;
        --docker)
            install_docker
            ;;
        --modules)
            install_kernel_modules
            load_kernel_modules
            setup_modules_autoload
            ;;
        --tools)
            install_adb
            install_scrcpy
            install_criu
            ;;
        --verify)
            verify_environment
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            log_error "未知选项: $1"
            print_usage
            exit 1
            ;;
    esac
    
    log_info "设置完成！"
}

main "$@"
