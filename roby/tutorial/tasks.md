---
title: Tasks
keywords: roby, robotics, rock, framework, ide
permalink: "/tutorial/tasks/"
---
{include_file: {filename: src/basics_shell_header.txt, escape_html: false}}

Definition of Tasks
-------------------

Unlike with event objects, which are usually created and parametrized
on-the-fly, tasks are mostly first _defined_ and then _used_. To define a task,
one creates a subclass of {rdoc_class: Task}. In our examples, we'll take "the mother
of all tasks in robotic systems": the MoveTo task.

``` ruby
class MoveTo < Roby::Task
end
```

Then, to use it, one would do:

``` ruby
plan.add(task = MoveTo.new)
```

As for events, the task must be included in a plan to be usable, which is done
by calling plan.add(). Don't forget that !

Parametrization
---------------

Obviously, a plain MoveTo task is nothing if the system does not know *where*
to go to ... That is called parametrization and has to be declared in the task
definition, using Task.argument

``` ruby
>> class MoveTo < Roby::Task
?>   argument :x
?>   argument :y
>> end
```

Then, the arguments are provided at instanciation through an argument hash:

``` ruby
>> task = MoveTo.new :x => 10, :y => 20
>> task.x
=> 10
>> task.y
=> 20
```

A task instance (i.e. the result of TaskClass.new) will *not* be usable unless
you initialize all its arguments. Such a task is called _partially
instanciated_:

``` ruby
>> task = MoveTo.new
>> task.partially_instanciated?
=> true
>> task.x = 10
>> task.y = 20
>> task.partially_instanciated?
=> false
```

It is possible to declare default arguments:

``` ruby
>> class MoveTo
?>   argument :max_speed, :default => 1
?> end
>> task = MoveTo.new(:x => 10, :y => 20)
>> task.max_speed
=> nil
>> task.partially_instanciated?
=> false
```

You can see that, even though the task has a default for the max_speed
argument, task.max_speed initially returns nil but task.partially_instanciated?
returns false. This is because the default value gets assigned when the task is
started, not before. To "freeze" all default arguments, one can use the
Task#freeze_delayed_arguments call. This should be seldom needed, though.

Task control and monitoring: defining events
--------------------------------------------

In Roby, tasks are a __collection of events__.  Now that  you know the basics
about events, the purpose of those events should be clear:

* the controllable events allow to change the process' behaviour (the obvious
  one being "start" which allows to start the task)
* both contingent and controllable events allow to monitor the task's execution.

The basic task already defines four events:

 * the *start* event
 * the *stop* event
 * the *success* event
 * and finally the *failed* event

In the class definition, events are defined using Roby::Task.event. To define a
controllable event, simply associate a block. First, copy/paste the following code in a
my\_task.rb file.

``` ruby
class MyTask < Roby::Task
   event :start do |context|
      puts "start event called"
      emit :start
   end
   event :controlable do |context|
      puts "controlable event called"
      emit :controlable
   end
   event :contingent

   on(:start) { |event| puts "start event emitted" }
   on(:controlable) { |event| puts "controlable event emitted" }
   on(:contingent) { |event| puts "contingent event emitted" }
   on(:failed) { |event| puts "failed event emitted" }
   on(:stop) { |event| puts "stop event emitted" }

   event :finished, :terminal => true
   on(:finished) { |event| puts "finished event emitted" }
end
```

Finally, an event can be *terminal*: its emission means the end of the task's
execution. __failed__ and __success__ are examples of terminal events. To declare a
terminal event, one does as for the "finished" event above.

Now, read that code into the ruby shell with

``` ruby
>> source "my_task.rb"
```

Using task events
-----------------
Task event generators are defined using a subclass of EventGenerator,
{rdoc_class: TaskEventGenerator}. One can access them from the task by using
either Task#event or the more widely used ${task_name}_event shortcuts. Then,
you can manipulate them as for normal events:

``` ruby
>> plan.add(task = MyTask.new)
>> ev = task.start_event
>> ev.call
start event called
start event emitted
>> task.running?
=> true
>> ev = task.contingent_event
>> ev.controlable?
=> false
>> ev.emit
contingent event emitted
```

Instead of calling #on, #signal, #emit and #call on the event object, one can use
shortcuts that are defined on {rdoc_class: Task}:

``` ruby
# Same as task.event(:contingent).on { |ev| ... }
>> task.on(:contingent) { |ev| puts "contingent event emitted" } 
# Same as task.event(:contingent).emit
>> task.emit(:contingent)
# There's two handlers now, so we should have two lines displayed
contingent event emitted
contingent event emitted
# Same as task.event(:controlable).call
>> task.controlable!
controlable event called
controlable event emitted
# Same as task.event(:contingent).signals task.event(:controlable)
>> task.signals(:contingent, task, :controlable)
>> task.emit :contingent
contingent event emitted
contingent event emitted
controlable event called
controlable event emitted
>> task.emit :finished
finished event emitted
stop event emitted
>> task.running?
=> false
```

Event classification: using the *forward* relation
--------------------------------------------------
As we in the above examples, it is possible to have terminal events, which are events
that end the task. Obviously, the "stop" event should be emitted when they are
emitted ("stop" represents the task end, does not it ?).

In a more generic way, these terminal events are likely to be either special
cases of the task success or of the task failure. Then, we actually need a way
to *classify* events: to say "success is a special case of stop, or
"wheel\_blocked is a special case of failed, which is a special case of
stop".

To represent this specific event relationship, Roby provides a *forward*
relation between events, which can be added as follows:

``` ruby
>> class MyTask < Roby::Task
?>     event :wheel_blocked
?>     on(:wheel_blocked) { |ev| puts "wheel_blocked emitted" }
?> end
>> plan.add(task = MyTask.new)
>> task.start!
start event called
start event emitted
>> blocked = task.event(:wheel_blocked)
>> failed = task.event(:failed)
>> blocked.forward_to failed
>> task.emit :wheel_blocked
wheel_blocked emitted
stop event emitted
```

In practice, a _forward_ relation between two events a and b says "b should be
emitted when a is". Or "b is a superset of the situations that a represents".

This relation is also available on "plain" events (i.e. EventGenerator.new). 

Task model and event relations
------------------------------
Until now, we only saw how to add relations between events of task instances.
Sometime (especially with forwarding relations), some relations should be
defined on _all_ the task instances of a given task class. To do that, use the
class methods <tt>signal</tt> and <tt>forward</tt> defined on {rdoc_class:
Task}:

``` ruby
>> class MyTask < Roby::Task
?>   signal :start => :controlable
?>   forward :wheel_blocked => :failed
?> end
>> plan.add(task = MyTask.new)
>> task.start!
start event called
start event emitted
controlable event called
controlable event emitted
>> task.emit :wheel_blocked
wheel_blocked emitted
failed event emitted
stop event emitted
```

Tasks that terminates
---------------------
A very important characteristic of tasks is their ability to be _interrupted_
(or lack of). What is meant by that is that Roby should be able to stop some
(actually, most) tasks. In Roby, that ability is represented by giving a command
to the 'stop' event.

For most of the tasks, there is actually no need to perform specific actions.
Simply having Roby mark the task as 'stopped' is enough. For those tasks, using
the 'terminates' statement is enough:

``` ruby
>> class MyTask
?>   terminates
?> end
>> plan.add(task = MyTask.new)
>> task.start!
start event called
start event emitted
controlable event called
controlable event emitted
>> task.stop!
failed event emitted
stop event emitted
```

As you can see, 'terminates' is equivalent to

``` ruby
 >> class MyTask
 ?>   event(:failed) { emit :failed }
 ?>   event(:stop) { failed! }
 ?> end
```

Common errors when manipulating tasks
-------------------------------------

As for the event, a common error is to forget to include the task in a plan
before calling events on it:

``` ruby
>> task = MyTask.new
>> task.start!
Roby::EventNotExecutable: start! called on MyTask{}:0x7f336c455af0[] but the task is in no plan
```

Another related error is to emit/call events other than "start" while the task is not yet running ...

``` ruby
>> plan.add(task = MyTask.new)
>> task.controllable!
Roby::CommandFailed: controlable!() called by [] but the task has never been started
   from (irb):30
>> task.emit :contingent
Roby::EmissionFailed: emit(contingent, []) called by [] but the task has never been started
   from (irb):31
```

... or when it has stopped

``` ruby
>> task.start!
>> task.stop!
>> task.controlable!
Roby::CommandFailed: controlable!() called by [] but the task has finished. Task has been terminated by [MyTask{}:0x7ff179064358[]/failed@7 [344917:00:42.215]:
       from (irb):32
>> task.emit :contingent
Roby::EmissionFailed: emit(contingent, []) called by [] but the task has finished. Task has been terminated by [MyTask{}:0x7ff179064358[]/failed@7 [344917:00:42.215]: ].
       from (irb):33
```

<div markdown="1" class="info">
In these messages, the notation

    MyTask{}:0x7ff179064358[]

represents a task, the notation

    MyTask{}:0x7ff179064358[]/failed

represents the event "failed" of the same task and finally

    MyTask{}:0x7ff179064358[]/failed@7 [344917:00:42.215]

is an emitted event that has been generated by the "failed" event of the given
task. The time on the right is the time of emission, and the "@x" notation is
the propagation cycle (usually, you don't care about this but it is VERY useful
for debugging Roby itself).
</div>

Of course, as we saw at the beginning of this page, a task must be fully
instanciated to be started:

``` ruby
 >> class Bla < Roby::Task
 >>    argument :foo
 >> end
 >> plan.add(task = Bla.new)
 >> task.start!
 Roby::EventNotExecutable: start! called on Bar{}:0x7ff17901c1e8[] which is partially instanciated
 The following arguments were not set:
        foo
```

Summary
-------

What do we do know ?

* we know how the robot's situation is represented: through the *emission
  of events*
* we know how the robot is controlled: through the call of *controlable
  events*
* we know how to sort events in tasks, in order to represent the different
  processes that run on the robot.

One important question is still left open: how all of this can be made into a
whole that allows to control a robot ? Right now, we only have an overview of
the basics of Roby plan. What follows will show what a *Roby application* is
made of.

