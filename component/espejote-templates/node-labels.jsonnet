local esp = import 'espejote.libsonnet';
local nmstate_nodestates = esp.context().nmstate_nodestates;

local get_default_iface(nodestate) =
  local routes = nodestate.status.currentState.routes.running;
  local defroute = [ r for r in routes if r.destination == '0.0.0.0/0' ];
  assert std.length(defroute) == 1 : 'Expected exactly one default route on node %s' % nodestate.metadata.name;
  defroute[0]['next-hop-interface'];

local label_node_from_nmstate(nodestate) = {
  apiVersion: 'v1',
  kind: 'Node',
  metadata: {
    name: nodestate.metadata.name,
    labels: {
      'nmstate.syn.tools/default-interface-name': get_default_iface(nodestate),
    },
  },
};

local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';

if esp.triggerName() == 'nmstate_nodestate' then (
  local n = esp.triggerData().resource;
  if n != null && !inDelete(n) then
    label_node_from_nmstate(n)
) else [
  label_node_from_nmstate(n)
  for n in nmstate_nodestates if !inDelete(n)
]
