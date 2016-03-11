---
title: A First Roby Application
keywords: roby, robotics, rock, framework, ide
permalink: "/tutorial/app/"
---

This page will present another facet of Roby. What we saw until now is how,
in Roby, one can represent the task actions and build plans that describe the
task execution. What we will see here is how Roby tie the different models
together to offer an application environment.

Creation
--------

Go into a *regular shell* (i.e. not the Ruby shell) and create a new directory.
That directory will become your first Roby application by running "roby init":

    $ mkdir first_app
    $ cd first_app
    $ roby init
    creating README.txt
    creating models/
    creating models/tasks/
    creating models/tasks/.gitattributes
    creating models/actions/
    creating models/actions/main.rb
    creating scripts/
    creating scripts/controllers/
    creating scripts/controllers/.gitattributes
    creating Rakefile
    creating config/
    creating config/init.rb
    creating config/app.yml
    creating data/
    creating data/.gitattributes

There's a lot of stuff created, but don't worry we'll learn what this is all
about later on. Right now, we're only interested in two small parts of it:

* the models/tasks/ directory, which is where task models (task classes) should
  be defined
* the robot's controllers in scripts/controllers/. These files contain the code
  that is run when the application is started.

The goForward robot
-------------------
As an introduction, we will create a simulated robot controller which makes the
robot go forward at constant speed.

First, let's create the files specific to this robot

    $ roby add-robot goForward
    creating models/tasks/goForward/
    creating models/tasks/goForward/.gitattributes
    creating models/actions/goForward/
    creating models/actions/goForward/main.rb
    creating scripts/controllers/goForward.rb
    creating config/goForward.rb

Let's define the task model. Edit models/tasks/go\_forward.rb and add

``` ruby
class GoForward < Roby::Task
  # The GoForward task needs the robot speed to be specified
  argument :speed

  # Block called at every execution loop if the task is running. It simulates
  # the robot moving at the specified speed.
  poll do
    State.pos.x += speed
  end

  # This task does not need any specific action to stop
  terminates
end
```

In the controller file, scripts/controllers/goForward.rb, we add the code that
should run at startup:

``` ruby
# Define the original value of x
State.pos.x = 0

# Block will be called once every one second
Roby.every(1) do
  puts State.pos.x
end

# Create the task and start moving !
Roby.plan.add_mission(go = GoForward.new(:speed => 0.1))
puts "Going forward at speed #{go.speed}"
go.start!
```

You can then start the robot controller, and then stop it with CTRL+C.

    $ roby run -rgoForward -c
    335705:25:08.324 (goForward) loading controller file /home/doudou/dev/goForward/scripts/controllers/goForward.rb
    Going forward at speed 0.1
    335705:25:08.356 (goForward) done initialization
    0
    0.9
    1.9
    2.9
    335705:25:16.449 (Roby) received interruption request
    335705:25:16.524 (Roby) control quitting. Waiting for 1 tasks to finish (1 tasks still in plan)

Broken down explanation
-----------------------
* the State object holds all the state data that
  represents the robot's state. In our case, we initialize the robot's position
  in the controller file, and then update it when the robot moves. An equivalent
  singleton exists for configuration, Conf

* the poll statement adds a block that should be executed during each execution
  cycle **if the task is running** (see the [concepts](../concepts/execution.html))

