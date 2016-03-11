---
title: Task Hierarchies
keywords: roby, robotics, rock, framework, ide
permalink: "/tutorial/hierarchy/"
---

What building blocks do we have until now ?

* events, signals and forwarding: a way to represent how the execution should
  proceed. This is **the execution flow**.
* tasks: how events can be aggregated into a representation of long-running
  processes

The goal of a plan-based system such as Roby is to allow aggregating the tasks
to represent both *what* the system is doing and *how* it is doing it. To do
this, Roby offers different **task relations**: these relations are a
representation of the purpose of each tasks.  For instance, the *hierarchy*
relation represents a dependency, i.e. saying "a given task purpose is to allow
the successful execution of another task".  Another example is the "planned\_by"
relation. This other relation represents that a given task takes care of
generating the plan needed to perform an action.

This page presents the most important of them: the hierarchy relation.

Semantics of task hierarchies
-----------------------------
The goal of that relation is to represent the hard dependencies between tasks.
I.e. to say "task A needs results from task B to perform its duty" or "task A
needs task B to run to perform its duty". The idea behind such a relation is to
be able to create a "library" of tasks that perform simple actions (usually
implemented in a functional layer external to Roby itself), and then to be able
**aggregate** them into more complex actions simply by building plans.

What is the purpose of this ? Why not just run things "like this" ?

The goal is to be able to detect errors in execution. What a dependency relation
gives is not only a semantic (why things are what they are), but also that "if
the child fails, then something is wrong". The support of error detection and
reparation is the central issue in supervision, and Roby offers advanced tools
for it.

Adding dependencies between tasks
---------------------------------

The code in that section is not meant to be tried out, but to support the
explanations. A proper controller, that uses these principles, is shown in the
following sections.
{: .warning}

Let's assume our robot's functional layer offers two services:

 * it has a way to compute a path from A to B (path planning)
 * it has a way to execute that path once its computed

What we want here is to build the plan that represents a _movement_ from the
current robot's position to a goal position.  That aggregate action will
naturally be represented by a MoveTo task that takes one 'goal' argument. In
Roby, it would look like this:

``` ruby
class MoveTo < Roby::Task
  argument :goal
end
```

So, now, we would have two options:

 * either call the functional layer directly from the MoveTo task
 * or integrate both services independently (in two different tasks) and then
   aggregate their functionality through the plan.

In Roby, we would usually use the second method, as it promotes reusability. The
plan would therefore have to represent the following:

    To do a MoveTo from point A to point B
      => first the robot must successfully compute its 
         path between those two points
      => then it must successfully execute that path

Assuming that we have the ComputePath and ExecutePath task models to represent
our functional layer's services, and that the target point is represented by the
variable 'p', this can be translated as a plan into:

    The successful execution of MoveTo(:goal => p) depends on
      the successful execution of ComputePath(:goal => p)
      followed by the successful execution of ExecutePath

Finally, that plan would be generated with the following code.

``` ruby
 move    = MoveTo.new :goal => a
 compute = ComputePath.new :goal => a
 execute = ExecutePath.new

 # The movement depends on the successful execution of both the computation and
 # execution of the path
 move.depends_on compute
 move.depends_on execute
 # Execution should start when computation has finished successfully
 compute.signal :success, execute, :start
 # Computation should start when the movement starts
 move.signal :start, compute, :start
 # The movement has successfully finished when the execution has successfully
 # finished
 execute.forward :success, move, :success
```

Obviously, the ComputePath/ExecutePath combination is a **sequence**. Rephrasing
again, we could describe this plan with:
    The MoveTo task is a sequence of ComputePath followed by ExecutePath

and could be written

``` ruby
 move    = MoveTo.new :goal => a
 compute = ComputePath.new :goal => a
 execute = ExecutePath.new
 (compute + execute).to_task(move)
 move
```
 

A controller using task hierarchies
-----------------------------------

What do we need to get a proper controller implementing this ?
* first we need to define the three task models described above
* then we need to define the planning method that will create the necessary
  plan.

The only thing that still needs to be defined is how to transfer the path from
the ComputePath task to the ExecutePath task. In general, such an endeavour is
done in Roby through the attributes on task objects. Here, we will simply define
a 'path' attribute on the MoveTo class.  Given that the actual actions are
performed by ComputePath and ExecutePath, the definition of the MoveTo task is
actually quite simple (add in models/tasks/move_to.rb)

``` ruby
class MoveTo < Roby::Task
  terminates

  # The movement goal
  argument :goal
  # The generated path
  attr_accessor :path
end
```

The implementation of the ComputePath task is a bit more complex. First, on a
model point of view, it will require the 'goal' argument again, and also a
'path\_task' argument which is the task holding the path data when computed.

On the implementation side, we will use a standard task, the {rdoc_class:
Tasks::Thread}. This task represents in Roby's plan a computation that is done in a
separate thread. To use this task, one simply needs to define an
"implementation" block (see below). This block is ran in a separate thread by
Tasks::Thread and, upon successful execution of the thread, the result value is
saved in the tasks's 'result' attribute (and success is emitted). The
added value is that if the thread fails by raising an exception, the "failed"
event is simply emitted with the exception as context. Now, open
models/tasks/compute\_path.rb and add the following code to it:

``` ruby
require 'roby/tasks/thread'
class ComputePath < Roby::Tasks::Thread
  # The movement goal
  argument :goal

  # The robot position at which we started planning the path
  attr_reader :start_point

  # Initialize start_point and call Tasks::Thread's start command
  event :start do |context|
    @start_point = State.pos.dup
    super
  end

  # Implementation of the computation thread
  implementation do
    path      = [start_point]
    max_speed = 1
    while goal.distance(path.last) > max_speed
      u = goal - path.last
      u /= u.length / max_speed
      path << path.last + u
    end
    path << goal

    Robot.info "#{path.size} points between #{start_point} and #{goal}"
    path
  end
end
```

Finally, ExecutePath takes the path generated and follows it. It assumes that
its path is stored on its parent task. Edit models/tasks/execute\_path.rb and
add the following:

``` ruby
class ExecutePath < Roby::Task
  terminates

  # The current waypoint
  def current_waypoint; parent_task.path[@waypoint_index] end

  poll do
    @waypoint_index ||= 0
    State.pos = current_waypoint
    @waypoint_index += 1
    if @waypoint_index == parent_task.path.size
      emit :success
    end

    Robot.info "moved to #{current_waypoint}"
  end
end
```

There are two things left to do: properly initializing the position and adding
the planning method. For the first point, we will use the Roby::Pos::Vector3D class
that Roby provides (a simple x,y,z tuple). Edit scripts/controllers/goForward.rb and
add:

~~~ ruby
State.pos = Roby::Pos::Vector3D.new
~~~

Finally, edit models/planners/goForward/main.rb and add the following method:

~~~ ruby
describe("a movement that is using a planner").
    required_arg('x', 'the X part of the position').
    required_arg('y', 'the Y part of the position')
def planned_move(arguments)
 goal = Roby::Pos::Vector3D.new(*arguments.values_at(:x, :y))
 move    = MoveTo.new :goal => goal
 compute = ComputePath.new :goal => goal
 execute = ExecutePath.new
 # ExecutePath expects its target path from its parent. Make sure that it
 # happens
 compute.on :success do |event|
   move.path = compute.result
 end
 (compute + execute).to_task(move)
 move
end
~~~

Trying it out 
-------------

In one Unix shell, do

    $ roby run -rgoForward -c
    344919:32:59.172 (Roby) GC.enable does not accept an argument. GC will not be controlled by Roby
    344919:32:59.204 (goForward) loaded Roby 0.7.90 on ruby 1.8.7 (2008-08-11 patchlevel 72) [x86_64-linux]
    344919:32:59.272 (goForward) loading controller file /home/joyeux/dev/first_app/controllers/goForward.rb
    344919:32:59.273 (goForward) done initialization                                                        

Then, **in another one**, start the Roby shell

    $ roby shell
    localhost:48902 >

And do

~~~ ruby
localhost:48902 > planned_move! :x => 10, :y => 20
=> #<service Roby::Task:0x7f34d6dce5f8{}[]>
localhost:48902 > 
[1] planned_move! started to plan
[1] planned_move!: Roby::Task:0x7f34d6dce5f8{}[] has been replaced by MoveTo:0x7f34d6db7358{goal => Vector3D(x=10.000000,y=20.000000,z=0.000000)}[]
[1] planned_move!: task MoveTo:0x7f34d6db7358{goal => Vector3D(x=10.000000,y=20.000000,z=0.000000)}[] started
[1] planned_move!: task MoveTo:0x7f34d6db7358{goal => Vector3D(x=10.000000,y=20.000000,z=0.000000)}[] finished successfully
[1] planned_move!: task MoveTo:0x7f34d6db7358{goal => Vector3D(x=10.000000,y=20.000000,z=0.000000)}[] has been removed
~~~

