{ pkgs, inputs, ... }:

let
  system = pkgs.stdenv.system;

  # Emacs 29.x lives only in the pinned older nixpkgs (see devenv.yaml).
  pkgs29 = import inputs.nixpkgs-29 { inherit system; };

  # The CI matrix sets $EMACS_PKG to one of these keys to test across versions.
  # Unset (local dev) -> current stable. -nox builds keep the closures small
  # and X-free, which is all the batch test suite needs.
  emacsByKey = {
    emacs29 = pkgs29.emacs-nox;       # 29.4  (pinned nixos-24.05)
    emacs30 = pkgs.emacs-nox;         # 30.x  (rolling nixpkgs)
  };
  key = let v = builtins.getEnv "EMACS_PKG"; in if v == "" then "emacs30" else v;
  emacs = emacsByKey.${key} or
    (throw "EMACS_PKG=${key} must be one of: ${toString (builtins.attrNames emacsByKey)}");
in
{
  # Tooling needed to develop and test go-ginkgo.el.
  packages = [
    # Emacs runs the package and the ERT suite (`make compile|checkdoc|test`).
    emacs

    # The `ginkgo' CLI is what the package actually drives.
    pkgs.ginkgo
    # ginkgo shells out to `go' to compile spec binaries at run time.
    pkgs.go

    # `make grammar' clones tree-sitter-go (git) and builds it (C compiler);
    # needed for the tree-sitter tests, which otherwise skip themselves.
    pkgs.git
    pkgs.gcc

    # Drives the developer Makefile.
    pkgs.gnumake
  ];

  enterShell = ''
    echo "go-ginkgo dev shell"
    echo "  emacs   $(emacs --version | head -1 | cut -d' ' -f3)"
    echo "  ginkgo  $(ginkgo version 2>/dev/null | head -1)"
    echo "  go      $(go version | cut -d' ' -f3)"
    echo
    echo "Run 'make all' for the full CI gate (compile + checkdoc + test)."
  '';
}
