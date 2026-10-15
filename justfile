# Justfile for the nixos-config repo.
#
# Common operations: rebuild, switch, update the flake

set default-list := true

# Build the NixOS system (tuxedo) without activating.
build:
    nixos-rebuild build --flake .#tuxedo

# Build and activate the NixOS system (tuxedo). Needs sudo.
switch:
    sudo nixos-rebuild switch --flake .#tuxedo

# Update the flake lock file.
update:
    nix flake update
