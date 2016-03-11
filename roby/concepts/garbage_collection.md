---
title: Useful and useless tasks
keywords: roby, robotics, rock, framework, ide
permalink: "/concepts/garbage_collection/"
---

So far, we have seen that the plan is basically a bunch of tasks and events that
are related to each other.

What this page will detail is how Roby knows what is needed by the system and
what is not. And what it does with the garbage ...

Missions and permanent tasks
----------------------------
In any Roby plan, a certain, usually very limited, number of tasks are marked
either as __missions__ or as __permanent__ tasks. The missions are the current
robot's main activities (i.e. what it should do). The permanent tasks are the
tasks that the system's controller wants to keep around, but which are not
essential to its function. This marking is either done manually, or
automatically by some of the Roby interfaces when the system is given a
high-level command.

Garbage collection
------------------
At the end of each execution cycle, Roby looks at all the tasks in the system's
plan. Tasks that are __needed__ by a mission or a permanent tasks are left
alone. Everything else is stopped automatically and 

Roby determines what is "needed" and what is "not needed" by looking at the
task relations. Unless specified otherwise in the relation declaration,
relations all express a "needed by" relationship, i.e. the source of a relation
edge needs the target of that edge to function properly.

In other words, Roby follows all the relations, from the missions and permanent
tasks, and marks all tasks it finds as "useful". Everything else is garbage
collected.

The stopping order is top-down, i.e. the toplevel tasks (that are not a child in
one of the task relations) is stopped. Once that task is stopped, it is removed
from the plan and the process continues until there is nothing to stop.

In general, the garbage collection mechanism allows to manage only the
high-level actions (i.e. the missions), leaving the rest of the tasks in the
system to Roby.

Conclusion
----------
What we have seen so far:

 - the concept of reactors
 - the structuration of tasks and events in plans
 - how these plans get executed
 - and how, in Roby, one can only manage the high-level mission tasks, leaving
   the cleanup to automatic garbage collection handling

The next step is to understand [how Roby represents and handles
errors](error_handling.html)

