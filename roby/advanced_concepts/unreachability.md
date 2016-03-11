---
title: Event Unreachability
keywords: roby, robotics, rock, framework, ide
permalink: "/advanced_concepts/unreachability/"
---

What we saw about events, so far, is the ability to listen to their emission
(event handlers) and to trigger this emission (event commands).

Now, let's think a pretty common situation: something is waiting for event A to
be emitted. In other words, the follow-up execution of the system depends on
having an event be emitted. But, for whatever reason, this event is __not__
going to happen.

This is covered by another event-related triggering mechanism: the event
unreachability. An event generator is marked as unreachable when it is known
that it cannot be emitted anymore.

By default, this happens for all the generators of a task when the task
finishes. Other conditions can apply (it can even be done by the tasks
themselves to provide more information to the rest of the system).

A generator is declared as unreachable by calling unreachable! on it:

``` ruby
task.success_event.unreachable!
```

The fact that event becomes unreachable can be listened to with
EventGenerator#when_unreachable

``` ruby
task.success_event.when_unreachable do |reason|
end
```

Additionally, one can use #when_unreachable without a block. Then, an event
generator is returned that is emitted when the event becomes unreachable.

A reason can be given, which is then stored in the #unreachability_reason
attribute of the generator. The reason can be any object but is traditionally
either an instance of Roby::Event or an instance of Exception.

