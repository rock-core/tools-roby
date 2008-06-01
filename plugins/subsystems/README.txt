
http://rubyforge.org/projects/roby

= Subsystems plugin for Roby

This is a plugin for the Roby robotic control framework. It allows to generate
an initial plan in which a set of common subsystems (sensors, localization,
...) are already initialized, easing later the writing and management of the
planning methods for other, more dynamical actions.

== Usage

A set of services can be defined on <tt>State.services</tt> like this:

  State.services.localization = 'pom'
  State.services.camera = 'cam'

Then, at controller initialization and before the controller file is actually
loaded, the corresponding planning methods are called to generate a plan in which those
subsystems are present:

  planner.localization(:id => 'pom')
  planner.camera(:id => 'cam')

The returned tasks are also started, in order. The controller file gets loaded
only when the subsystems are ready (i.e. their start events are emitted).

== Enabling the plugin

The plugin must be enabled in the configuration files (i.e. either in
<tt>config/init.rb</tt> or in one of the robot-specific files) through a call
to Roby.app.using:

  Roby.app.using 'subsystems'

== License:

This work is licensed under the CeCiLL-B license, which is a free software
license similar to the BSD license. See License.txt for details.

