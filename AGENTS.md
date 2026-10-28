# AGENTS.md

Instructions for AI coding agents working in this repository.

## Nix builds: never leave `result` symlinks

`nix build` (without `--no-link`) creates a `./result` symlink pointing to the
built store path. Do not use that form here. Always build with the no-link
form so no build artifact appears in the working tree:

```sh
# Good: builds, no symlink
nix build --no-link .#nixosConfigurations.tuxedo.config.system.build.toplevel

# Print the store path when needed:
nix build --no-link --print-out-paths .#nixosConfigurations.tuxedo.config.system.build.toplevel

# Avoid: leaves a ./result symlink behind
nix build .#...
```

`result` and `result-*` are covered by `.gitignore`, but a stale `result`
symlink is still useless clutter: if one exists, remove it (`rm result`).
`nixos-rebuild` (used by `just build` / `just switch`) does not create
`./result` — only bare `nix build` does.