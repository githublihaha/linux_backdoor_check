#!/bin/bash

# 设置 busybox 路径
BUSYBOX="./busybox"

# 检查 busybox 是否存在且可执行
if [ ! -x "$BUSYBOX" ]; then
    echo "错误: busybox 不存在或没有执行权限"
    exit 1
fi

# 定义要检查的 cron 相关路径
declare -A CRON_PATHS=(
    ["系统 crontab"]="/etc/crontab"
    ["cron.d 目录"]="/etc/cron.d"
    ["用户 cron 任务"]="/var/spool/cron"
)

# 定义周期性任务路径
declare -A PERIODIC_TASKS=(
    ["每小时任务"]="/etc/cron.hourly"
    ["每天任务"]="/etc/cron.daily"
    ["每周任务"]="/etc/cron.weekly"
    ["每月任务"]="/etc/cron.monthly"
)

# 定义 Anacron 相关路径
declare -A ANACRON_PATHS=(
    ["Anacron 配置"]="/etc/anacrontab"
    ["Anacron 运行记录"]="/var/spool/anacron"
)

# 定义 AT 任务相关路径
declare -A AT_PATHS=(
    ["AT 任务目录"]="/var/spool/at"
    ["AT spool 目录"]="/var/spool/cron/atspool"
    ["AT jobs 目录"]="/var/spool/cron/atjobs"
)

echo "============================================================"
echo "开始检查系统定时任务配置..."
echo "============================================================"

# 1. 检查基本的 cron 配置
echo; echo "============================================================"
echo ">>> 1. 系统 Cron 配置检查"
echo "============================================================"

for desc in "${!CRON_PATHS[@]}"; do
    path="${CRON_PATHS[$desc]}"
    echo; echo "------------------------------------------------------------"
    echo "[+] $desc ($path)"
    echo "------------------------------------------------------------"
    
    if [ -f "$path" ]; then
        $BUSYBOX cat "$path" || echo "无法访问 $path"
    elif [ -d "$path" ]; then
        files=$($BUSYBOX ls "$path" 2>/dev/null)
        if [ -z "$files" ]; then
            echo "目录为空或无法访问"
        else
            for file in "$path"/*; do
                if [ -f "$file" ]; then
                    echo "文件: $($BUSYBOX basename "$file")"
                    echo "----------------------------------------"
                    $BUSYBOX cat -v "$file"
                    echo
                fi
            done
        fi
    else
        echo "路径不存在"
    fi
done

# 2. 检查周期性任务配置和最后运行时间
echo; echo "============================================================"
echo ">>> 2. 周期性任务检查"
echo "============================================================"

for desc in "${!PERIODIC_TASKS[@]}"; do
    path="${PERIODIC_TASKS[$desc]}"
    echo; echo "------------------------------------------------------------"
    echo "[+] $desc ($path)"
    echo "------------------------------------------------------------"
    
    if [ -d "$path" ]; then
        # 首先显示目录中的任务列表
        echo "任务列表:"
        $BUSYBOX ls -l "$path" | $BUSYBOX grep -v '^total' || echo "目录为空"
        echo
        
        # 然后显示每个任务的最后运行时间
        echo "最后运行时间:"
        for task in "$path"/*; do
            if [ -f "$task" ]; then
                task_name=$($BUSYBOX basename "$task")
                timestamp_file="/var/spool/anacron/${task_name}"
                if [ -f "$timestamp_file" ]; then
                    last_run=$($BUSYBOX cat "$timestamp_file" 2>/dev/null)
                    if [ -n "$last_run" ]; then
                        last_run_date=$($BUSYBOX date -d "@$last_run" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
                                      $BUSYBOX date -r "$last_run" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
                        echo "  - $task_name: $last_run_date"
                    else
                        echo "  - $task_name: 未找到运行记录"
                    fi
                else
                    echo "  - $task_name: 无时间戳文件"
                fi
            fi
        done
    else
        echo "目录不存在"
    fi
done

# 3. 检查 Anacron 配置
echo; echo "============================================================"
echo ">>> 3. Anacron 配置检查"
echo "============================================================"

for desc in "${!ANACRON_PATHS[@]}"; do
    path="${ANACRON_PATHS[$desc]}"
    echo; echo "------------------------------------------------------------"
    echo "[+] $desc ($path)"
    echo "------------------------------------------------------------"
    
    if [ -f "$path" ]; then
        $BUSYBOX cat "$path" || echo "无法访问"
    elif [ -d "$path" ]; then
        for file in "$path"/*; do
            if [ -f "$file" ]; then
                echo "文件: $($BUSYBOX basename "$file")"
                echo "----------------------------------------"
                $BUSYBOX cat -v "$file"
                echo
            fi
        done
    else
        echo "路径不存在"
    fi
done

# AT 任务检查
echo; echo "============================================================"
echo ">>> 4. AT 计划任务检查:"
echo "============================================================"

# 遍历检查 AT 相关目录
for desc in "${!AT_PATHS[@]}"; do
    path="${AT_PATHS[$desc]}"
    $BUSYBOX echo -e "\n检查 $desc ($path):"
    if [ -d "$path" ]; then
        $BUSYBOX ls -la "$path"
        # 检查目录中的文件内容
        for file in "$path"/*; do
            if [ -f "$file" ]; then
                $BUSYBOX echo -e "\n文件内容 $file:"
                $BUSYBOX cat -v "$file"
            fi
        done
    else
        echo "目录不存在: $path"
    fi
done

# Systemd timers
echo; echo "============================================================"
echo ">>> 5. 列出所有 Systemd 定时器:"
echo "============================================================"
systemctl list-timers --all --no-pager

# Systemd enabled services
# 聚焦于已启动的 services
echo; echo "============================================================"
echo ">>> 6. 查看自启动的 service (使用systemctl检查)(按单元文件的修改时间排序，前 20 条):"
echo "============================================================"
# 定义要检查的 Systemd 单元文件目录（仅包含可能包含已启用服务的路径）
directories=("/etc/systemd/system/" "/usr/lib/systemd/system/")

# 初始化关联数组，用于跟踪文件的真实路径
declare -A seen_files
# 初始化数组来存储文件的路径和修改时间
file_info=()

# 获取已启用服务列表
while read unit _; do
  # 检查服务名称是否包含 '@'，如果包含，则跳过
  if [[ "$unit" == *@* ]]; then
    continue
  fi

  # 使用 systemctl show 来获取服务文件的绝对路径
  path=$(systemctl show -p FragmentPath "$unit" | $BUSYBOX cut -d'=' -f2)

  # 检查路径是否存在且是 .service 文件
  if [[ -f "$path" ]] && [[ "$path" == *.service ]]; then
    # 获取文件的真实路径，避免重复
    real_path=$($BUSYBOX readlink -f "$path")
    if [ -z "${seen_files[$real_path]}" ]; then
      seen_files[$real_path]=1
      # 获取文件的修改时间
      mod_time=$($BUSYBOX stat -c %Y "$real_path" 2>/dev/null || $BUSYBOX stat -f %m "$real_path" 2>/dev/null)
      if [ -n "$mod_time" ]; then
        file_info+=("$mod_time:$real_path")
      fi
    fi
  fi
done < <(systemctl list-unit-files | $BUSYBOX grep enabled)

# 按照修改时间排序文件信息（从新到旧）
IFS=$'\n' sorted_info=($($BUSYBOX sort -rn <<<"${file_info[*]}"))
unset IFS

# 打印排序后的前 20 条 .service 文件信息
count=0
for info in "${sorted_info[@]}"; do
  if [ $count -ge 20 ]; then
    break
  fi
  mod_time=${info%%:*}
  path=${info#*:}
  # 转换时间戳为可读格式
  readable_time=$($BUSYBOX date -d "@$mod_time" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || $BUSYBOX date -r "$mod_time" +"%Y-%m-%d %H:%M:%S" 2>/dev/null)
  if [ -n "$readable_time" ]; then
    echo "$readable_time - $path"
    ((count++))
  fi
done

# 如果少于 20 条，提示
if [ $count -eq 0 ]; then
  echo "未找到任何已启用的 .service 文件。"
fi

# Systemd enabled services
# 列出所有文件
echo; echo "============================================================"
echo ">>> 7. 列出 Systemd 单元文件目录下的所有文件，并按修改时间排序 (前 20 条):"
echo "============================================================"
# 定义要检查的 Systemd 单元文件目录
directories=("/etc/systemd/system/" "/usr/lib/systemd/system/" "/lib/systemd/system/" "/run/systemd/system/")

# 初始化关联数组，用于跟踪文件的真实路径，避免重复处理符号链接指向的同一文件
declare -A seen_files
# 初始化数组来存储文件的路径和修改时间
file_info=()

# 遍历目录
for dir in "${directories[@]}"; do
    if [ -d "$dir" ]; then
        # 输出当前目录路径
        echo "检查目录: $dir"
        # 处理目录下的所有文件
        for item in "$dir"*; do
            # 跳过目录本身的通配符展开
            [ "$item" = "$dir*" ] && continue
            
            real_path=""
            # 检查是否为符号链接或普通文件
            if [ -L "$item" ]; then
                # 获取符号链接指向的真实文件路径
                real_path=$($BUSYBOX readlink -f "$item")
            elif [ -f "$item" ]; then
                real_path="$item"
            fi
            
            # 如果文件存在且未被处理过
            if [ -n "$real_path" ] && [ -z "${seen_files[$real_path]}" ]; then
                seen_files["$real_path"]=1
                # 获取文件的修改时间
                mod_time=$($BUSYBOX stat -c %Y "$real_path" 2>/dev/null || $BUSYBOX stat -f %m "$real_path" 2>/dev/null)
                # 确保 mod_time 不为空
                if [ -n "$mod_time" ]; then
                    # 将文件路径和修改时间存储到数组中
                    file_info+=("$mod_time:$real_path")
                fi
            fi
        done
    else
        echo "目录不存在: $dir"
    fi
done

# 按照修改时间排序文件信息（从新到旧，-r 降序）
IFS=$'\n' sorted_info=($($BUSYBOX sort -rn <<<"${file_info[*]}"))
unset IFS

# 打印排序后的前 20 条文件信息
echo; echo "------------------------------------------------------------"
echo "[+]按修改时间从新到旧排序的文件 (前 20 条):"
echo "------------------------------------------------------------"

count=0
for info in "${sorted_info[@]}"; do
    if [ $count -ge 20 ]; then
        break
    fi
    mod_time=${info%%:*}
    path=${info#*:}
    # 转换时间戳为可读格式
    readable_time=$($BUSYBOX date -d "@$mod_time" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || $BUSYBOX date -r "$mod_time" +"%Y-%m-%d %H:%M:%S" 2>/dev/null)
    if [ -n "$readable_time" ]; then
        if [ -L "${path%/*}/${path##*/}" ]; then
            # 如果是符号链接，显示链接信息
            link_target=$($BUSYBOX readlink -f "${path%/*}/${path##*/}")
            echo "$readable_time - ${path%/*}/${path##*/} -> $link_target"
        else
            echo "$readable_time - $path"
        fi
        ((count++))
    fi
done

# 如果少于 20 条，提示
if [ $count -eq 0 ]; then
    echo "未找到任何文件。"
fi

# SysVinit 检查
echo; echo "============================================================"
echo ">>> 8. 检查 SysVinit 启动相关文件（rc.local、init.d、rcX.d）的修改时间和内容:"
echo "============================================================"

# 定义要检查的目录和文件
directories_and_files=(
    "/etc/rc.local"
    "/etc/rc0.d"
    "/etc/rc1.d"
    "/etc/rc2.d"
    "/etc/rc3.d"
    "/etc/rc4.d"
    "/etc/rc5.d"
    "/etc/rc6.d"
    "/etc/init.d"
    "/etc/inittab"
    "/etc/rc.d/init.d"
    "/etc/rc.d/rc0.d"
    "/etc/rc.d/rc1.d"
    "/etc/rc.d/rc2.d"
    "/etc/rc.d/rc3.d"
    "/etc/rc.d/rc4.d"
    "/etc/rc.d/rc5.d"
    "/etc/rc.d/rc6.d"
)

echo "将检查以下路径:"
echo "------------------------------------------------------------"
for path in "${directories_and_files[@]}"; do
    if [ -e "$path" ]; then
        echo "[存在] $path"
    else
        echo "[不存在] $path"
    fi
done
echo "------------------------------------------------------------"
echo

# 检查文件是否全为注释或空行的函数
is_all_comments_or_empty() {
    local file="$1"
    local content
    content=$($BUSYBOX grep -v '^[[:space:]]*#' "$file" | $BUSYBOX grep -v '^[[:space:]]*$')
    [ -z "$content" ]
}

# 初始化关联数组，用于跟踪文件的真实路径，避免重复处理符号链接指向的同一文件
declare -A seen_files
# 初始化数组来存储文件的路径和修改时间
file_info=()

# 遍历目录和文件
for item in "${directories_and_files[@]}"; do
    if [ -f "$item" ]; then
        # 处理文件（如 /etc/rc.local）
        real_path="$item"
        if [ -z "${seen_files[$real_path]}" ]; then
            seen_files[$real_path]=1
            # 获取文件的修改时间
            mod_time=$($BUSYBOX stat -c %Y "$real_path" 2>/dev/null || $BUSYBOX stat -f %m "$real_path" 2>/dev/null)
            if [ -n "$mod_time" ]; then
                # 将文件路径和修改时间存储到数组中
                file_info+=("$mod_time:$real_path")
            fi
            # 输出文件内容（仅对 /etc/rc.local）
            if [[ "$item" == "/etc/rc.local" ]]; then
                echo; echo "------------------------------------------------------------"
                echo "[+]/etc/rc.local 内容:"
                echo "------------------------------------------------------------"
                $BUSYBOX cat -v "$item" 2>/dev/null || echo "无法访问 /etc/rc.local"
            fi
        fi
    elif [ -d "$item" ]; then
        # 遍历目录下的所有文件和链接
        for file in "$item"/*; do
            real_path=""
            # 检查是否为符号链接或普通文件
            if [ -L "$file" ]; then
                # 获取符号链接指向的真实文件
                real_path=$($BUSYBOX readlink -f "$file")
            elif [ -f "$file" ]; then
                real_path="$file"
            fi
            # 如果文件存在且未被处理过
            if [ -n "$real_path" ] && [ -z "${seen_files[$real_path]}" ]; then
                seen_files[$real_path]=1
                # 获取文件的修改时间
                mod_time=$($BUSYBOX stat -c %Y "$real_path" 2>/dev/null || $BUSYBOX stat -f %m "$real_path" 2>/dev/null)
                if [ -n "$mod_time" ]; then
                    # 将文件路径和修改时间存储到数组中
                    file_info+=("$mod_time:$real_path")
                fi
            fi
        done
    fi
done

# 按照修改时间排序文件信息（从新到旧）
IFS=$'\n' sorted_info=($($BUSYBOX sort -rn <<<"${file_info[*]}"))
unset IFS

# 打印排序后的文件信息
echo; echo "------------------------------------------------------------"
echo "[+]以上目录中所有文件，按修改时间从新到旧排序列表:"
echo "------------------------------------------------------------"
for info in "${sorted_info[@]}"; do
    mod_time=${info%%:*}
    path=${info#*:}
    # 转换时间戳为可读格式
    readable_time=$($BUSYBOX date -d "@$mod_time" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || $BUSYBOX date -r "$mod_time" +"%Y-%m-%d %H:%M:%S" 2>/dev/null)
    if [ -n "$readable_time" ]; then
        echo "$readable_time - $path"
    fi
done

# 如果没有找到任何文件，提示
if [ ${#file_info[@]} -eq 0 ]; then
    echo "未找到任何相关文件。"
fi

# 检查/etc/profile.d/目录下的文件的修改时间
echo; echo "============================================================"
echo ">>> 9. /etc/profile.d/ (bash的全局配置文件)目录下的文件的修改时间:"
echo "============================================================"
echo "按修改时间从新到旧排序的文件列表:"
# 检查目录是否存在
if [ -d "/etc/profile.d/" ]; then
    # 按修改时间排序列出文件，最新的在前
    for file in $($BUSYBOX ls -lt "/etc/profile.d/" | $BUSYBOX grep '^-' | $BUSYBOX awk '{print $9}' | $BUSYBOX sed "s|^|"/etc/profile.d/"|"); do
        mod_time=$($BUSYBOX stat -c %Y "$file")
        readable_time=$($BUSYBOX date -d "@$mod_time" +"%Y-%m-%d %H:%M:%S")
        echo "$readable_time - $file"
    done
else
    echo "目录 $directory 不存在。"
fi

# bash files
echo; echo "============================================================"
echo ">>> 10. bash配置文件检查 (按修改时间从新到旧排序):"
echo "============================================================"

# 定义要检查的文件列表
bash_files=(
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
    "$HOME/.bash_aliases"
    "$HOME/.zshrc"
    "/etc/bash.bashrc"
    "/etc/profile"
    "/etc/bashrc"
    "$HOME/.profile"
    "$HOME/.bash_logout"
    "/etc/environment"
)

# 初始化数组来存储文件信息
file_info=()

# 收集文件信息
for file in "${bash_files[@]}"; do
    if [ -f "$file" ]; then
        # 获取文件的修改时间
        mod_time=$($BUSYBOX stat -c %Y "$file" 2>/dev/null || $BUSYBOX stat -f %m "$file" 2>/dev/null)
        if [ -n "$mod_time" ]; then
            file_info+=("$mod_time:$file")
        fi
    fi
done

# 按修改时间排序并显示
if [ ${#file_info[@]} -gt 0 ]; then
    # 排序文件信息（从新到旧）
    IFS=$'\n' sorted_info=($($BUSYBOX sort -rn <<<"${file_info[*]}"))
    unset IFS

    # 显示文件信息
    echo "检查到以下配置文件:"
    echo "------------------------------------------------------------"
    for info in "${sorted_info[@]}"; do
        mod_time=${info%%:*}
        file=${info#*:}
        readable_time=$($BUSYBOX date -d "@$mod_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
                       $BUSYBOX date -r "$mod_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        echo "$readable_time - $file"
    done
else
    echo "未找到任何相关配置文件"
fi

echo "------------------------------------------------------------"
echo "不存在的配置文件:"
for file in "${bash_files[@]}"; do
    if [ ! -f "$file" ]; then
        echo "[-][不存在] $file"
    fi
done

# SSH authorized_keys 检查
echo; echo "============================================================"
echo ">>> 11. 检查 SSH authorized_keys 文件:"
echo "============================================================"

# 定义要检查的 SSH 密钥文件
declare -A ssh_files=(
    ["$HOME/.ssh/authorized_keys"]="标准 OpenSSH 授权公钥文件"
    ["$HOME/.ssh/authorized_keys2"]="旧版 SSH2 授权公钥文件（已不推荐使用）"
)

for file in "${!ssh_files[@]}"; do
    if [ -f "$file" ]; then
        echo "------------------------------------------------------------"
        echo "[+] 文件: $file"
        echo "说明: ${ssh_files[$file]}"
        
        # 获取文件修改时间
        mod_time=$($BUSYBOX stat -c %Y "$file" 2>/dev/null || $BUSYBOX stat -f %m "$file" 2>/dev/null)
        if [ -n "$mod_time" ]; then
            readable_time=$($BUSYBOX date -d "@$mod_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
                          $BUSYBOX date -r "$mod_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            echo "最后修改时间: $readable_time"
        fi
        
        echo "------------------------------------------------------------"
        echo "[+]公钥列表:"
        # 读取并处理每个公钥
        while IFS= read -r line; do
            # 跳过空行和注释
            if [ -n "$line" ] && [[ ! "$line" =~ ^[[:space:]]*# ]]; then
                # 提取公钥类型和注释（如果有）
                key_type=$($BUSYBOX echo "$line" | $BUSYBOX awk '{print $1}')
                key_comment=$($BUSYBOX echo "$line" | $BUSYBOX awk '{if(NF>2) print $NF}')
                
                echo "类型: $key_type"
                if [ -n "$key_comment" ]; then
                    echo "备注: $key_comment"
                fi
                echo
            fi
        done < "$file"
        
        # 添加完整的文件内容显示
        echo "------------------------------------------------------------"
        echo "[+]文件完整内容 (cat -v 显示):"
        $BUSYBOX cat -v "$file"
        echo "------------------------------------------------------------"
        
        # 检查文件权限
        perms=$($BUSYBOX stat -c "%a" "$file")
        echo "[+]文件权限: $perms (建议: 600)"
        if [ "$perms" != "600" ]; then
            echo "[+]警告: 文件权限过于开放，建议执行: chmod 600 $file"
        fi
        
    else
        echo "[不存在] $file"
    fi
done

# 检查 .ssh 目录权限
if [ -d "$HOME/.ssh" ]; then
    perms=$($BUSYBOX stat -c "%a" "$HOME/.ssh")
    echo; echo "[+].ssh 目录权限: $perms (建议: 700)"
    if [ "$perms" != "700" ]; then
        echo "[+]警告: 目录权限过于开放，建议执行: chmod 700 $HOME/.ssh"
    fi
fi

# history 检查
echo; echo "============================================================"
echo ">>> 12. history 命令（包含时间, 最后20行）:"
echo "============================================================"

export HISTTIMEFORMAT='%F %T '
history | $BUSYBOX tail -n 20

echo "============================================================"
echo "任务检查完成。"
echo "============================================================"

echo; echo "============================================================"
echo ">>> 13. 其他有用的检查命令参考:"
echo "============================================================"
echo "1. 查看文件中的非注释和非空行:"
echo "   grep -E -v '^\s*($|#)' <文件路径>"
echo

echo "2. 查找最近24小时内修改过的文件:"
echo "   find / -mtime -1 -ls"
echo

echo "3. 查找最近60分钟内修改过的文件:"
echo "   find / -mmin -60 -ls"
echo

echo "4. 查看定时任务是否有可疑命令:"
echo "   grep -E '(wget|curl|bash|nc|ncat|perl|python|ruby|php|gcc|cc|chmod|chown)' /etc/cron*/*"
echo

echo "5. 检查系统服务的可疑监听端口:"
echo "   netstat -tlpn | grep -v '127.0.0.1'"
echo

echo "6. 检查定时任务中的IP地址和域名:"
echo "   grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}|[a-zA-Z0-9]+\.[a-zA-Z0-9]+\.[a-zA-Z0-9]+' /etc/cron*/*"
echo

echo "7. 递归搜索 /etc/systemd/system/ 目录，查找 ExecStart= 行，并筛选可疑命令:"
echo "   grep -r 'ExecStart=' /etc/systemd/system/ | grep -E '(wget|curl|bash|nc)'"
echo

echo "8. 搜索特定时间范围内的文件:"
echo '   find /path/to/search -type f -newermt "2024-07-19 12:30" ! -newermt "2024-07-19 15:28"'
echo

echo "9. 查看某个服务的日志:"
echo '   journalctl -u crond.service'
echo

echo "10. 系统完整性检查:"
echo '   CentOS: rpm -Va'
echo '   Ubuntu: apt install debsums && debsums --all --changed'
echo

echo "11. 内核模块:"
echo '   列模块(新安装的在最上面): lsmod'
echo '   查看模块信息: modinfo <模块名>'
echo

echo "12. 查看内核是否被污染(可能是安装了内核模块):"
echo '   如果值为 0，表示内核未被污染，是纯净状态'
echo '   如果值大于 0，表示内核被污染，且具体值反映了污染的原因'
echo '   cat /proc/sys/kernel/tainted'
echo

echo "13. 命令别名查询 alias:"
echo '   直接输入 alias 命令即可'
echo

echo "14. 使用 mount /proc/PID 隐藏进程的排查:"
echo '   查看挂载信息'
echo '   cat /proc/$$/mountinfo'
echo

echo "15. 进程、线程树:"
echo '   pstree -agplU'
echo

echo "16. 查看文件相关时间:"
echo '   stat xxx.sh'
echo

echo "17. 杀死进程组:"
echo '   kill -9 -PGID'
echo '   sudo kill -9 -- -PGID'
echo '   sudo pkill -g PGID'
echo

echo "18. 查看文件占用:"
echo '   lsof eval.sh'
echo

echo "19. 历史命令, 包含时间戳:"
echo '   export HISTTIMEFORMAT="%F %T "; history | $BUSYBOX tail -n 20'
echo

echo "20. 查看文件内容, 避免\r等转义符的影响:"
echo '   cat -v <filename>'
echo

echo "20. 其他常用命令:"
echo '   systemctl status pid'
echo '   ps -w axjf'
echo '   ls -al /proc/pid/exe'
echo

echo "注意: 以上命令仅供参考，请根据实际情况使用。"
echo "============================================================"


