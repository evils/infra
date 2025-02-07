{ config, pkgs, lib, ... }:
let
  localAddressOptions = { ... }: {
    options = {
      local = lib.mkOption {
        type = lib.types.str;
      };
      peer = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };

  wireguardPeerConfig = { name, ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
      };

      babel = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      mtu = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 1420;
      };

      interfaceName = lib.mkOption {
        internal = true;
        type = lib.types.str;
      };
      remoteEndpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      remotePort = lib.mkOption {
        type = lib.types.port;
        default = 11001;
      };
      remotePublicKey = lib.mkOption {
        type = lib.types.str;
      };
      localPort = lib.mkOption {
        type = lib.types.port;
      };
      remoteAddresses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      localAddresses = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf (lib.types.either lib.types.str (lib.types.submodule localAddressOptions)));
        default = null;
        apply = values: if values == null then null else
        (
          map
            (
              value:
              if (builtins.typeOf value) == "string" then {
                local = value;
                peer = null;
              } else value
            )
            values
        );
      };

      pskFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
    config = {
      inherit name;
      interfaceName = "wg-${builtins.substring 0 10 name}";
    };
  };
in
{
  imports = [ ./hosts.nix ];

  options.h4ck.wireguardBackbone = {
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/wireguardBackbone";
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.h4ck.wireguardBackbone.dataDir}/wireguard.key";
    };
    publicKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.h4ck.wireguardBackbone.dataDir}/wireguard.pub";
    };

    addresses = lib.mkOption {
      default = null;
      type = lib.types.nullOr (lib.types.listOf (lib.types.str));
    };

    peers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule wireguardPeerConfig);
      default = { };
    };
  };

  config =
    let
      cfg = config.h4ck.wireguardBackbone;

      check-kernel-config = pkgs.runCommand "check-ipv6-kernel-support"
        {
          inherit (config.boot.kernelPackages.kernel) configfile;
        } ''
        grep -q CONFIG_IPV6=y $configfile && mkdir $out
      '';
    in
    lib.mkIf (cfg.peers != { }) {
      environment.systemPackages = [ pkgs.wireguard check-kernel-config pkgs.tcpdump ];
      systemd.tmpfiles.rules = [
        "d ${config.h4ck.wireguardBackbone.dataDir} 700 systemd-network systemd-network - -"
      ];
      systemd.services."wireguardBackbone-generate-keys" = {
        path = [ pkgs.wireguard ];
        after = [ "systemd-tmpfiles-setup.service" ];
        before = [ "network.target" ];
        partOf = [ "network-pre.target" ];
        wantedBy = [ "multi-user.target" ];
        script = ''
          set -ex
          test -e ${config.h4ck.wireguardBackbone.privateKeyFile} || {
            wg genkey > ${config.h4ck.wireguardBackbone.privateKeyFile}
          }
          test -e ${config.h4ck.wireguardBackbone.publicKeyFile} || {
            wg pubkey < ${config.h4ck.wireguardBackbone.privateKeyFile} > ${config.h4ck.wireguardBackbone.publicKeyFile}
          }
          chmod 600 ${config.h4ck.wireguardBackbone.privateKeyFile}
        '';
        serviceConfig = {
          Type = "oneshot";
          User = "systemd-network";
          RemainAfterExit = true;
        };
      };
      boot.extraModulePackages = if config.boot.kernelPackages.wireguard != null then [ config.boot.kernelPackages.wireguard ] else [ ];
      h4ck.bird = {
        enable = true;
      };
      services.bird2 = {
        enable = lib.mkDefault true;
        config =
          let
            interfaces = lib.mapAttrsToList (_: p: p.interfaceName) cfg.peers;
            babelInterfaces = lib.mapAttrsToList (_: p: p.interfaceName)
              (lib.filterAttrs (_: p: p.babel == true) cfg.peers);
          in
          ''
            #
            # Configuration for all the "internal" wireguard peerings between
            # *MY* machines. This shouldn't be used for external peers as
            # they'd ultimately be trusted for all DN42 prefixes.
            # This propagates all routes learned from babel and all those that
            # fall into the DN42 network range to all neighbours.
            # With sufficient interconnects between all my nodes they should
            # always find a way to talk to each other – even indirectly.
            #
            protocol babel wg_backbone {
              randomize router id yes;
              interface ${lib.concatMapStringsSep ", " (iface: "\"${iface}\"") babelInterfaces} {
                type wired;
              };
              ipv4 {
                table master4;
                export filter {
                  if (source = RTS_BABEL || source = RTS_STATIC || source = RTS_DEVICE || source = RTS_INHERIT) && (net ~ 172.20.0.0/14) then {
                    accept;
                  }
                  reject;
                };
                import filter {
                  if net ~ 172.20.0.0/14 then accept;
                  reject;
                };
              };
              ipv6 {
                table master6;
                export filter {
                  # FIXME: I had to add RTS_INHERIT TO add routes for subnets on wireguard interfaces
                  if (source = RTS_BABEL || source = RTS_STATIC || source = RTS_DEVICE || source = RTS_INHERIT) && (net ~ fd00::/8) then {
                    accept;
                  }
                  reject;
                };
                import filter {
                  if net ~ fd00::/8 then accept;
                  reject;
                };
              };
            };
          '';
      };
      networking.firewall.allowedUDPPorts = [ 6696 ] ++ lib.mapAttrsToList (_: peer: peer.localPort) config.h4ck.wireguardBackbone.peers;
      systemd.network = lib.mkMerge (
        lib.mapAttrsToList
          (
            name: peer:
              {
                enable = lib.mkDefault true;
                netdevs = {
                  "40-${peer.interfaceName}" = {
                    netdevConfig = {
                      Kind = "wireguard";
                      MTUBytes = toString peer.mtu;
                      Name = "${peer.interfaceName}";
                    };
                    extraConfig = ''
                      [WireGuard]
                      PrivateKeyFile = ${toString cfg.privateKeyFile}
                      ListenPort = ${toString peer.localPort}

                      [WireGuardPeer]
                      PublicKey = ${peer.remotePublicKey}
                      AllowedIPs=::/0, 0.0.0.0/0
                      ${lib.optionalString (peer.remoteEndpoint != null) "Endpoint=${peer.remoteEndpoint}:${toString peer.remotePort}"}
                      ${lib.optionalString (peer.pskFile != null) "PresharedKeyFile = ${peer.pskFile}"}
                    '';
                  };
                };

                networks = {
                  "40-${peer.interfaceName}" = {
                    matchConfig = {
                      Name = "${peer.interfaceName}";
                    };
                    networkConfig = {
                      #                  DHCP = false;
                      #                  IPv6AcceptRA = false;
                      LinkLocalAddressing = "ipv6";
                    };
                    addresses =
                      let
                        peerAddresses = map
                          (
                            { local, peer, ... }: {
                              addressConfig = {
                                Address = local;
                              } // (if peer != null then { Peer = peer; } else { });
                            }
                          )
                          peer.localAddresses;
                      in
                      if (peer.localAddresses == null) then
                        map
                          (
                            addr:
                            {
                              addressConfig = {
                                Address = addr;
                              };
                            }
                          )
                          cfg.addresses else peerAddresses;
                    routes = map
                      (
                        addr:
                        { routeConfig = { Destination = addr; }; }
                      )
                      peer.remoteAddresses;
                  };
                };
              }
          )
          config.h4ck.wireguardBackbone.peers
      );
    };
}
