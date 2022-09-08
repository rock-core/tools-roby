# frozen_string_literal: true

# This file is called to do application-global configuration. For configuration
# specific to a robot, edit config/NAME.rb, where NAME is the robot name.
#
# Here are some of the most useful configuration options

# Use backward-compatible naming and behaviour, when applicable
#
# For instance, a Syskit app will get the task context models defined at
# toplevel as well as within the OroGen namespace
Roby.app.backward_compatible_naming = false

# Set the module's name. It is normally inferred from the app name, and the app
# name is inferred from the base directory name (e.g. an app located in
# bundles/flat_fish would have an app name of flat_fish and a module name of
# FlatFish
#
# Roby.app.module_name = 'Override'

# Whether Roby::Tasks::ExternalProcess should start the subprocess when executed
# under `roby test` (false) or not (true)
#
# The default is false for backward compatibility reasons. We recommend setting it
# to true, and overriding it in tests as needed by setting the specific task's
# stub_in_roby_simulation_mode argument
#
# require "roby/tasks/external_process"
# Roby::Tasks::ExternalProcess.stub_in_roby_simulation_mode = false
