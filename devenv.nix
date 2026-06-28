{ pkgs, ... }:

{
  # Tooling needed to develop and test go-ginkgo.el.
  packages = [
    # Emacs runs the package and the ERT suite (`make compile|checkdoc|test`).
    pkgs.emacs

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

  # `devenv test` runs the same gate as CI.
  enterTest = ''
    make all
  '';
}
