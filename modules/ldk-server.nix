# NixOS module for LDK Server.
#
# Supports any number of independent instances under
# `services.ldk-server.instances.<name>`. Each instance gets its own user,
# data directory, systemd unit, and (optionally) Tor onion service.
#
# This module only depends on vanilla NixOS options (systemd, users,
# services.tor). It does not require nix-bitcoin, though it composes with it.
{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkOption mkEnableOption mkPackageOption mkIf mkDefault mkMerge
    types literalExpression optional optionalString optionalAttrs
    mapAttrs' mapAttrsToList nameValuePair filterAttrs concatMapStringsSep
    escapeShellArg;

  cfg = config.services.ldk-server;
  tomlFormat = pkgs.formats.toml { };

  enabledInstances = filterAttrs (_: i: i.enable) cfg.instances;

  # Split "host:port" into its components (IPv6 in brackets supported).
  splitHostPort = addr:
    let
      m = builtins.match "[[](.*)[]]:([0-9]+)" addr;
      m2 = builtins.match "(.*):([0-9]+)" addr;
    in
    if m != null then { host = builtins.elemAt m 0; port = lib.toInt (builtins.elemAt m 1); }
    else if m2 != null then { host = builtins.elemAt m2 0; port = lib.toInt (builtins.elemAt m2 1); }
    else throw "ldk-server: cannot parse address '${addr}' as host:port";

  instanceModule = { name, config, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable this LDK Server instance.";
      };

      package = mkOption {
        type = types.package;
        default = cfg.package;
        defaultText = literalExpression "config.services.ldk-server.package";
        description = "The ldk-server package to use for this instance.";
      };

      user = mkOption {
        type = types.str;
        default = "ldk-server-${name}";
        description = "System user the instance runs as.";
      };

      group = mkOption {
        type = types.str;
        default = "ldk-server-${name}";
        description = "System group the instance runs as.";
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/ldk-server/${name}";
        description = ''
          Storage directory (`[storage.disk] dir_path`). Holds the BIP39
          mnemonic, channel database, TLS certificate and API key. Back it up.
        '';
      };

      settings = mkOption {
        description = ''
          Contents of the ldk-server TOML config file. See
          <https://github.com/lightningdevkit/ldk-server/blob/main/contrib/ldk-server-config.toml>
          for every available field. Anything set here is written verbatim
          to the generated config file, so do not put secrets in it (use
          {option}`environmentFile` / {option}`bitcoind.rpcPasswordFile`).
        '';
        default = { };
        type = types.submodule {
          freeformType = tomlFormat.type;
          options = {
            node = {
              network = mkOption {
                type = types.enum [ "bitcoin" "testnet" "signet" "regtest" ];
                default = "bitcoin";
                description = "Bitcoin network to run on.";
              };
              alias = mkOption {
                type = types.str;
                default = "ldk-server-${name}";
                description = "Lightning node alias.";
              };
              listening_addresses = mkOption {
                type = types.listOf types.str;
                default = [ "127.0.0.1:9735" ];
                description = ''
                  Addresses the Lightning node listens on. For a Tor-only
                  node keep this on localhost and let Tor forward to it.
                '';
              };
              announcement_addresses = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = ''
                  Addresses announced to the gossip network. When
                  {option}`tor.onionService.enable` and
                  {option}`tor.onionService.announce` are set, the onion
                  address is appended to this list at runtime.
                '';
              };
              grpc_service_address = mkOption {
                type = types.str;
                default = "127.0.0.1:3536";
                description = "Bind address of the gRPC API (TLS, HMAC-authenticated).";
              };
            };
            log = {
              level = mkOption {
                type = types.enum [ "Error" "Warn" "Info" "Debug" "Trace" ];
                default = "Info";
                description = "Log level.";
              };
              log_to_file = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Also write logs to a file inside the data directory.
                  Disabled by default because stdout/stderr already go to
                  the journal.
                '';
              };
            };
          };
        };
      };

      bitcoind = {
        rpcAddress = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "127.0.0.1:8332";
          description = ''
            Bitcoin Core RPC address. Setting this selects bitcoind as the
            chain source (recommended, and required for a no-clearnet setup).
            Alternatively set `settings.electrum.server_url` or
            `settings.esplora.server_url`.
          '';
        };
        rpcUser = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Bitcoin Core RPC user.";
        };
        rpcPasswordFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/secrets/bitcoin-rpcpassword-ldk-server";
          description = ''
            File containing the Bitcoin Core RPC password. Read by systemd
            (as root) via `LoadCredential` and passed to the daemon through
            the `LDK_SERVER_BITCOIND_RPC_PASSWORD` environment variable, so
            it never lands in the Nix store. Use with {option}`bitcoind.rpcUser`.
          '';
        };
        rpcCookieFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/var/lib/bitcoind-main/.cookie";
          description = ''
            Bitcoin Core RPC cookie file (`<datadir>/.cookie`, or
            `<datadir>/<network>/.cookie` for non-mainnet). Alternative to
            {option}`bitcoind.rpcUser` + {option}`bitcoind.rpcPasswordFile`
            that needs no manual secret management: systemd reads the cookie
            via `LoadCredential` and the user/password are exported as
            `LDK_SERVER_BITCOIND_RPC_USER` / `_PASSWORD`. Bitcoin Core writes
            a new cookie on every start, so make the ldk-server unit
            `partOf` the bitcoind unit (see the examples) so they restart
            together.
          '';
        };
      };

      tor = {
        enable = mkEnableOption "outbound Tor for .onion peers via a SOCKS proxy";

        proxyAddress = mkOption {
          type = types.str;
          default = "127.0.0.1:9050";
          description = ''
            Tor SOCKS proxy address (`[tor] proxy_address`). Note that
            ldk-server only routes connections to `.onion` peers through
            this proxy; see {option}`enforceLocalhostOnly` for how to make
            sure nothing else leaves the box in the clear.
          '';
        };

        onionService = {
          enable = mkEnableOption ''
            an inbound Tor onion service for this instance, configured via
            `services.tor.relay.onionServices`
          '';
          port = mkOption {
            type = types.port;
            default = 9735;
            description = "Virtual port exposed on the onion address.";
          };
          announce = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Read the generated `.onion` hostname at startup and add it to
              the node's announcement addresses.
            '';
          };
        };
      };

      enforceLocalhostOnly = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Use systemd `IPAddressDeny`/`IPAddressAllow` so the process can
          only open sockets to loopback. Combined with a local bitcoind and
          {option}`tor.enable`, this guarantees the node never talks to the
          clearnet: everything either goes to bitcoind on localhost or out
          through the Tor SOCKS proxy on localhost. Also disables the
          default clearnet pathfinding-scores download.
        '';
      };

      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Optional file with `LDK_SERVER_*` environment variables (secrets
          such as LSP tokens or metrics credentials). Loaded via systemd
          `EnvironmentFile`; must be readable by root.
        '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra command-line arguments passed to ldk-server.";
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Open the Lightning listening ports in the firewall. Not needed
          for a Tor-only node.
        '';
      };
    };

    config = {
      settings = mkMerge [
        {
          storage.disk.dir_path = toString config.dataDir;
        }
        (mkIf config.tor.enable {
          tor.proxy_address = config.tor.proxyAddress;
        })
        (mkIf (config.bitcoind.rpcAddress != null) {
          bitcoind.rpc_address = config.bitcoind.rpcAddress;
        })
        (mkIf (config.bitcoind.rpcUser != null) {
          bitcoind.rpc_user = config.bitcoind.rpcUser;
        })
        (mkIf config.enforceLocalhostOnly {
          # Otherwise ldk-node fetches scores from rapidsync.lightningdevkit.org
          # on mainnet, which the sandbox would block anyway.
          node.pathfinding_scores_source_url = mkDefault "";
        })
      ];
    };
  };

  nixosConfig = config;

  mkInstance = name: inst:
    let
      configFile = tomlFormat.generate "ldk-server-${name}.toml" inst.settings;
      onionName = "ldk-server-${name}";
      onionHostnameFile = "${nixosConfig.services.tor.relay.onionServices.${onionName}.path}/hostname";
      useOnion = inst.tor.enable && inst.tor.onionService.enable;
      announceOnion = useOnion && inst.tor.onionService.announce;
      loadRpcPassword = inst.bitcoind.rpcPasswordFile != null;
      loadRpcCookie = inst.bitcoind.rpcCookieFile != null;

      # Announcement addresses are passed as repeated CLI flags (highest
      # precedence) so we can splice in the runtime-discovered onion address.
      staticAnnounceArgs = concatMapStringsSep " "
        (a: "--node-announcement-addresses ${escapeShellArg a}")
        inst.settings.node.announcement_addresses;

      startScript = pkgs.writeShellScript "ldk-server-${name}-start" ''
        set -euo pipefail
        args=( ${escapeShellArg (toString configFile)} )
        ${optionalString loadRpcPassword ''
          LDK_SERVER_BITCOIND_RPC_PASSWORD="$(cat "$CREDENTIALS_DIRECTORY/bitcoind-rpc-password")"
          export LDK_SERVER_BITCOIND_RPC_PASSWORD
        ''}
        ${optionalString loadRpcCookie ''
          cookie="$(cat "$CREDENTIALS_DIRECTORY/bitcoind-rpc-cookie")"
          LDK_SERVER_BITCOIND_RPC_USER="''${cookie%%:*}"
          LDK_SERVER_BITCOIND_RPC_PASSWORD="''${cookie#*:}"
          export LDK_SERVER_BITCOIND_RPC_USER LDK_SERVER_BITCOIND_RPC_PASSWORD
        ''}
        ${optionalString announceOnion ''
          onion="$(cat "$CREDENTIALS_DIRECTORY/onion-hostname")"
          args+=( ${staticAnnounceArgs} --node-announcement-addresses "$onion:${toString inst.tor.onionService.port}" )
        ''}
        exec ${inst.package}/bin/ldk-server "''${args[@]}" ${lib.escapeShellArgs inst.extraArgs}
      '';

      # Convenience wrapper: `ldk-server-cli-<name> get-node-info`.
      # Reads the api key / TLS cert from the instance's data dir, so run
      # it as root or as the instance user.
      cliWrapper = pkgs.writeShellScriptBin "ldk-server-cli-${name}" ''
        exec ${inst.package}/bin/ldk-server-cli --config ${escapeShellArg (toString configFile)} "$@"
      '';
    in
    {
      users = {
        users.${inst.user} = {
          isSystemUser = true;
          group = inst.group;
          home = inst.dataDir;
          description = "LDK Server (${name})";
        };
        groups.${inst.group} = { };
      };

      systemPackages = [ cliWrapper ];

      firewallPorts = lib.optionals inst.openFirewall
        (map (a: (splitHostPort a).port) inst.settings.node.listening_addresses);

      tor = mkIf useOnion {
        enable = true;
        client.enable = mkDefault true;
        relay.onionServices.${onionName} = {
          version = 3;
          map = [{
            port = inst.tor.onionService.port;
            target =
              let l = splitHostPort (builtins.head inst.settings.node.listening_addresses);
              in { addr = if l.host == "localhost" then "127.0.0.1" else l.host; port = l.port; };
          }];
        };
      };

      tmpfilesRules = [
        "d '${inst.dataDir}' 0750 ${inst.user} ${inst.group} - -"
      ];

      service = {
        description = "LDK Server Lightning node (${name})";
        wantedBy = [ "multi-user.target" ];
        # NixOS names bitcoind units `bitcoind-<name>.service`, nix-bitcoin
        # uses `bitcoind.service`; add the right one via
        # `systemd.services.ldk-server-<name>.after` in your config.
        after = [ "network-online.target" ] ++ optional useOnion "tor.service";
        wants = [ "network-online.target" ] ++ optional useOnion "tor.service";

        serviceConfig = {
          Type = "simple";
          User = inst.user;
          Group = inst.group;
          ExecStart = startScript;
          WorkingDirectory = inst.dataDir;
          Restart = "on-failure";
          RestartSec = "10s";
          TimeoutStopSec = "120s";
          KillSignal = "SIGTERM";
          LoadCredential =
            optional loadRpcPassword "bitcoind-rpc-password:${inst.bitcoind.rpcPasswordFile}"
            ++ optional loadRpcCookie "bitcoind-rpc-cookie:${inst.bitcoind.rpcCookieFile}"
            ++ optional announceOnion "onion-hostname:${onionHostnameFile}";

          # Hardening
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ inst.dataDir ];
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectProc = "invisible";
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@privileged" ];
          CapabilityBoundingSet = "";
          UMask = "0077";
        } // optionalAttrs (inst.environmentFile != null) {
          EnvironmentFile = [ inst.environmentFile ];
        } // optionalAttrs inst.enforceLocalhostOnly {
          IPAddressDeny = "any";
          IPAddressAllow = [ "127.0.0.0/8" "::1/128" ];
        };
      };

      assertions = [
        {
          assertion = inst.settings.node.listening_addresses != [ ];
          message = "services.ldk-server.instances.${name}: node.listening_addresses must not be empty.";
        }
        {
          assertion = (inst.bitcoind.rpcAddress != null) ->
            (inst.bitcoind.rpcCookieFile != null
              || (inst.bitcoind.rpcUser != null && (inst.bitcoind.rpcPasswordFile != null || inst.environmentFile != null)));
          message = "services.ldk-server.instances.${name}: with bitcoind.rpcAddress set, either set bitcoind.rpcCookieFile, or bitcoind.rpcUser plus bitcoind.rpcPasswordFile (or LDK_SERVER_BITCOIND_RPC_PASSWORD via environmentFile).";
        }
        {
          assertion = !(inst.bitcoind.rpcCookieFile != null && (inst.bitcoind.rpcUser != null || inst.bitcoind.rpcPasswordFile != null));
          message = "services.ldk-server.instances.${name}: bitcoind.rpcCookieFile is exclusive with bitcoind.rpcUser/rpcPasswordFile.";
        }
        {
          assertion = !(inst.enforceLocalhostOnly && inst.bitcoind.rpcAddress == null);
          message = "services.ldk-server.instances.${name}: enforceLocalhostOnly requires a local bitcoind chain source (electrum/esplora would be blocked).";
        }
        {
          assertion = !(inst.tor.onionService.enable && !inst.tor.enable);
          message = "services.ldk-server.instances.${name}: tor.onionService.enable requires tor.enable.";
        }
      ];
    };

  instances = lib.mapAttrs mkInstance enabledInstances;
  perInstance = f: mapAttrsToList (_: f) instances;
in
{
  options.services.ldk-server = {
    package = mkPackageOption pkgs "ldk-server" { };

    instances = mkOption {
      type = types.attrsOf (types.submodule instanceModule);
      default = { };
      description = "LDK Server instances to run, keyed by instance name.";
      example = literalExpression ''
        {
          main = {
            settings.node.network = "bitcoin";
            bitcoind = {
              rpcAddress = "127.0.0.1:8332";
              rpcUser = "ldk-server";
              rpcPasswordFile = "/secrets/bitcoin-rpcpassword-ldk-server";
            };
            tor.enable = true;
            tor.onionService.enable = true;
            enforceLocalhostOnly = true;
          };
        }
      '';
    };
  };

  # Top-level attribute names must be static (not depend on `config`),
  # otherwise the module system recurses infinitely; merge per-instance
  # pieces one level down.
  config = {
    users.users = mkMerge (perInstance (i: i.users.users));
    users.groups = mkMerge (perInstance (i: i.users.groups));
    environment.systemPackages = lib.concatLists (perInstance (i: i.systemPackages));
    networking.firewall.allowedTCPPorts = lib.concatLists (perInstance (i: i.firewallPorts));
    services.tor = mkMerge (perInstance (i: i.tor));
    systemd.tmpfiles.rules = lib.concatLists (perInstance (i: i.tmpfilesRules));
    systemd.services = mapAttrs' (name: i: nameValuePair "ldk-server-${name}" i.service) instances;
    assertions = lib.concatLists (perInstance (i: i.assertions));
  };
}
