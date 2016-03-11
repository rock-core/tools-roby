---
title: Dependency
keywords: roby, robotics, rock, framework, ide
permalink: "/task_relations/dependency/"
---

Available as Roby::TaskStructure::Dependency

See `TaskStructure::DependencyGraphClass::Extension` for the list
of methods that are defined on Roby::Task and
Roby::TaskStructure::DependencyGraphClass for the methods accessible on the
relation graph.

Semantics
---------
The dependency relation defines that a task requires the result, or the
execution, of another task. If task t1 is a parent of task t2 in that relation,
it means that the successful execution of t1 requires the successful execution
of t2.

To add a new dependency relation between two tasks +t1+ and +t2+, simply do

``` ruby
t1.depends_on t2
```

More specifically, the dependency relation expresses that +t2+ must achieve a
specific thing for +t1+. In Roby, such an achievement is of course defined by a
set of events.

So, in Roby terms, _depends\_on_ specifies that +t2+ should achieve a specific
thing for +t1+. By default, that achievement is the _success_ of the child task.
That can be changed through the +:success+ option of _depends\_on_. By default,
that set is <tt>:success</tt> (i.e. +t1+ requires a successful execution of
+t2+). As another example, the following

``` ruby
t1.depends_on t2, :success => [:updated]
```

specifies that +t1+ needs +t2+ to emit its _updated_ event at least once. The
default is obviously equivalent to

``` ruby
t1.depends_on t2, :success => [:success]
```

A different constraint that can be specified is that some events <b>should
not</b> be emitted. That is specified through the +:failure+ option. For
instance, if it is required that +t2+ does not stop while +t1+ is running, do

``` ruby
t1.depends_on t2, :success => [], :failure => [:stop]
```

Moreover, it is possible to refine what the parent task actually needs by
specifying a __fullfilled model__ explicitely. I.e. by adding the :model
option, one can specifically tell what tasks are acceptable as children in this
particular relation. This can be used during plan transformations to replace tasks
by other tasks.

For instance:

``` ruby
# Tells that t1 needs a task that fullfills the Localization model with the
# given mode argument. Other arguments are left free.
t1.depends_on t2, :model => [Localization, :mode => :icp]
```

Both the :success and :failure options accept [event
predicates](../advanced_concepts/recognizing_patterns.html#event-predicates) as
values. 

__Important__ The dependency relation does not express any assumption on the
_succcess_ of the parent task, only (1) the conditions in which a child is not
needed anymore (the success events) and (2) the conditions in which the child
did not achieve what the parent task required (the failure events and the
unreachability of the success events). To represent e.g. a relationship between
the success of a child and the success of a parent, use the forward relation
{: .warning}

Error Conditions
----------------
The two types of errors that can occur in the context of a dependency relation
are:

 * no success event will ever be emitted
 * one of the failure events is emitted

The first condition is reached when the event predicate given for :success is
(1) static and has a "false" value. When giving simple events, it means that the
events have never been emitted and are marked [as
unreachable](../advanced_concepts/unreachability.html). For instance, the
default parameters of :success => \[:success], :failure => [] both specify that
:success is a success event __and__ that :stop without :sucess is an error (as,
once :stop is emitted, :success becomes unreachable)

In both cases, a `ChildFailedError` exception is generated. In the
first case, the failure point is the event generator that is unreachable. In the
second case, it is the event that triggered the failure. In both cases, the
explanation field contains the Roby::EventConstraints::Explanation object that
explains why the event condition has been triggered.

Relationship to Scheduling
--------------------------
The planned_by relation has an influence on both [the basic and
temporal schedulers](../advanced_concepts/scheduling.html).

