# Walker VPN

A Bash menu for PIA WireGuard on NixOS. It opens in Walker's dmenu mode from a Waybar button. Systemd manages the host tunnel, recovery timer and Vopono app namespaces. It works with IWD and either openresolv or systemd-resolved.

## Install

1. Place this directory at `/etc/nixos/walker-vpn` or next to your tracked `sys.nix`. Add `./walker-vpn` to the imports in `sys.nix`. The module authorizes the sole normal user in `wheel`. If there are several, set `services.walker-vpn.user` to the intended desktop account.
2. Add `"custom/vpn"` to the desired Waybar module list and merge [module.json](waybar/module.json) into the top-level Waybar config. The [CSS snippet](waybar/style.css) is optional. If your Waybar configuration is generated, add the module to the source template.
3. Rebuild NixOS and reload Waybar. Walker must already be available in your graphical session. Flatpak support uses the desktop's existing Flatpak installation.
4. Click the VPN button and choose **Set up VPN → Private Internet Access (PIA)**. Enter your PIA VPN username and password in Walker. Choose a location or **Optimal**.

Systemd encrypts the login with the machine's credential key and saves it under `/var/lib/walker-vpn`, owned by root. The encryption key and generated WireGuard profiles stay on the machine. Use **Change VPN login…** or **Forget VPN login…** under **VPN settings…** to manage the saved login. PIA is the only provider listed. Its login, catalog and WireGuard registration are implemented in `lib/pia.sh` for future provider work.

## VPN and kill switch

**Connect to VPN…** or **Change VPN location…** searches the PIA locations. **Optimal** ranks reachable locations by TLS connection time. A successful connection arms the system kill switch by default. An explicit **Turn off kill switch** keeps automatic arming off for the rest of the boot. You can turn it back on from the menu.

**Disconnect and restore regular internet** stops recovery, tears down the host tunnel and opens the kill switch. A dropped tunnel keeps the armed policy in place and triggers recovery through the timer. If a location stays unavailable, select a different one. The kill switch and the active tunnel reset on reboot. The saved login remains available.

To reopen networking immediately, use **Turn off kill switch** or run this in Fish:

```fish
walker-vpn kill-off
```

The administrator recovery command is `run0 systemctl start walker-vpn-emergency-open.service`. Rebooting also clears this version's tunnel and kill switch. Before removing or deactivating the module during the current boot, disconnect and close routed apps.

## App routing

- **VPN-only apps** use either the system VPN location or their own PIA WireGuard tunnel. In **App routing…**, select an app, choose **VPN only**, and pick **Follow the system VPN location**, **Optimal**, or a named location. Launching an app that follows the system VPN can reconnect the host tunnel using the saved login and last successful location. If you disconnected manually during this boot, connect the host VPN from the menu first. While the host tunnel is down these apps lose connectivity. A named location or **Optimal** keeps the app on its own tunnel, even with the system kill switch on. If its dedicated tunnel drops, the app loses network access. Existing VPN-only apps follow the system location until you choose a different one.
- **Excluded apps** run in a Vopono namespace restricted to the physical IPv4 uplink and its DNS. They retain this route when the host VPN or kill switch is active. Restart an excluded app after changing uplinks.
- If an app is still running when you change its route or location, save your work and choose **Close and reopen app**. Walker VPN applies the change after the process exits and reopens the selected launcher. **Cancel** keeps the current setting. At the route menu, **Follow system VPN** restores the original launcher.
- Desktop actions and native shortcuts that resolve to the same executable share the saved route. Flatpak shortcuts that launch the same exported app share its route and keep their own commands. Opening another shortcut, file or URI for a running routed app uses its existing protected namespace. Its firewall and uplink stay in place if the original launcher exits while the app is still running. Walker VPN refreshes Elephant after changing a launcher.
- Managed apps receive the desktop session's theme settings. Native apps use a filtered D-Bus connection for tray icons, notifications and theme settings. Flatpaks retain their filtered desktop bus. Native apps launched by an explicit path to the underlying executable still follow the host policy.
- App policies survive updates that keep the same application ID or command name. Flatpak launches read the installed version’s executable at launch. The Flatpak network override also stays in place across updates.

The same commands work in Fish without aliases or shell functions:

```fish
walker-vpn run vpn -- curl -4 https://ifconfig.co/ip
walker-vpn run direct -- curl -4 https://ifconfig.co/ip
```

Use `walker-vpn restore --all` before uninstalling to restore your desktop launchers and the managed Flatpak network permissions.

The NixOS login environment, Fish, and UWSM add Walker VPN's managed commands to their command search paths. After you save a policy, normal desktop launches, named native commands, and plain `flatpak run APP_ID` launches follow it. Existing Hyprland autostart commands use the same paths. For a package without a desktop entry, choose **Installed system commands** from the routing menu. Command routing applies to the executable name recorded by Walker.

## Check status

```fish
walker-vpn status
systemctl status walker-vpn.socket walker-vpn-maintain.timer
journalctl -u 'walker-vpn@*.service' -u walker-vpn-maintain.service -n 80
```

The [KDE WireGuard applet](https://github.com/minkytown/KDE-Wireguard-applet) provided the feature baseline. [Vopono](https://github.com/jamesmcm/vopono) supplies app network namespaces. The public PIA CA is sourced from [PIA's manual connection scripts](https://github.com/pia-foss/manual-connections).

## Security scope

The desktop account owns the control socket, launcher overrides, and saved routing choices. These policies protect ordinary launches against accidental use of the wrong network. Software with the same account's access to the control socket or configuration can change those choices. Network namespaces govern direct socket traffic. A host service contacted through local IPC can make its own connections under its own policy.

The [security model](SECURITY.md) describes the routing guarantees and trust boundaries.
