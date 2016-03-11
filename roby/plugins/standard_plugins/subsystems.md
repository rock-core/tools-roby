---
title: Subsystems <a href="../subsystems/index.html">[API]</a>
routed_title: Subsystems
keywords: roby, robotics, rock, framework, ide
permalink: "/plugins/standard_plugins/subsystems/"
---

This is a plugin for the Roby robotic control framework. It allows to generate
an initial plan in which a set of common subsystems (sensors, localization,
...) are already initialized, easing later the writing and management of the
planning methods for other, more dynamical actions.

Usage
-----

A set of services can be defined on <tt>State.services</tt> in the configuration
files like this:

``` ruby
State.services.localization = 'pom'
State.services.camera = 'cam'
```

Then, at controller initialization and before the controller file is actually
loaded, the corresponding planning methods are called on MainPlanner to generate
a plan in which those subsystems are present:

``` ruby
planner.localization(:id => 'pom')
planner.camera(:id => 'cam')
```

The returned tasks are also started, in order. The controller file gets loaded
only when the subsystems are ready (i.e. their start events are emitted).

Enabling the plugin
-------------------

The plugin must be enabled in the configuration files (i.e. either in
<tt>config/init.rb</tt> or in one of the robot-specific files) through a call
to Roby.app.using:

``` ruby
Roby.app.using 'subsystems'
```

