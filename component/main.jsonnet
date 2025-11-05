local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local operatorlib = import 'lib/openshift4-operators.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift_nmstate;

local namespace =
  kube.Namespace(params._namespace) {
    metadata+: {
      annotations+: {
        // the nmstate-handler daemonset needs to be scheduled on all nodes.
        'openshift.io/node-selector': '',
      },
      labels+: {
        'openshift.io/cluster-monitoring': 'true',
      },
    },
  };

local operator_group = operatorlib.OperatorGroup(params._namespace) {
  metadata+: {
    namespace: params._namespace,
  },
  spec: {
    targetNamespaces: [ params._namespace ],
  },
};

local subscription = operatorlib.namespacedSubscription(
  params._namespace,
  'kubernetes-nmstate-operator',
  params.olm.channel,
  'redhat-operators',
  installPlanApproval=params.olm.installPlanApproval
);

local console_plugin_netpol =
  kube.NetworkPolicy('allow-console-console-nmstate-plugin') {
    spec: {
      ingress: [ {
        from: [
          { podSelector: { matchLabels: { app: 'console', component: 'ui' } } },
          { namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'openshift-console' } } },
        ],
        ports: [ { port: 9443, protocol: 'TCP' } ],
      } ],
      podSelector: {
        matchLabels: {
          app: 'nmstate-console-plugin',
        },
      },
      policyTypes: [ 'Ingress' ],
    },
  };

local instance =
  kube._Object('nmstate.io/v1', 'NMState', 'nmstate') {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
  } + com.makeMergeable(params.config);

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
  '00_namespace': namespace,
  '10_operator_group': operator_group,
  '10_subscription': subscription,
  '20_nmstate_instance': instance,
  '30_console_plugin_netpol': console_plugin_netpol,
  '40_policies': validate(policies + static_routes),
}
