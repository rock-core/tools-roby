---
title: Defining new relations
keywords: roby, robotics, rock, framework, ide
permalink: "/task_relations/new_relations/"
---

This page will detail the mechanisms Roby has to define new relations (tasks or
events), as well as how relations can be plugged into the overall execution
system.

Relation spaces
---------------

Generally speaking, relations are graphs that allow to link plan objects _of the
same type_ (i.e. tasks together and/or events together).

To ease relation management, relations on one given object are gathered in a
relation space (instance of `RelationSpace`). Two relation spaces
are defined by default:

``` ruby
TaskStructure = RelationSpace(Task)
EventStructure = RelationSpace(EventGenerator)
```

where `Task` is the task class and `EventGenerator` are
the objects that emit events

In the API, EventGenerator is the plan object that has a command and can emit
events (i.e. the class on which #emit and #call is defined). Event is the
representation of an emission (i.e. it is created by #emit and stored in
histories).
{.block}

Defining new relations
----------------------

When you define a relation, you basically declare that a certain type of object
(the object on which the associated relation space applies) can be part of the
given relation. Moreover, you add methods on the same object that allow to
easily inspect the relation graph.

A new relation is created with RelationSpace#relation. Its first argument is the
constant name of the newly created relation, which is added to the associated
relation space.

For instance, to define [the Dependency relation](dependency.html), one does:

``` ruby
TaskStructure.relation 'Dependency'
```

See the documentation of `RelationSpace`#relation for the various
parametrization that is possible to do on a relation.

Management of information embedded in a relation
-----------------------------------------------

Relations can have embed edge information (it is on by default). This
information can be an arbitrary Ruby object and allows to describe specific
edges in the relation. For instance, for the Dependency relation, this object is
a hash in which various parameters as the child's roles, the set of success
events and so on are saved.
If a relation does *not* have the need for additional information, the <tt>:noinfo</tt>
flag should be set in the relation declaration.
   
Information embedded in this object *must* no directly refer to the parent or
child, as during execution this parent/child can change (for instance through
Plan#replace\_task). In the dependency relation, the <tt>success</tt> set is
defined as event names, not actual EventGenerator objects for this very reason.

Finally, for some relation, it can be meaningful to 'merge' these additional
information objects, i.e. to represent the union of the constraints of what was
previously two separate relations. This happens in particular in a replacement
context: a parent task A has two children B and C, but C is used to replace B.
In the end, the A => C relation must therefore contain the information that was
embedded in both the A => B and the original A => C relations.

Supporting this is done by defining a merge\_info method on the relation object:

``` ruby
module TaskStructure
    relation 'Dependency', ... do
    end

    def Dependency.merge_info(old, new)
    end
end
```

Plugging into the constraint verification mechanism
---------------------------------------------------

As presented [in the concepts section](../concepts), the execution cycle is split
into an event propagation phase (where things happen) and a constraint
verification phase (where things are checked).

It is the job of each relation to check that the constraints it represents are
actually met. Structure checks can be added either on a per-plan basis or on all
running plans.

In practice, adding a structure checking method is done by defining a
check\_structure method on the relation object:

``` ruby
module TaskStructure
    relation 'Dependency', ... do
    end

    def Dependency.check_structure(plan)
    end
end
```

This method must return an array of exception objects, that must all be
subclasses of `LocalizedError`. On a general level, these exception
objects must assign the problem to one particular plan object (event, event
generator or task). This assignation will be used by the error propagation
mechanism to decide what to do with it.

