# linux_backdoor_check
linux持久化的检查项。还是倾向于手动确认，所以只是查找一些文件，按时间排序并输出，内容需要手动确认
适用于挖矿、入侵排查场景

## 检查项
1. 系统 Cron 配置检查
2. 周期性任务检查
3. Anacron 配置检查
4. 列出所有 Systemd 定时器
5. 查看自启动的 service (使用systemctl检查)(按单元文件的修改时间排序，前 20 条)
6. 列出 Systemd 单元文件目录下的所有文件，并按修改时间排序 (前 20 条)
7. 检查 SysVinit 启动相关文件（rc.local、init.d、rcX.d）的修改时间和内容
8. /etc/profile.d/ (bash的全局配置文件)目录下的文件的修改时间
9. bash配置文件检查 (按修改时间从新到旧排序)
10. 检查 SSH authorized_keys 文件
11. 其他有用的检查命令参考

## 效果
<img width="711" alt="image" src="https://github.com/user-attachments/assets/b28a43a4-90de-4281-bc15-34dee0cf2c40" />

---

<img width="691" alt="image" src="https://github.com/user-attachments/assets/eb36c75d-0815-43cf-8e75-2a1fb8f56562" />

---

<img width="760" alt="image" src="https://github.com/user-attachments/assets/a6ebecdc-2bf7-4f45-bdbc-e5d11c912ad7" />
