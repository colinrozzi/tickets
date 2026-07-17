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
      # Canonical packr-0.10.2 self-contained fleet rev (theater main HEAD,
      # post-`theater compose`, PR #141). ONE rev pinned by every actor AND the
      # rev the prod binary is cut from — the atomic-flip contract. It HAS the
      # `theater compose` CLI used to build our self-contained composites, and
      # its host theater:simple/* pact/WIT ABI is byte-identical to the earlier
      # staged binary (#141 was theater-cli + CI + docs only), so it stays
      # interface-aligned at spawn time.
      url = "github:colinrozzi/theater/7daab2ada0051f0517bf8cf3de9719fc2d75e0f6";
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
          # crane ignores .cargo/config.toml rustflags, so pass the fixed-base
          # self-contained link flags (recipe §2) via CARGO_ENCODED_RUSTFLAGS
          # (0x1f-separated). Must stay in sync with .cargo/config.toml — these
          # build each member at a fixed absolute base (single-package 0x50000)
          # so `theater compose` can internalize memory + pack:alloc.
          CARGO_ENCODED_RUSTFLAGS = builtins.concatStringsSep (builtins.fromJSON ''"\u001f"'') [
            "-C" "link-arg=--import-memory"
            "-C" "link-arg=--initial-memory=8388608"
            "-C" "link-arg=--stack-first"
            "-C" "link-arg=-zstack-size=262144"
            "-C" "link-arg=--global-base=327680"
            "-C" "link-arg=--no-entry"
            "-C" "link-arg=--no-merge-data-segments"
          ];
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # The compose-capable theater CLI (has `theater compose`) from the
        # pinned input; `.theater` and `.default` both resolve to it.
        theaterBin = theater.packages.${system}.theater;

      in {
        packages.default = craneLib.buildPackage (commonArgs // {
          # Recipe §Crane: one buildPackage pass, no shared deps-only artifact
          # for the wasm32 self-contained member build.
          cargoArtifacts = null;
          # theater compose + binaryen (wasm-merge) + wasm-tools do the
          # compose/verify inside the sandboxed derivation.
          nativeBuildInputs = [ theaterBin pkgs.binaryen pkgs.wasm-tools ];
          # Build the 3 bare members, then compose each with packr's bundled
          # allocator into a self-contained <name>.composite.wasm and drop the
          # bare member (the 0.10.x loader rejects bare members — deploy the
          # composite). `theater compose` verifies imports-are-host-only and
          # fails the build on a non-self-contained member.
          installPhaseCommand = ''
            mkdir -p $out
            for name in tickets_acceptor tickets_handler tickets_cli; do
              cp "target/wasm32-unknown-unknown/release/$name.wasm" "$out/$name.wasm"
              theater compose "$out/$name.wasm" -o "$out/$name.composite.wasm"
              rm "$out/$name.wasm"
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
          # binaryen (wasm-merge) + wasm-tools are NEW vs the 0.8.1 PIC build:
          # `theater compose` needs wasm-merge to fuse the member with packr's
          # bundled allocator into the self-contained composite, and wasm-tools
          # to validate + assert imports are host-only. `nix build` runs the
          # compose in the sandbox; these are here for manual/local use.
          packages = [ rustToolchain theaterBin pkgs.binaryen pkgs.wasm-tools pkgs.ripgrep ];
          shellHook = ''
            echo "tickets dev environment"
            echo "  cargo build --release --target wasm32-unknown-unknown"
            # theater build <member> can't resolve a shared-workspace target dir;
            # compose the prebuilt member instead (same as the flake installPhase).
            echo "  theater compose target/wasm32-unknown-unknown/release/tickets_acceptor.wasm"
            echo "  theater spawn acceptor/manifest.toml"
            echo "  ./cli/tickets list"
          '';
        };
      });
}
