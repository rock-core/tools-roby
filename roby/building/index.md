---
title: Building a Roby app
keywords: roby, robotics, rock, framework, ide
permalink: "/building/index/"
---

This section will deal with the issue of how to create global behaviour(s) by
__coordinating__ single-purpose units using Roby.

This behaviour-building is done at two levels when using Roby:

 * at the _local_ level by creating interfaces, where high-level behaviours --
   built using smaller pieces -- are "hidden" behind high-level tasks.
 * at the _global_ level by coordinating behaviours, as for instance by
   switching between them.

For instance, a move-to-goal behaviour could be represented by a simple MoveTo
task that gets an argument (the target), read the position information while
executing the task and emit an event (reached_target) when the goal is reached.
Additionally, one would model that the reached_target event also means that the
task is successful.

However, having an actual robot realize this behaviour is a bit more
complicated. One would for instance want to run a planner first to plan the path
to the goal, then execute it. While executing it, one would also like to monitor
localization and abort if it gets too bad.

In Roby, the local interface-building code is done at the level of models by
defining events and arguments to Roby tasks, and at runtime by adding actual
code to tasks. There are various places where the code can be hooked. The main
goal of this code is to make sure that events are emitted whenever _what they
represent_ happened. Sometimes, achieving this is as easy as regularly executing
code blocks that check for conditions and emit events accordingly. Sometimes, it
requires more advanced concepts such as for instance a state machine.

The global-coordination code is created __outside__ the tasks. Roby allows you
to define __actions__, whose job it to bind tasks together to form more complex
behaviours. These actions also form the "public" interface for your robot: you
can start / stop them and track their progress remotely using the Roby shell. It
is also the basis for generic error recovery.

This section will first detail the programming interfaces for these two aspects.
Then, a few pages will try to explain the role that they all have to play into a
Roby controller.

In other words, this section will describe:

 * how to add code into tasks
 * how to create plans inside planning methods
 * where to put what

