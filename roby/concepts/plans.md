---
title: Plans
keywords: roby, robotics, rock, framework, ide
permalink: "/concepts/plans/"
---

Now that we have seen what the [reactor pattern](reactor.html) is about, we will
dig a bit more into how things are managed inside Roby.

The main issue with reactor frameworks in general is their inability to offer a
high-level structure. Events are the only things that you deal with. This
becomes tedious when errors happen, as tracking down what caused the errors are
very hard. Since Roby is designed with the ability, in the long run, to have
the systems _autonomously_ repair the errors, that's not acceptable.

So, in contrast, Roby tries very hard to provide a structure to what happens to the
system. This page will describe how this is done

The root data structure is the __plan__. A plan is basically a collection of plan objects
(events and tasks, see below) that are linked in different __relations__. Relations,
in this context, are graphs that link two plan objects together, while adding some
additional information to describe how they are related.

Plan Objects
------------
The basic object is the __event__. Events are, obviously, a representation of
what happens to the system. As we will see later, it is also a way to represent
which commands can be sent to it.

Events are usually (but not necessarily) grouped in **tasks**. While events are
single-shot, i.e. represent one thing that happened to the system, tasks
represent what the system (or other systems) do in the long run. For instance,
one could represent the fact that the battery of a robot gets low with a single
battery_low event, but would represent the fact that the robot moves to a certain
position with a move_to_position task. In other words, the event represents a
single point in time, while tasks represent processes that change in time.

As mentionned, plans therefore contain _free events_, i.e. events that are not
part of a task, and _task events_, i.e. events that are given meaning by the
task they are in. Building on the example above, the fact that the robot
reached its destination could be represented by a free reached_destination
event, but would in effect be represented as the success of the
move_to_position task, i.e. as the success event of that task.

Relations
---------
In a Roby plan, relations describe how the events and tasks are related to each
other.

For instance, the most common __task relation__ is the dependency: it says that
a given task requires "something" from another task. What is actually required
is added as additional information to each edge in the relation graph. In our
move_to_position example above, it is very likely that the move_to_position task
would depend on a localization task (i.e. the robot would need to know where it
is to go to reach its goal).

Common __event relations__ describe how the system should evolve in time: for
instance, the temporal relation allows to say that an event should happend (a.k.a.
be emitted) after another, allowing to build sequences by expressing that the stop
event of a task should happen before the start event of another.

Relations are not fixed, i.e. Roby can be augmented with additional relations.
However, the most standard relations are predefined in the Roby core
application.

Example
-------
To put these concepts into play, let's represent what could be a Roby plan to
represent the following scenario:
 
 * go to position (10, 10)
 * then, go to position (20, 10)
 * both movements require localization to run
 * if the battery is low, abort

To match the Roby nomenclature, the task types are represented in CamelCase
(i.e. MoveTo) and the events in snake_case (i.e. battery_low)

![Simple plan example](simple_plan_example.png)
{: .center}

This example shows another aspect of the events: the event commands. Let's
explain that.

Events as commands
------------------
As mentionned earlier, events are both a way to represent what happened __(past
tense)__ to the system and a way to __command__ the system. The command side of
the events can be explained as follows: event commands are_a way to make sure
that the event is going to be emitted_.

For instance, in the above example, the stop events of MoveTo has a command.
This command, when called, ensures that the task gets stopped, i.e. that the
event is emitted. The __signals__ relation that is added between low_battery and
stop represents that this command should be called whenever the low_battery
event is emitted. In other words: the MoveTo tasks should be stopped when the
battery is low.

Conclusion
----------
That's all for the description of plans. The [next page](execution.html) will lead you to the
execution, i.e. what code is executed when, and why.
