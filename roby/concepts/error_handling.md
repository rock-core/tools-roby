---
title: Error Handling
keywords: roby, robotics, rock, framework, ide
permalink: "/concepts/error_handling/"
---

Error representation and handling is a very important aspect of Roby. It is
tightly integrated and -- by default -- is meant to let __nothing pass__.
Obviously, the "handling" part being there, and pretty powerful to allow errors
to pass unnoticed ... by the external observer (a.k.a., safely).

This page will outline the general principles of error handling in Roby. 

Errors in Roby
--------------
There is mostly three sources of errors in Roby:

 1. constraint violations in the plan. Each relation allows to define
    constraints on what is acceptable and what is not. These constraints are
    checked at the end of each execution cycles, and corresponding errors are
    generated.
 2. code errors (i.e. Ruby exceptions) raised by the code blocks that are
    part of the Roby application (event commands, event handlers, ...)
 3. code errors (i.e. Ruby exceptions) raised by the framework itself

The last case is a pretty hard one. The error is registered as a framework
error and, as we will see, not much can be done. In effect, the Roby application
will shutdown, trying to stop as much things as possible in the process.

In the first two cases, Roby will create a __localized error__. I.e., an error
is created and registered, and assigned to a _Roby plan object_. This plan
object is considered to be the source of the error. Which object is associated
with the error will be described in the documentation for each error that gets
generated. These types of errors will not cause the Roby application to stop, as
they are an integral part of the framework's error handling mechanisms.
There are actuall two: events and exceptions.

What is an error is a relative concept
--------------------------------------
The concept of expressing constraints through relations means that what can be
an error for a given relation is not for another. For instance, the dependency
relation can specify in one case that the failure event is an error, while in
another case it might be an expected outcome of the task (it sounds weird, but
it is possible as long as the emission of the failure event does not change
the overall system's ability to reach its goal).

Ruby exceptions in tasks
------------------------
Whenever an exception is raised from within a "user" code block that is
associated with a task (i.e. an event command, event handler, ...), this
exception is isolated from the rest of the framework by Roby. It then causes the
emission of an internal_error event on the task. This emission causes the task
to be stopped if the error was not within the task's own stopping mechanism. If
the error **was** within the task's own stopping mechanism, then it is
quarantined...

Quarantined tasks are tasks that failed to be stopped. Roby puts then
"on the side" and removes all relations from them. These tasks are a bit of a
stingy thing, as they are still running and could therefore cause problems.
However, it is up to the system designer to decide how to handle them, as there
are no generic ways to handle the problem.

Localized errors
----------
Exceptions are generated either by code errors in free events, or by constraint
violations from the relations (since core errors in tasks are expressed through
the task's event mechanism).

As stated before, localized errors are all assigned a source. This source can be
an event or a task. They are handled by looking for __exception handlers__
across the task hierarchy. This propagation involves the
[dependency](../task_relations/dependency.html) and
[planned_by](../task_relations/planned_by.html) relations. The lookup goes up in the
dependency relation and looks for each task it finds for (1) a handler in the
task itself or (2) a handler in the planning task of that task (i.e. in the
child in the planned_by relation).

The diagram below, for instance, shows in which order the exception handlers
are looked for when the dependency relation between the task in red and its
parent generates a dependency constraint violation. The black arrows between
tasks are dependencies, the green arrow planned_by relations.

![Lookup order for exception handler](exception_propagation.png)

Handling constraint errors "on the spot"
----------------------------------------
Since constraint violations are checked at the end of the execution cycle, no
error is going to be generated if a constraint is violated but **in the same
cycle** the plan is changed to repair that fault. This is actually a very
important error handling mechanism is Roby: modifying the plan "on the spot" to
avoid errors. For instance, this is why restarting a process that crashed with
a segmentation fault works, since the "old" faulty plan (where the process
crashed) is, in the same cycle, replaced by a "new" repaired plan.

Conclusion
----------
Well, that's almost all ...

There is one thing left to talk about: default policies, and how to override
them. That's the subject of the [next page](policy.html)

