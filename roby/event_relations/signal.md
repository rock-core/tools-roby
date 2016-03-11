---
title: The Signal relation
keywords: roby, robotics, rock, framework, ide
permalink: "/event_relations/signal/"
---

Available as Roby::EventStructure::Signal

This relation is part of the Roby core relations, and therefore signal-related
methods are defined on the Roby::EventGenerator class directly.

Semantics
---------
The signal relation expresses a reaction to an event in the form of calling the
command of another controllable event.

It is created with #signals

``` ruby
cause.signals(controllable_event)
```

Once this relation is createdm, he command of controllable_event is going to be
called each time the _cause_ event is emitted.

The emission context is passed to the command, i.e.

``` ruby
controllable_event = Roby::EventGenerator.new do |context|
    puts context.inspect
    emit
end
cause.signals(controllable_event)
cause.emit(42) # displays "[42]"
```

Task models
--------------
Signals can be declared from within a task model by using the Task.signals:

``` ruby
class Task < Roby::Task
  event :blocked
  event :replan do |context|
    puts "doing replanning"
    emit :replan
  end
  signals :blocked => :replan
end
```

Relationship to Scheduling
--------------------------
The signal relation has an influence on both [the basic and
temporal schedulers](../advanced_concepts/scheduling.html).

