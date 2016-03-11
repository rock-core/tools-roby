---
title: Scheduling Constraints
keywords: roby, robotics, rock, framework, ide
permalink: "/event_relations/scheduling_constraints/"
---

Available as Roby::EventStructure::SchedulingConstraints

See {rdoc_class: EventStructure::SchedulingConstraintsGraphClass::Extension} for the list
of methods that are defined on Roby::EventGenerator and
{rdoc_class: EventStructure::SchedulingConstraintsGraphClass} for the methods accessible on the
relation graph.

Semantics
---------
The scheduling constraint network allows to specify that an event _b_ can be
scheduled only if _a_ can be scheduled, ignoring in this particular case all
temporal constraints on _a_ that are due to _b_.

This is usually used to delay the startup of planning tasks until the actual
task is needed. Let's imagine a simple [planning
pattern](../building/runtime.html#planning-pattern). A common case is to
require the planner to be called only when the task is actually needed. However,
this cannot be specified by temporal constraints as the task itself requires the
planning to be finished to start.

This situation would be encoded by mixing temporal and scheduling constraints:

``` ruby
planned_task.should_start_after planning_task
planning_task.start_event.schedule_as(planned_task.start_event)
```

Error Conditions
----------------
This is used only as hints for scheduling, and therefore does not really specify
hard constraints

Relationship to Scheduling
--------------------------
The scheduling relation has an influence on [the temporal
scheduler](../advanced_concepts/scheduling.html).


