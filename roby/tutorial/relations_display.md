---
title: Using Plan Display
keywords: roby, robotics, rock, framework, ide
permalink: "/tutorial/relations_display/"
---

What we will see in this page is how to trace the execution flow (the flow of
events), and understand a bit more how the plans you will build are actually
executed by the system. We will re-use the planned\_move planning action we just
built.

Getting a log file
------------------

Using logging is the most common case, so it is enabled by default. However, it
is can be expensive from a CPU point of view. To disable, edit config/app.yml
and comment "events: false" around line 23. 
{: .block}

Run the controller again

    # roby run -rgoForward -c

and in the shell, do

    localhost:48902 > planned_move! :x => 10, :y => 20 => #<service Roby::Task:0x7f48f073d6e8{}[]>
    localhost:48902 > 
    [1] planned_move! started to plan
    [1] planned_move!: Roby::Task:0x7f48f073d6e8{}[] has been replaced by MoveTo:0x7f48f0726448{goal => Vector3D(x=10.000000,y=20.000000,z=0.000000)}[]
    [1] planned_move!: task MoveTo:0x7f48f0726448{goal => Vector3D(x=10.000000,y=20.000000,z=0.000000)}[] started
    [1] planned_move!: task MoveTo:0x7f48f0726448{goal => Vector3D(x=10.000000,y=20.000000,z=0.000000)}[] finished successfully
    [1] planned_move!: task MoveTo:0x7f48f0726448{goal => Vector3D(x=10.000000,y=20.000000,z=0.000000)}[] has been removed

The log files are saved in the logs/ folder with a name that represents the
start time of the run (YYYYMMDD-HHMM). The last run (or the current run, if it
is still running) is symlinked to logs/current. One can use

    roby results plan_display_tutorial

to rename the folder to YYYYMMDD-HHMM_plan_display_tutorial, so that finding
this particular dataset later is easier.

Displaying the log file
-----------------------
List the contents of the generated log directory:

    $ cd /home/doudou/dev/roby-tutorials/
    $ ls logs/current/
    goForward-events.log
    goForward-index.log

If you look into it, two goForward files are present:
<tt>goForward-events.log</tt> and "goForward-index.log".  The first one includes
a trace of everything that happens in the Roby controller which has been traced
(which virtually includes everything). The second one can actually be generated
from data in the first one. It is simply used to speed up operations.

The data in the event log can be used to display the plan operations in a GUI.
For that, you need to have installed [Ruby/Qt4](http://korundum.rubyforge.org), as
the GUI is written using Qt and Ruby. This can be done by installing the
qtbindings rubygem.

To start it, simply do the following in the directory of the log files:

    $ roby display logs/current/goForward-events.log

The following two windows should appear:

![](log_replay/roby_log_main_window.png)

The right window is the replay control. It displays the execution cycles in
which something happened (an event has been emitted or the plan got modified).
The left window represents the plan structure at the currently selected cycle,
the events that got emitted during this cycle as well as the propagation between
these events. The set of task relations that should be displayed can be selected
by going into View/Configure.

**Very important note** your own display may not look exactly like the ones
displayed here. Some of the features showed here (like threaded planning) are
asynchronous and as such the exact displays depend on the execution timing. Note
that, even though it is the case, the robot _behaviour_ remains unchanged.
{: .warning}

Startup of the "planned\_move!" action {#planning}
---------------------------------------

Let's get to the first task-related events. Click on the first element in
execution history (cycle @13 in the right window above). It should look like the
next image:

![](log_replay/goForward_1.png)

What you see here is a representation of the plan built when the planned\_move!
command is entered in the shell. It consists of a generic task (Roby::Task)
which is planned\_by a Roby::PlanningTask. This is how Roby handles action
requests from the shell: (i) it searches a planner defined for that robot with
the specific action and (ii) generates the plan representing the planning
process _in a separate thread_.

Once that initial plan has been built, the Roby::PlanningTask task has been
started. The various cases of event propagation are represented in different
ways, based on whether or not the event is controlable or contingent, if it has been
called and/or emitted. Finally, two different arrow representations are used for
signalling (plain) and forwarding (dotted):

![](log_replay/roby_replay_event_representation.png)

A note about propagation representation: it would be useless to represent all
the event propagation from the beginning of the execution to the current point.
The display therefore represents only the propagations that have taken place
_within the selected cycle_. In our case, we see that, in this cycle, the
planning task "start" event has been called and emitted.

The MoveTo plan
---------------

Advance one step (to the next cycle)

![](log_replay/goForward_2.png)

The MoveTo action has been planned and the executed plan is modified to reflect
that. The MoveTo action itself is then started, and that is propagated to the
ComputePath 'start' event through the signalling relation that was established
in planned\_move.

Next execution step gives us the following:

![](log_replay/goForward_3.png)

ComputePath emitted its "success" event. We see here that the emission of the
"success" event of that task does not mean 'the plan modification has just took
place' but instead that 'it has taken place some time earlier'.

The ComputePath task has also finished generating the path, which is why
ExecutePath is started. Here, the dotted lines between the events
represent a forwarding relation between them, while the plain lines
represent signal relations.

Finally, light grey here represents tasks that have finished with the "success"
event. Tasks whose "failed" event has been emitted are represented in red.

To finish: the garbage collection process
-----------------------------------------

Advance a few more steps.

![](log_replay/goForward_5.png)

Here, ExecutePath has finished its execution with success and MoveTo is
therefore finished as well -- per the forwarding relation between those two
events. Note that the tasks have this thick dark grey contour. It means that the
task got [garbage collected](../concepts/garbage_collection.html) in this cycle,
i.e. removed from the plan because it was not useful anymore.

