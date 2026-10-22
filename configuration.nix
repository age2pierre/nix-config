{
  config,
  pkgs,
  hostname,
  pkgs-stable,
  ...
}: {
  # agenix: age-encrypted secrets (secrets/*.age), decrypted at activation.
  # Identity is a dedicated age key (no SSH host keys on this host).
  age.identityPaths = ["/etc/agenix/tuxedo.age"];
  age.secrets = {
    # Combined env file for NM ensureProfiles envsubst (one var per SSID);
    # profiles reference "$WIFI_PSK_<NAME>" instead of inline PSKs.
    wifi-env.file = ./secrets/wifi-env.age;
    searxng-env = {
      file = ./secrets/searxng-env.age;
      owner = "searx";
      group = "searx";
      mode = "0400";
    };
  };
  # Kernel 7.1: the MT7922 Bluetooth regression present in 7.0.7 (truncated
  # WMT_FUNC_CTRL response -> "Failed to send wmt func ctrl (-22)") is already
  # fixed upstream (the truncated branch now sets BTMTK_WMT_ON_UNDONE instead
  # of returning -EINVAL), so no extra patch needed. linux_7_0 was removed from
  # nixpkgs after reaching EOL upstream; 7.1 is the successor mainline series.
  # TODO(drop): tuxedo-drivers workaround for nixpkgs PR #571181 (kmodigest,
  # landed in nixos-unstable @ 02c087f3): kernelModuleMakeFlags now contains
  # cmd_sign=<kmodigest>$(space)$@ and tuxedo-drivers 4.20.1's Makefile
  # re-expands $(MAKEFLAGS) through `bash -c` in its all/install/clean recipes —
  # bash can't parse the literal `$(space)$@` and the build dies instantly.
  # make transmits command-line overrides to recursive sub-makes via the
  # MAKEFLAGS environment automatically, so the explicit $(MAKEFLAGS) in those
  # recipes is redundant: strip it. The kernel sub-make (which defines `space`
  # in Kbuild.include) then receives cmd_sign cleanly and modules_install signs
  # every module with kmodigest → .ko.cer files required by the NixOS module
  # aggregation (aggregateModules). Verify removal with:
  #   nix build nixpkgs#linuxPackages_7_2.tuxedo-drivers
  boot.kernelPackages = pkgs.linuxPackages_7_2.extend (self: super: {
    tuxedo-drivers = super.tuxedo-drivers.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace Makefile \
          --replace-fail ' $(MAKEFLAGS)' ""
      '';
      # modules_install runs depmod inside INSTALL_MOD_PATH, leaving stale
      # modules.dep/*.bin maps next to the modules; aggregateModules re-runs
      # depmod over the merged tree, and keeping both makes buildEnv fail with
      # a conflicting-subpath error. modules.* and modules.builtin* are kept.
      postInstall = (old.postInstall or "") + ''
        rm -f "$out"/lib/modules/*/modules.dep* \
          "$out"/lib/modules/*/modules.alias* \
          "$out"/lib/modules/*/modules.softdep \
          "$out"/lib/modules/*/modules.symbols* \
          "$out"/lib/modules/*/modules.devname \
          "$out"/lib/modules/*/modules.builtin*
      '';
    });
  });
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 5;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # --- Crash diagnostics & amdgpu (Strix Point / Radeon 890M) stability ---
  # Two hard freezes, both silent black-screen hangs on this RDNA3.5 iGPU:
  #
  # 2026-06-23: hard freeze + black screen with NOTHING in the journal. The
  # journal was flagged "uncleanly shut down" on the next boot and the kernel
  # ring buffer had gone silent ~5h before the lockup: no panic, no oops, no
  # amdgpu GPU-reset, no MCE, no thermal trip were captured. With no evidence
  # to go on, PSR (Panel Self Refresh) was the prime suspect — a frequent
  # source of silent display hangs on Strix Point — so amdgpu.dcdebugmask=0x10
  # (DC_DISABLE_PSR) was added. These settings below also (a) keep logging
  # alive so the NEXT freeze leaves evidence, and (b) defuse the most likely
  # culprit. All reversible - drop the amdgpu params once the machine has
  # proven stable.
  #
  # 2026-08-11: hard freeze while playing a YouTube video, with on-screen
  # glitches beforehand. This time the journal (kept alive by the settings
  # above) captured the cause: a kernel WARNING at
  # dc_dmub_srv_apply_idle_power_optimizations+0x22b [amdgpu] — the ASSERT(0)
  # at dc_dmub_srv.c:1705 fires because idle_exit_counter goes negative. Two
  # threads race exiting IPS (Idle Power States) when the driver reads a
  # register during an atomic commit (YouTube = frequent page flips). IPS —
  # not PSR — was the culprit all along. The fix is amdgpu.dcdebugmask=0x800
  # (DC_DISABLE_IPS), which maps to DMUB_IPS_DISABLE_ALL (amdgpu_dm.c:2037-38)
  # and short-circuits the entire idle-power-optimization path, eliminating
  # the race. PSR (0x10) is kept too: both are display-power-saving features
  # that can hang this very new iGPU, and the cost of disabling them is
  # battery life, not correctness. See the inline comment on the kernelParam
  # for the full code path.
  boot.kernelParams = [
    # Keep the console + kernel log alive across suspend/resume, so a hang right
    # after resume can still be written out instead of dying in the dark.
    "no_console_suspend"
    # DC_DISABLE_PSR (0x10) + DC_DISABLE_IPS (0x800). On DCN 3.5 (Strix Point /
    # Radeon 890M) the display driver races two threads exiting IPS (Idle Power
    # States) at once when reading a register during an atomic commit (e.g.
    # YouTube page flips). idle_exit_counter goes negative → ASSERT(0) at
    # dc_dmub_srv.c:1705, and the display pipeline eventually hangs. The journal
    # captured this WARNING twice (boot -2 @19:24:15 right before the silent
    # freeze; boot -1 @19:29:52 as the on-screen glitches). 0x800 maps to
    # DMUB_IPS_DISABLE_ALL (amdgpu_dm.c:2037-2038), which short-circuits the
    # entire idle-power-optimization path (dc.c:5802,5849) and eliminates the
    # race — this is the real fix for the 2026-08-11 hard freeze. PSR (0x10) is
    # kept too: both are display-power-saving features that can hang this very
    # new iGPU, and the cost of disabling them is battery life, not correctness.
    # See the header comment above for the full history. All reversible — drop
    # 0x800 (and 0x10) once the machine has proven stable.
    "amdgpu.dcdebugmask=0x810"
  ];

  # Persist the journal to disk (so the last seconds survive a crash) and flush
  # aggressively rather than buffering in RAM.
  services.journald.settings.Journal = {
    Storage = "persistent";
    SyncIntervalSec = "30s";
  };

  # Archive any firmware/kernel crash record found in pstore (UEFI vars / RAM)
  # into /var/lib/systemd/pstore on the next boot, so a captured panic is kept.
  systemd.services.systemd-pstore.wantedBy = ["multi-user.target"];

  # Hardware watchdog. This machine has the AMD SP5100 TCO timer (sp5100_tco ->
  # /dev/watchdog). systemd PID1 pets it every runtimeTime; if the kernel hard-
  # locks and PID1 can no longer run, the chip force-resets the box after the
  # interval - turning an indefinite black-screen freeze into a quick reboot, so
  # the persistent journal above can capture the lead-up. CAVEAT: this catches
  # true full-system lockups; a pure display/GPU hang where the kernel still
  # schedules normally will keep petting the dog and won't trip it.
  boot.kernelModules = ["sp5100_tco"];
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "10m";
  };

  # Networking
  networking.hostName = hostname;
  networking.networkmanager = {
    enable = true;
    # Decrypted at activation from secrets/wifi-env.age (agenix).
    ensureProfiles.environmentFiles = [config.age.secrets.wifi-env.path];
    plugins = with pkgs; [
      networkmanager-openvpn
    ];
    /*
    To generate profiles look at https://github.com/janik-haag/nm2nix :
    sudo su -c "cd /etc/NetworkManager/system-connections &&\
      nix --extra-experimental-features 'nix-command flakes' run github:Janik-Haag/nm2nix |\
      nix --extra-experimental-features 'nix-command flakes' run nixpkgs#alejandra"
    */
    ensureProfiles.profiles = {
      # Bleury
      Livebox-8350 = {
        connection = {
          id = "Livebox-8350";
          type = "wifi";
          uuid = "732ebd6c-a955-47b8-b8c0-72dbd9f0266d";
        };
        ipv4 = {
          method = "auto";
        };
        ipv6 = {
          addr-gen-mode = "default";
          method = "auto";
        };
        proxy = {};
        wifi = {
          mode = "infrastructure";
          ssid = "Livebox-8350";
        };
        wifi-security = {
          auth-alg = "open";
          key-mgmt = "wpa-psk";
          psk = "$WIFI_PSK_LIVEBOX_8350";
        };
      };
      # Veigné
      Livebox-9EE0 = {
        connection = {
          id = "Livebox-9EE0";
          type = "wifi";
          uuid = "2ada03ab-c95a-4732-8c52-fd20cb4927c8";
        };
        ipv4 = {
          dns = "185.222.222.222;45.11.45.11;";
          method = "auto";
        };
        ipv6 = {
          addr-gen-mode = "stable-privacy";
          dns = "2a09::;2a11::;";
          method = "auto";
        };
        proxy = {};
        wifi = {
          mode = "infrastructure";
          ssid = "Livebox-9EE0";
        };
        wifi-security = {
          auth-alg = "open";
          key-mgmt = "wpa-psk";
          psk = "$WIFI_PSK_LIVEBOX_9EE0";
        };
      };
      RobiphoneHotspot = {
        connection = {
          id = "RobiphoneHotspot";
          type = "wifi";
          uuid = "04f8e97c-38a1-4fa2-bf28-f7f4c19ce314";
        };
        ipv4 = {
          method = "auto";
        };
        ipv6 = {
          addr-gen-mode = "default";
          method = "auto";
        };
        proxy = {};
        wifi = {
          mode = "infrastructure";
          ssid = "RobiphoneHotspot";
        };
        wifi-security = {
          auth-alg = "open";
          key-mgmt = "wpa-psk";
          psk = "$WIFI_PSK_ROBIPHONEHOTSPOT";
        };
      };
      # VPN Lokaly
      VDC-000206_VNC-000101 = {
        connection = {
          autoconnect = "false";
          id = "VDC-000206_VNC-000101";
          permissions = "user:age2pierre:;";
          timestamp = "1760457603";
          type = "vpn";
          uuid = "a13de22d-c943-4d2d-9344-ba882051c58c";
        };
        ipv4 = {
          method = "auto";
          never-default = "true";
        };
        ipv6 = {
          addr-gen-mode = "default";
          method = "auto";
          never-default = "true";
        };
        proxy = {};
        vpn = {
          ca = "/home/age2pierre/lokaly/Castle IT - VPN SSL - VPNPierre/ca.crt";
          cert = "/home/age2pierre/lokaly/Castle IT - VPN SSL - VPNPierre/VDC-000206_VNC-000101.crt";
          cert-pass-flags = "0";
          challenge-response-flags = "2";
          cipher = "AES-256-CBC";
          comp-lzo = "adaptive";
          connection-type = "tls";
          dev = "tun";
          key = "/home/age2pierre/lokaly/Castle IT - VPN SSL - VPNPierre/VDC-000206_VNC-000101.key";
          proto-tcp = "yes";
          remote = "vpn-ssl-lcx1.castle-it.fr:1450";
          service-type = "org.freedesktop.NetworkManager.openvpn";
          ta = "/home/age2pierre/lokaly/Castle IT - VPN SSL - VPNPierre/ta.key";
          ta-dir = "1";
        };
      };
      # Kamino
      CODE-TROOPERS = {
        connection = {
          id = "CODE-TROOPERS";
          timestamp = "1742546804";
          type = "wifi";
          uuid = "dcbcbe3b-c032-43f9-afc2-c7e30fb161b5";
        };
        ipv4 = {
          dns = "185.222.222.222;45.11.45.11;";
          method = "auto";
        };
        ipv6 = {
          addr-gen-mode = "stable-privacy";
          dns = "2a09::;2a11::;";
          method = "auto";
        };
        proxy = {};
        wifi = {
          mode = "infrastructure";
          ssid = "CODE-TROOPERS";
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$WIFI_PSK_CODE_TROOPERS";
        };
      };
      # Epieds ??
      Bbox-8A4D7F2E = {
        connection = {
          id = "Bbox-8A4D7F2E";
          timestamp = "1658861906";
          type = "wifi";
          uuid = "64c717e7-3495-42bf-b39b-26d5f90b2b00";
        };
        ipv4 = {
          dns = "185.222.222.222;45.11.45.11;";
          method = "auto";
        };
        ipv6 = {
          addr-gen-mode = "stable-privacy";
          dns = "2a09::;2a11::;";
          method = "auto";
        };
        proxy = {};
        wifi = {
          mode = "infrastructure";
          ssid = "Bbox-8A4D7F2E";
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$WIFI_PSK_BBOX_8A4D7F2E";
        };
      };
    };
  };

  # Time zone
  time.timeZone = "Europe/Paris";

  # Internationalisation
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "fr_FR.UTF-8";
    LC_IDENTIFICATION = "fr_FR.UTF-8";
    LC_MEASUREMENT = "fr_FR.UTF-8";
    LC_MONETARY = "fr_FR.UTF-8";
    LC_NAME = "fr_FR.UTF-8";
    LC_NUMERIC = "fr_FR.UTF-8";
    LC_PAPER = "fr_FR.UTF-8";
    LC_TELEPHONE = "fr_FR.UTF-8";
    LC_TIME = "fr_FR.UTF-8";
  };

  # GDM login manager. The GNOME desktop session is gone; GDM just offers the
  # "Niri" Wayland session. X server kept enabled for XWayland.
  services.xserver = {
    enable = true;
  };
  services.displayManager.gdm.enable = true;

  # niri Wayland compositor (registers a "Niri" session in GDM).
  # The compositor config itself lives in home-manager (programs.niri.settings).
  programs.niri.enable = true;

  # Bits the GNOME desktop used to provide that we still want under niri:
  programs.dconf.enable = true; # gsettings backend for GTK apps (dark mode, etc.)
  services.gvfs.enable = true; # trash, mounting, network shares for Nautilus
  services.udisks2.enable = true; # disk mounting/format for gnome-disk-utility

  # Services the Noctalia shell expects for its bar widgets.
  services.upower.enable = true;
  hardware.bluetooth.enable = true;
  services.power-profiles-daemon.enable = true;

  # Configure keymap in X11 (XWayland)
  services.xserver.xkb = {
    layout = "fr";
    variant = "";
  };

  # Console keymap
  console.keyMap = "fr";
  # keyd: remap the airplane-mode Fn key (F12 position) to a no-op.
  # On this TUXEDO (uniwill_wmi), the physical F12/Fn key emits KEY_RFKILL
  # (code 247) via the "TUXEDO Keyboard" WMI input device (bustype 0x19,
  # vendor:product 0000:0000) — pressing it toggles airplane mode (kills
  # Wi-Fi + Bluetooth) instead of F12. The TUXEDO Fn-Lock toggle (Fn+Esc)
  # swaps between the media/Fn layer and the F-key layer; when Fn-Lock is
  # ON the key still sends KEY_RFKILL, not F12, so Chrome devtools (F12)
  # is unreachable. keyd intercepts KEY_RFKILL system-wide and drops it.
  #
  # IMPORTANT: the "TUXEDO Keyboard" WMI device only has media keys in its
  # sparse keymap (KEY_RFKILL, KEY_KBDILLUMDOWN, …), so keyd does NOT
  # classify it as a keyboard and ignores it under the "*" wildcard. It
  # must be matched explicitly by its vendor:product id (0000:0000). The
  # AT keyboard ("AT Translated Set 2 keyboard", 0001:0001) is matched by
  # "*" and gets the same noop binding harmlessly (it never emits
  # KEY_RFKILL). To re-enable airplane mode later, remove this block.
  services.keyd.enable = true;
  services.keyd.keyboards.tuxedo = {
    ids = ["0000:0000" "*"];
    settings = {
      main = {
        rfkill = "noop";
      };
    };
  };

  # Printing
  services.printing.enable = true;

  # SearXNG meta-search engine — local instance used by omp's web_search
  # tool (SEARXNG_ENDPOINT=http://127.0.0.1:7475). Bound to localhost only;
  # rate limiter / bot protection disabled so the agent can query it freely.
  services.searx = {
    enable = true;
    environmentFile = config.age.secrets.searxng-env.path; # sets SEARX_SECRET_KEY
    redisCreateLocally = false; # only needed for the rate limiter (off)
    settings = {
      server = {
        port = 7475;
        bind_address = "127.0.0.1";
        secret_key = "$SEARX_SECRET_KEY";
        limiter = false; # no rate limiting — agent queries from localhost
        public_instance = false; # not exposed to the internet
        image_proxy = true;
      };
      search = {
        formats = ["html" "json"]; # omp needs JSON responses
        autocomplete = "google";
      };
      ui = {
        default_theme = "simple";
        infinite_scroll = true;
      };
      outgoing = {
        request_timeout = 10.0; # seconds
        max_request_timeout = 20.0;
      };
    };
  };

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # jack.enable = true;
  };

  # User account
  users.users.age2pierre = {
    isNormalUser = true;
    description = "Pierre Robillard";
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
      "kvm"
    ];
    shell = pkgs.fish;
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Binary caches so niri and noctalia are fetched, not compiled from source.
  # (First rebuild won't have these active yet - see the one-time command noted
  # when this was set up, or just rebuild twice.)
  nix.settings.extra-substituters = [
    "https://niri.cachix.org"
    "https://noctalia.cachix.org"
  ];
  nix.settings.extra-trusted-public-keys = [
    "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
    "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
  ];

  # optimised nix store during every build - slow down build, save disk space
  nix.settings.auto-optimise-store = true;
  nix.gc.automatic = true;
  nix.gc.dates = "weekly";
  nix.gc.options = "--delete-older-than 15d";

  # Nerd Font for the Noctalia shell's icon glyphs.
  fonts.packages = [pkgs.nerd-fonts.jetbrains-mono];

  # Enable Fish Shell
  programs.fish.enable = true;
  # nix.settings.trusted-users = ["root" "age2pierre"];

  # Docker
  virtualisation.docker.enable = true;
  virtualisation.docker.daemon.settings = {
    # https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file
    userland-proxy = false;
    experimental = true;
  };
  # Steam games
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
  };

  # programs.ssh.startAgent = true;

  # OpenSSH daemon (optional)
  # services.openssh.enable = true;

  # Antivirus ClamAV
  environment.systemPackages = [
    pkgs.clamav
  ];
  services.clamav.daemon.enable = true;

  services.clamav.updater.enable = true;

  # Tailscale
  
  services.tailscale.enable = true;

  # Ovis (herdr-web-ui, 127.0.0.1:7317): publish to the tailnet over HTTPS so
  # the phone can reach it (PWA install + push alerts need a secure context).
  # `tailscale serve` persists in tailscaled state; this oneshot is a
  # self-healing idempotent guard, not a per-boot requirement.
  systemd.services.herdr-web-ui-serve = {
    description = "Publish Ovis (herdr-web-ui) to the tailnet via tailscale serve";
    after = ["tailscaled.service"];
    wants = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];
    path = [pkgs.tailscale];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if tailscale serve status 2>/dev/null | grep -q "127.0.0.1:7317"; then
        exit 0
      fi
      # tailscaled may need a few seconds after the unit ordering target.
      tries=0
      until tailscale serve --bg --https=443 http://127.0.0.1:7317 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 5 ] || { echo "tailscale serve failed; check: tailscale status" >&2; exit 1; }
        sleep 2
      done
    '';
  };

  # Firewall
  networking.firewall.enable = true;
  networking.firewall.trustedInterfaces = ["docker0"];

  # First version of NixOS installed - DO NOT CHANGE
  system.stateVersion = "25.05";
  # nix-ld: exec-time loader for UNPATCHED prebuilt ELFs (e.g. biome from
  # node_modules — interpreter /lib64/ld-linux-x86-64.so.2). stub-ld default
  # otherwise prints the "NixOS cannot run dynamically linked executables"
  # error. NOTE: does not affect dlopen() inside Nix-patched binaries (bun +
  # duckdb) — that is handled by the bun overlay's LD_LIBRARY_PATH wrapper.
  # Default library set already includes stdenv.cc.cc (libstdc++/libgcc).
  programs.nix-ld.enable = true;
}
