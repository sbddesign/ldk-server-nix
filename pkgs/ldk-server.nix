{ lib
, rustPlatform
, fetchFromGitHub
, withLsps2 ? false
}:

rustPlatform.buildRustPackage rec {
  pname = "ldk-server";
  # Upstream has no tagged releases yet; track a pinned commit of `main`.
  version = "0.1.0-unstable-2026-08-17";

  src = fetchFromGitHub {
    owner = "lightningdevkit";
    repo = "ldk-server";
    rev = "1af5168db2be57cbad09b122ec60d80027dce700";
    hash = "sha256-HpOLZJaLFfte2jz8SjMvNMth+W+MAvmPcxSKF9aGksg=";
  };

  # Cargo.lock contains git dependencies (ldk-node, rust-lightning, ...);
  # cargoHash vendors them along with crates.io deps.
  cargoHash = "sha256-pkYdB7tgmRF1bVVrDBSWppjSO5TRW26+o03nqwzJ7hE=";

  # Only build the daemon and CLI; ldk-server-mcp / e2e-tests are not needed.
  cargoBuildFlags = [ "-p" "ldk-server" "-p" "ldk-server-cli" ]
    ++ lib.optionals withLsps2 [ "--features" "experimental-lsps2-support" ];

  # ldk-server/build.rs embeds this into `ldk-server --version`; there is no
  # .git directory inside the Nix sandbox so provide it explicitly.
  GIT_HASH = builtins.substring 0 7 src.rev;

  # Tests need a chain backend / network access.
  doCheck = false;

  meta = with lib; {
    description = "A ready-to-run Lightning node daemon built using LDK Node";
    homepage = "https://github.com/lightningdevkit/ldk-server";
    license = with licenses; [ mit asl20 ];
    mainProgram = "ldk-server";
    platforms = platforms.unix;
  };
}
