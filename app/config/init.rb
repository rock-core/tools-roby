# This file is called to do application-global configuration. For configuration
# specific to a robot, edit config/NAME.rb, where NAME is the robot name.
#
# Enable some of the standard plugins
# Roby.app.using 'fault_injection'
# Roby.app.using 'subsystems'

##############################
# Sets some configuration options
#
# If true, the engine aborts if an uncaught task or event exception is
# received. Defaults to false, as Roby has meaningful ways to handle those
#  Roby.app.abort_on_exception = false
#
# If true, the engine aborts if an exception is raised outside of the reach of
# the plan-based error management. Defaults to true, as there is no safe ways
# to handle those.
#  Roby.app.abort_on_application_exception = true

##############################
# Set the decision control object to be used during execution (can also be
# done per-robot)
#
# Roby.control = Roby::DecisionControl.new


##############################
# Set the scheduler object to be used during execution (can also be done
# per-robot)
#
# require 'roby/schedulers/basic'
# Roby.scheduler = Roby::Schedulers::Basic.new

