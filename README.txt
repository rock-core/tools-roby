Roby
    http://roby.rubyforge.org
    http://www.rubyforge.org/projects/roby
    http://github.com/doudou/roby (dev. repository)

Copyright (c) 2006-2008
    Sylvain Joyeux <sylvain.joyeux@m4x.org>
    LAAS/CNRS <openrobots@laas.fr>

This work is licensed under the CeCiLL-B license, which is a free software
license with the same spirit than the BSD license. See License.txt for details


== What is Roby ?

Roby is a plan manager: it allows to represent, execute and adapt a plan, which
is a set of past, present and future activities of a robot along with the
information needed to supervise their execution.

Roby is:
* a task/event model in which one can represent the activities (Roby::Task) and
  the noticeable situations during execution (Roby::EventGenerator,
  Roby::Task.event).
* a set of task relations describing the interactions between the activities
  (Roby::TaskStructure).
* a set of event relations describing the reaction the system should have in
  response to some situations (Roby::EventStructure).
* error management tools which allow to catch errors during execution and
  repair them (i.e. let the system manage the error).
* a mean to modify the plan as it is being executed (Roby::Transaction)
* (G)UI tools for interacting/controlling the living system.
* all of that in a multi-robot context.

= Related publications

== Installation
= External dependencies
* The Roby engine needs 
  * +utilrb+, which is available on RubyForge[http://utilrb.rubyforge.org] as a gem
  * +utilmm+, which is available on SourceForge
  * Facets, available on RubyForge[http://rubyforge.org/projects/facets] or as a gem
  * ActiveSupport, available on RubyForge[http://rubyforge.org/projects/activesupport] or as a gem
  * the Boost/Graph C++ library

* the test suite needs also
  * FlexMock, available on RubyForge[http://rubyforge.org/projects/flexmock]

* finally, the GUI requires {QtRuby >=
  1.4.9}[http://rubyforge.org/projects/korundum], SVG export requires QtRuby to
  be built with Qt >= 4.3

= Installing the easy way

Roby is available on RubyForge as a gem. After having installed the C++ dependencies (boost/graph and utilmm), you can simply install it with

  gem install roby

= Installing from source

First, install all the required dependencies. Then, get the sources either
from a release tarball or the RubyForge git
repository[http://rubyforge.org/projects/roby], or from the development
one[http://github.com/doudou/roby].

Once the source is installed, run
  rake setup

