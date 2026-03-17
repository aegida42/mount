# VPN Auto-Mount (macOS LaunchAgent)

Mountet SMB-Shares automatisch nach VPN-Reconnect und fuehrt Recovery-Mounts aus, wenn Shares fehlen.

## Dateien

- `vpn_mount_drp.sh`: Mount-Logik
- `LaunchAgents/com.drp.vpn_mount_drp.plist`: LaunchAgent-Konfiguration

## Installation / Deploy

```bash
cp vpn_mount_drp.sh ~/vpn_mount_drp.sh
chmod +x ~/vpn_mount_drp.sh
cp LaunchAgents/com.drp.vpn_mount_drp.plist ~/Library/LaunchAgents/com.drp.vpn_mount_drp.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.drp.vpn_mount_drp.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.drp.vpn_mount_drp.plist
launchctl kickstart -k gui/$(id -u)/com.drp.vpn_mount_drp
```

## Verhalten

- Pruefintervall: `30` Sekunden (`StartInterval` im plist)
- Erkennt VPN-Interface ueber `utun*`
- Startet Mount-Lauf bei:
  - VPN-Reconnect (`vpn_down -> vpn_up`)
  - fehlenden Shares trotz aktivem VPN (Recovery)
- Bei Mount-Fehlern:
  - Fehler im Log mit Share-Liste
  - macOS-Notification `VPN-Mount Fehler`

## Logs

- `~/Library/Logs/vpn_mount_drp.log`
- `~/Library/Logs/vpn_mount_drp.err`

## Nützliche Befehle

```bash
# Agent-Status
launchctl print gui/$(id -u)/com.drp.vpn_mount_drp

# Sofortiger Lauf
launchctl kickstart -k gui/$(id -u)/com.drp.vpn_mount_drp

# Letzte Logzeilen
tail -n 50 ~/Library/Logs/vpn_mount_drp.log
```
