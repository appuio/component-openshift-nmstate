local esp = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift_nmstate;

local fixername = 'nmstate-handler-scheduling-fixer';

local sa = kube.ServiceAccount(fixername) {
  metadata+: {
    namespace: params._namespace,
  },
};

local role = kube.Role(fixername) {
  rules: [
    {
      apiGroups: [ '' ],
      resources: [ 'pods' ],
      verbs: [ 'get', 'list', 'watch', 'delete' ],
    },
  ],
};

local rolebinding = kube.RoleBinding(fixername) {
  subjects_: [ sa ],
  roleRef_: role,
};

local mr = esp.managedResource(fixername, params._namespace) {
  spec+: {
    serviceAccountRef: { name: sa.metadata.name },
    context: [
      {
        name: 'handler_pods',
        resource: {
          apiVersion: 'v1',
          kind: 'Pod',
          labelSelector: {
            matchLabels: {
              app: 'kubernetes-nmstate',
              component: 'kubernetes-nmstate-handler',
            },
          },
        },
      },
    ],
    triggers: [
      {
        name: 'handler_pod',
        watchContextResource: {
          name: 'handler_pods',
        },
      },
    ],
    template: importstr 'espejote-templates/scheduling-fixer.jsonnet',
  },
};

if params.schedulingFix then {
  '99_scheduling_fix_managed_resource': [ mr, sa, role, rolebinding ],
} else {}
