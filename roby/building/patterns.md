---
title: Patterns and Protocols
keywords: roby, robotics, rock, framework, ide
permalink: "/building/patterns/"
---

The art of building code in Roby is the art of putting __plan patterns and
protocols__ in tasks, and creating plans that conform to these patterns and
protocols in the planning methods. This page lists a few guidelines on how that
can be achieved

Keep Isolation
--------------
Moreover, a good guideline when building plans is to avoid having a given task
access other tasks that are at a distance of more than 1 in any given relation.
I.e. a task should only access other tasks that are in its direct neighborhood.

The most useful tool to achieve this is the forwarding relation: it allows to
"forward" an event between tasks, making the child event an equivalent of the
parent event. This is often used to declare that a high-level event is the
equivalent of a child event.

![Example of using forwarding to create high-level events from low-level
ones](patterns_forwarding.png)
{: .align-center}

__Using forwarding to create high-level events from low-level ones__. This
allows the rest of the plan to only synchronize on the high-level "leak_found"
event instead of explicitely looking at the children. If the PipelineRepair is
implemented in a different way, the rest of the behaviour will stay unchanged.
{: .figurecaption}

This pattern is commonly used to forward failure and/or success up in the
dependency hierarchy: the success event of one child task is forwarded to the
success event of the parent task(s).

Don't put too much assumptions in
---------------------------------
Ideally, when writing tasks, one should seek to write it in a way that has as
as little assumptions as possible about the tasks that are around it. It can
obviously require some functionalities / interfaces from them. But it should
not assume, say, that "localization_child is a task of type X".

The trick to achieve this is to use events as much as possible as an interface
to other tasks. The general guidelines here are:

 * use events for synchronization
 * use attributes for data transfer

Embed protocols in task code, embed plan building in actions
------------------------------------------------------------
What tasks do with each other form __protocols__. I.e., any given task assumes
that other task will emit events A, B, C and have attributes filled in with data
when e.g. these events are emitted.

However, to be reusable, a task should not __by itself__ build the plan, i.e.
add the relevant tasks. This should be left to actions.

Embedding placeholders in the plan {#abstract-tasks}
----------------------------------
If, at any point in execution, one wants to represent that a task __will__ be
there and executed, but without explaining __how__, it is possible, in Roby, to
add a task that will act as a placeholder.

This is simply done by adding an instance of the right task model and marking it
as abstract:

``` ruby
task = MoveTo.new
task.abstract = true
root.depends_on(task)
```

Moreover, if a certain task model is used as a base for other models, but
without being executable, the model itself can be marked as abstract:

``` ruby
class AbstractMoveModel < Roby::Task
  abstract
end
```

__Note__ This is different from having an abstract class, as one can define one
in C++ or Java. Here, it is possible to create instances of AbstractMoveModel
and add the task instance in the plan. What is impossible is to execute this
task
{: .warning}
