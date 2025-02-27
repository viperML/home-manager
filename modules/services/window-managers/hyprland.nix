{ config, lib, pkgs, ... }:
let

  cfg = config.wayland.windowManager.hyprland;

  variables = builtins.concatStringsSep " " cfg.systemd.variables;
  extraCommands = builtins.concatStringsSep " "
    (map (f: "&& ${f}") cfg.systemd.extraCommands);
  systemdActivation = ''
    exec-once = ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd ${variables} ${extraCommands}
  '';

in {
  meta.maintainers = [ lib.maintainers.fufexan ];

  # A few option removals and renames to aid those migrating from the upstream
  # module.
  imports = [
    (lib.mkRemovedOptionModule # \
      [ "wayland" "windowManager" "hyprland" "disableAutoreload" ]
      "Autoreloading now always happens")

    (lib.mkRemovedOptionModule # \
      [ "wayland" "windowManager" "hyprland" "recommendedEnvironment" ]
      "Recommended environment variables are now always set")

    (lib.mkRemovedOptionModule # \
      [ "wayland" "windowManager" "hyprland" "xwayland" "hidpi" ]
      "HiDPI patches are deprecated. Refer to https://wiki.hyprland.org/Configuring/XWayland")

    (lib.mkRenamedOptionModule # \
      [ "wayland" "windowManager" "hyprland" "nvidiaPatches" ] # \
      [ "wayland" "windowManager" "hyprland" "enableNvidiaPatches" ])

    (lib.mkRenamedOptionModule # \
      [ "wayland" "windowManager" "hyprland" "systemdIntegration" ] # \
      [ "wayland" "windowManager" "hyprland" "systemd" "enable" ])
  ];

  options.wayland.windowManager.hyprland = {
    enable = lib.mkEnableOption "Hyprland wayland compositor";

    package = lib.mkPackageOption pkgs "hyprland" { };

    finalPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = cfg.package.override {
        enableXWayland = cfg.xwayland.enable;
        enableNvidiaPatches = cfg.enableNvidiaPatches;
      };
      defaultText = lib.literalMD
        "`wayland.windowManager.hyprland.package` with applied configuration";
      description = ''
        The Hyprland package after applying configuration.
      '';
    };

    plugins = lib.mkOption {
      type = with lib.types; listOf (either package path);
      default = [ ];
      description = ''
        List of Hyprland plugins to use. Can either be packages or
        absolute plugin paths.
      '';
    };

    systemd = {
      enable = lib.mkEnableOption null // {
        default = true;
        description = ''
          Whether to enable {file}`hyprland-session.target` on
          hyprland startup. This links to `graphical-session.target`.
          Some important environment variables will be imported to systemd
          and D-Bus user environment before reaching the target, including
          - `DISPLAY`
          - `HYPRLAND_INSTANCE_SIGNATURE`
          - `WAYLAND_DISPLAY`
          - `XDG_CURRENT_DESKTOP`
        '';
      };

      variables = lib.mkOption {
        type = with lib.types; listOf str;
        default = [
          "DISPLAY"
          "HYPRLAND_INSTANCE_SIGNATURE"
          "WAYLAND_DISPLAY"
          "XDG_CURRENT_DESKTOP"
        ];
        example = [ "-all" ];
        description = ''
          Environment variables to be imported in the systemd & D-Bus user
          environment.
        '';
      };

      extraCommands = lib.mkOption {
        type = with lib.types; listOf str;
        default = [
          "systemctl --user stop hyprland-session.target"
          "systemctl --user start hyprland-session.target"
        ];
        description = "Extra commands to be run after D-Bus activation.";
      };
    };

    xwayland.enable = lib.mkEnableOption "XWayland" // { default = true; };

    enableNvidiaPatches =
      lib.mkEnableOption "patching wlroots for better Nvidia support";

    settings = lib.mkOption {
      type = with lib.types;
        let
          valueType = nullOr (oneOf [
            bool
            int
            float
            str
            path
            (attrsOf valueType)
            (listOf valueType)
          ]) // {
            description = "Hyprland configuration value";
          };
        in valueType;
      default = { };
      description = ''
        Hyprland configuration written in Nix. Entries with the same key
        should be written as lists. Variables' and colors' names should be
        quoted. See <https://wiki.hyprland.org> for more examples.

        ::: {.note}
        Use the [](#opt-wayland.windowManager.hyprland.plugins) option to
        declare plugins.
        :::

      '';
      example = lib.literalExpression ''
        {
          decoration = {
            shadow_offset = "0 5";
            "col.shadow" = "rgba(00000099)";
          };

          "$mod" = "SUPER";

          bindm = [
            # mouse movements
            "$mod, mouse:272, movewindow"
            "$mod, mouse:273, resizewindow"
            "$mod ALT, mouse:272, resizewindow"
          ];
        }
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        # window resize
        bind = $mod, S, submap, resize

        submap = resize
        binde = , right, resizeactive, 10 0
        binde = , left, resizeactive, -10 0
        binde = , up, resizeactive, 0 -10
        binde = , down, resizeactive, 0 10
        bind = , escape, submap, reset
        submap = reset
      '';
      description = ''
        Extra configuration lines to add to `~/.config/hypr/hyprland.conf`.
      '';
    };

    sourceFirst = lib.mkEnableOption ''
      putting source entries at the top of the configuration
    '' // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      (lib.hm.assertions.assertPlatform "wayland.windowManager.hyprland" pkgs
        lib.platforms.linux)
    ];

    warnings = let
      inconsistent = (cfg.systemd.enable || cfg.plugins != [ ])
        && cfg.extraConfig == "" && cfg.settings == { };
      warning =
        "You have enabled hyprland.systemd.enable or listed plugins in hyprland.plugins but do not have any configuration in hyprland.settings or hyprland.extraConfig. This is almost certainly a mistake.";
    in lib.optional inconsistent warning;

    home.packages = lib.optional (cfg.package != null) cfg.finalPackage;

    xdg.configFile."hypr/hyprland.conf" = let
      shouldGenerate = cfg.systemd.enable || cfg.extraConfig != ""
        || cfg.settings != { } || cfg.plugins != [ ];

      toHyprconf = with lib;
        attrs: indentLevel:
        let
          indent = concatStrings (replicate indentLevel "  ");

          mkSection = n: attrs: ''
            ${indent}${n} {
            ${toHyprconf attrs (indentLevel + 1)}${indent}}
          '';
          sections = filterAttrs (n: v: isAttrs v) attrs;

          mkFields = generators.toKeyValue {
            listsAsDuplicateKeys = true;
            inherit indent;
          };
          allFields = filterAttrs (n: v: !(isAttrs v)) attrs;
          importantFields = filterAttrs (n: _:
            (hasPrefix "$" n) || (hasPrefix "bezier" n)
            || (cfg.sourceFirst && (hasPrefix "source" n))) allFields;
          fields = builtins.removeAttrs allFields
            (mapAttrsToList (n: _: n) importantFields);
        in mkFields importantFields
        + concatStringsSep "\n" (mapAttrsToList mkSection sections)
        + mkFields fields;

      pluginsToHyprconf = plugins:
        toHyprconf {
          plugin = let
            mkEntry = entry:
              if lib.types.package.check entry then
                "${entry}/lib/lib${entry.pname}.so"
              else
                entry;
          in map mkEntry cfg.plugins;
        } 0;
    in lib.mkIf shouldGenerate {
      text = lib.optionalString cfg.systemd.enable systemdActivation
        + lib.optionalString (cfg.plugins != [ ])
        (pluginsToHyprconf cfg.plugins)
        + lib.optionalString (cfg.settings != { }) (toHyprconf cfg.settings 0)
        + lib.optionalString (cfg.extraConfig != "") cfg.extraConfig;

      onChange = lib.mkIf (cfg.package != null) ''
        ( # Execute in subshell so we don't poision environment with vars
          # This var must be set for hyprctl to function, but the value doesn't matter.
          export HYPRLAND_INSTANCE_SIGNATURE="bogus"
          for i in $(${cfg.finalPackage}/bin/hyprctl instances -j | jq ".[].instance" -r); do
            HYPRLAND_INSTANCE_SIGNATURE=$i ${cfg.finalPackage}/bin/hyprctl reload config-only
          done
        )
      '';
    };

    systemd.user.targets.hyprland-session = lib.mkIf cfg.systemd.enable {
      Unit = {
        Description = "Hyprland compositor session";
        Documentation = [ "man:systemd.special(7)" ];
        BindsTo = [ "graphical-session.target" ];
        Wants = [ "graphical-session-pre.target" ];
        After = [ "graphical-session-pre.target" ];
      };
    };

    systemd.user.targets.tray = {
      Unit = {
        Description = "Home Manager System Tray";
        Requires = [ "graphical-session-pre.target" ];
      };
    };
  };
}
