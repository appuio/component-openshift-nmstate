local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local ipcalc = import 'lib/cilium-ipcalc.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift_nmstate;

local NodeNetworkConfigurationPolicy(name) =
  kube._Object('nmstate.io/v1', 'NodeNetworkConfigurationPolicy', kube.hyphenate(name)) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
  };

local policies = com.generateResources(params.policies, NodeNetworkConfigurationPolicy);

local static_routes = [
  local cfg = params.staticRoutes[name];
  // convert to set to remove duplicates
  local destinations = std.set(cfg.destinations);
  local add_destinations = [ d for d in destinations if !std.startsWith(d, '~') ];
  // use d[1:] for rem destinations since they're prefixed with ~
  local rem_destinations = [ d[1:] for d in cfg.destinations if std.startsWith(d, '~') ];
  local route_for_dest(d) = {
    metric: 100,
  } + com.makeMergeable(cfg.config) {
    destination: d,
  };
  NodeNetworkConfigurationPolicy(name) {
    spec: {
      nodeSelector: cfg.nodeSelector,
      desiredState: {
        routes: {
          config: [
            route_for_dest(d)
            for d in add_destinations
          ] + [
            route_for_dest(d) {
              state: 'absent',
            }
            for d in rem_destinations
          ],
        },
      },
    },
  }
  for name in std.objectFields(params.staticRoutes)
  if params.staticRoutes[name] != null
];

local egress_ip_ranges =
  local generateInterfaces(name, cfg, node=null) =
    local cidr_range =
      if node != null then
        ipcalc.parse_cidr(name, cfg.shadowCIDRs[node])
      else
        ipcalc.parse_cidr(name, cfg.egressCIDR);
    local iface = {
      type: 'dummy',
      ipv4: {
        dhcp: false,
        enabled: true,
        address: [],
      },
    } + com.makeMergeable(std.get(cfg, 'ifConfig', {}));
    local addressEntry(idx) = {
      ip: ipcalc.format_ipval(ipcalc.ipval(cidr_range.network_address) + idx),
      'prefix-length': cidr_range.prefix_length,
    };
    // std.range() doesn't like big integers, so we do `[0, count)` instead of
    // `[start,end)`.
    // We go from 0 to count-1 because CIDR last IP is non-inclusive and
    // std.range() is inclusive for start and end. We start at 1 if
    // `skipFirst=true` to omit the network address. We only go to `count-2`
    // if `skipLast=true` to omit the broadcast address.
    local skipFirst = if std.get(cfg, 'skipFirst', false) then 1 else 0;
    local skipLast = if std.get(cfg, 'skipLast', false) then 1 else 0;
    local idx_range = std.range(skipFirst, cidr_range.count - skipLast);

    local ifkey = std.setDiff(
      [ 'interface_name', 'interface_prefix' ],
      std.set(std.objectFields(cfg))
    );
    if std.length(ifkey) != 1 then
      error
        'egressIPRange entries are expected to have exactly one of ' +
        '`interface_name` and `interface_prefix`. entry "%s" has %s.' % [
          name,
          if std.length(ifkey) == 2 then 'neither'
          else if std.length(ifkey) == 0 then 'both'
          else 'a weird configuration',
        ]
    else if std.objectHas(cfg, 'interface_name') then
      // generate a single interface and attach all IPs in `cfg.egressCIDR`
      // when field `interface_name` is set.
      if std.length(cfg.interface_name) > 15 then
        error 'Interface name for "%s" is longer than 15 characters: %s' % [
          name,
          cfg.interface_name,
        ]
      else
        [
          iface {
            name: cfg.interface_name,
            ipv4+: {
              address: [
                addressEntry(idx)
                for idx in idx_range
              ],
            },
          },
        ]
    else
      // generate one interface for each IP in `cfg.egressCIDR`.
      [
        local ifname = '%s_%d' % [ cfg.interface_prefix, idx - skipFirst ];
        if std.length(ifname) > 15 then
          error 'Interface name for "%s" is longer than 15 characters: %s' % [ name, ifname ]
        else
          iface {
            name: ifname,
            ipv4+: {
              address: [ addressEntry(idx) ],
            },
          }
        for idx in idx_range
      ];

  local generatePolicy(name) =
    local cfg = params.egressIPRanges[name];
    local selkey = std.setDiff(
      [ 'nodeSelector', 'shadowCIDRs' ],
      std.set(std.objectFields(cfg))
    );
    if std.length(selkey) != 1 then
      error
        'egressIPRange entries are expected to have exactly one of ' +
        '`nodeSelector` and `shadowCIDRs`. entry "%s" has %s.' % [
          name,
          if std.length(selkey) == 2 then 'neither'
          else if std.length(selkey) == 0 then 'both'
          else 'a weird configuration',
        ]
    else if std.objectHas(cfg, 'shadowCIDRs') then
      // Generate separate policies for each node listed in shadowCIDRs.
      local ecidr = ipcalc.parse_cidr(name, cfg.egressCIDR);
      [
        local pname = '%s-%s' % [ name, node ];
        local scidr = ipcalc.parse_cidr(pname, cfg.shadowCIDRs[node]);
        if scidr.count != ecidr.count then
          error
            "Shadow CIDR size in '%s' for '%s' doesn't match egress CIDR size. " % [ name, node ]
            + 'Egress CIDR: %s (length %d), Shadow CIDR: %s (length %d)' % [
              cfg.egressCIDR,
              ecidr.count,
              cfg.shadowCIDRs[node],
              scidr.count,
            ]
        else
          NodeNetworkConfigurationPolicy(pname) {
            spec: {
              nodeSelector: {
                'kubernetes.io/hostname': node,
              },
              desiredState: generateInterfaces(name, cfg, node=node),
            },
          }
        for node in std.objectFields(cfg.shadowCIDRs)
      ]
    else
      // Generate a shared policy for all nodes matching the provided node
      // selector.
      [
        NodeNetworkConfigurationPolicy(name) {
          spec: {
            nodeSelector: cfg.nodeSelector,
            desiredState: {
              interfaces: generateInterfaces(name, cfg),
            },
          },
        },
      ];

  std.flattenArrays([
    generatePolicy(name)
    for name in std.objectFields(params.egressIPRanges)
    if params.egressIPRanges[name] != null
  ]);

local validate(policies) = std.objectValues(std.foldl(
  function(seen, p)
    local name =
      p.metadata.name;
    if std.objectHas(seen, name) then
      error 'duplicated policy name "%s" in parameters `policies` and `staticRoutes`' % [
        name,
      ]
    else
      seen {
        [name]: p,
      },
  policies,
  {}
));

{
  '90_policies': validate(policies + static_routes + egress_ip_ranges),
}
