---
title: Recognizing patterns in plans
keywords: roby, robotics, rock, framework, ide
permalink: "/advanced_concepts/recognizing_patterns/"
---

Plan Queries and Task Matchers {#plan-queries}
-----------------------------
Roby plan structure is semantically very rich: it allows to very finely
represent the relationships that tasks and events have with each other. In
principle, one could use __plan patterns__ to recognize situations or specific
behaviours in a plan (and act upon it).

Defining a pattern in the plan and testing for it is done by task matchers
(`TaskMatcher`). Task matchers are objects that allow to test
whether a certain task object match some criteria.  The task matchers are
created by calling #match on the type of tasks that we want to match. For
instance, to create a match object for running Localization tasks, one would do

``` ruby
matcher = Localization.match.running
```

One can also match the task's surroundings

``` ruby
matcher = MoveTo.match.with_child(Localization.match.running).pending
```

An extension of task matchers are plan queries. Plan queries are ways to
enumerate all tasks, in a plan, that match a given task match object. The big
difference with simply enumerating all tasks is that, for some of the match
predicates, queries are O(1) instead of O(n), namely:

 * task model
 * task state (running, pending, finished)

For instance, to match all running tasks that fullfill the MoveTo model:

``` ruby
set = plan.find_tasks(MoveTo).
  running
set.each do |task|
  pp task
end
```

To match all tasks that fullfill the MoveTo model and have a pending (not yet
running) child that fullfill the Localization model

``` ruby
plan.find_tasks(MoveTo).
  running.
  with_child(Localization.match.pending)
```

Event Predicates {#event-predicates}
----------------
Event predicates (or, in full, unbounded event predicates) are a tool that
allows to decide whether the history of a certain task matches a pattern or not.
The event predicate being the representation of that pattern.

They are created from symbols (which are the names of the events that should be
matched). For instance:

``` ruby
:start.followed_by(:blocked)
```

will return an instance of `EventConstraints::UnboundTaskPredicate`
or of one of its subclasses that can then be evaluated on a task. See
`EventConstraints::UnboundPredicateSupport` for the list of methods
available on symbols and `EventConstraints::UnboundTaskPredicate`
for the predicate interface, which allows to logically combine predicates with
each other.

One very important aspects of these predicates is the ability to say whether the
predicate may change its value in the future or not
(UnboundTaskPredicate#static?). This is done through the notion of event
unreachability. Moreover, the predicates can give an __explanation__ of why they
have the value they have and/or why they won't change value anymore. This
explanation is formed as a set of events, a set of non-emitted events (i.e.
generators that should have emitted an event and did not) and a set of
unreachable events.
