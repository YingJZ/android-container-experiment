#!/bin/bash
#
# 修复 Binder 设备节点
# 手动创建 /dev/binder 等设备节点
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本需要 root 权限"
    exit 1
fi

log_info "检查 binder 模块状态..."

if ! lsmod | grep -q "^binder_linux"; then
    log_error "binder_linux 模块未加载"
    log_info "尝试加载模块..."
    modprobe binder_linux devices="binder,hwbinder,vndbinder"
fi

# 方法 1: 检查并手动创建设备节点
create_device_nodes() {
    log_info "检查 /dev/binderfs..."
    
    # 检查是否支持 binderfs
    if grep -q binderfs /proc/filesystems 2>/dev/null; then
        log_info "系统支持 binderfs，使用 binderfs..."
        
        # 创建挂载点
        mkdir -p /dev/binderfs
        
        # 挂载 binderfs
        if ! mountpoint -q /dev/binderfs 2>/dev/null; then
            mount -t binder binder /dev/binderfs
            log_info "binderfs 已挂载到 /dev/binderfs"
        fi
        
        # 创建符号链接
        ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null || true
        ln -sf /dev/binderfs/hwbinder /dev/hwbinder 2>/dev/null || true
        ln -sf /dev/binderfs/vndbinder /dev/vndbinder 2>/dev/null || true
        
        log_info "设备节点符号链接已创建"
    else
        log_warn "系统不支持 binderfs，尝试使用 misc 设备..."
        
        # 尝试从 /sys/class/misc 获取设备号
        if [[ -d /sys/class/misc/binder ]]; then
            MAJOR=$(cat /sys/class/misc/binder/dev | cut -d: -f1)
            MINOR=$(cat /sys/class/misc/binder/dev | cut -d: -f2)
            
            if [[ ! -c /dev/binder ]]; then
                mknod /dev/binder c $MAJOR $MINOR
                chmod 666 /dev/binder
                log_info "创建 /dev/binder (${MAJOR}:${MINOR})"
            fi
        else
            log_warn "/sys/class/misc/binder 不存在"
        fi
        
        # hwbinder
        if [[ -d /sys/class/misc/hwbinder ]]; then
            MAJOR=$(cat /sys/class/misc/hwbinder/dev | cut -d: -f1)
            MINOR=$(cat /sys/class/misc/hwbinder/dev | cut -d: -f2)
            
            if [[ ! -c /dev/hwbinder ]]; then
                mknod /dev/hwbinder c $MAJOR $MINOR
                chmod 666 /dev/hwbinder
                log_info "创建 /dev/hwbinder (${MAJOR}:${MINOR})"
            fi
        fi
        
        # vndbinder
        if [[ -d /sys/class/misc/vndbinder ]]; then
            MAJOR=$(cat /sys/class/misc/vndbinder/dev | cut -d: -f1)
            MINOR=$(cat /sys/class/misc/vndbinder/dev | cut -d: -f2)
            
            if [[ ! -c /dev/vndbinder ]]; then
                mknod /dev/vndbinder c $MAJOR $MINOR
                chmod 666 /dev/vndbinder
                log_info "创建 /dev/vndbinder (${MAJOR}:${MINOR})"
            fi
        fi
    fi
}

# 方法 2: 创建 udev 规则（永久方案）
create_udev_rules() {
    log_info "创建 udev 规则..."
    
    cat > /etc/udev/rules.d/99-android-binder.rules << 'EOF'
# Android Binder devices
KERNEL=="binder", MODE="0666"
KERNEL=="hwbinder", MODE="0666"
KERNEL=="vndbinder", MODE="0666"
KERNEL=="ashmem", MODE="0666"
EOF
    
    log_info "udev 规则已创建"
    
    # 重新加载 udev 规则
    udevadm control --reload-rules
    udevadm trigger
    
    log_info "udev 规则已重新加载"
}

# 验证设备
verify_devices() {
    echo ""
    echo "========================================"
    echo "        设备节点验证"
    echo "========================================"
    
    if [[ -c /dev/binder ]]; then
        echo -e "/dev/binder:     ${GREEN}✓ 存在${NC} ($(ls -l /dev/binder))"
    elif [[ -L /dev/binder ]]; then
        echo -e "/dev/binder:     ${GREEN}✓ 符号链接${NC} -> $(readlink /dev/binder)"
    else
        echo -e "/dev/binder:     ${RED}✗ 不存在${NC}"
    fi
    
    if [[ -c /dev/hwbinder ]]; then
        echo -e "/dev/hwbinder:   ${GREEN}✓ 存在${NC} ($(ls -l /dev/hwbinder))"
    elif [[ -L /dev/hwbinder ]]; then
        echo -e "/dev/hwbinder:   ${GREEN}✓ 符号链接${NC} -> $(readlink /dev/hwbinder)"
    else
        echo -e "/dev/hwbinder:   ${YELLOW}⚠ 不存在${NC}"
    fi
    
    if [[ -c /dev/vndbinder ]]; then
        echo -e "/dev/vndbinder:  ${GREEN}✓ 存在${NC} ($(ls -l /dev/vndbinder))"
    elif [[ -L /dev/vndbinder ]]; then
        echo -e "/dev/vndbinder:  ${GREEN}✓ 符号链接${NC} -> $(readlink /dev/vndbinder)"
    else
        echo -e "/dev/vndbinder:  ${YELLOW}⚠ 不存在${NC}"
    fi
    
    if [[ -c /dev/ashmem ]] || [[ -L /dev/ashmem ]]; then
        echo -e "/dev/ashmem:     ${GREEN}✓ 存在${NC}"
    else
        echo -e "/dev/ashmem:     ${YELLOW}⚠ 不存在${NC} (可选)"
    fi
    
    echo "========================================"
    echo ""
}

main() {
    echo "========================================"
    echo "  修复 Binder 设备节点"
    echo "========================================"
    echo ""
    
    create_device_nodes
    create_udev_rules
    
    sleep 1
    
    verify_devices
    
    # 如果仍然没有 /dev/binder，给出建议
    if [[ ! -c /dev/binder ]] && [[ ! -L /dev/binder ]]; then
        echo ""
        log_warn "宿主机 /dev/binder 设备节点创建失败"
        echo ""
        echo "⚠️ 这在某些内核版本中是已知问题"
        echo ""
        echo "✅ 好消息：这不影响 ReDroid 实验！"
        echo ""
        echo "ReDroid 容器会在内部创建 binder 设备，Android 系统可以正常工作。"
        echo ""
        echo "继续操作："
        echo "  1. 直接启动容器: ./scripts/redroid-manage.sh start"
        echo "  2. 验证容器内 binder: docker exec redroid-experiment ls -la /dev/binder"
        echo "  3. 如果容器启动成功，就可以继续实验"
        echo ""
        echo "如果容器无法启动，可以尝试："
        echo "  - 升级内核: sudo apt install linux-image-generic-hwe-20.04"
        echo "  - 安装 Anbox 模块: sudo add-apt-repository ppa:morphis/anbox-support"
        echo "  - 查看详细说明: cat docs/binder-device-issue.md"
        echo ""
    else
        log_info "✓ 设备节点修复完成！"
        log_info "现在可以启动 ReDroid 容器了"
    fi
}

main "$@"
