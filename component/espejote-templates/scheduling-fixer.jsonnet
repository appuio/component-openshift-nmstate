local esp = import 'espejote.libsonnet';

// check if the object is getting deleted by checking if it has
// `metadata.deletionTimestamp`.
local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';


// check pod conditions for
// type=PodScheduled
// status="False"
// reason=Unschedulable
local isUnschedulable(pod) =
  local podStatus = std.get(pod, 'status', {});
  local conds = std.get(podStatus, 'conditions', []);
  local phase = std.get(podStatus, 'phase', '');
  local condScheduled = std.filter(function(c) c.type == 'PodScheduled', conds);

  phase == 'Pending' &&
  std.length(condScheduled) > 0 &&
  condScheduled[0].status == 'False' &&
  condScheduled[0].reason == 'Unschedulable';

local deleteIfUnschedulable(pod) =
  local nodeSel = pod.spec.nodeSelector;
  if isUnschedulable(pod) then
    esp.markForDelete(pod);

if esp.triggerName() == 'handler_pod' then (
  local podT = esp.triggerData();
  if podT != null && std.get(podT, 'resource') != null && !inDelete(podT.resource) then
    deleteIfUnschedulable(podT.resource)
) else
  // full reconcile
  [
    deleteIfUnschedulable(pod)
    for pod in esp.context().handler_pods
    if !inDelete(pod)
  ]
