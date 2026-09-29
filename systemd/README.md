# systemd scheduling (Linux / Raspberry Pi)

| File                      | Installed to                                   |
|---------------------------|------------------------------------------------|
| `network-monitor.service` | `/etc/systemd/system/network-monitor.service` (`@AGENT_USER@`/`@AGENT_GROUP@` filled in by `install.sh`) |
| `network-monitor.timer`   | `/etc/systemd/system/network-monitor.timer`    |

- The **timer** wakes the service every 5 minutes (`OnCalendar=*:0/5`,
  `Persistent=true`).
- The **service** (`Type=oneshot`, runs as the agent user) executes
  `network-speedtest --scheduled` and exits. The agent measures only inside
  the device's slot (interval/offset from notes.pidiman.sk) and at most once
  per slot; otherwise it logs one line and exits in milliseconds.
- State: `/var/lib/notes-network-monitor` (`StateDirectory=`), holds only the
  last measured slot and a lock file.

Installed, updated and removed by `install.sh` / `uninstall.sh` — do not copy
the files manually. See the main [README](../README.md#scheduling).

```bash
systemctl status network-monitor.timer
systemctl list-timers | grep network-monitor
journalctl -u network-monitor.service
```
