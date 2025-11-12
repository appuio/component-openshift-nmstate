/**
 * \file Library with public methods provided by component openshift-nmstate.
 */

local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

// Helper which generates a empty `NodeNetworkConfigurationPolicy` K8s resource
//
// The provided `name` is used as `metadata.name` and is hyphenated with
// `kube.libjsonnet`'s `hyphenate()` helper.
local NodeNetworkConfigurationPolicy(name) =
  kube._Object('nmstate.io/v1', 'NodeNetworkConfigurationPolicy', kube.hyphenate(name)) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
  };


{
  NodeNetworkConfigurationPolicy: NodeNetworkConfigurationPolicy,
}
