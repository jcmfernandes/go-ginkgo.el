# go-ginkgo

Run [Ginkgo](https://onsi.github.io/ginkgo/) (BDD) specs straight from a Go
buffer in Emacs. `go-ginkgo` drives the `ginkgo` CLI through `compilation-mode`
and is **tree-sitter native**: it finds the spec at point by walking the Go
syntax tree, not by scanning text.

It is a modern rework of the unmaintained, Ginkgo-v1-era
[`ginkgo-mode`](https://github.com/garslo/ginkgo-mode).

## Why

- **Tree-sitter spec finding.** Walks up the buffer's Go parser to the enclosing
  container/spec `call_expression` and reads its description. Understands the
  full Ginkgo v2 node set — `Describe`/`Context`/`When`/`It`/`Specify`/
  `DescribeTable`/`Entry` and the `F` (focused) and `P`/`X` (pending) decorator
  variants — and the real call nesting, so a stray `It(` in a comment or string
  never confuses it.
- **RE2-correct `--focus`.** `ginkgo --focus` takes a Go (RE2) regexp. A
  description with metacharacters — e.g. the parens in `handles (key) lookups` —
  passed verbatim would match nothing and *silently run zero specs*. `go-ginkgo`
  escapes the description as an RE2 literal first. (Emacs's own `regexp-quote`
  is wrong for this: it leaves `(` `)` `{` `}` unescaped, since they are literal
  in Emacs regexp syntax.)
- **Precise nested focus.** By default it joins the *full ancestry* of
  descriptions, so focusing a deeply nested `It` runs that one spec rather than
  every spec that shares its innermost text.
- **Real compilation buffer.** Navigable (`RET` / `C-x \``), re-runnable (`g`),
  ANSI-coloured output.

## Requirements

- Emacs 29.1+ (tree-sitter).
- The **Go tree-sitter grammar** (e.g. via `M-x treesit-install-language-grammar`
  or `treesit-auto`), and a Go major mode that creates a parser, such as the
  built-in `go-ts-mode`.
- The **`ginkgo` CLI** on `exec-path`
  (`go install github.com/onsi/ginkgo/v2/ginkgo@latest`).

## Installation

With `use-package` + a recent Emacs (`:vc`):

```elisp
(use-package go-ginkgo
  :vc (:url "https://github.com/jcmfernandes/go-ginkgo.el")
  :hook (go-ts-mode . go-ginkgo-mode)
  :custom (go-ginkgo-keymap-prefix "C-c G"))
```

With `straight.el`:

```elisp
(use-package go-ginkgo
  :straight (:host github :repo "jcmfernandes/go-ginkgo.el")
  :hook (go-ts-mode . go-ginkgo-mode)
  :init (setq go-ginkgo-keymap-prefix "C-c G"))
```

Or clone it onto your `load-path` and `(require 'go-ginkgo)`.

## Usage

Enable `go-ginkgo-mode` in Go buffers (the hooks above do this). With
`go-ginkgo-keymap-prefix` set, `go-ginkgo-command-map` is bound under it:

| Key (after prefix) | Command                     | Action                                            |
|--------------------|-----------------------------|---------------------------------------------------|
| `s`                | `go-ginkgo-run-spec`        | Run the container/spec at point (`--focus`)       |
| `f`                | `go-ginkgo-run-file`        | Run specs in the current file (`--focus-file`)    |
| `p`                | `go-ginkgo-run-package`     | Run the suite in the current directory            |
| `j`                | `go-ginkgo-run-project`     | Run every suite in the project (`-r`)             |
| `L`                | `go-ginkgo-run-labels`      | Run by label filter (`--label-filter`)            |
| `l`                | `go-ginkgo-run-last`        | Re-run the last invocation                        |
| `w`                | `go-ginkgo-watch`           | `ginkgo watch` the current package                |
| `b`                | `go-ginkgo-bootstrap`       | `ginkgo bootstrap`                                |
| `n`                | `go-ginkgo-generate`        | `ginkgo generate` for the current file            |
| `d`                | `go-ginkgo-toggle-dry-run`  | Toggle `--dry-run`                                |

Prefer to bind it yourself? `go-ginkgo-command-map` is a prefix command:

```elisp
(keymap-set go-ts-mode-map "C-c G" 'go-ginkgo-command-map)
```

All commands are also available via `M-x` and are autoloaded.

## Customization

- `go-ginkgo-binary` — name/path of the executable (default `"ginkgo"`).
- `go-ginkgo-extra-args` — args always added to spec runs and `watch` (e.g.
  build tags `("--tags" "integration")`).
- `go-ginkgo-parallel` — `nil` (serial), `t` (`-p`, auto), or an integer
  (`--procs N`).
- `go-ginkgo-dry-run` — when non-nil, add `--dry-run` (list without running).
- `go-ginkgo-focus-strategy` — `full-path` (default, precise) or `innermost`.
- `go-ginkgo-container-nodes` — the constructor names treated as containers;
  extend it if you wrap Ginkgo's nodes in your own helpers.
- `go-ginkgo-buffer-name` — name of the compilation buffer.

## Development

A [devenv](https://devenv.sh) shell provides Emacs, the `ginkgo` CLI, Go, and
the toolchain the grammar build needs (git, a C compiler, make):

```sh
devenv shell     # drop into the dev environment
devenv test      # run the full CI gate (make all)
```

With [direnv](https://direnv.net), `direnv allow` loads it automatically on
`cd`. The included `.envrc` is portable — it only needs `devenv` on `PATH`.

The Makefile targets work in or out of the shell:

```sh
make compile     # byte-compile, warnings are errors
make checkdoc    # doc/style lint
make grammar     # install the Go grammar (for the tree-sitter tests)
make test        # run the ERT suite
make all         # the full CI gate
```

Tree-sitter tests skip themselves when the Go grammar is unavailable, so the
non-grammar tests run anywhere. To run them against a grammar you already have
installed elsewhere:

```sh
make test TREESIT_EXTRA=/path/to/dir/with/libtree-sitter-go.so
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
