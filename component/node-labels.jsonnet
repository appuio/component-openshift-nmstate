local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local esp = import 'lib/espejote.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift_nmstate;

local sa = kube.ServiceAccount('node-labels-manager') {
  metadata+: {
    namespace: params._namespace,
  },
};

local name = 'appuio:openshift-nmstate:node-labels-manager';
local clusterrole = kube.ClusterRole(name) {
  rules: [
    {
      apiGroups: [ 'nmstate.io' ],
      resources: [ 'nodenetworkstates' ],
      verbs: [ 'get', 'list', 'watch' ],
    },
    {
      apiGroups: [ '' ],
      resources: [ 'nodes' ],
      verbs: [ 'patch', 'update' ],
    },
  ],
};

local clusterrolebinding = kube.ClusterRoleBinding(name) {
  subjects_: [ sa ],
  roleRef_: clusterrole,
};

local managedresource =
  esp.managedResource('nmstate-node-labels', params._namespace) {
    spec+: {
      serviceAccountRef: { name: sa.metadata.name },
      context: [
        {
          name: 'nmstate_nodestates',
          resource: {
            apiVersion: 'nmstate.io/v1beta1',
            kind: 'NodeNetworkState',
          },
        },
      ],
      triggers: [
        {
          name: 'nmstate_nodestate',
          watchContextResource: {
            name: 'nmstate_nodestates',
          },
        },
      ],
      template: importstr 'espejote-templates/node-labels.jsonnet',
    },
  };

if params.dynamicNodeLabels then
  assert
    std.member(inv.applications, 'espejote')
    : 'The dynamic node labels feature requires Espejote to be present on the target cluster';
  {
    '50_node_labels_rbac': [ sa, clusterrole, clusterrolebinding ],
    '50_node_labels_managedresource': managedresource,
  }
else
  {}
