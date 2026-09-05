# Home Manager module for CLIProxyAPI
flake:

{ config, lib, pkgs, ... }:

let
  cfg = config.services.cliproxyapi;
in
{
  options.services.cliproxyapi = {
    enable = lib.mkEnableOption "CLIProxyAPI service";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${pkgs.system}.cliproxyapi;
      defaultText = lib.literalExpression "flake.packages.\${pkgs.system}.cliproxyapi";
      description = "The CLIProxyAPI package to use. Available editions: cliproxyapi (base), cliproxyapi-business.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8317;
      description = "Port for CLIProxyAPI to listen on.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "${config.xdg.dataHome}/cliproxyapi";
      defaultText = lib.literalExpression ''"''${config.xdg.dataHome}/cliproxyapi"'';
      description = "Directory for CLIProxyAPI data (config.yaml, auth tokens).";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a config.yaml file to use. If null, an example config will be
        copied to the data directory on first run for you to customize.

        Note: CLIProxyAPI configuration is complex and varies by use case.
        It's recommended to either:
        - Use the Web UI or Desktop GUI to configure
        - Manually edit the config.yaml file
        - Use remote storage (Git, PostgreSQL, S3) for config management
      '';
    };

    settings = lib.mkOption {
      type = (pkgs.formats.yaml { }).type;
      default = { };
      description = ''
        Declarative configuration for CLIProxyAPI. Will be written to config.yaml.
        If set, this overrides any existing config.yaml in the data directory.
      '';
    };

    lib.cliproxyapi = {
      injectSecret = lib.mkOption {
        type = lib.types.unspecified;
        readOnly = true;
        description = "Helper function to securely inject file-based secrets into the settings.";
      };
    };

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of plugins to install (must exist in plugins.json)";
    };

    storage = {
      type = lib.mkOption {
        type = lib.types.enum [ "local" "git" "postgres" "s3" ];
        default = "local";
        description = ''
          Storage backend for configuration and authentication data.
          - local: Store locally in dataDir (default)
          - git: Sync with a Git repository
          - postgres: Store in PostgreSQL database
          - s3: Store in S3-compatible object storage
        '';
      };

      git = {
        url = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "HTTPS URL of the Git repository for storage.";
        };

        username = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Username for Git authentication.";
        };

        tokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "File containing the Git personal access token.";
        };
      };

      postgres = {
        dsnFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            File containing the PostgreSQL connection string.
            Format: postgresql://user:pass@host:5432/db
          '';
        };

        schema = lib.mkOption {
          type = lib.types.str;
          default = "public";
          description = "PostgreSQL schema to use.";
        };
      };

      s3 = {
        endpoint = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "S3-compatible endpoint URL.";
        };

        bucket = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "S3 bucket name.";
        };

        accessKeyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "File containing the S3 access key.";
        };

        secretKeyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "File containing the S3 secret key.";
        };
      };
    };

    managementPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing the password for the management web UI.
        Required when using remote storage backends.
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables to pass to CLIProxyAPI.";
    };
  };

  config = lib.mkIf cfg.enable {
    lib.cliproxyapi.injectSecret = path: "@@SECRET:${toString path}@@";

    assertions = [
      {
        assertion = cfg.storage.type != "git" || cfg.storage.git.url != null;
        message = "services.cliproxyapi.storage.git.url must be set when using git storage.";
      }
      {
        assertion = cfg.storage.type != "postgres" || cfg.storage.postgres.dsnFile != null;
        message = "services.cliproxyapi.storage.postgres.dsnFile must be set when using postgres storage.";
      }
      {
        assertion = cfg.storage.type != "s3" || (cfg.storage.s3.endpoint != null && cfg.storage.s3.bucket != null);
        message = "services.cliproxyapi.storage.s3.endpoint and bucket must be set when using s3 storage.";
      }
      {
        assertion = cfg.storage.type == "local" || cfg.managementPasswordFile != null;
        message = "services.cliproxyapi.managementPasswordFile is required when using remote storage.";
      }
    ];

    home.packages = [
      (pkgs.writeShellScriptBin "cliproxyapi" ''
        cd ${cfg.dataDir} || exit 1
        exec ${lib.getExe cfg.package} "$@"
      '')
    ];

    systemd.user.services.cliproxyapi = {
      Unit = {
        Description = "CLIProxyAPI - AI CLI Proxy Service";
        After = [ "network.target" ];
      };

      Install = {
        WantedBy = [ "default.target" ];
      };

      Service = let
        pluginData = lib.importJSON ../plugins.json;
        pluginEnv = pkgs.symlinkJoin {
          name = "cliproxyapi-plugins";
          paths = map (name: 
            let
              data = pluginData.${name} or (throw "Plugin ''${name} not found in plugins.json");
              src = if data.format == "zip" then
                pkgs.fetchzip {
                  url = data.url;
                  hash = data.hash;
                  stripRoot = false;
                }
              else
                pkgs.fetchurl {
                  url = data.url;
                  hash = data.hash;
                };
            in
            if data.format == "zip" then
              pkgs.runCommand "${name}-plugin" {} ''
                mkdir -p $out/plugins/linux/amd64
                cp ${src}/*.so $out/plugins/linux/amd64/
              ''
            else
              pkgs.runCommand "${name}-plugin" {} ''
                mkdir -p $out/plugins/linux/amd64
                cp ${src} $out/plugins/linux/amd64/${name}.so
              ''
          ) cfg.plugins;
        };

        storageEnv = {
          "local" = { };
          "git" = {
            GITSTORE_GIT_URL = cfg.storage.git.url;
            GITSTORE_LOCAL_PATH = cfg.dataDir;
          } // lib.optionalAttrs (cfg.storage.git.username != null) {
            GITSTORE_GIT_USERNAME = cfg.storage.git.username;
          };
          "postgres" = {
            PGSTORE_LOCAL_PATH = cfg.dataDir;
            PGSTORE_SCHEMA = cfg.storage.postgres.schema;
          };
          "s3" = {
            OBJECTSTORE_ENDPOINT = cfg.storage.s3.endpoint;
            OBJECTSTORE_BUCKET = cfg.storage.s3.bucket;
            OBJECTSTORE_LOCAL_PATH = cfg.dataDir;
          };
        }.${cfg.storage.type};

        preStartScript = pkgs.writeShellScript "cliproxyapi-prestart" ''
          mkdir -p ${cfg.dataDir}
          mkdir -p ${cfg.dataDir}/tmp

          if [ -f ${cfg.package}/share/cliproxyapi/config.example.yaml ]; then
            cp -f ${cfg.package}/share/cliproxyapi/config.example.yaml ${cfg.dataDir}/config.example.yaml
            chmod 600 ${cfg.dataDir}/config.example.yaml
          fi

          ${if cfg.settings != { } then ''
            cp -f ${(pkgs.formats.yaml { }).generate "cliproxyapi-config.yaml" cfg.settings} ${cfg.dataDir}/config.yaml
            chmod 600 ${cfg.dataDir}/config.yaml
          '' else if cfg.configFile != null then ''
            cp -f ${cfg.configFile} ${cfg.dataDir}/config.yaml
            chmod 600 ${cfg.dataDir}/config.yaml
          '' else ''
            if [ ! -f ${cfg.dataDir}/config.yaml ] && [ "${cfg.storage.type}" = "local" ]; then
              if [ -f ${cfg.package}/share/cliproxyapi/config.example.yaml ]; then
                cp ${cfg.package}/share/cliproxyapi/config.example.yaml ${cfg.dataDir}/config.yaml
                chmod 600 ${cfg.dataDir}/config.yaml
              fi
            fi
          ''}

          if [ -f ${cfg.dataDir}/config.yaml ]; then
            grep -oE '@@SECRET:[^@]+@@' ${cfg.dataDir}/config.yaml | sort -u | while read -r match; do
              secret_path="''${match#@@SECRET:}"
              secret_path="''${secret_path%@@}"
              if [ -f "$secret_path" ]; then
                secret_val=$(cat "$secret_path")
                sed -i "s|$match|$secret_val|g" ${cfg.dataDir}/config.yaml
              fi
            done
          fi

          ${lib.optionalString (cfg.plugins != []) ''
            rm -rf "${cfg.dataDir}/plugins"
            mkdir -p "${cfg.dataDir}/plugins/linux/amd64"
            cp -L ${pluginEnv}/plugins/linux/amd64/* "${cfg.dataDir}/plugins/linux/amd64/"
            chmod 755 "${cfg.dataDir}/plugins/linux/amd64"/*.so
          ''}
        '';

        execScript = pkgs.writeShellScript "cliproxyapi-exec" ''
          cd ${cfg.dataDir} || exit 1

          ${lib.optionalString (cfg.managementPasswordFile != null) ''
            export MANAGEMENT_PASSWORD="$(cat ${cfg.managementPasswordFile})"
          ''}
          ${lib.optionalString (cfg.storage.type == "git" && cfg.storage.git.tokenFile != null) ''
            export GITSTORE_GIT_TOKEN="$(cat ${cfg.storage.git.tokenFile})"
          ''}
          ${lib.optionalString (cfg.storage.type == "postgres" && cfg.storage.postgres.dsnFile != null) ''
            export PGSTORE_DSN="$(cat ${cfg.storage.postgres.dsnFile})"
          ''}
          ${lib.optionalString (cfg.storage.type == "s3" && cfg.storage.s3.accessKeyFile != null) ''
            export OBJECTSTORE_ACCESS_KEY="$(cat ${cfg.storage.s3.accessKeyFile})"
          ''}
          ${lib.optionalString (cfg.storage.type == "s3" && cfg.storage.s3.secretKeyFile != null) ''
            export OBJECTSTORE_SECRET_KEY="$(cat ${cfg.storage.s3.secretKeyFile})"
          ''}
          
          exec ${lib.getExe cfg.package}
        '';
      in {
        Type = "simple";
        ExecStartPre = "${preStartScript}";
        ExecStart = "${execScript}";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = lib.mapAttrsToList (k: v: "${k}=${toString v}") ({ TMPDIR = "${cfg.dataDir}/tmp"; } // storageEnv // cfg.extraEnvironment);

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.dataDir ];
      };
    };
  };
}
