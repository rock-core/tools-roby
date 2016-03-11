---
title: Fault Injection <a href="../fault_injection/index.html">[API]</a>
keywords: roby, robotics, rock, framework, ide
permalink: "/plugins/standard_plugins/fault_tolerance/"
---

This is a fault injection plugin for the Roby robotic control framework. It
allows to test the management of rarely occuring events by simulating the
emission of those events. This plugin relies only on the core Roby library.

Usage
-----

The fault injection plugin can be used in a system to inject some spurious
events randomly. To set it up, one must call Application#add\_fault\_model
in the configuration files of the application. For instance,

``` ruby
Roby.app.add_fault_model P3d::Track,
      :no_path, :blocked,
      Roby::FaultInjection::Rate.new(500, 0.3)
```
  
Would inject events no\_path and blocked randomly on any task of the P3d:Track
model. The probability distribution used is a rate distribution with MTTF of
500s and base probability of 0.3. See Roby::FaultInjection in the plugin's API
documentation for the description of the available probability distributions.

Enabling the plugin
-------------------

The plugin must be enabled in the configuration files (i.e. either in
<tt>config/init.rb</tt> or in one of the robot-specific files) through a call
to Roby.app.using:

``` ruby
Roby.app.using 'fault_injection'
```

License
-------

This work is licensed under the CeCiLL-B license, which is a free software
license similar to the BSD license. See License.txt for details.

