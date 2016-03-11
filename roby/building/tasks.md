---
title: Adding runtime code to tasks
keywords: roby, robotics, rock, framework, ide
permalink: "/building/tasks/"
---

Roby allows you to mix model-based descriptions (the tasks, the plan, ...) with
model-free code.

The first forms an __explicit__ representation of the system's activity, on which other
tools can reason. That's the interest: one can reason on it, and -- for instance
-- detect problems before they actually appear, or provide information about the
future to other systems, or ...

The second allows to iron out the "gory details". While model-oriented
development is all nice on the paper, real systems are usually not "sticking" to
the model willingly. This aspect of Roby allows to adapt the model to the real
thing.

Some of these code blocks can only be added in the context of the task model
(i.e. in the task class), while other can be added both at the class and
instance levels. What can be done where is given in details.

This page will cover how you can have some code executed at runtime, and in
which conditions

Event commands
--------------
One can associate a single code block, at the model level, as the __command__ of
a task event. It is done at the event creation:

~~~ ruby
class MoveTo < Roby::Task
  event :start do |context|
     emit :start
  end
end
~~~

If the only thing that the command should do is emitting the event, one can use
the :controlable => true option to Task.event instead:

~~~ ruby
class MoveTo < Roby::Task
  event :start, :controlable => true
end
~~~

When done in subclasses, one can use the super keyword to call the command from
the parent task. Note that due to Ruby's language limitations, you must call
super with explicit arguments (i.e. super() and not super).

Event handlers
--------------
Any number of event handlers can be associated with a single task event, both at
the model and instance levels. The syntax is identical in both cases (you will
see examples below) and the blocks gets an instance of Roby::Event that
represents the emitted event.

At the model level, the code block is evaluated as if it was a method of the
class (i.e. self == task). At the instance level, the code block is instanciated
as all blocks (i.e. self != task). If referring to the task is needed, 

__Model-level example__

~~~ ruby
class MoveTo < Roby::Task
  on :start do |event|
    puts "movement started by task #{self}"
  end
end
~~~

__Instance-level example__

~~~ ruby
task = MoveTo.new
task.on :start do |event|
  puts "movement started by task #{event.task}"
end
~~~

Executing an event command through a subtask (or subplan)
---------------------------------------------------------
It is, sometimes, desired that the command of an event is realized by a task
itself, instead of simply using a code block.

At execution time, this can be done with

~~~ ruby
event.achieve_with(task)
~~~

The corresponding task will be started, and the event is going to be emitted as
soon as the task's success event is emitted. The task can, obviously, be the
root task of a complete Roby subplan.

Polling handlers
----------------
Poll handlers are code blocks attached to tasks. These code blocks are executed
__if the task is running__ at each of the system's execution cycle (by default,
it means once every 100ms).

A single polling block can be defined on task models, in which case the poll
block is evaluated as if it was an instance method on the class. super() can be
used to call the parent task's poll block if there is one.

~~~ ruby
class MyTask < Roby::Task
  poll do
    # Code executed if any instance of class MyTask
    # is running
    #
    # In here, +self+ refers to the task instance
    puts "polling in #{self}"
  end
end
~~~

It can also be attached to a task instance with

~~~ ruby
t = MyTask.new
t.poll do |task|
  # Code executed if +task+ is running
  # In here, +self+ refers to the caller object (i.e. the object that added the
  # poll block). Use +task+ to refer to the task instance. Do NOT use the
  # toplevel instance 't'.
  puts "polling in #{task}"
end
~~~

While there can be only one class-level polling block, there can be more than
one instance-level polling blocks.

If a poll block has a coding error, the task is going to be terminated by
emitting its __internal_error__ event.

Scripts
-------
Scripts offer a step-by-step representation of a long running process in a way
that is compatible with the underlying [reactor
mechanisms](../concepts/reactor.html) of Roby. For instance:

~~~ ruby
task = MyTask.new
movement = move_to :target => [12, 11]
task.script do
  # Redirect log messages to the logger on Robot
  setup_logger(Robot)
  # Wait for the ready event of the task child that has a 'localization' role to
  # be emitted. It returns immediately if the event has been
  # emitted in the past
  wait_any(localization_child.ready_event)
  # Send a log message
  info "localization ready, starting to move"
  # Start the movement task. It also adds +movement+ as a child of +task+
  start(movement, :role => 'movement_child')
  # Wait for the target position to be reached
  poll do
    if State.position.x > 10
      transition! # exit from the poll loop
    end
  end
  # Emit success
  emit :success
end
~~~

The commands available in scripts are detailed in the API
documentation: `Roby::TaskScripting::Script`

Any number of scripts can be associated, both at the model and instance levels,
on a given task class or object.

__Important__ The toplevel context is evaluated as soon as the script is
defined. It means that if you do an error there, it is going to be raised right
away. However, the code blocks provided to e.g. poll or execute will only be
evaluated when the script reaches this point.
{: .warning}

State machines
--------------
Users can detail a Roby task using a state machine concept. The interface described in the following
embeds the [state_machine gem](http://github.com/pluginaweek/state_machine). 
When defining a Roby task the user can inject substates to the 'running' state. The initial state is 'running' by default.

With each state a poll block can be associated. This block is repeatedly called, as long as the task remain in the corresponding state.

~~~ ruby
class MyTask < Roby::Task
  def success_condition_reached?
    # Check for the success condition and return true if it is reached
  end
  refine_running_state do
    poll_in_state :running do
      if success_condition_reached?
        emit :success
      end
    end
  
    on :pause do 
      transition [:running] => :paused
    end
  
    on :resume do 
      transition [:paused] => :running
    end
  
    # In this simple example, 'pause' causes the task to sleep 4 second
    # and then resumes
    poll_in_state :paused do |task|
      if rand < 0.1
        task.emit :resume
      end
    end

    script_in_state :running do
      start(MoveTo, :role => 'movement')
      wait movement_child.success_event
      info "now pausing and trying again"
      emit :pause
    end
  end

  on :pause do |ev|
    # stop running actions
  end
  ....
end
~~~


If an event is referred to by a __on__ call in refine_running_state, then it is
created on the Roby task model as well. This allows you to apply the usual
syntax to include event actions or to emit events __after__ the
refine_running_state block.

~~~ ruby
on :yourevent do |ev|
  # The event context will be a instance of StateMachine::Event
end
~~~

In order to define your state machine behaviour you have to specify when to
transition from one state to another (as a reaction to an event). These
transitions should be specified in the __on__ handlers inside the
refine_running_state block. See [state_machine
documentation](https://github.com/pluginaweek/state_machine) for an detailed
example on the syntax which can be used. A simple example is given in the
following:

~~~ ruby
on :repair do
    # First transition which matches the current state applies
    transition [:exception, :fatal] => :running
    transition [:running] => :halted
end

on :halt do
   transition all => :halted
end
~~~

The current state of a task can be retrieved (as usual). However the list of states will be extended given the newly introduced substates of running:

~~~ ruby
mytask = MyTask.new
if mytask.current_state == :paused
    ...
end
~~~

A statemachine transition will be only executed if it is a valid transition, otherwise an InvalidTransition error is raised.
{: .note}

Summary
-------
This page and the previous one told you how to build single tasks that represent
processing, either by abstracting sets of tasks in the roby plan, or external
processes.

The [next page](actions.html) will go to the next level and tell you about Roby's means of
coordination across tasks: the action interface.

