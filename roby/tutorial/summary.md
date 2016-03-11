---
title: Summary
keywords: roby, robotics, rock, framework, ide
permalink: "/tutorial/summary/"
---


* *events* allow you to represent the robot's situations and the commands that the
  robot accepts
  * the _Signal_ relation represents reactions: it calls the command of the
    target when the source is emitted.
  * the _Forwarding_ relation represents generalization: it emits the target
    event when the source is emitted, and therefore the _situation_ of the
    target is a superset of the _situation_ of the source.
  * event handlers allow to call arbitrary code blocks when an event is emitted.
* *tasks* allow you to represent the processes that run on the robot.
  * the _Hierarchy_ relation represents dependencies between tasks.
* <b>a Roby application</b> allows you to build a controller for a robot
  * the task models are put in the tasks/ subdirectory
  * the startup code is put in the robot's controllers/ file
  * a Roby shell allows to interact with a running application
  * planning methods can be defined in planners/ROBOT_NAME/main.rb. Those
    methods define the set of actions that is exported to the Roby shell
  * it is possible to log execution traces and replay them using
    <tt>roby-log</tt>
* <b>error handling</b>
  * errors in user code are harmless to the Roby application as a whole
  * the hierarchy relation allows to automatically detect failed dependencies
  * three means exist to repair errors:
    - in event handlers
    - using plan repairs
    - using exception handlers

