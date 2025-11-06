local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift_nmstate;

local NodeNetworkConfigurationPolicy(name) =
  kube._Object('nmstate.io/v1', 'NodeNetworkConfigurationPolicy', name) {
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
  NodeNetworkConfigurationPolicy(name) {
    spec: {
      nodeSelector: cfg.nodeSelector,
      desiredState: {
        routes: {
          config: [
            cfg.config {
              destination: d,
            }
            for d in add_destinations
          ] + [
            cfg.config {
              destination: d,
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
  '90_policies': validate(policies + static_routes),
}
