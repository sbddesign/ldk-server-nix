# Example: a single mainnet LDK Server instance on top of nix-bitcoin, with
# no clearnet connections at all.
#
#   - bitcoind runs locally (nix-bitcoin) and only talks to the network via Tor
#   - ldk-server talks to bitcoind on localhost and to Lightning peers only
#     through the Tor SOCKS proxy on localhost
#   - the node is reachable as a v3 onion service, which is auto-announced
#   - systemd's IPAddressDeny/Allow guarantees the ldk-server process cannot
#     open a socket to anything but loopback
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
#       "${nix-bitcoin}/modules/presets/enable-tor.nix"
#       ldk-server-nix.nixosModules.default
#       ./this-file.nix
#     ];
#   };
{ config, ... }:
{
  ###### nix-bitcoin side ######

  services.bitcoind = {
    enable = true;
    # Recommended for LDK: fast fee estimation / package relay need a recent
    # Core. Zero-fee commitment channels additionally require Core >= 29.

    # A dedicated RPC user for ldk-server. nix-bitcoin's built-in `public`
    # user has an RPC whitelist that lacks `submitpackage`, which LDK Node's
    # bitcoind backend uses, so we create our own (no whitelist = full RPC
    # access, but no wallet is enabled on this bitcoind).
    rpc.users.ldk-server.passwordHMACFromFile = true;
  };

  # Tell nix-bitcoin to generate and own the password/HMAC secrets for the
  # user above. The password ends up at
  # ${nix-bitcoin.secretsDir}/bitcoin-rpcpassword-ldk-server (default
  # secretsDir is /etc/nix-bitcoin-secrets).
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
      # Keep the Lightning listener on loopback; Tor forwards to it.
      listening_addresses = [ "127.0.0.1:9735" ];
      grpc_service_address = "127.0.0.1:3536";
    };

    bitcoind = {
      rpcAddress = "${config.services.bitcoind.rpc.address}:${toString config.services.bitcoind.rpc.port}";
      rpcUser = "ldk-server";
      rpcPasswordFile = "${config.nix-bitcoin.secretsDir}/bitcoin-rpcpassword-ldk-server";
    };

    tor = {
      enable = true;                    # outbound .onion peers via 127.0.0.1:9050
      onionService.enable = true;       # inbound v3 onion service on port 9735
      onionService.announce = true;     # add the .onion to announcement_addresses
    };

    # Loopback-only sandbox: nothing can leave in the clear.
    enforceLocalhostOnly = true;

    # Optional extra tweaks: e.g. skip RGS (would be clearnet anyway) and rely
    # on P2P gossip from onion peers; disable BIP-353 DNS lookups.
    # settings.node.rgs_server_url is simply left unset.
    # settings.hrn.mode = "blip32";     # resolve HRNs via peers instead of DNS
  };

  # Start after bitcoind (nix-bitcoin's unit is `bitcoind.service`).
  systemd.services.ldk-server-main = {
    after = [ "bitcoind.service" ];
    requires = [ "bitcoind.service" ];
  };
}
