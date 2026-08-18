# Example: a single mainnet LDK Server instance using ONLY vanilla NixOS
# modules (no nix-bitcoin), with no clearnet connections at all.
#
#   - bitcoind runs via NixOS's `services.bitcoind`, outbound over Tor only
#     (proxy + onlynet=onion), no inbound, loopback-only sandbox
#   - ldk-server talks to bitcoind on localhost using cookie auth (no
#     passwords to manage) and to Lightning peers only through the Tor SOCKS
#     proxy on localhost
#   - the node is reachable as a v3 onion service, which is auto-announced
#   - systemd IPAddressDeny/Allow guarantees neither process can open a
#     socket to anything but loopback
#
# Drop this file next to your configuration.nix and add it to `imports`
# together with the ldk-server module (see README).
#
# NOTE: initial block download entirely over Tor is slow (days on mainnet).
# If you prefer, do the IBD on clearnet first (comment out the Tor lines in
# bitcoind's extraConfig and the IPAddressDeny block), then switch.
{ config, pkgs, lib, ... }:
let
  bitcoind = config.services.bitcoind.main;
in
{
  ###### Tor ######

  services.tor = {
    enable = true;
    client.enable = true;                 # SOCKS proxy on 127.0.0.1:9050
  };

  ###### bitcoind (vanilla NixOS module) ######

  services.bitcoind.main = {
    enable = true;
    # dataDir defaults to /var/lib/bitcoind-main, user/group to bitcoind-main.
    # prune = 50000;                      # MiB; LDK works fine with a pruned node
    # dbCache = 2000;                     # MiB; speeds up IBD if you have RAM
    extraConfig = ''
      # --- Tor-only networking ---
      proxy=127.0.0.1:9050
      onlynet=onion
      listen=0
      dns=0
      # --- RPC on loopback only (cookie auth is on by default) ---
      rpcbind=127.0.0.1
      rpcallowip=127.0.0.1
    '';
  };

  # Loopback-only sandbox for bitcoind as well.
  systemd.services.bitcoind-main.serviceConfig = {
    IPAddressDeny = "any";
    IPAddressAllow = [ "127.0.0.0/8" "::1/128" ];
  };

  ###### ldk-server ######

  services.ldk-server.instances.main = {
    settings.node = {
      network = "bitcoin";
      alias = "my-ldk-node";
      listening_addresses = [ "127.0.0.1:9735" ];   # Tor forwards to this
      grpc_service_address = "127.0.0.1:3536";
    };

    bitcoind = {
      rpcAddress = "127.0.0.1:${toString (if bitcoind.rpc.port != null then bitcoind.rpc.port else 8332)}";
      # Cookie auth: no rpcauth/HMAC generation, no password file to manage.
      # For signet/testnet the cookie lives in <dataDir>/<network>/.cookie.
      rpcCookieFile = "${bitcoind.dataDir}/.cookie";
    };

    tor = {
      enable = true;                    # outbound .onion peers via 127.0.0.1:9050
      onionService.enable = true;       # inbound v3 onion service on port 9735
      onionService.announce = true;     # add the .onion to announcement_addresses
    };

    # Loopback-only sandbox: nothing can leave in the clear. Also disables
    # the default clearnet pathfinding-scores download.
    enforceLocalhostOnly = true;

    # settings.hrn.mode = "blip32";     # resolve BIP-353 names via peers, not DNS
  };

  # bitcoind writes a fresh RPC cookie on every start, so tie the two units
  # together: start after bitcoind and restart whenever it restarts.
  systemd.services.ldk-server-main = {
    after = [ "bitcoind-main.service" ];
    requires = [ "bitcoind-main.service" ];
    partOf = [ "bitcoind-main.service" ];
  };
}
