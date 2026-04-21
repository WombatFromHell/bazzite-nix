{
  description = "Development environment with Python and pytest";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          actionlint
          bashInteractive
          crane
          go
          grype
          oras
          python3
          python3Packages.pytest
          python3Packages.pytest-mock
          shellcheck
          shfmt
          syft
        ];

        shellHook = ''
          export GOPATH="$HOME/.local/share/go"
          export GOMODCACHE="$GOPATH/pkg/mod"
          export GOBIN="$GOPATH/bin"

          mkdir -p "$GOPATH" "$GOBIN"
          export PATH="$GOBIN:$PATH"

          if ! command -v composite-action-lint >/dev/null; then
            echo "Installing composite-action-lint..."
            go install github.com/bettermarks/composite-action-lint/cmd/composite-action-lint@latest
          fi
        '';
      };
    });
}
