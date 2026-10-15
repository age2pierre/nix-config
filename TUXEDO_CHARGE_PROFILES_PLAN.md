# tuxedo-charge-profiles — dual battery charging strategies (80% capped / 100% full)

## Context

Ask: two recharging strategies on the TUXEDO InfinityBook Pro AMD Gen10 — one capping the charge at 80% (the ±2% stop/resume hysteresis is part of that behavior), one charging to max (the current default), switchable at runtime.

Hardware facts (verified live on this machine, tuxedo-drivers 4.20.1 from `hardware.tuxedo-drivers.enable`, kernel 7.1.12, board `XxKK4NAx_XxSP4NAx`):

- The **only** charge-control interface is the sysfs node
  `/sys/devices/platform/tuxedo_keyboard/charging_profile/charging_profile`
  (driver: EC RAM `0x07a6` bits 4–5, `src/uniwill_keyboard.h` in tuxedo-drivers 4.20.1).
- Exactly **three fixed EC presets**, no custom thresholds, no configurable hysteresis:
  `high_capacity` = 100%, `balanced` = 90%, `stationary` = 80%.
  Node exists, currently reads `high_capacity`; `charging_profiles_available` lists all three.
  BAT0 has no `charge_control_start/end_threshold`; the ±2% hysteresis is EC-firmware-internal and comes with the preset — nothing to (or can be) configured.
- Under a capped profile the EC **rescales the battery gauge**: the OS reports 100% once the cap is reached (documented in the nixpkgs `hardware.tuxedo-drivers` module). Do not "fix" this.
- nixpkgs ships `hardware.tuxedo-drivers.settings.charging-profile`, which generates a udev rule re-applying the profile at **every boot** (device add event of `tuxedo_keyboard`). A `nixos-rebuild switch` does not re-fire it — live switching needs a tiny script.

User decisions (locked): boot default = **80% (`stationary`)**; runtime switching via a script allowed **passwordless sudo scoped to that one script**.

End state: every boot caps charging at 80%; `tuxedo-charge 100` (or `90`) flips the EC preset instantly without a password; the next boot returns to 80%. The 100%-always behavior remains available both at runtime and by changing one nix attr.

## Approach

Three independent edits; one rebuild applies all. The existing fn_lock tmpfiles rule in flake.nix is untouched (not charging-related).

### Step 1 — flake.nix: declare the 80% boot default

In the `tuxedo` host's `extraModules` block (flake.nix:138-150), immediately after `hardware.tuxedo-drivers.enable = true;` (line 143), add:

```nix
          # Cap charging at 80% at every boot via the "stationary" EC preset —
          # the only charge limit this uniwill EC offers (no custom thresholds;
          # stop/resume hysteresis is EC-internal). For runtime overrides use
          # `tuxedo-charge 90|100` (see configuration.nix); the boot rule
          # re-asserts 80% after the next reboot. Note the EC rescales the
          # battery gauge under capped profiles: 100% displayed = cap reached.
          hardware.tuxedo-drivers.settings.charging-profile = "stationary";
```

No new code — this option ships with the nixpkgs tuxedo-drivers NixOS module and emits a udev rule (`90-tuxedo.rules`: `SUBSYSTEM=="platform", DRIVER=="tuxedo_keyboard", ATTR{charging_profile/charging_profile}="stationary"`).

### Step 2 — configuration.nix: `tuxedo-charge` runtime switch script

2a. Convert the file header (configuration.nix:1-6) from:

```nix
{
  pkgs,
  hostname,
  pkgs-stable,
  ...
}: {
```

to:

```nix
{
  pkgs,
  hostname,
  pkgs-stable,
  ...
}: let
  # Runtime switcher for the TUXEDO EC charging profile (boot default is set
  # in flake.nix via hardware.tuxedo-drivers.settings.charging-profile).
  # Writing the sysfs node requires root, so non-root invocations re-exec
  # themselves via sudo at the literal /run/current-system path — that path is
  # exactly what the NOPASSWD sudoers rule below matches, so switching never
  # prompts. writeShellApplication runs the text under `set -euo pipefail`
  # (same as sketchup2017 in home.nix) and shellchecks it at build time.
  tuxedo-charge = pkgs.writeShellApplication {
    name = "tuxedo-charge";
    runtimeInputs = [pkgs.coreutils pkgs.sudo];
    text = ''
      node=/sys/devices/platform/tuxedo_keyboard/charging_profile/charging_profile
      case "''${1:-}" in
        80) profile=stationary ;;
        90) profile=balanced ;;
        100) profile=high_capacity ;;
        "")
          printf 'current charging profile: %s\n' "$(cat "$node")"
          printf 'usage: tuxedo-charge <80|90|100>\n'
          printf 'note: capped profiles rescale the battery gauge (100%% shown = cap reached)\n'
          exit 0
          ;;
        *)
          printf 'error: expected 80, 90 or 100\n' >&2
          printf 'usage: tuxedo-charge <80|90|100>\n' >&2
          exit 1
          ;;
      esac
      if [ "$(id -u)" -ne 0 ]; then
        exec sudo /run/current-system/sw/bin/tuxedo-charge "$1"
      fi
      printf '%s' "$profile" > "$node"
      printf 'charging profile set: %s\n' "$(cat "$node")"
    '';
  };
in {
```

The three literals map 1:1 onto the only three EC presets; any other argument is rejected before any sudo/write, so the NOPASSWD rule below is closed against argument injection. No missing-node handling needed: under `set -e`, a failed `cat`/write aborts with the shell's own error.

2b. Add the package to `environment.systemPackages` (configuration.nix:461-463):

```nix
  environment.systemPackages = [
    tuxedo-charge
    pkgs.clamav
  ];
```

### Step 3 — configuration.nix: scoped passwordless sudo

Insert right after the `users.users.age2pierre` block (ends at line 404), before `# Allow unfree packages`:

```nix
  # Passwordless switching of the EC charging profile, scoped to exactly the
  # tuxedo-charge binary. No args spec in the rule => sudo allows any args;
  # the script itself validates its single argument, so there is no injection
  # surface. Rule lands after the module's wheel-grant (last match wins), so
  # NOPASSWD takes effect for this one command.
  security.sudo.extraRules = [
    {
      users = ["age2pierre"];
      commands = [
        {
          command = "/run/current-system/sw/bin/tuxedo-charge";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];
```

Why the literal path works: this sudo build has no compiled-in `secure_path` (nixpkgs `pkgs/by-name/su/sudo/package.nix` configureFlags — verified) and NixOS's module writes no `Defaults secure_path`, so sudo resolves `tuxedo-charge` from the user's PATH (which contains `/run/current-system/sw/bin`) and string-matches the rule; the script's own re-exec uses the same literal.

## Critical files & anchors

- `flake.nix:138-150` — tuxedo `extraModules` block; insert the `charging-profile` attr after `hardware.tuxedo-drivers.enable = true;` (line 143).
- `configuration.nix:1-6` — module header; becomes `}: let … in {` with the `tuxedo-charge` binding (full code in Step 2a).
- `configuration.nix:461-463` — `environment.systemPackages` gains `tuxedo-charge`.
- `configuration.nix:404` — `security.sudo.extraRules` inserted after the user block.
- Implementer rereads each region before editing; line numbers are hints.

## Verification

Working directory: `~/nixos-config`.

Pre-switch (no root needed):

```
nix eval --raw .#nixosConfigurations.tuxedo.config.hardware.tuxedo-drivers.settings.charging-profile
# → stationary
nix eval --raw .#nixosConfigurations.tuxedo.config.security.sudo.configFile | grep tuxedo-charge
# → the /run/current-system/sw/bin/tuxedo-charge NOPASSWD line
just build
```

`just build` is also the safety proof for the sudoers edit: NixOS runs `visudo -f <file> -c` while building `/etc/sudoers`, and writeShellApplication shellchecks the script — a syntax error fails the build.

Post-switch (new-behavior checks; `NODE=/sys/devices/platform/tuxedo_keyboard/charging_profile/charging_profile`):

```
just switch
cat /etc/udev/rules.d/90-tuxedo.rules          # contains ATTR{charging_profile/charging_profile}="stationary"
sudo grep tuxedo-charge /etc/sudoers            # NOPASSWD line present
tuxedo-charge                                   # exit 0; prints current profile + usage + gauge note; no sudo
tuxedo-charge 80                                # NO password prompt; afterwards: cat $NODE -> stationary
tuxedo-charge 100                               # cat $NODE -> high_capacity
tuxedo-charge 80                                # back to stationary
tuxedo-charge 42; echo $?                       # exit 1, "error: expected 80, 90 or 100" on stderr
```

Reboot check: after reboot, `cat $NODE` → `stationary` (udev coldplug applies the boot rule; the runtime `100` from before the reboot was ephemeral by design).

Physical long-run behavior (informational, hours, not a gate): with `stationary` active and AC connected, charging stops at the 80% cap and the gauge shows 100% there (rescaled).

## Assumptions & contingencies

- Locked with user: 80% boot default; passwordless sudo scoped to `tuxedo-charge`.
- Runtime overrides are ephemeral — the boot rule re-asserts 80%. To make 100% the persistent default, change the attr from Step 1 to `"high_capacity"` (90 → `"balanced"`).
- `tuxedo-charge 90` is included: one extra case arm over the asked-for pair, maps directly to the third EC preset.
- If after reboot `$NODE` still reads `high_capacity`: debug with
  `udevadm test "$(udevadm info -q path /sys/devices/platform/tuxedo_keyboard)"` and the journal. If the udev path proves unreliable on this box, replace Step 1 with a oneshot unit `tuxedo-charge-boot.service` (`wantedBy = ["multi-user.target"]`, `after = ["systemd-udevd.service"]`, `unitConfig.ConditionPathIsWritable = "$NODE"`, `serviceConfig.ExecStart = "${pkgs.bash}/bin/bash -c 'echo stationary > ${NODE}'"`); everything else unchanged.
- If `tuxedo-charge 80` ever prompts for a password (rule not matching), invoke the full path `/run/current-system/sw/bin/tuxedo-charge 80` — the script itself always re-execs that literal, which the rule matches exactly.
- An intermittent `printf: write error: Input/output error` means the EC was busy: the driver's `uw_set_charging_profile` write is single-shot; just re-run the command.