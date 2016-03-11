---
title: The Forward relation
keywords: roby, robotics, rock, framework, ide
permalink: "/event_relations/forward/"
---

Available as Roby::EventStructure::Forward

This relation is part of the Roby core relations, and therefore forward-related
methods are defined on the Roby::EventGenerator class directly.

Semantics
---------
The forward relation causes the emission of the child event when the source
event is emitted.

From a semantic point of view, the forward relation expresses a
__generalization__ of an event. I.e. it expresses that the set of situations
that cause the emission of the target event is a __superset__ of the situations
that cause the emission of the source event. Indeed, the target event will
_always_ be emitted when the source event is __and__ might be emitted in other
cases.

A direct example is the _stop_ event, which is forwarded from both _success_ and
_failed_.

There are two main use cases:

 * the "horizontal" use case, usually within one task model. The forwarding
   relation allows to create event categorization, creating more general
   representations of specific situations, without losing the information of
   the exact causes.
 * the "vertical" use case, where events are forwarded between tasks. This
   allows to create "interfaces" in the plan, where a given task accesses
   other tasks only when they are directly associated to it. See [this
   page](../building/patterns.html)

It is created with #forward_to

``` ruby
special_case.forward_to(generalized_case)
```

The emission context is passed along, i.e.

``` ruby
generalized = Roby::EventGenerator.new
generalized.on do |context|
    puts context.inspect
    emit
end
special_case.forward_to(generalized)
special_case.emit(42) # displays "[42]"
```


Task models
--------------
Forwards can be declared from within a task model by using Task.forward:

``` ruby
class Move < Roby::Task
  event :blocked
  forward :blocked => :failed
end
```

Relationship to Scheduling
--------------------------
The forward relation has an influence on both [the basic and
temporal schedulers](../advanced_concepts/scheduling.html).

