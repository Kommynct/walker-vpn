{ config, lib, pkgs, ... }:

let
  cfg = config.services.walker-vpn;
  desktopOpener = lib.getExe' pkgs.xdg-utils "xdg-open";
  unwrappedOpener = pkgs.runCommand "walker-vpn-unwrapped-xdg-open" { } ''
    install -Dm755 ${desktopOpener} "$out/bin/xdg-open"
  '';
  linkHandler = pkgs.writeShellScript "walker-vpn-link-handler" (builtins.readFile ./bin/open-link);
  linkOpener = pkgs.writeShellScriptBin "xdg-open" ''
    exec ${linkHandler} client ${unwrappedOpener}/bin/xdg-open ${lib.getExe' pkgs.socat "socat"} "$@"
  '';
  client = pkgs.runCommand "walker-vpn-client" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    install -Dm755 ${./bin/walker-vpn} "$out/bin/walker-vpn"
    install -Dm644 ${./lib/desktop.sh} "$out/lib/desktop.sh"
    install -Dm644 ${./lib/desktop-entry.sh} "$out/lib/desktop-entry.sh"
    install -Dm644 ${./lib/session-env.sh} "$out/lib/session-env.sh"
    patchShebangs "$out/bin"
    wrapProgram "$out/bin/walker-vpn" --prefix PATH : ${lib.makeBinPath (with pkgs; [
      coreutils gawk jq socat util-linux ripgrep procps libnotify glib desktop-file-utils inotify-tools systemd
    ])} --set WALKER_VPN_FLATPAK ${lib.getExe pkgs.flatpak}
  '';
  routedFlatpak = pkgs.writeShellScriptBin "flatpak" ''
    case "''${1:-}" in
      run|-v|--verbose|--ostree-verbose) ;;
      *) exec ${lib.getExe pkgs.flatpak} "$@" ;;
    esac
    exec ${client}/bin/walker-vpn flatpak "$@"
  '';
  routingEnvironment = ''
    walker_vpn_bin="''${XDG_STATE_HOME:-$HOME/.local/state}/walker-vpn/apps/bin"
    case ":$PATH:" in
      *":$walker_vpn_bin:"*) ;;
      *) export PATH="$walker_vpn_bin:$PATH" ;;
    esac
    unset walker_vpn_bin
  '';
  backend = pkgs.runCommand "walker-vpn-backend" { } ''
    mkdir -p "$out"
    install -m644 ${./lib/service.sh} "$out/service.sh"
    install -m644 ${./lib/guard.sh} "$out/guard.sh"
    install -m644 ${./lib/pia.sh} "$out/pia.sh"
    install -m644 ${./lib/pia-ca.crt} "$out/pia-ca.crt"
    install -m644 ${./lib/app-service.sh} "$out/app-service.sh"
    install -m644 ${./lib/app-inside.sh} "$out/app-inside.sh"
    install -m644 ${./lib/app-session.sh} "$out/app-session.sh"
    install -m644 ${./lib/session-env.sh} "$out/session-env.sh"
  '';
  backendPath = with pkgs; [
    bash coreutils findutils gawk getent gnugrep gnused jq iproute2 iptables nftables wireguard-tools
    openresolv systemd curl util-linux procps ripgrep dbus xdg-dbus-proxy pkgs.flatpak
  ];
  backendCommand = "${pkgs.bash}/bin/bash ${backend}/service.sh ${backend} ${cfg.user}";
  commonService = {
    path = backendPath;
    environment = {
      HOME = "/var/lib/walker-vpn";
      XDG_CONFIG_HOME = "/var/lib/walker-vpn";
      SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      WALKER_VPN_FLATPAK = lib.getExe pkgs.flatpak;
      WALKER_VPN_LINK_OPENER = lib.getExe' linkOpener "xdg-open";
      WALKER_VPN_DESKTOP_OPENER = desktopOpener;
    };
    serviceConfig = {
      UMask = "0077";
      NoNewPrivileges = true;
      TimeoutStopSec = "12s";
    };
  };
  eligible = lib.filterAttrs (_: user: user.isNormalUser && lib.elem "wheel" user.extraGroups) config.users.users;
  inferredUser = if builtins.length (builtins.attrNames eligible) == 1 then
    builtins.head (builtins.attrNames eligible)
  else
    "";
in {
  options.services.walker-vpn = {
    user = lib.mkOption {
      type = lib.types.strMatching "[a-z_][a-z0-9_-]*|";
      default = inferredUser;
      defaultText = lib.literalExpression "the only normal user in wheel, when unambiguous";
      description = "Desktop account allowed to use the Walker VPN control socket.";
    };
    # Accept existing module configurations. Forwarding no longer uses Vopono.
    voponoPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.vopono;
      description = "Legacy option retained for existing configurations.";
    };
  };

  config = {
    assertions = [{
      assertion = cfg.user != "" && (config.users.users.${cfg.user}.isNormalUser or false);
      message = "Set services.walker-vpn.user to the desktop account when it cannot be inferred.";
    }];
    environment.systemPackages = [ client ] ++ lib.optional config.services.flatpak.enable
      (lib.hiPrio routedFlatpak);
    environment.extraInit = routingEnvironment;
    environment.etc."xdg/uwsm/env.d/80-walker-vpn".text = routingEnvironment;
    programs.fish.shellInit = lib.mkAfter ''
      set -l walker_vpn_state "$HOME/.local/state"
      if set -q XDG_STATE_HOME; and test -n "$XDG_STATE_HOME"
        set walker_vpn_state "$XDG_STATE_HOME"
      end
      set -l walker_vpn_bin "$walker_vpn_state/walker-vpn/apps/bin"
      if not contains -- "$walker_vpn_bin" $PATH
        set -gx PATH "$walker_vpn_bin" $PATH
      end
    '';

    users.groups.walker-vpn-api = { };
    users.users.walker-vpn-api = {
      isSystemUser = true;
      group = "walker-vpn-api";
    };

    systemd.tmpfiles.rules = [
      "d /run/walker-vpn 0700 root root - -"
      "d /run/walker-vpn-view 0755 root root - -"
      "d /var/lib/walker-vpn 0700 root root - -"
    ];

    systemd.sockets.walker-vpn = {
      description = "Walker VPN desktop control";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "/run/walker-vpn.sock";
        Accept = true;
        SocketMode = "0600";
        SocketUser = cfg.user;
        MaxConnections = 32;
        RemoveOnStop = true;
      };
    };

    systemd.user.sockets.walker-vpn-links = {
      description = "Open web links in the desktop session";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "%t/walker-vpn-links.sock";
        SocketMode = "0600";
        Accept = true;
        MaxConnections = 16;
      };
    };

    systemd.user.services."walker-vpn-links@" = {
      description = "Open a routed app’s web link";
      # Desktop entries can name executables from the system or user profile.
      environment.PATH = lib.mkForce (lib.concatStringsSep ":" [
        "/run/wrappers/bin"
        "%h/.nix-profile/bin"
        "%h/.local/state/nix/profile/bin"
        "/etc/profiles/per-user/%u/bin"
        "/run/current-system/sw/bin"
      ]);
      serviceConfig = {
        ExecStart = "${linkHandler} serve ${lib.getExe' pkgs.glib "gio"}";
        StandardInput = "socket";
        StandardOutput = "inherit";
        ExitType = "cgroup";
      };
    };

    systemd.services."walker-vpn@" = lib.recursiveUpdate commonService {
      description = "Walker VPN desktop request";
      unitConfig.CollectMode = "inactive-or-failed";
      serviceConfig = {
        ExecStart = backendCommand;
        StandardInput = "socket";
        StandardOutput = "inherit";
        StandardError = "journal";
      };
    };

    systemd.services.walker-vpn-maintain = lib.recursiveUpdate commonService {
      description = "Recover the Walker VPN tunnel and expire kill switch tests";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backendCommand} maintain";
      };
    };

    systemd.timers.walker-vpn-maintain = {
      description = "Check the Walker VPN tunnel every ten seconds";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitInactiveSec = "10s";
        AccuracySec = "1s";
      };
    };

    systemd.services.walker-vpn-emergency-open = lib.recursiveUpdate commonService {
      description = "Disable the Walker VPN system kill switch";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backendCommand} emergency-open";
      };
    };
  };
}
