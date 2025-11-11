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
        from: [ {
          podSelector: { matchLabels: { app: 'console', component: 'ui' } },
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'openshift-console' } },
        } ],
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

{
  '00_namespace': namespace,
  '10_operator_group': operator_group,
  '10_subscription': subscription,
  '20_nmstate_instance': instance,
  '30_console_plugin_netpol': console_plugin_netpol,
}
