# ldk-server-nix

Nix flake providing a package and a NixOS module for
[LDK Server](https://github.com/lightningdevkit/ldk-server), the Lightning
node daemon built on LDK Node.

Upstream has no Nix support and is not (yet) in nixpkgs or nix-bitcoin, so
this repo fills the gap.

## What's here

| Path | What |
|------|------|
| `flake.nix` | Flake entry point: `packages`, `overlays.default`, `nixosModules.default` |
| `pkgs/ldk-server.nix` | `buildRustPackage` derivation (daemon + CLI), pinned to an upstream commit |
| `modules/ldk-server.nix` | Standalone NixOS module, `services.ldk-server.instances.<name>` |
| `examples/nix-bitcoin-tor-only.nix` | Single mainnet node on nix-bitcoin, Tor-only, no clearnet |
| `examples/nix-bitcoin-clearnet.nix` | Single mainnet node on nix-bitcoin, clearnet (optionally dual-stack with Tor) |

## Usage

Add the flake as an input and import the module:

```nix
{
  inputs.ldk-server-nix.url = "github:sbddesign/ldk-server-nix";

  outputs = { nixpkgs, ldk-server-nix, ... }: {
    nixosConfigurations.mybox = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ldk-server-nix.nixosModules.default
        {
          services.ldk-server.instances.main = {
            settings.node.network = "signet";
            settings.esplora.server_url = "https://mempool.space/signet/api";
          };
        }
      ];
    };
  };
}
```

Then:

```sh
sudo systemctl status ldk-server-main
sudo ldk-server-cli-main get-node-info   # per-instance CLI wrapper
```

The package alone: `nix build github:sbddesign/ldk-server-nix` (or
`.#ldk-server-lsps2` for the experimental LSPS2 service feature).

## Module overview

Each entry in `services.ldk-server.instances` gets its own system user,
data directory (`/var/lib/ldk-server/<name>` by default), hardened systemd
unit `ldk-server-<name>.service`, and `ldk-server-cli-<name>` wrapper.
Multiple instances on one machine just need distinct ports.

Key options per instance:

- `settings` – the TOML config, typed for the common fields
  (`node.network`, `node.listening_addresses`, `node.grpc_service_address`,
  `node.alias`, `log.level`, ...) and free-form for everything else. See
  upstream's [annotated config](https://github.com/lightningdevkit/ldk-server/blob/main/contrib/ldk-server-config.toml).
  Never put secrets here; the file lands in the Nix store.
- `bitcoind.{rpcAddress,rpcUser,rpcPasswordFile}` – Bitcoin Core chain
  source. The password file is read by systemd (`LoadCredential`) and passed
  via `LDK_SERVER_BITCOIND_RPC_PASSWORD`, so it never touches the store.
- `tor.enable` / `tor.proxyAddress` – outbound `.onion` peers via SOCKS.
- `tor.onionService.{enable,port,announce}` – creates a v3 onion service via
  `services.tor.relay.onionServices` and, if `announce`, reads the generated
  hostname at start-up and adds it to the announced addresses.
- `enforceLocalhostOnly` – systemd `IPAddressDeny=any` +
  `IPAddressAllow=loopback`. With a local bitcoind and `tor.enable`, this is
  what makes "no clearnet" a guarantee rather than a hope (see below).
- `environmentFile` – extra `LDK_SERVER_*` env vars (LSP tokens etc.).
- `openFirewall`, `extraArgs`, `user`, `group`, `dataDir`, `package`.

## Tor / no-clearnet caveats

Upstream's [Tor guide](https://github.com/lightningdevkit/ldk-server/blob/main/docs/tor.md)
is explicit that `[tor] proxy_address` only proxies **outbound connections to
`.onion` peers**. Chain backends (Electrum/Esplora), Rapid Gossip Sync,
pathfinding-score downloads, and BIP-353 DNS lookups are *not* proxied.

So for a Tor-only node:

1. Use a local `bitcoind` chain source (nix-bitcoin makes bitcoind itself
   Tor-only).
2. Set `enforceLocalhostOnly = true`. This also disables the default
   pathfinding-scores download. Leave `rgs_server_url` unset; gossip syncs
   P2P from your onion peers instead (slower initially).
3. Only peer with `.onion` addresses.

`examples/nix-bitcoin-tor-only.nix` puts all of that together;
`examples/nix-bitcoin-clearnet.nix` is the plain clearnet counterpart.

## Backups

`<dataDir>/keys_mnemonic` and `<dataDir>/<network>/ldk_node_data.sqlite`
are needed to recover funds. See upstream
[Operations](https://github.com/lightningdevkit/ldk-server/blob/main/docs/operations.md).

## Updating the pinned upstream

Edit `rev`, `version`, `hash` and `cargoHash` in `pkgs/ldk-server.nix`.
Setting the two hashes to `lib.fakeHash` and building will print the correct
values. Note upstream has git dependencies in `Cargo.lock`, so `cargoHash`
must be recomputed on every bump.

## Status

- Not in nixpkgs / nix-bitcoin. Contributions upstream welcome; the package
  file should move over nearly unchanged.
- The module has been evaluated but not yet exercised on a live system —
  please report issues.
