{
  description = "Tickets: work-tracking actor system on Theater";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";

    theater = {
      # packr-0.11.0 plain-build fleet rev (theater main HEAD, PR #149 — the
      # 0.11.0 hard break that retired all compose/fuse machinery). Actors are
      # plain cargo cdylibs now, so the build no longer needs the theater CLI;
      # this input remains for the dev shell (`theater spawn`) + interface
      # alignment with the eventual 0.11.0 prod binary.
      url = "github:colinrozzi/theater/73a4540b";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.crane.follows = "crane";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane, theater }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          targets = [ "wasm32-unknown-unknown" ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            (pkgs.lib.hasSuffix ".rs" path) ||
            (pkgs.lib.hasSuffix ".toml" path) ||
            (pkgs.lib.hasSuffix ".lock" path) ||
            (type == "directory");
        };

        commonArgs = {
          inherit src;
          pname = "tickets";
          version = "0.1.0";
          cargoExtraArgs = "--target wasm32-unknown-unknown";
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
          doCheck = false;
          # crane ignores .cargo/config.toml rustflags, so pass the two plain-build
          # link-args via CARGO_ENCODED_RUSTFLAGS (0x1f-separated). Must stay in
          # sync with .cargo/config.toml. packr 0.11.0 = plain cargo build: the
          # cdylib exports its own growable memory (--export-memory), no start
          # (--no-entry); setup_guest!() links dlmalloc. No fixed-base, no compose.
          CARGO_ENCODED_RUSTFLAGS = builtins.concatStringsSep (builtins.fromJSON ''"\u001f"'') [
            "-C" "link-arg=--export-memory"
            "-C" "link-arg=--no-entry"
          ];
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # theater CLI from the pinned input — for the dev shell (`theater spawn`
        # / `theater build --release` import-surface check); not used by the
        # plain-build derivation.
        theaterBin = theater.packages.${system}.theater;

      in {
        packages.default = craneLib.buildPackage (commonArgs // {
          # One buildPackage pass for the wasm32 plain build.
          cargoArtifacts = null;
          # packr 0.11.0: plain cargo build, no compose. The cdylib is directly
          # loadable — install the bare <name>.wasm (no allocator fuse, no
          # binaryen/theater-compose step). Import surface (host theater:simple/*
          # only) is asserted by the CI verify job.
          installPhaseCommand = ''
            mkdir -p $out
            for name in tickets_acceptor tickets_handler tickets_cli; do
              cp "target/wasm32-unknown-unknown/release/$name.wasm" "$out/$name.wasm"
            done
          '';
        });

        packages.theater = theaterBin;

        # nix run .#release — explicit version-stamping ceremony.
        # Creates a release tag (release-YYYYMMDD-<sha7>) on the current
        # HEAD and pushes it. The push triggers .github/workflows/release.yml,
        # which builds the wasm artifacts and uploads them to the GH release.
        # This mirrors theater's release-script pattern: developer-initiated,
        # explicit, no auto-trigger on every main commit.
        packages.release = pkgs.writeShellScriptBin "tickets-release" ''
          set -e
          BRANCH=$(${pkgs.git}/bin/git rev-parse --abbrev-ref HEAD)
          if [ "$BRANCH" != "main" ]; then
            echo "release: refusing to tag a non-main branch (current: $BRANCH)" >&2
            exit 1
          fi
          if ! ${pkgs.git}/bin/git diff --quiet HEAD 2>/dev/null || \
             ! ${pkgs.git}/bin/git diff --cached --quiet 2>/dev/null; then
            echo "release: refusing to tag with a dirty working tree" >&2
            exit 1
          fi
          DATE=$(date +%Y%m%d)
          SHA=$(${pkgs.git}/bin/git rev-parse --short=7 HEAD)
          TAG="release-$DATE-$SHA"
          if ${pkgs.git}/bin/git rev-parse "$TAG" >/dev/null 2>&1; then
            echo "release: tag $TAG already exists" >&2
            exit 1
          fi
          ${pkgs.git}/bin/git tag "$TAG"
          ${pkgs.git}/bin/git push origin "$TAG"
          echo "release: tagged + pushed $TAG"
          echo "release: CI will build + create the GH release at"
          echo "  https://github.com/colinrozzi/tickets/releases/tag/$TAG"
        '';

        packages.clippy = craneLib.cargoClippy (commonArgs // {
          inherit cargoArtifacts;
          cargoClippyExtraArgs = "--target wasm32-unknown-unknown -- -D warnings";
        });

        packages.fmt = craneLib.cargoFmt {
          inherit src;
          pname = "tickets";
          version = "0.1.0";
        };

        devShells.default = craneLib.devShell {
          # wasm-tools for the local import-surface check (host theater:simple/*
          # only). No binaryen: packr 0.11.0 is a plain cargo build — the compose
          # step and its wasm-merge dependency are retired.
          packages = [ rustToolchain theaterBin pkgs.wasm-tools pkgs.ripgrep ];
          shellHook = ''
            echo "tickets dev environment"
            echo "  cargo build --release --target wasm32-unknown-unknown"
            echo "  # verify: wasm-tools print <name>.wasm | grep '(import' -> theater:simple/* only"
            echo "  theater spawn acceptor/manifest.toml"
            echo "  ./cli/tickets list"
          '';
        };
      });
}
