{
  description = "Lollypops - Lollypop Operations Deployment Tool";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, ... }@inputs:
    with inputs;
    {
      nixosModules.lollypops = import ./module.nix;
      nixosModule = self.nixosModules.lollypops;
    } //

    # TODO test/add other plattforms
    (flake-utils.lib.eachSystem [ "aarch64-linux" "i686-linux" "x86_64-linux" ])
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          # Allow custom packages to be run using `nix run`
          apps =
            let
              mkSeclist = config: pkgs.lib.lists.flatten (map
                (x: [
                  "echo 'Deploying ${x.name} to ${x.path}'"
                  # Remove if already
                  ''
                    ssh {{.REMOTE_USER}}@{{.REMOTE_HOST}} "rm -f ${x.path}"
                  ''
                  # Copy file
                  ''
                    ${x.cmd} | ssh {{.REMOTE_USER}}@{{.REMOET_HOST}} "umask 077; cat > ${x.path}"
                  ''
                  # Set group and owner
                  ''
                    ssh {{.REMOTE_USER}}@{{.REMOET_HOST}} "chown ${x.owner}:${x.group-name} ${x.path}"
                  ''
                ])
                (builtins.attrValues config.lollypops.secrets.files));

            in
            {

              default = { configFlake, nixosConfigurations, ... }:
                let

                  mkTaskFileForHost = hostName: hostConfig: pkgs.writeText "CommonTasks.yml"
                    (builtins.toJSON {
                      version = "3";
                      output = "prefixed";

                      vars = with hostConfig.config.lollypops; {
                        REMOTE_USER = deployment.user;
                        REMOTE_HOST = deployment.host;
                        REMOTE_CONFIG_DIR = deployment.config-dir;
                        LOCAL_FLAKE_SOURCE = configFlake;
                        HOSTNAME = hostName;
                      };

                      tasks = {

                        check-vars.preconditions = [{
                          sh = ''[ ! -z "{{.HOSTNAME}}" ]'';
                          msg = "HOSTNAME not set: {{.HOSTNAME}}";
                        }];

                        deploy-secrets = {
                          deps = [ "check-vars" ];

                          # TODO hide secrets deployment
                          # silent = true;

                          cmds = [
                            ''echo "Deploying secrets to: {{.HOSTNAME}} (not impletmented yet)!"''
                          ] ++ mkSeclist hostConfig.config;

                        };

                        rebuild = {
                          dir = self;
                          deps = [ "check-vars" ];
                          cmds = [
                            ''echo "Rebuilding: {{.HOSTNAME}}!"''
                            # For dry-running use `nixos-rebuild dry-activate`
                            ''
                              nixos-rebuild dry-activate \
                              --flake '{{.REMOTE_CONFIG_DIR}}#{{.HOSTNAME}}' \
                              --target-host {{.REMOTE_USER}}@{{.REMOTE_HOST}} \
                              --build-host root@{{.REMOTE_HOST}}
                            ''
                          ];
                        };

                        deploy-flake = {

                          deps = [ "check-vars" ];
                          cmds = [
                            ''echo "Deploying flake to: {{.HOSTNAME}}"''
                            ''
                              source_path={{.LOCAL_FLAKE_SOURCE}}
                              if test -d "$source_path"; then
                                source_path=$source_path/
                              fi
                              ${pkgs.rsync}/bin/rsync \
                              --verbose \
                              -e ssh\ -l\ root\ -T \
                              -FD \
                              --times \
                              --perms \
                              --recursive \
                              --links \
                              --delete-excluded \
                              $source_path {{.REMOTE_USER}}\@{{.REMOTE_HOST}}:{{.REMOTE_CONFIG_DIR}}
                            ''
                          ];
                        };
                      };
                    });

                  # Taskfile passed to go-task
                  taskfile = pkgs.writeText
                    "Taskfile.yml"
                    (builtins.toJSON {
                      version = "3";
                      output = "prefixed";

                      # Import the taks once for each host, setting the HOST
                      # variable. This allows running them as `host:task` for
                      # each host individually.
                      includes = builtins.mapAttrs
                        (name: value:
                          {
                            taskfile = mkTaskFileForHost name value;
                          })
                        nixosConfigurations;

                      # Define grouped tasks to run all tasks for one host.
                      # E.g. to make a complete deployment for host "server01":
                      # `nix run '.' -- server01
                      tasks = builtins.mapAttrs
                        (name: value:
                          {
                            cmds = [
                              # TODO make these configurable, set these three as default in the module
                              { task = "${name}:deploy-flake"; }
                              { task = "${name}:deploy-secrets"; }
                              { task = "${name}:rebuild"; }
                            ];
                          })
                        nixosConfigurations;
                    });
                in
                flake-utils.lib.mkApp
                  {
                    drv = pkgs.writeShellScriptBin "go-task-runner" ''
                      ${pkgs.go-task}/bin/task -t ${taskfile} "$@"
                    '';
                  };
            };

        });
}
