---
title: Creating plugins
keywords: roby, robotics, rock, framework, ide
permalink: "/plugins/creating_plugins/"
---

Plugins are dynamically-loaded Ruby files that can hook into the Roby main code
using modules.

Defining and declaring plugins
------------------------------

A plugin defines an application plugin object. This object is used by
{rdoc_class: Application} to integrate the plugin initialization and teardown code into
the Roby application dataflow. This object can define the following methods. If
a plugin application object does *not* provide a method, it is simply ignored.

``` ruby
class Plugin
  # Load configuration files (YAML and Roby)
  # Do not load task models. That is done by
  # require_models
  def load(app)
  end
  # Set up things based on the configuration
  # loaded in #load
  def setup(app)
  end
  # Load files that define new task/event models
  # This is done after Roby loaded the standard
  # task/event model tasks
  def require_models(app)
  end
  # Startup the controller. The main execution engine
  # is already started at this point. The method
  # should yield to the given block, and clean up
  # when it returns.
  def run(app, &block)
  end

  # Start any service needed in distributed context.
  # It is called when scripts/distributed starts
  def start_distributed(app)
  end
  # Stop any service needed in distributed context.
  # It is called when scripts/distributed quits
  def stop_distributed(app)
  end
  # Start any service needed for live log display
  # It is called when scripts/server starts
  def start_server(app)
  end
  # Stop any service needed for live log display
  # It is called when scripts/server quits
  def stop_server(app)
  end
end
```

This plugin object is then declared using Roby::Application.register_plugin:

``` ruby
Application.register_plugin(plugin_name, plugin_object) do
  [code to be executed when the plugin is loaded]
end
```

This declaration has to be added to an app.rb file. Roby will automatically
require all app.rb files it can find in the ROBY_PLUGIN_PATH environment
variable. Then, when a plugin gets loaded using Application.using(plugin_name),
the associated block is called and the plugin object's methods will get called
when the controller starts.

