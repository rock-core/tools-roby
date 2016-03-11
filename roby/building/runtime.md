---
title: Runtime Considerations
keywords: roby, robotics, rock, framework, ide
permalink: "/building/runtime/"
---

The Planning Pattern {#planning-pattern}
----------------
Generating plans can be a pretty expensive operation. This is why, in Roby, it
is done __asynchronously__ whenever possible.

Injecting new tasks-that-should-be-planned is a plan is done by actually adding
two tasks:

 * an instance of Roby::Task or of one of its subclasses which is a placeholder
   for the final task
 * a planning task, i.e. a Roby task that is the child of the placeholder in
   the planned_by relation. When using the standard Roby action interface,
   the task used is Roby::Actions::Task.

There is an example of that pattern in action [in the
tutorial](../tutorial/relations_display.html#planning)

When using the action interface, the type declared as being the returned task
type for the action is used as the placeholder. It allows to make it obvious
what the system __intends__ to do.

Failures in the planning methods
--------------------------------
The failures in the planning methods are handled through [the planned_by
relation](../task_relations/planned_by.html)

Accessing other tasks
---------------------
It is common to access related tasks at runtime, to for instance synchronize
with the other task's events.

The only guideline here is: __always__ use the relations to find about these
tasks. This is a very common use case of the :role option in the [depends_on
relation](../task_relations/dependency.html), which allows to use for instance
localization_child to get the child with the localization role. Another common
use-case is to use [the #planned_task and #planning_task
accessors](../task_relations/planned_by.html), or
[#execution_agent](../task_relations/executed_by.html).

However, the only rule here is: __never__ cache the value of these accessors
across execution cycles (e.g. two calls to a poll block). If you want to access
the localization child, then access it using #localization_child.  There are no
guarantee that the localization child at one execution cycle will be the same
at the next, as for instance because of error handling.

Delayed planning and task access
--------------------------------
When one calls another planner, the planning method is called right away. The
returned task is, therefore, an actual plan (i.e. task with children and so
on). However, interfaces with other plan-generation tools (such as
[syskit](http://rock-robotics.org/documentation/system/index.html)) might
decide to always return a planner that will be executed when it is needed.

In this case, you can obviously not access the children of the returned task directly.

__First__, it is not a very good practice: one should only use the toplevel
task as the "interface" to the task's subplan. [The next page](patterns.html)
covers these issues.

__However__, life being what it is, it is sometimes a good solution to access these children
directly. To do this, you must wait for the task to be planned. This can be done in two ways:

 * you wait for the task to be started. If it is started, it is planned !
 * you synchronize on the task's planning task _success_ event

Synchronizing on running tasks
------------------------------
__Never__ assume a relation between a task's running state and its children /
parent unless it is explicitely defined by some constraints. Startup of tasks
is managed by the a scheduler, which can make any decision valid w.r.t.
the constraints encoded in the plan. Roby is very flexible in this respect, so
-- unless you explicitely specify e.g. temporal constraints -- you should not
assume that e.g. a task is running if its parent is. If you need
synchronization, do it explicitely __on the exact task that you want to
synchronize with__.

This can be hard to achieve, though, when combined with delayed planning (see
above). However, the scripting interface do take into account delayed planning,
so it is possible to for instance:

``` ruby
script do
  wait_any localization_child.gps_child.start_event
end
```

At runtime, this will take into account delayed planning. I.e., if the localization
child or the gps child are not present, it will wait for any delayed planning on the
path before generating an error.

