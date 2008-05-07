Roby
    http://roby.rubyforge.org
    http://www.rubyforge.org/projects/roby
    http://github.com/doudou/roby (dev. repository)

Copyright (c) 2006-2008
    Sylvain Joyeux <sylvain.joyeux@m4x.org>
    LAAS/CNRS <openrobots@laas.fr>

This work is licensed under the CeCiLL-B license, which is a free software
license with the same spirit than the BSD license. See License.txt for details


= What is Roby ?

Roby is a plan manager: it allows to represent, execute and adapt a plan, which
is a representation of the past, present and future activities of a robot along
with the information needed to verify that their executin is going well, and to
manage errors.

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

== Related publications

Roby is the result of my PhD. As such, my PhD thesis can be considered as a
design document for the system. If you want an overview of the principles, you
can also refer to the two publications I published.

See http://roby.rubyforge.org/publications for the PDF files.

== Videos

The videos that are available show some capabilities of the system. Frankly you
will not be able to understand them unless you have already an idea on what is
going on. They are also referenced in other parts of the API documentation,
when it is meaningful.

See http://roby.rubyforge.org/videos for the available videos.

== Tutorials

A set of tutorials describe Roby's main features and let you experiment with
them:
1. the GettingStarted[link:files/doc/tutorials/01-GettingStarted_rdoc.html] tutorial makes
   you start a brand new Roby application and explains its structure.
2. the GoForward[link:files/doc/tutorials/02-GoForward_rdoc.html] tutorial shows how to create
   a simple task, how to start the Roby controller and how to interact with it
   using a shell.
3. the PlannedPath[link:files/doc/tutorials/03-PlannedPath_rdoc.html] tutorial
   shows how to create a (slightly) more complex plan, using the plan-generation
   capabilities of Roby. It also shows some properties of that plan.
4. the ExecutionCycle[link:files/doc/tutorials/04-ExecutionCycle_rdoc.html]
   tutorial describes how the plan execution actually goes, with examples from
   Roby's plan execution display (requires to have QtRuby)
5. the ErrorHandling[link:files/doc/tutorials/05-ErrorHandling_rdoc.html]
   tutorial shows how errors are represented in the system, and how it is possible
   to handle and repair them.
6. the Transaction[link:files/doc/tutorials/06-Transactions_rdoc.html]
   describes one of the most innovative ideas of Roby: the transaction. This tool
   allows safe simultaneous plan execution and modification.

= Installation

== External dependencies
* The Roby engine needs 
  * +utilrb+, which is available on RubyForge[http://utilrb.rubyforge.org] as a gem
  * +utilmm+, which is available on SourceForge[http://utilmm.sourceforge.net]
  * Facets, available on RubyForge[http://rubyforge.org/projects/facets] or as a gem
  * ActiveSupport, available on RubyForge[http://rubyforge.org/projects/activesupport] or as a gem
  * the Boost/Graph C++ library

* the test suite needs also
  * FlexMock, available on RubyForge[http://rubyforge.org/projects/flexmock]

* finally, the GUI requires {QtRuby >=
  1.4.9}[http://rubyforge.org/projects/korundum], SVG export requires QtRuby to
  be built with Qt >= 4.3

== Before installation

Whatever the way you install Roby, the only dependencies that you really have
to install yourself are util-- and (optionally) QtRuby (see above). In the case
of Util--, you must make sure that it is, after installation, available to
pkg-config by either installing it in a standard prefix (either <tt>/usr</tt>
or <tt>/usr/local</tt>) or by updating PKG_CONFIG_PATH.

Moreover, Roby uses {the jamis
template}[http://weblog.jamisbuck.org/2005/4/8/rdoc-template], which is
provided with the Roby sources (nothing needs to be done). If you want to use
another template, you can define the +ROBY_RDOC_TEMPLATE+ environment variable
before the installation. For instance, to use the standard RDoc HTML template,
do (for Unix-like shells):

  ROBY_RDOC_TEMPLATE=html rake docs

== Installing the easy way

Roby is available on RubyForge as a gem. After having installed the C++ dependencies (boost/graph and utilmm), you can simply install it with

  gem install roby

== Installing from source

First, install all the required dependencies. Then, get the sources either
from a release tarball or the RubyForge git
repository[http://rubyforge.org/projects/roby], or from the development
one[http://github.com/doudou/roby].

Once the source is installed, run
  rake setup

