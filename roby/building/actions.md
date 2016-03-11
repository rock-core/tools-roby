---
title: Actions
keywords: roby, robotics, rock, framework, ide
permalink: "/building/actions/"
---

As explained in [the introduction of this section](index.html), the action
interface presented on this page has two roles:

 - to define actual behaviours, that can run on the robot, by coordinating sets
   of smaller behaviours
 - to present this set of behaviours to the rest of the Roby application as well
   as to outside (for instance to a user or to an automated planner). This
   aspect of the usage of the action interfaces is covered in [another
   section](interacting)

This section will describe the capabilities of this interface to __build
plans__. Modifying running plans is a bit of a harder problem, so we keep it
for a different time.

In general, an action interface is defined by creating a subclass of
`Roby::Actions::Interface`. Action interfaces are defined in
a file in the models/actions/ subfolder of the Roby application. The file name is usually
the snake_case version of the class name, as e.g. my_actions.rb for the MyAction
class:

~~~ ruby
class MyAction < Roby::Actions::Interface
end
~~~

Roby expects an action interface class called Main to exist per Roby
application, and registers it automatically. The Roby app template creates such
a class in models/actions/main.rb (or model/actions/myrobot/main.rb for
per-robot action interfaces). There is generally no point of defining another
one. To foster reuse of action definitions, one creates an action library:

~~~ ruby
module MyApp
  module Movements
    action_library
  end
end
~~~

Action libraries accept the same statements than the action interfaces, but can
be added to action interfaces (or other action libraries):

~~~ ruby
class Main < Roby::Actions::Interface
  use_library MyApp::Movements
end
~~~

Defining actions
----------------
Generally speaking, an __action__ is simply "something" that returns a Roby
task.  It is up to the action to create all the tasks required for the
behaviour, bind them together using Roby's plan building API and return the
toplevel task that will represent the action.

This page will not dwelve too much into how to do this. Higher-level
representations allow to define actions without having to dwelve too much into
Roby's plan model and plan building API.

In any case, an action definition always start with an action _description_.
This is done by calling the "describe" statement in the context of the action
interface class or action library module and then chaining description calls on
the returned object (which is of type `Actions::ActionModel`).

~~~ ruby
class Main
  describe("move").
    required_arg('speed', 'the speed it should move at in m/s').
    optional_arg('time', 'how long it should move in seconds').
    returns(MoveTo)
  ... define the actual action ...
end
~~~

The way the action name is retrieved depends on the action type. We will
describe each action type later in this page and talk about this.

One very important attribute is the 'returns' statement. It defines the type of
task this action is going to return. If it is not provided, one is created by
the action interface using the action's name but CamelCased. I.e. a move_to
action would return, by default, a MoveTo task type that is defined in the
action's namespace (e.g. Main::MoveTo)

Raw Interface
-------------
"Raw" actions are the one that are building Roby plans using Roby's plan
building interface. They are defined as plain methods on the action interface
class or the action library module. The action name is the name of the method.
This interface requires a deep understanding of the Roby plan model.
Higher-level coordination models (presented [on the next
page](action_coordination.html)) are most often than not enough.

If the action description specifies arguments, then the method must accept to be
called with an argument of type Hash that is going to get the arguments. If it
accepts only optional arguments, it is best practice to make that argument
optional.

__Important__ only methods that are directly preceded by a #describe block are
turned into actions. You can freely add "helper" methods to the interface.
{: .block}

~~~ ruby
class Main
  describe("move").
    required_arg('speed', 'the speed it should move at in m/s').
    optional_arg('time', 'how long it should move in seconds')
  def move_to(arguments)
    Main::MoveTo.new(:speed => arguments[:speed], :time => arguments[:time])
  end
end
~~~

One can always call another action from within a raw action method to integrate
the toplevel task of that action. However, you should really see the returned
value as an interface (as it should) and never assume anything about the
subtasks of the returned task. In particular, some actions will return you a
[planning pattern](runtime.html#planning-pattern) which, at the time the action
is called, will have no children.

