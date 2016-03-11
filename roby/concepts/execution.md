---
title: Execution
keywords: roby, robotics, rock, framework, ide
permalink: "/concepts/execution/"
---

What should have understood by now is the concept of [reactor](reactor.html) and
[plan](plans.html). This page will bind both concepts together to explain how the
plans are interpreted to actually execute _something_.

So, now, we have (1) a plan which represents the tasks and events that exist on
our system and (2) a reactor that is supposed to handle gathering events and
executing code. Let's see how these two get combined.

This page is using the same example than [the previous page](plans.html). Let's
repeat the corresponding plan:

![Simple plan example](simple_plan_example.png)
{: .center}

1: Gathering of External Events
-------------------------------
The first role of a reactor, and Roby is no different in that respect, is that
it should gather events from external sources (other processes, sensors) and
react to these. The first step in each execution cycle is therefore to _gather
these events and emit them_.

External event gatherers are essentially code blocks (routines) that get called
at the beginning of each execution cycle. They have to read whatever "external"
source of information (remote servers, subprocesses, time, ...) and emit the
corresponding events.

In the example above, we could for instance have a routine that reads the
system's battery and emits the battery_low event when that reaches a certain
threshold. Another routine would monitor the system's position and emit the
success event on the corresponding MoveTo task when the destination is reached.

2: Scheduling {#scheduling}
-------------
The scheduler is a source of commands. Essentially, given a plan, its job is to
decide which task can be started, and start them.

The default scheduler, the temporal scheduler, looks for temporal and dependency
relations and bases its decision on that. In our example, when the first MoveTo
is finished, the temporal scheduler will see that the start event of the second
MoveTo can be emitted (the should_emit_after constraint is OK with that) and
therefore calls it, in effect making sure that we have a proper sequence.

3: Event Propagation
------------
Once initial events are gathered (and therefore emitted), corresponding code
blocks called __event handlers__ get called. Identically, the scheduler's
calling of commands causes other blocks, __event commands__ to be called. There
are other constructs in which "user" code blocks can be attached so as to be
called in specific situations during execution, but we won't detail them here.

In both cases, these code blocks can decide to call or emit other events and
therefore have the corresponding code blocks to be called and so on. Moreover,
some event relations define that the relation's target should either be called
or emitted when the parent is emitted, therefore also causing some propagation.

The process of calling these blocks, emitting and calling other events and so on
is called __event propagation__. It is managed in the main reactor loop (i.e.
a command call or an event emission is handled the same way than the external
events). In other words, when an event handler emits another event, this event
is not immediately called: the emission is queued, and processed later in the
main reactor loop.

Overview of the Execution Cycle
-------------------------------
The execution cycle outlined above is executed periodically, with a default
period of 100ms. See below for a graphical representation of the cycle:

![Overview of the Execution Cycle](execution_cycle.png)

Conclusion
----------
What you saw until now is: how things are represented and how code gets
executed. There are actually two pieces missing in the overall puzzle.

The first piece, which is the subject of the next page, is the management of
tasks that are needed by the system and the ones that are not required anymore.
In other words: garbage collection at the plan level.

The second piece, that you will see later, is error representation and handling.

