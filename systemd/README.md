# systemd (planned)

Scheduling is **not implemented yet**. The agent is currently run manually:

```bash
network-speedtest
```

A future step will add a systemd service + timer that uses
`interval_minutes` / `offset_minutes` from `GET /api/network/config`.
The agent already runs non-interactively (Ookla license is accepted via
`--accept-license --accept-gdpr`, all network calls have timeouts), so it is
ready to be wrapped by a timer.
