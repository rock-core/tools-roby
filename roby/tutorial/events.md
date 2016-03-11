---
title: Events
keywords: roby, robotics, rock, framework, ide
permalink: "/tutorial/events/"
---

This page will present the basic tools that allow to define and manipulate
events. In [the concepts section](../concepts/plans.html), we saw that
events are two sided objects: one the one hand, they represent the situations
the system is in (event _emission_). On the other hand, they represent the
commands that the system accepts (event _commands_).  We'll see in this page
how this is translated in the Roby API: how to add a command block to an event
(event command), how to call code when an event is emitted (event handlers),
how to call it and how to emit it.

{include_file: {filename: src/basics_shell_header.txt, escape_html: false}}

The basics
----------
Two classes are used to represent "events". The first is the event generator
{rdoc_class: EventGenerator}. Event generators are the objects that will emit
events. In other words, they represent __the event sources__. When a generator
does emit an event, an instance of {rdoc_class: Event} is created to represent
this event, with timestamp and additional information.

To simplify the discourse, event generators and events are often both called
events. We will try to make the difference in this tutorial, though, to ease
the understanding.

A free event generator that has no command, also called _contingent_ or
_non-controllable_ generators are created with:

``` ruby
 >> ev1 = Roby::EventGenerator.new
```

Then, before using it, you need to include it in a plan, which is simply done
with

``` ruby
>> plan.add(ev1)
```

Finally, to be able to see the event's emission, we would display some text
using an _event handler_: a piece of code that is executed when the event is
emitted.

``` ruby
>> ev1.on { |e| puts "ev1 emitted with context=#{e.context.inspect}" }
```

The event handler's block gets an argument which is the actual event (the
instance of {rdoc_class: Event}). See the API documentation for what you can
get out of it.

Let's try to emit it. The event _emission_ says "the event happened just now".

``` ruby
>> ev1.emit
ev1 emitted with context=nil
```

And if you would like to associate data with the event (what is called the event
context), you would do
  
``` ruby
>> ev1.emit(10)
ev1 emitted with context=[10]
```

Let's now create a second event

``` ruby
>> ev2 = Roby::EventGenerator.new do |argument|
?>   puts "ev2 called with argument=#{argument.inspect}"
?>   ev2.emit(argument.first + 1)
>> end
>> plan.add(ev2)
>> ev2.on { |ev| puts "ev2 emitted with context=#{ev.context.inspect}" }
```

This second event is _controllable_. It has a block of code associated to it
(the event command) whose purpose it to make sure that the event will _happen_
(be emitted). As you can see above, a command accepts an argument. In this
example, the emission is done by calling emit directly. More complex
(asynchronous) schemes can also be built, but in general they would be
represented by tasks (that we will see later on).

Let's try our controllable event

``` ruby
>> ev2.call(10)
ev2 called with argument=[10]
ev2 emitted with context=[11]
```

Reacting to events
------------------
The whole point of having a *plan* is to be able to describe _reactions_: i.e.
what the system should do when something happens. The basic tool to do that,
is to create a _signal_ between two events:

``` ruby
>> ev1.signals ev2
```

Try it:

``` ruby
>> ev1.emit(10)
ev1 emitted with context=10
ev2 called with argument=10
ev2 emitted with context=11
```

You can therefore see that

 * because of the signal, the _emission_ of the first event caused the second
   event's command to be called. The signal therefore means "when ev1 happens,
   call ev2"
 * the signalling transforms the event's context into the target command's
   argument.

Composing events
----------------

Another important capability built around events is the ability to _compose_ them. Two
basic operators exist.

For instance, in the following snippet, "and\_ev" is emitted when _both_ ev1
__and__ ev2 have been emitted and "or\_ev" is emitted as soon as _one of_ ev1
__or__ ev2 have been emitted.

``` ruby
 >> plan.add(ev1 = EventGenerator.new)
 >> plan.add(ev2 = EventGenerator.new)
 >> and_ev = ev1 & ev2
 >> or_ev  = ev1 | ev2
 >> and_ev.on { |ev| puts "AND" }
 >> or_ev.on { |ev| puts "OR" }
 >> ev1.emit
 OR
 >> ev2.emit
 AND
```

You did not have to add the and\_ev and or\_ev events to the plan. This is because
they are linked to ev1 and ev2, so Roby added them to the plan automatically.
{: .info}

You can see that the "OR" event is emitted only once. If you want it to be
emitted every time one of its sources are, you would do:

``` ruby
 >> or_ev = ev1 | ev2
 >> or_ev.on { |ev| puts "OR" }
 >> or_ev.on { |ev| or_ev.reset }
 >> ev2.emit
 OR
 >> ev2.emit
 OR
 >> ev1.emit
 OR
```

In the same way, the "AND" event is emitted only once. You can also use #reset
to make it emit again.

Common errors when manipulating events
---------------------------------------

A common error is to try to manipulate an event which is not included in a
plan (objects are included in plans through the #add call). In that case,
the event is not executable and you will get the following error:

``` ruby
>> ev = EventGenerator.new { }
>> ev.call
Roby::EventNotExecutable: #call called on #<Roby::EventGenerator:0x484aa3c0> which is a non-executable event
>> ev.emit
Roby::EventNotExecutable: #emit called on #<Roby::EventGenerator:0x484aa3c0> which is a non-executable event
```

Another common error is to try to call (or signal) and event that is non
controllable. In that case, Roby raises a {rdoc_class: EventNotControlable}
exception.

``` ruby
>> plan.add(ev = EventGenerator.new)
>> ev.call
Roby::EventNotControlable: #call called on a non-controllable event
>> source = EventGenerator.new
>> source.signal(ev)
Roby::EventNotControlable: trying to establish a signal from #<Roby::EventGenerator:0x484a77f8> to #<Roby::EventGenerator:0x484aab88> which is not controllable
```

