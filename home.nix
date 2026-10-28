{
  self,
  inputs,
  config,
  hostname,
  pkgs,
  pkgs-stable,
  pkgs-android,
  pkgs-jdk24,
  lib,
  ...
}: let
  ai = import ./ai-shared.nix {inherit lib pkgs;};
  # gcloud CLI with the GKE auth plugin (needed for `gcloud container clusters
  # get-credentials` on GKE).
  gdk = pkgs.google-cloud-sdk.withExtraComponents (with pkgs.google-cloud-sdk.components; [
    gke-gcloud-auth-plugin
  ]);
  # --- VSCode: config shared by every profile ---
  # programs.vscode.profiles.<name> do NOT inherit from each other, so the
  # theme/font/formatter/keybindings block must be passed to each profile
  # explicitly. Keep these keys language-agnostic; put language-specific
  # settings (java.*, dotnet.*) in the profile that needs them.
  vscodeSharedSettings = {
    "workbench.colorTheme" = "Dark Modern";
    "editor.minimap.enabled" = false;
    "editor.fontLigatures" = true;
    "editor.fontFamily" = "'Fira Code', 'Droid Sans Mono', 'monospace', monospace";
    "terminal.integrated.fontFamily" = "'Fira Code', 'MesloLGS NF'";
    "diffEditor.diffAlgorithm" = "advanced";
    "editor.codeActionsOnSave" = {"source.fixAll.ts" = "always";};
    "js/ts.updateImportsOnFileMove.enabled" = "always";
    "js/ts.preferences.importModuleSpecifier" = "project-relative";
    "workbench.iconTheme" = "material-icon-theme";
    "Prettier-SQL.ignoreTabSettings" = true;
    "Prettier-SQL.keywordCase" = "lower";
    "github.copilot.enable" = {"*" = false;};
    "shellformat.path" = "${pkgs.shfmt}/bin/shfmt";
    "[json]" = {"editor.defaultFormatter" = "esbenp.prettier-vscode";};
    "[javascript]" = {"editor.defaultFormatter" = "esbenp.prettier-vscode";};
    "[css]" = {"editor.defaultFormatter" = "esbenp.prettier-vscode";};
    "[scss]" = {"editor.defaultFormatter" = "esbenp.prettier-vscode";};
    "[html]" = {"editor.defaultFormatter" = "esbenp.prettier-vscode";};
    "[typescriptreact]" = {"editor.defaultFormatter" = "esbenp.prettier-vscode";};
    "[jsonc]" = {"editor.defaultFormatter" = "esbenp.prettier-vscode";};
    "[typescript]" = {"editor.defaultFormatter" = "esbenp.prettier-vscode";};
    "gitlens.showWelcomeOnInstall" = false;
    "gitlens.showWhatsNewAfterUpgrades" = false;
    "peacock.favoriteColors" = [
      {
        name = "Angular Red";
        value = "#dd0531";
      }
      {
        name = "Azure Blue";
        value = "#007fff";
      }
      {
        name = "JavaScript Yellow";
        value = "#f9e64f";
      }
      {
        name = "Mandalorian Blue";
        value = "#1857a4";
      }
      {
        name = "Node Green";
        value = "#215732";
      }
      {
        name = "React Blue";
        value = "#61dafb";
      }
      {
        name = "Something Different";
        value = "#832561";
      }
      {
        name = "Svelte Orange";
        value = "#ff3d00";
      }
      {
        name = "Vue Green";
        value = "#42b883";
      }
    ];
  };

  vscodeSharedKeybindings = [
    {
      key = "ctrl+k ctrl+s";
      command = "-workbench.action.openGlobalKeybindings";
    }
    {
      key = "ctrl+k ctrl+s";
      command = "workbench.action.files.saveFiles";
    }
  ];

  # Extensions every profile gets (the non-Java set currently in `default`).
  vscodeDefaultExtensions = with pkgs.nix-vscode-extensions.vscode-marketplace; [
    lumirelle.shell-format-rev
    wmaurer.change-case
    pkief.material-icon-theme
    mhutchie.git-graph
    gruntfuggly.todo-tree
    esbenp.prettier-vscode
    malo.copy-json-path
    maattdd.gitless
    johnpapa.vscode-peacock
    leonkohli.snapsource # Copy4AI
    frostime.file-path-autocomplete
    nefrob.vscode-just-syntax
    tobiashochguertel.just-formatter
    redhat.vscode-yaml
    unifiedjs.vscode-mdx
    qufiwefefwoyn.inline-sql-syntax
    inferrinizzard.prettier-sql-vscode
    matthewpi.caddyfile-support
    bradlc.vscode-tailwindcss
    yoavbls.pretty-ts-errors
    dbaeumer.vscode-eslint
    angular.ng-template
    vue.volar
    pkgs.vscode-extensions.oxc.oxc-vscode
    jackiotyu.git-worktree-manager
  ];

  # Android SDK composition matching chapito/mobile/android/build.gradle
  # (ndkVersion 27.1.12297006, buildToolsVersion 34.0.0, compileSdk 35).
  # Built from the FROZEN nixpkgs-android pin (see flake.nix) so `nix flake
  # update` never re-pins/re-downloads the ~5 GiB of Google zips; bump the
  # pin deliberately instead.
  androidComposition = pkgs-android.androidenv.composeAndroidPackages {
    platformVersions = ["36" "35" "34" "31"];
    buildToolsVersions = ["36.0.0" "34.0.0" "35.0.0" "31.0.0"];
    ndkVersions = ["27.1.12297006"];
    cmakeVersions = ["3.22.1"];
    includeNDK = true;
    includeEmulator = true;
    includeSystemImages = true;
    systemImageTypes = ["google_apis_playstore"];
    abiVersions = ["x86_64" "arm64-v8a"];
  };
  # Strip the legacy `ndk-bundle` symlink — modern AGP autoscans the SDK and
  # errors with CXX5304 because the dir name doesn't match the NDK's package id.
  androidsdkPatched = pkgs-android.runCommand "androidsdk-no-ndk-bundle" {} ''
    cp -a ${androidComposition.androidsdk} $out
    chmod u+w $out/libexec/android-sdk
    rm -f $out/libexec/android-sdk/ndk-bundle
  '';
  androidSdkRoot = "${androidsdkPatched}/libexec/android-sdk";
  androidEmulator = pkgs-android.androidenv.emulateApp {
    name = "emulate-android";
    platformVersion = "36";
    abiVersion = "x86_64";
    systemImageType = "google_apis_playstore";
  };

  # SketchUp Make 2017 — the last freeware edition of SketchUp Make. There is no
  # native Linux build, so this is a Wine wrapper. The installer .exe is fetched
  # reproducibly into the store (mirrored on the Internet Archive, since Trimble
  # took the original download links down); the wrapper bootstraps a *stateful*
  # 64-bit Wine prefix under $XDG_DATA_HOME on first launch (Wine prefixes can't
  # live in the read-only store), installs SketchUp's .NET 4.5.2 prerequisite +
  # runs the GUI installer once, then launches the installed SketchUp.exe on every
  # subsequent run.
  sketchup2017 = let
    wine = pkgs.wineWow64Packages.stable; # 64-bit-capable (wow64) wine
    installer = pkgs.fetchurl {
      url = "https://archive.org/download/sketchupmake2017/sketchupmake-2017-2-2555-90782-en-x64.exe";
      hash = "sha256-mEF5LxcNgDrpWidBxEzOOOYYZg+YoaOBYzXpvxtFozc=";
    };
    # SketchUp 2017's installer requires .NET Framework 4.5.2. We pin Microsoft's
    # offline installer here (reproducible, like the SketchUp .exe above) and seed
    # it into winetricks' download cache; the file/sha256 are exactly what the
    # winetricks `dotnet452` verb expects, so winetricks skips the network fetch
    # but still does the prefix prep (mono removal, fusion override) that makes
    # .NET-under-Wine work.
    dotnet452 = pkgs.fetchurl {
      url = "https://download.microsoft.com/download/E/2/1/E21644B5-2DF2-47C2-91BD-63C560427900/NDP452-KB2901907-x86-x64-AllOS-ENU.exe";
      hash = "sha256-bCxYkTLoMKGFxfQPggQr7jAi5yGiFmgL2bOZW6hvN4E=";
    };
  in
    pkgs.writeShellApplication {
      name = "sketchup2017";
      runtimeInputs = [wine pkgs.winetricks pkgs.cabextract];
      # writeShellApplication runs under `set -euo pipefail`; winetricks/the
      # installer routinely exit non-zero on success, so each is `|| true`.
      text = ''
        export WINEARCH=win64
        export WINEPREFIX="''${XDG_DATA_HOME:-$HOME/.local/share}/sketchup-2017"
        # Suppress the wine-gecko (mshtml) nag. mscoree is left at its default so
        # the real .NET 4.5.2 we install below can load — winetricks removes
        # wine-mono itself as part of the dotnet452 verb, so no mono nag either.
        export WINEDLLOVERRIDES="mshtml="

        su_exe="$WINEPREFIX/drive_c/Program Files/SketchUp/SketchUp 2017/SketchUp.exe"

        if [ ! -f "$su_exe" ]; then
          echo ">> First run: bootstrapping the SketchUp 2017 Wine prefix at"
          echo "   $WINEPREFIX"
          wineboot --init || true

          # Keyboard: prefer Wine's native Wayland driver. Over XWayland
          # (winex11.drv) Wine tries to *match* the X keymap against built-in
          # tables, frequently fails for French, and falls back to US QWERTY.
          # winewayland.drv takes niri's AZERTY keymap straight from the
          # compositor, so the layout is correct. Falls back to x11 if Wine is
          # ever launched outside a Wayland session.
          wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /d "wayland,x11" /f || true

          # Pre-seed winetricks' cache with the store-pinned .NET 4.5.2 installer
          # so the dotnet452 verb verifies it and skips the Microsoft download.
          dotnet_cache="''${XDG_CACHE_HOME:-$HOME/.cache}/winetricks/dotnet452"
          mkdir -p "$dotnet_cache"
          install -m644 "${dotnet452}" \
            "$dotnet_cache/NDP452-KB2901907-x86-x64-AllOS-ENU.exe"

          # Install .NET 4.5.2 first (its own pass; sets win7, removes mono). This
          # is slow — several minutes — but stops the installer's .NET prompt.
          echo ">> Installing the .NET 4.5.2 prerequisite (this takes a while)..."
          winetricks -q --unattended dotnet452 || true
          # Win7 mode + the fonts/richedit controls the installer and UI need.
          winetricks -q --unattended win7 corefonts tahoma riched30 || true
          echo ">> Launching the SketchUp Make 2017 installer — click through it once."
          wine "${installer}" || true
        fi

        if [ ! -f "$su_exe" ]; then
          echo "!! SketchUp.exe not found — the installer was probably cancelled." >&2
          echo "   Just run 'sketchup2017' again to retry." >&2
          exit 1
        fi

        exec wine "$su_exe" "$@"
      '';
    };
in {
  imports = [
    # noctalia v5 shell (programs.noctalia)
    inputs.noctalia.homeModules.default
    # NOTE: the niri home module (programs.niri.settings) is injected
    # automatically by the niri NixOS module, so it is NOT imported here.
  ];

  # agenix (home-manager module): decrypts at login into $XDG_RUNTIME_DIR/agenix
  # via the `agenix` systemd user service; consumed by xdg.configFile symlinks
  # and the {file:}/!cat indirections in ai-shared.nix.
  age.secrets.ssh-id-ed25519.file = ./secrets/ssh-id-ed25519.age;
  age.secrets.ssh-id-rsa.file = ./secrets/ssh-id-rsa.age;
  age.secrets.kubeconfig.file = ./secrets/kubeconfig.age;
  age.secrets.ollama-key.file = ./secrets/ollama-key.age;
  age.secrets.runpod-ct-key.file = ./secrets/runpod-ct-key.age;
  age.secrets.runpod-perso-key.file = ./secrets/runpod-perso-key.age;
  age.secrets.context7-key.file = ./secrets/context7-key.age;
  # Dedicated age identity (root-only system key is unreadable by the HM
  # user service, which runs as the user).
  age.identityPaths = ["/home/age2pierre/.config/agenix/age2pierre.age"];

  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "age2pierre";
  home.homeDirectory = "/home/age2pierre";
  home.stateVersion = "25.05";

  # Packages to install in the user profile.
  home.packages = with pkgs; [
    # Dev tools
    git-crypt # Transparent file encryption in git
    nodejs # JavaScript runtime,
    bun # JavaScript runtime, bundler, transpiler and package manager
    python3
    just # run project-specific commands https://github.com/casey/just
    httpie # Command line HTTP client https://httpie.org/
    alejandra # Nix formatter https://kamadorueda.com/alejandra/
    shfmt # Shell parser and formatter https://github.com/mvdan/sh
    pnpm # package manager for JavaScrip
    yarn # dependency management for javascript
    jdk21 # OpenJDK
    ngrok # Allows you to expose a web server running on your local machine to the internet
    fastlane # Tool to automate building and releasing iOS and Android apps
    skopeo # Command line utility for various operations on container images and image repositories
    gh # GitHub CLI tool
    glab # GitLab CLI tool
    fresh-editor # Terminal-based text editor with LSP support and TypeScript plugins
    freelens-bin # IDE for Kubernetes
    kubectl # Kubernetes CLI
    duckdb # Embeddable SQL OLAP Database Management System
    # nixfmt # Nix formatter https://github.com/NixOS/nixfmt
    # dotnet-sdk_10
    # powershell
    git-igitt # Interactive app for clear git graphs
    serie # Rich git commit graph in your terminal
    glow # Render markdown on the CLI

    #LSP
    nixd # Nix Language server https://github.com/nix-community/nixd
    typescript
    jdt-language-server # Java language server
    kotlin-language-server # Kotlin language server
    just-lsp # Language server for just
    # mdx-language-server
    # vscode-json-languageserver²
    # vscode-css-languageserver
    # caddyfile-language-server

    gdk
    # terraform # Tool for building, changing, and versioning infrastructure
    pkgs-stable.firebase-tools # Manage, and deploy your Firebase project from the command line https://github.com/firebase/firebase-tools
    scaleway-cli
    runpodctl

    # AI
    opencode # coding agent
    codex # coding agent
    claude-code # coding agent
    oh-my-pi # coding agent (omp binary)
    ollama-vulkan

    # Utilities
    zip # archiver for creating and modifying zipfiles
    unzip # Extraction utility for archives compressed in .zip format
    dtrx # Do The Right Extraction: A tool for taking the hassle out of extracting archives
    wget # Tool for retrieving files using HTTP, HTTPS, and FTP - https://www.gnu.org/software/wget/
    yq-go # command-line YAML processor - https://mikefarah.gitbook.io/yq/
    sops # tool for managing secrets - https://getsops.io/
    age # encryption tool with small explicit keys - https://age-encryption.org/
    tldr # Simplified and community-driven man pages - https://tldr.sh/
    gawk # GNU implementation of the Awk programming language - https://www.gnu.org/software/gawk/
    which # Shows the full path of (shell) commands - https://www.gnu.org/software/which/
    tree # Command to produce a depth indented directory listing - https://oldmanprogrammer.net/source.php?dir=projects/tree
    btop # replacement of htop/nmon - https://github.com/aristocratos/btop
    iotop # io monitoring - http://guichaz.free.fr/iotop
    iftop # network monitoring - http://ex-parrot.com/pdw/iftop/
    dust # Like du (disk usage) but more intuitive - https://github.com/bootandy/dust
    ps_mem # Report the in core memory usage for a program - https://github.com/pixelb/ps_mem
    lshw # Provide detailed information on the hardware configuration of the machine
    delta # Syntax-highlighting pager for git - https://github.com/dandavison/delta
    mustache-go # Mustache template language in Go - https://github.com/cbroglie/mustache
    wl-clipboard # Command-line copy/paste utilities for Wayland - https://github.com/bugaevc/wl-clipboard
    gjs # JavaScript bindings for GNOME - https://gitlab.gnome.org/GNOME/gjs/blob/master/doc/Home.md
    brightnessctl # Backlight/LED control, used by the niri brightness keys - https://github.com/Hummer12007/brightnessctl

    # Fonts
    fira-code
    meslo-lgs-nf

    # Browsers and communication
    brave
    ferdium
    chromium
    proton-vpn

    # Creative apps
    krita # Krita 6.0.1 (nixpkgs-unstable) — Wayland-native + qt6-branch plugin
    gimp
    lycheeslicer
    upscayl
    stable-diffusion-cpp-vulkan
    sketchup2017 # SketchUp Make 2017 (last free edition) under Wine — see let-binding above

    # Media
    vlc
    libreoffice
    pdfarranger
    obsidian
    totem
    deluge
    imagemagick

    # GUI dev tools
    bruno # IDE For exploring and testing APIs
    jetbrains.datagrip # SQL IDE - https://www.jetbrains.com/datagrip/
    mongodb-compass # GUI for MongoDB - https://github.com/mongodb-js/compass
    qalculate-gtk # Ultimate desktop calculator - http://qalculate.github.io/
    pgadmin4-desktopmode

    # GNOME apps kept after dropping the GNOME desktop session
    nautilus # File manager
    file-roller # Archive manager (zip/tar/... GUI, integrates with Nautilus)
    loupe # Image viewer
    papers # PDF/document viewer (successor to Evince)
    gnome-disk-utility # Partition/format/mount disks
    baobab # Visual disk-usage analyzer
    gnome-system-monitor # GUI process/resource monitor
    seahorse # GUI to manage gnome-keyring secrets
    # GTK theming the GNOME desktop used to pull in
    adwaita-icon-theme
    (pkgs-android.android-studio.withSdk androidsdkPatched)
    androidComposition.platform-tools # adb, fastboot
    androidEmulator # run-test-emulator script
  ];

  # Simple, fast and user-friendly alternative to find
  # https://github.com/sharkdp/fd
  programs.fd = {
    enable = true;
  };

  programs.firefox = {
    enable = true;
    # Pin to legacy profile path (stateVersion < 26.05 default). To adopt
    # the XDG default later: move ~/.mozilla/firefox to
    # $XDG_CONFIG_HOME/mozilla/firefox, then set
    # configPath = "\${config.xdg.configHome}/mozilla/firefox".
    configPath = ".mozilla/firefox";
  };

  # A lightweight and flexible command-line JSON processor
  # https://jqlang.github.io/jq/
  programs.jq = {
    enable = true;
  };

  # recursively searches directories for a regex pattern
  # https://github.com/BurntSushi/ripgrep
  programs.ripgrep = {
    enable = true;
  };
  # Ripgrep, but also search in PDFs, E-Books, Office documents, zip, tar.gz, and more
  # https://github.com/phiresky/ripgrep-all
  programs.ripgrep-all = {
    enable = true;
  };

  # Modern and intuitive terminal-based text editor
  # https://micro-editor.github.io/
  programs.micro = {
    enable = true;
    package = pkgs.micro-full;
    settings = {
      wordwrap = true;
      softwrap = true;
    };
  };

  # A modern replacement for ‘ls’
  # https://github.com/eza-community/eza
  programs.eza = {
    enable = true;
    enableFishIntegration = true;
    git = true;
  };

  # Command line program to sync files and directories to and from major cloud storage
  # https://rclone.org/
  programs.rclone = {
    enable = true;
  };

  # cat clone with syntax highlighting and Git integration
  # https://github.com/sharkdp/bat
  programs.bat = {
    enable = true;
  };

  # Launcher entry for the Wine-wrapped SketchUp Make 2017 (sketchup2017 above).
  xdg.desktopEntries.sketchup2017 = {
    name = "SketchUp Make 2017";
    genericName = "3D Modeling";
    comment = "Last free SketchUp Make edition, running under Wine";
    exec = "sketchup2017";
    terminal = false;
    categories = ["Graphics" "3DGraphics"];
  };

  # Default browser
  xdg.mimeApps.defaultApplications = {
    "text/html" = "brave.desktop";
    "x-scheme-handler/http" = "brave.desktop";
    "x-scheme-handler/https" = "brave.desktop";
    "x-scheme-handler/about" = "brave.desktop";
    "x-scheme-handler/unknown" = "brave.desktop";
  };

  # Environment variables
  home.sessionVariables = {
    EDITOR = "micro";
    ANDROID_HOME = androidSdkRoot;
    ANDROID_SDK_ROOT = androidSdkRoot;
    ANDROID_NDK_ROOT = "${androidSdkRoot}/ndk/27.1.12297006";
    # Force gradle to use the nix-store aapt2 (the SDK dir is read-only).
    # Must match buildToolsVersion in android/build.gradle.
    GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdkRoot}/build-tools/34.0.0/aapt2";
    JDK17 = "${pkgs.jdk17.home}";
    JDK24 = "${pkgs-jdk24.jdk24.home}";
    JDK25 = "${pkgs.jdk25.home}";
  };

  # Fish shell configuration
  # https://fishshell.com/
  programs.fish = {
    enable = true;
    plugins = [
      {
        name = "plugin-git";
        src = pkgs.fishPlugins.plugin-git.src;
      }
      {
        name = "tide";
        src = pkgs.fishPlugins.tide.src;
      }
    ];
    functions = {
      "multicd" = {
        body = ''
          echo cd (string repeat -n (math (string length -- $argv[1]) - 1) ../)
        '';
      };
    };
    shellAbbrs = {
      nup = "sudo nixos-rebuild switch --flake ~/nixos-config#${hostname}";
      extract = "dtrx";
    };
    interactiveShellInit = ''
      abbr --add dotdot --regex '^\.\.+$' --function multicd
    '';
  };
  home.activation = {
    # `tide configure` lays down the Lean base, then we override the prompt
    # layout that the wizard can't express:
    #   - tide_character_icon / tide_character_vi_icon_default: ❯ prompt symbol.
    #     Both are set because on Fish 4.3 `fish_key_bindings` is empty, which
    #     makes tide 6.2.0 fall through to its vi branch and render the vi icon
    #     (tide bug #622, fixed upstream in #626). Setting the vi-default icon to
    #     ❯ too keeps the symbol correct regardless.
    #   - tide_left_prompt_items: a single line — status + cmd_duration first
    #     (both self-hide when the last command succeeded / was quick), then
    #     pwd/git/character. Keeping it one line lets pwd keep tide's width-aware
    #     truncation (the @PWD@ mechanism only works on a single-line prompt).
    #   - tide_right_prompt_items: emptied — nothing on the right side
    # `tide reload` regenerates the cached prompt from these variables.
    tide-configure = lib.hm.dag.entryAfter ["writeBoundary"] ''
      ${pkgs.fish}/bin/fish -c "
        tide configure --auto --style=Lean --prompt_colors='True color' --show_time=No --lean_prompt_height='One line' --prompt_spacing=Sparse --icons='Few icons' --transient=No
        set -U tide_character_icon '❯'
        set -U tide_character_vi_icon_default '❯'
        set -U tide_left_prompt_items status cmd_duration pwd git character
        set -U tide_right_prompt_items
        tide reload
        # tide reload returns 1 whenever transient mode is disabled: it ends with
        # `source fish_prompt.fish`, whose final statement is an `if test
        # \$tide_prompt_transient_enabled = true` that is false here (--transient=No),
        # so source exits 1. Swallow it so the activation unit doesn't fail.
        true
      "
    '';

    # Ovis (devswha/herdr-web-ui): materialize the flake-pinned source into a
    # writable tree, build it with the Nix-provided bun, and link it into
    # herdr. herdr plugin link runs no build commands, so the build happens
    # here. Idempotent: the .nix-pinned-rev marker skips the ~1 min rebuild
    # when the pinned rev is already built. Build failures are non-fatal
    # (previous version keeps running; next `just switch` retries).
    herdr-web-ui = lib.hm.dag.entryAfter ["writeBoundary"] ''
      set -eu
      rev="${inputs.herdr-web-ui.rev}"
      src="${inputs.herdr-web-ui}"
      dest="$HOME/.local/share/herdr-web-ui"
      stage="$dest.staging"
      herdr="${pkgs.herdr}/bin/herdr"

      if [ -f "$dest/.nix-pinned-rev" ] && [ "$(cat "$dest/.nix-pinned-rev")" = "$rev" ]; then
        :
      else
        echo "Ovis: building pinned rev $rev"
        rm -rf "$stage"
        cp -a "$src"/. "$stage"/
        chmod -R u+w "$stage"
        # ~/.bun cache is reused across rebuilds; frozen lockfile for reproducibility.
        (cd "$stage" && ${pkgs.bun}/bin/bun install --frozen-lockfile \
          && ${pkgs.bun}/bin/bun run build) \
          || { echo "Ovis: build failed; keeping previous version" >&2; rm -rf "$stage"; exit 0; }
        echo "$rev" > "$stage/.nix-pinned-rev"
        rm -rf "$dest.old"
        [ -e "$dest" ] && mv "$dest" "$dest.old" || true
        mv "$stage" "$dest"
        rm -rf "$dest.old"
      fi

      # Re-register (unregister first: link over an existing id is refused).
      "$herdr" plugin unlink devswha.herdr-web-ui >/dev/null 2>&1 || true
      "$herdr" plugin link "$dest"

      # Keep the flake pin authoritative: disable the in-app updater.
      cfg_dir="$("$herdr" plugin config-dir devswha.herdr-web-ui)"
      env_file="$cfg_dir/env"
      touch "$env_file"
      chmod 600 "$env_file"
      grep -q '^HERDR_WEB_AUTO_UPDATE=' "$env_file" \
        || printf 'HERDR_WEB_AUTO_UPDATE=0\n' >> "$env_file"
    '';

    # herdr agent integrations: hooks that report native session IDs to herdr
    # so agent panes (omp, claude, opencode) resume their conversations after
    # a server restart (session.resume_agents_on_restore). Install is
    # idempotent (status shows "installed"); run once per switch so a herdr
    # update rewrites the hooks with matching integration versions.
    herdr-agent-integrations = lib.hm.dag.entryAfter ["writeBoundary"] ''
      herdr="${pkgs.herdr}/bin/herdr"
      # One target per invocation: `herdr integration install` takes a single
      # <TARGET> argument.
      "$herdr" integration install omp
      "$herdr" integration install claude
      "$herdr" integration install opencode
    '';
  };

  programs.ghostty = {
    enable = true;
    enableFishIntegration = true;
    settings = {
      theme = "Atom One Dark";
      background-opacity = "0.95";
    };
  };

  # herdr — "agent multiplexer that lives in your terminal" (tmux-like with
  # sessions/workspaces/tabs/panes and AI-agent state tracking).
  # Config reference: https://herdr.dev/docs/config-reference/
  # The default keymap is prefix-first; the [keys] block below only overrides
  # bindings that clash with this machine's no-vim-keys/arrow-navigation
  # conventions. Prefix is "super+²".
  programs.herdr = {
    enable = true;
    # Pin to the same herdr build used by the wrapper below.
    package = pkgs.herdr;
    settings = {
      onboarding = false;
      experimental = {
        # Replay recent pane contents (scrollback) after a full server restart.
        # Stored in plaintext at ~/.config/herdr/session-history.json — treat
        # the herdr config dir like terminal history (docs/session-state).
        pane_history = true;
      };
      ui = {
        pane_gaps = false;
        prompt_new_tab_name = false;
      };
      # Native agent session restore after a server restart (omp, claude,
      # opencode, … via herdr integrations). Defaults true/100; pinned to
      # document intent.
      session = {
        resume_agents_on_restore = true;
        startup_per_agent_delay_ms = 100;
      };
      keys = {
        prefix = "super+²";
        # --- tabs ---
        new_tab = ["prefix+t" "ctrl+alt+t"];
        split_vertical = ["prefix+n" "ctrl+alt+n"];
        split_horizontal = ["prefix+j" "ctrl+alt+j"];
        cycle_pane_next = ["prefix+tab" "ctrl+alt+!"];
        navigate_workspace_up = ["ctrl+alt+up"]; 
        navigate_workspace_down = ["ctrl+alt+down"];
        close_pane = ["prefix+x" "ctrl+alt+x"];
        previous_tab = ["prefix+left" "ctrl+alt+left"];
        next_tab = ["prefix+right" "ctrl+alt+right"];

        switch_tab = "prefix+1..9";
        rename_tab = "prefix+shift+t";
        focus_pane_left = ["prefix+l" "ctrl+alt+l"];
        focus_pane_right = ["prefix+m" "ctrl+alt+m"];
        focus_pane_up = ["prefix+up"];
        focus_pane_down = ["prefix+down"];
        zoom = ["prefix+z" "ctrl+alt+z"];
        resize_mode = "prefix+r";
        resize_pane_left = "prefix+ctrl+left";
        resize_pane_right = "prefix+ctrl+right";
        resize_pane_up = "prefix+ctrl+up";
        resize_pane_down = "prefix+ctrl+down";
        workspace_picker = "prefix+w";
        goto = "prefix+g";
        new_workspace = "prefix+shift+n";
        rename_workspace = "prefix+shift+w";
        close_workspace = "prefix+shift+d";
        toggle_sidebar = "prefix+b";
        detach = "prefix+q";
      };
    };
  };

  # niri scrollable-tiling Wayland compositor.
  # Selectable as a "Niri" session at the GDM login screen (GNOME stays the
  # default). Mod == Super on a real TTY.
  programs.niri.settings = let
    # --- display geometry: single source of truth ---
    # A monitor's logical size = native pixels / scale. niri positions are in
    # logical coordinates and may be negative.
    edp = {
      w = 2560;
      h = 1600;
      scale = 1.25;
    };
    acer = {
      w = 3840;
      h = 2160;
      scale = 1.33;
    };
    edpLogicalW = edp.w / edp.scale;
    acerLogicalW = acer.w / acer.scale;
    acerLogicalH = acer.h / acer.scale;
    # eDP-1 anchored at the origin; the Acer sits directly above it (bottom
    # edge at y=0) and horizontally centered on the eDP. floor -> integer.
    acerX = builtins.floor ((edpLogicalW - acerLogicalW) / 2);
    acerY = builtins.floor (0 - acerLogicalH);
  in {
    prefer-no-csd = true;

    # Zed uses client-side decorations, so niri defaults to drawing the focus
    # ring/border as a solid rectangle *behind* the window — which bleeds through
    # Zed's slightly transparent background. Set draw-border-with-background to
    # false to draw it as just the border *around* the window instead.
    # Zed's Wayland app-id is "dev.zed.Zed".
    window-rules = [
      {
        matches = [{app-id = "^dev\\.zed\\.Zed$";}];
        draw-border-with-background = false;
      }
    ];

    # Ferdium (and other Electron apps) work under GNOME via XWayland but
    # hard-lock the amdgpu on niri's XWayland path. Force native Wayland.
    # Ferdium is Electron 37 (< 39), so per the niri wiki the env-var form is
    # the right method (Electron >= 39 would instead use --ozone-platform=wayland).
    # Scoped to the niri session, so the working GNOME session is untouched.
    environment = {
      ELECTRON_OZONE_PLATFORM_HINT = "auto";
      # niri 25.08 ships no XWayland bridge unless xwayland-satellite is in
      # $PATH, so $DISPLAY is never set and Qt apps (krita, etc.) crash on the
      # xcb plugin. Force the native Wayland QPA instead — also avoids the
      # amdgpu hard-lock niri's XWayland path triggers on this GPU (see the
      # Ferdium note above). Scoped to the niri session; GNOME untouched.
      QT_QPA_PLATFORM = "wayland";
    };

    # Display layout, translated from GNOME's ~/.config/monitors.xml (logical
    # coordinates). niri keeps a single outputs map and only applies the ones
    # actually connected, so unplugged monitors here are simply ignored.
    # Verify the connector names once inside niri with `niri msg outputs`
    # (GNOME shows "HDMI-1" but niri/DRM usually name it "HDMI-A-1").
    outputs = {
      # Acer B286HK (external, over HDMI @ 30Hz) — centered directly above eDP-1.
      "HDMI-A-1" = {
        scale = acer.scale;
        mode = {
          width = acer.w;
          height = acer.h;
          refresh = 30.000;
        };
        position = {
          x = acerX;
          y = acerY;
        };
      };
      # Internal laptop panel (primary), anchored at the origin.
      "eDP-1" = {
        scale = edp.scale;
        mode = {
          width = edp.w;
          height = edp.h;
          refresh = 300.000;
        };
        position = {
          x = 0;
          y = 0;
        };
      };
    };

    input = {
      keyboard.xkb.layout = "fr";
      touchpad = {
        tap = true;
        natural-scroll = false;
      };
      mouse.natural-scroll = false;
    };

    spawn-at-startup = [
      # Desktop shell / bar.
      {command = ["noctalia"];}
    ];

    binds = with config.lib.niri.actions; {
      # --- launch ---
      # New ghostty window with herdr
      "Mod+Return".action = spawn "ghostty" "-e" "herdr";
      # Plain terminal without herdr.
      "Mod+T".action = spawn "ghostty";
      # Noctalia's built-in application launcher.
      "Mod+D".action = spawn "noctalia" "msg" "panel-toggle" "launcher";

      "Mod+space".action = toggle-overview;

      # Show the niri keybind cheat-sheet (the overlay shown at startup).
      "Mod+I".action = show-hotkey-overlay;

      # --- noctalia panels ---
      "Mod+V".action = spawn "noctalia" "msg" "panel-toggle" "clipboard";
      "Mod+Escape".action = spawn "noctalia" "msg" "panel-toggle" "session";
      "Mod+L".action = spawn "noctalia" "msg" "session" "lock";

      # --- window management ---
      "Mod+Q".action = close-window;
      "Mod+F".action = maximize-column;
      "Mod+Shift+F".action = fullscreen-window;
      "Mod+O".action = toggle-window-floating;
      "Mod+C".action = center-column;
      "Mod+W".action = consume-or-expel-window-left;
      "Mod+X".action = consume-or-expel-window-right;
      "Mod+P".action = set-column-width "+10%";
      "Mod+M".action = set-column-width "-10%";
      "Mod+H".action = set-column-width "50%";

      # --- focus ---
      "Mod+Left".action = focus-column-left;
      "Mod+Right".action = focus-column-right;
      "Mod+Up".action = focus-window-or-monitor-up;
      "Mod+Down".action = focus-window-or-monitor-down;
      "Mod+Alt+Up".action = focus-workspace-up;
      "Mod+Alt+Down".action = focus-workspace-down;

      # --- move ---
      "Mod+Shift+Left".action = move-column-left;
      "Mod+Shift+Right".action = move-column-right;
      "Mod+Shift+Up".action = move-column-to-monitor-up;
      "Mod+Shift+Down".action = move-column-to-monitor-down;
      "Mod+Ctrl+Up".action = move-column-to-workspace-up;
      "Mod+Ctrl+Down".action = move-column-to-workspace-down;

      # --- screenshots (raw form: not exposed via the actions lib) ---
      "Print".action.screenshot = {};
      "Mod+Print".action.screenshot-screen = {show-pointer = false;};

      # --- media keys ---
      "XF86AudioRaiseVolume" = {
        allow-when-locked = true;
        action = spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.05+";
      };
      "XF86AudioLowerVolume" = {
        allow-when-locked = true;
        action = spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.05-";
      };
      "XF86AudioMute" = {
        allow-when-locked = true;
        action = spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle";
      };
      "XF86MonBrightnessUp" = {
        allow-when-locked = true;
        action = spawn "brightnessctl" "set" "5%+";
      };
      "XF86MonBrightnessDown" = {
        allow-when-locked = true;
        action = spawn "brightnessctl" "set" "5%-";
      };

      # --- session ---
      "Mod+Shift+E".action = quit;
    };
    # --- cursor ---
    # Mouse cursor theme. Must match home.pointerCursor at the bottom of this
    # file. niri draws its own embedded fallback arrow when the theme is left
    # at the flake-default "default" (which has no files on disk), so pointer
    # shapes other than the arrow never appeared. Setting it here:
    #  1. makes niri itself load Adwaita for its own rendering, and
    #  2. exports XCURSOR_THEME=Adwaita (+ XCURSOR_SIZE) to every process
    #     niri spawns, so all clients render the full pointer set.
    cursor = {
      theme = "Adwaita";
      size = 24;
    };
  };

  # Noctalia v5 desktop shell (bar, launcher, panels). Autostarted by niri above.
  programs.noctalia = {
    enable = true;
    # noctalia config export | nix run nixpkgs#toml2nix
    settings = {
      bar = {
        default = {
          center = [
            "notifications"
            "clock"
            "clipboard"
          ];
          end = [
            "network"
            "bluetooth"
            "volume"
            "brightness"
            "battery"
            "session"
          ];
          margin_edge = 4;
          margin_ends = 10;
          padding = 14;
          radius = 12;
          scale = 1.10;
          start = [
            "launcher"
            "workspaces"
            "lock_keys"
          ];
          thickness = 36;
        };
      };
      desktop_widgets = {
        enabled = false;
      };
      lockscreen_widgets = {
        enabled = false;
      };
      shell = {
        niri_overview_type_to_launch_enabled = true;
        screenshot = {
          "directory" = "/home/age2pierre/Pictures/Screenshots";
        };
        settings_show_advanced = true;
        time_format = "{:%H:%M:%S}";
      };
      theme = {
        builtin = "Dracula";
        source = "community";
      };
      wallpaper = {
        default = {
          "path" = "/home/age2pierre/nixos-config/Wallpapers/amber.webp";
        };
        directory = "/home/age2pierre/nixos-config/Wallpapers";
        last = {
          "path" = "/home/age2pierre/nixos-config/Wallpapers/amber.webp";
        };
        monitors = {
          "HDMI-A-1" = {
            "path" = "/home/age2pierre/nixos-config/Wallpapers/amber.webp";
          };
          "eDP-1" = {
            "path" = "/home/age2pierre/nixos-config/Wallpapers/amber.webp";
          };
        };
      };
      weather = {
        enabled = false;
      };
      widget = {
        battery = {
          capsule = true;
          capsule_padding = 10.0;
          device = "/org/freedesktop/UPower/devices/battery_BAT0";
          display_mode = "graphic";
        };
        bluetooth = {
          capsule = true;
          capsule_padding = 10.0;
        };
        brightness = {
          capsule = true;
          capsule_padding = 10.0;
        };
        clock = {
          format = "{:%A %d %B %H:%M:%S}";
        };
        lock_keys = {
          capsule = true;
          capsule_padding = 10.0;
          display = "full";
          hide_when_off = true;
        };
        network = {
          capsule = true;
          capsule_padding = 10.0;
        };
        volume = {
          capsule = true;
          capsule_padding = 10.0;
        };
        workspaces = {
          display = "none";
          hide_when_empty = true;
        };
      };
    };
  };

  # Git configuration
  programs.git = {
    enable = true;
    lfs.enable = true;
    settings = {
      user = {
        name = "age2pierre";
        email = "pierre.j.robillard@gmail.com";
      };
      core = {
        editor = "micro";
        whitespace = "-l";
        excludesfiles = ["/home/age2pierre/.gitignore_global"];
        pager = "delta";
      };
      interactive.diffFilter = "delta --color-only";
      delta = {
        navigate = true;
        light = false;
      };
      merge.conflictstyle = "diff3";
      diff.colorMoved = "default";
      # blame.ignoreRevsFile = ".git-blame-ignore-revs";
      push = {
        recurseSubmodules = "on-demand";
        autoSetupRemote = true;
      };
      submodule = {
        recurse = true;
      };
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # SSH configuration
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        ForwardAgent = false;
        AddKeysToAgent = "no";
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };
      "swarmlet1" = {
        HostName = "51.15.69.22";
        User = "root";
        IdentityFile = "~/.ssh/id_ed25519";
      };
      "lokaly_app" = {
        HostName = "192.168.99.60";
        User = "lokalyadm";
        Port = 22;
        IdentityFile = "~/.ssh/id_ed25519";
      };
      "lokaly_db" = {
        HostName = "192.168.99.100";
        User = "lokalyadm";
        Port = 22;
        IdentityFile = "~/.ssh/id_ed25519";
      };
    };
  };

  home.file = {
    # oh-my-pi (omp) config — all three files rendered from ai-shared.nix.
    # omp reads ~/.omp/agent/{models.yml,config.yml,mcp.json}.  config.yml is
    # a store symlink (force = true overwrites the previous hand-written file),
    # so `/settings` and `omp config set` are read-only at runtime — edit
    # ompSettings in ai-shared.nix and rebuild instead.
    ".omp/agent/models.yml".text = ai.toOmpProvidersYaml;
    ".omp/agent/config.yml".text = ai.toOmpConfigYaml;
    ".omp/agent/config.yml".force = true;
    ".omp/agent/mcp.json".text = ai.toOmpMcp;
    # pi-brainstorm extension (conversation-only /brainstorm mode with
    # decision-brief export). omp auto-discovers *.ts under this directory;
    # its legacy-pi compat loader rewrites the extension's `@mariozechner/*`
    # imports onto omp's bundled copies, so no node_modules needed.
    ".omp/agent/extensions/brainstorm.ts".source = "${ai.piBrainstorm}/extensions/brainstorm.ts";
    ".gradle/gradle.properties" = {
      text = ''
        # NixOS: foojay-provisioned JDKs aren't patchelf'd, so disable auto-download.
        # Gradle picks up JDK 17 from the JDK17 env var set in home.sessionVariables.
        org.gradle.java.installations.auto-download=false
        org.gradle.java.installations.fromEnv=JDK17,JDK24,JDK25
      '';
    };
    ".ssh/id_rsa" = {
      # agenix HM secret: symlink into /run/user/1000/agenix.
      # The agenix HM module materializes decrypted secrets there at login;
      # mkOutOfStoreSymlink avoids eval-time access to these runtime paths.
      source = config.lib.file.mkOutOfStoreSymlink "/run/user/1000/agenix/ssh-id-rsa";
      force = true;
    };
    ".ssh/id_rsa.pub" = {
      source = ./id_rsa.pub;
      force = true;
    };
    ".ssh/id_ed25519" = {
      source = config.lib.file.mkOutOfStoreSymlink "/run/user/1000/agenix/ssh-id-ed25519";
      force = true;
    };
    ".ssh/id_ed25519.pub" = {
      source = ./id_ed25519.pub;
      force = true;
    };
    ".bunfig.toml" = {
      text = ''
        [install]
        linker = "isolated"
        exact = false
      '';
    };
    ".kube/config" = {
      source = config.lib.file.mkOutOfStoreSymlink "/run/user/1000/agenix/kubeconfig";
      force = true;
    };
  };

  services.ollama = {
    enable = true;
    package = pkgs.ollama-vulkan;
    port = 11434;
  };

  # opencode — AI coding agent. Config rendered from ai-shared.nix so the
  # provider list stays shared with omp / zed / fresh.
  programs.opencode = {
    enable = true;
    package = pkgs.opencode;
    settings = {
      "$schema" = "https://opencode.ai/config.json";
      autoupdate = false;
      instructions = ["~/.config/opencode/instructions/code-gen.md"];
      provider = ai.toOpencodeProviders;
      mcp = ai.toOpencodeMcp;
      permission = {
        bash = "ask";
        edit = "allow";
        write = "allow";
        read = "allow";
        grep = "allow";
        glob = "allow";
        list = "allow";
        lsp = "allow";
        apply_patch = "allow";
        skill = "allow";
        todowrite = "allow";
        webfetch = "allow";
        websearch = "allow";
        question = "allow";
      };
    };
    # No `tui` block: opencode v2 reads cli.json (migrated from v1 tui.json)
    # and defaults to the "opencode" theme. A HM-managed tui.json here would
    # be a read-only store symlink that blocks `herdr integration install
    # opencode` from registering its TUI plugin.
  };

  # VSCode: default profile (no Java/Nix-specific extensions) plus `java`
  # and `nix` profiles for Java/Gradle and Nix work respectively. Open a
  # project with `code --profile <name> <dir>`; VSCode then remembers the
  # folder→profile association. Adding any non-default profile flips the
  # extensions dir to a Nix-store symlink, wiping extensions not declared
  # here (the approved clean cutover).
  programs.vscode = {
    enable = true;
    package = pkgs.vscode-fhs;
    profiles = {
      default = {
        extensions = vscodeDefaultExtensions;
        userSettings = vscodeSharedSettings;
        keybindings = vscodeSharedKeybindings;
      };
      java = {
        extensions =
          vscodeDefaultExtensions
          ++ (with pkgs.nix-vscode-extensions.vscode-marketplace; [
            redhat.java
            vscjava.vscode-gradle
            vscjava.vscode-java-debug
            fwcd.kotlin
          ]);
        userSettings =
          vscodeSharedSettings
          // {
            "java.autobuild.enabled" = false;
            # Point Red Hat Java at a JDK from the Nix profile. jdk21 is
            # already in home.packages. Override only if a different JDK
            # is needed for these projects.
            "java.configuration.runtimes" = [
              {
                name = "JavaSE";
                path = "${pkgs.jdk21.home}";
                default = true;
              }
            ];
          };
        keybindings = vscodeSharedKeybindings;
      };
      nix = {
        extensions =
          vscodeDefaultExtensions
          ++ (with pkgs.nix-vscode-extensions.vscode-marketplace; [
            jnoortheen.nix-ide
          ]);
        userSettings =
          vscodeSharedSettings
          // {
            "nix.enableLanguageServer" = true;
            "nix.serverPath" = "nixd";
            "nix.serverSettings" = {
              nixd = {
                formatting = {command = ["alejandra"];};
                options = {
                  nixos = {
                    expr = "(builtins.getFlake \"/home/age2pierre/nixos-config\").nixosConfigurations.${hostname}.options";
                  };
                };
              };
            };
          };
        keybindings = vscodeSharedKeybindings;
      };
    };
  };

  programs.zed-editor = {
    enable = true;
    package = pkgs.zed-editor-fhs;
    # LSP binaries on PATH so zed's auto-discovery finds them. The list is
    # shared with fresh-editor / opencode / omp via ai-shared.nix.
    extraPackages = ai.toZedExtraPackages;
    # Preserve the existing hand-edited settings.json (font, theme, …) by
    # letting zed own it — we only inject extraPackages and don't override
    # userSettings, so zed keeps full read/write control of the file.
    mutableUserSettings = true;
  };

  # fresh-editor — LSP config rendered from ai-shared.nix (shared with zed,
  # opencode, omp). The rest of the config (theme, tsconfig, types)
  # is left to fresh-editor's own on-disk files.
  programs.fresh-editor = {
    enable = true;
    package = pkgs.fresh-editor;
    settings = {
      lsp = ai.toFreshLsp;
      theme = "builtin://dark";
    };
  };

  # dconf: only the settings that still affect GTK apps under niri. GTK/libadwaita
  # apps read color-scheme + accent from here (via the settings portal), giving
  # them dark mode. All the GNOME-Shell / extension config was removed with the
  # GNOME session.
  dconf = {
    enable = true;
    # to generate settings after using UI
    # dconf dump /foo/bar/ | nix run nixpkgs#dconf2nix
    settings = {
      "org/gnome/desktop/interface" = {
        accent-color = "teal";
        color-scheme = "prefer-dark";
        gtk-theme = "Adwaita-dark";
        # Keep GTK's cursor setting in sync with home.pointerCursor below so
        # GTK apps don't fall back to the (theme-less) "default" fallback.
        cursor-theme = "Adwaita";
        cursor-size = 24;
      };
    };
  };

  # Mouse cursor theme. On this niri session the compositor (niri-flake
  # default) exports XCURSOR_THEME="default", but no theme named "default"
  # exists in XCURSOR_PATH, so every app silently fell back to a minimal
  # arrow-only set — only `none` visibly changed anything. home.pointerCursor:
  #  - installs the theme package
  #  - exports XCURSOR_THEME/XCURSOR_SIZE/XCURSOR_PATH for the session
  #  - links ~/.icons/default (and $XDG_DATA_HOME/icons) to the theme via a
  #    generated index.theme (Inherits=Adwaita), which makes the
  #    compositor-level "default" theme resolve to Adwaita for every client.
  # gtk.enable also wires gtk.cursorTheme (Settings.ini). programs.niri.settings
  # sets the matching cursor { xcursor-theme } so the compositor draws the
  # same theme itself.
  home.pointerCursor = {
    enable = true;
    package = pkgs.adwaita-icon-theme;
    name = "Adwaita";
    size = 24;
    x11.enable = true;
    gtk.enable = true;
    dotIcons.enable = true;
  };
}
