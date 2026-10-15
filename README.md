## Install

```sh
# The installer environment does not include `git` by default. Enter a shell that has it.
nix-shell -p git

# Clone this configuration into your home directory.
git clone https://github.com/age2pierre/nixos-config.git ~/nixos-config

# Copy hardware config, rename it
cp /etc/nixos/hardware-configuration.nix ~/nixos-config/myhost-hardware-configuration.nix
# !!EDIT flake.nix (nixosConfigurations) to add the new host with that
# hardware config as an extraModule

# Backup the original configuration
sudo mv /etc/nixos /etc/nixos.bak

# Link this repository to the expected location
sudo ln -s ~/nixos-config /etc/nixos

# Build and install NixOS
sudo nixos-install --flake /etc/nixos#tuxedo
```

### Secrets

Secrets are managed with [agenix](https://github.com/ryantm/agenix): each
`secrets/*.age` file is age-encrypted to the recipients listed in
`secrets/agenix-rules.nix` and decrypted at activation time into `/run/agenix`
(system) and `$XDG_RUNTIME_DIR/agenix` (home-manager) — plaintext never
touches the Nix store or the repo.

Identities (age keyfiles) live outside the repo:
- system: `/etc/agenix/tuxedo.age` (root, 0400)
- user: `~/.config/agenix/age2pierre.age` (0600)

To edit or add a secret (from the repo root, where the rules file is found):
```sh
nix run github:ryantm/agenix -- -e secrets/<name>.age -i ~/.config/agenix/age2pierre.age
```
Piped input replaces the content without opening an editor (handy for a new
secret): set `AGENIX_RULES=$PWD/secrets/agenix-rules.nix` and add a rule
entry for the new file first:
```sh
echo -n "new value" | nix run github:ryantm/agenix -- -e secrets/<name>.age -i ~/.config/agenix/age2pierre.age
```
After adding a new `.age` file, declare it in `configuration.nix`
(`age.secrets`) or `home.nix` (home-manager `age.secrets`) and reference it
from there — API keys are consumed at runtime via `{file:}` (opencode) /
`!cat` (omp) indirections in `ai-shared.nix`.

## Update

```sh
just update   # nix flake update
just switch   # sudo nixos-rebuild switch --flake .#tuxedo (or just build to test-activate-less build)
```

## Layout

| File | Role |
|---|---|
| `flake.nix` | Hosts (currently `tuxedo`), nixpkgs pins (stable / jdk24 / frozen Android toolchain), niri + noctalia inputs, local overlay (oh-my-pi, bun override), home-manager wiring |
| `configuration.nix` | System config for tuxedo: kernel/amdgpu freeze workarounds, NetworkManager profiles (PSKs via agenix envsubst), GDM + niri session, SearXNG, pipewire, docker, sudo rules |
| `tuxedo-hardware-configuration.nix` | Generated hardware config (imports + filesystems) |
| `home.nix` | Home-manager: user packages, VSCode profiles, Android SDK, niri keybinds/outputs, Noctalia shell, fish/tide, git, ssh, opencode/zed/fresh-editor |
| `ai-shared.nix` | Single source of truth for LLM providers + LSP servers + MCP, rendered into each tool's config format (keys referenced at runtime from agenix) |
| `pkgs/oh-my-pi/` | Local package: omp binary from upstream GitHub release |
| `secrets/` | age-encrypted agenix files + `agenix-rules.nix` (see Secrets section) |

Secrets referenced: ssh keys, wifi PSKs, kubeconfig, API keys (OLLAMA, RUNPOD, CONTEXT7), searxng env.

## VSCode profiles

`code --profile <name> <dir>` (`default`/`java`/`nix`). Profiles do **not** inherit from
each other: the shared base is `vscodeDefaultExtensions` (25 extensions — git, prettier,
just, tailwind, eslint, vue/volar, oxc, …) plus `vscodeSharedSettings`/keybindings, all
defined at the top of `home.nix`. Each profile only appends its own extras:

- `java`: `redhat.java`, `vscjava.vscode-gradle`, `vscjava.vscode-java-debug`, `fwcd.kotlin`
  + `java.configuration.runtimes` pinned to `pkgs.jdk21`.
- `nix`: `jnoortheen.nix-ide` with nixd LSP + alejandra formatting, options pointed at
  this flake.

⚠️ Installing any non-default profile makes the extensions dir a Nix-store symlink —
any extension installed manually in VSCode (UI, `code --install-extension`) is wiped on
the next rebuild. Add extensions to `vscodeDefaultExtensions` in `home.nix`, never via
the marketplace UI.

## TODO later :

- [x] Fix broken vscode extension.
- [x] Fix fish prompt.
- [x] Link ssh files (keys private + public + known hosts).
- [ ] Use https://nixos.wiki/wiki/Impermanence#See_Also ?
- [ ] Adapt https://github.com/le0me55i/zsh-extract/blob/master/extract.plugin.zsh for fish
- [ ] Look at https://github.com/danielpieper/tuxedo-nixos for tuxedo
- [ ] Find a way to define "project" folders. 
      Those project folder should define dev dependencies (nodejs version and/or jdk version) + one or more git repository to clone + vscode config
 - add "on the go" specialisations ?
