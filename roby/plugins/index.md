---
title: Plugins
keywords: roby, robotics, rock, framework, ide
permalink: "/plugins/index/"
---

Plugins are extensions to the Roby models and engine. 

Plugins are searched in the ROBY_PLUGIN_PATH environment variable. Roby will
search for the plugin's app.rb file in each of the directories listed in this
environment variable, and load this file to get the plugin declaration.

For instance, the Orocos/Roby plugin is stored in the lib/orocos/roby/ directory
of the orocos.rb software package. This directory contains the plugin's app.rb
file, so one has to add /path/to/orocos/rb/lib/orocos/roby to ROBY_PLUGIN_PATH
to make the plugin available to Roby controllers.

Now, two things are needed to use a given plugin in a Roby controller:

 * one must add the plugin-specific files to the controller. This is done with

``` bash
roby init -m fault_injection
```

 * one must declare that the plugin should be loaded. This is usually done
   globally in config/init.rb, but can also be done on a per-robot basis. This
   is done by adding the following line to the relevant initialization file:

``` ruby
Roby.app.using "fault_injection"
``` 
   

