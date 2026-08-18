# Example: a single mainnet LDK Server instance on top of nix-bitcoin, with
# clearnet support (optionally dual-stack with Tor).
#
#   - bitcoind runs locally (nix-bitcoin), talking to the network however
#     you configured it
#   - ldk-server listens on all interfaces for Lightning peers and announces a
#     public IP/hostname
#   - the gRPC API stays on localhost
#   - Tor is optional here: set `tor.enable` to also reach .onion peers and
#     `tor.onionService.enable` to additionally announce an onion address
#
# Wire it into your system flake roughly like this:
#
#   inputs.nix-bitcoin.url = "github:fort-nix/nix-bitcoin/release";
#   inputs.ldk-server-nix.url = "github:sbddesign/ldk-server-nix";
#   ...
#   nixosConfigurations.mybox = nixpkgs.lib.nixosSystem {
#     modules = [
#       nix-bitcoin.nixosModules.default
#       "${nix-bitcoin}/modules/presets/secure-node.nix"
#       ldk-server-nix.nixosModules.default
#       ./this-file.nix
#     ];
#   };
{ config, ... }:
{
  ###### nix-bitcoin side ######

  services.bitcoind = {
    enable = true;
    # Dedicated RPC user; nix-bitcoin's `public` user whitelist lacks
    # `submitpackage`, which LDK Node's bitcoind backend uses.
    rpc.users.ldk-server.passwordHMACFromFile = true;
  };

  nix-bitcoin.secrets = {
    bitcoin-rpcpassword-ldk-server.user = config.services.bitcoind.user;
    bitcoin-HMAC-ldk-server.user = config.services.bitcoind.user;
  };
  nix-bitcoin.generateSecretsCmds.ldk-server = ''
    makeBitcoinRPCPassword ldk-server
  '';

  ###### ldk-server side ######

  services.ldk-server.instances.main = {
    settings.node = {
      network = "bitcoin";
      alias = "my-ldk-node";
      # Accept Lightning peers from anywhere.
      listening_addresses = [ "0.0.0.0:9735" ];
      # What other nodes will see in gossip. Replace with your public IP or
      # DNS name. Leave empty for an unannounced (private) node.
      announcement_addresses = [ "203.0.113.1:9735" ];
      # Keep the API local; reach it via SSH tunnel or a reverse proxy.
      grpc_service_address = "127.0.0.1:3536";
    };

    # Rapid Gossip Sync and pathfinding scores are on by default on mainnet
    # (clearnet HTTPS to rapidsync.lightningdevkit.org). Uncomment to disable:
    # settings.node.rgs_server_url = "";
    # settings.node.pathfinding_scores_source_url = "";

    bitcoind = {
      rpcAddress = "${config.services.bitcoind.rpc.address}:${toString config.services.bitcoind.rpc.port}";
      rpcUser = "ldk-server";
      rpcPasswordFile = "${config.nix-bitcoin.secretsDir}/bitcoin-rpcpassword-ldk-server";
    };

    # Open 9735/tcp in the NixOS firewall.
    openFirewall = true;

    # Optional dual-stack: also connect to .onion peers, and/or expose an
    # onion address alongside the clearnet one. Requires services.tor
    # (nix-bitcoin's presets/enable-tor.nix, or your own).
    # tor.enable = true;
    # tor.onionService.enable = true;   # announces <onion>:9735 in addition
  };

  # Start after bitcoind (nix-bitcoin's unit is `bitcoind.service`).
  systemd.services.ldk-server-main = {
    after = [ "bitcoind.service" ];
    requires = [ "bitcoind.service" ];
  };
}
