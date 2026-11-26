# Security model

Walker VPN protects direct IP traffic from apps started through a managed launcher. Its privileged service owns the network namespaces and installs the firewall before handing execution to the desktop user. VPN-only apps use the host tunnel or a separate WireGuard tunnel. Excluded apps use the selected physical uplink. Per-app routing currently allows IPv4 egress. IPv6 egress is blocked in managed namespaces.

## Trust boundaries

- The configured desktop account owns the control socket and can change routing preferences. Software with that account’s permissions can request the same changes or invoke unmanaged launch paths.
- A network namespace confines direct network connections. Local IPC, desktop portals, and other host services can perform operations from their own namespaces. The native D-Bus proxy limits session services available to routed apps. Flatpak continues to enforce its sandbox permissions.
- Native apps that exit immediately after a denied D-Bus name request retry on a private session bus. That bus has no host service activation or desktop integration. The app keeps its assigned network namespace.
- The root-owned runtime registry associates repeat launches with the original app’s route and namespace. Policy changes require the app to stop. Shared leases keep the namespace in place during repeat launches. Detached processes keep it alive until they exit.
- Saved PIA credentials are encrypted with a machine credential key. WireGuard private keys and generated profiles belong to the privileged service. Client requests and startup failures avoid logging credential values or provider configuration.

## Checks

A launch requires a separate mount and network namespace, the expected interface, DNS configuration, and the namespace’s default-drop output chain. The Flatpak launcher checks for the expected network interface and resolver configuration from inside its sandbox. The desktop and backend regression tests exercise shortcut migration, MIME arguments, route mismatch rejection, and detached-process lifetime.

Testing the kernel, Flatpak, systemd, Vopono, and PIA implementations themselves is outside the scope of this project.
