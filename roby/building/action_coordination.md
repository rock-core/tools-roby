---
title: Action Coordination
keywords: roby, robotics, rock, framework, ide
permalink: "/building/action_coordination/"
---

This page will present the high-level means of coordinating different actions to
create a high-level system behaviour (i.e. "a mission").

Action State Machines
---------------------
The easiest way to create an action is to define a state machine that calls
other actions and/or some Roby tasks.

~~~ ruby
class Main
  describe("move").
    required_arg('speed', 'the speed it should move at in m/s').
    optional_arg('time', 'how long it should move in seconds')
  action_state_machine 'move' do
    ... state machine definition ...
  end
end
~~~

The string argument to #action_state_machine being the action name. At runtime, the
state machine will be represented by a toplevel task of the type given in the
description, or if none is given by the automatically created task type
mentioned earlier (here: Main::Move).

Within the state machine, states are represented by __single Roby tasks__. These
tasks are generated by calling #state with an argument which is either
another action or a Roby task model, and some arguments. Note that the same
action can be used to define multiple states (even with the same arguments).
The starting state is defined with the start(state) statement and transitions
with transition(event, next_state).

~~~ ruby
state_machine 'move' do
  # Call other actions to get our states
  planning  = state path_planning(:target => [10, 10, 0])
  execution = state path_execution

  start(planning)
  transition(planning.success_event, execution)
end
~~~

Defining a state from an action or task model basically tells Roby to start such
an action / task each time the state is entered. Moreover, if the task that
represents the current state terminates through an event for which no
transitions is defined, this is going to generate a [dependency
error](task_relations/dependency.html) (ChildFailedError)

If the action has arguments, they can be referred to as local variables:

~~~ ruby
describe("move to a given target point").
  required_arg('target', 'the speed it should move at in m/s')
state_machine 'move' do
  planning  = state path_planning(:target => target)
  execution = state path_execution

  start(planning)
  transition(planning.success_event, execution)
end
~~~

Finally, one needs to tell the system when the toplevel task is terminated. This
is done, as usual in Roby, by [forwarding](event_relations/forward.html) a
state event to a terminal event on the toplevel task:

~~~ ruby
describe("move to a given target point").
  required_arg('target', 'the speed it should move at in m/s')
state_machine 'move_to' do
  planning  = state path_planning(:target => target)
  execution = state path_execution

  start(path_planning)
  transition(path_planning.success_event, path_execution)
  forward path_execution.reached_the_end_event, success_event
end
~~~

As an example, a retry-until-it-works action can be specified with:

~~~ ruby
state_machine 'wait_until_it_works' do
  act = state my_action
  start(act)
  transition(act.failed_event, act)
  forward act.success_event, success_event
end
~~~

