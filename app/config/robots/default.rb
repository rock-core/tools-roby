## One can require the configuration from another robot, for instance if one has
## a common robot class with minor modifications
#
# require 'config/robots/robot_class'

# Block evaluated at the very beginning of the Roby app initialization
Robot.init do
    ## You can load plugins here
    # Roby.app.using 'fault_injection'
    # Roby.app.using 'syskit'

    ## Change the scheduler
    require 'roby/schedulers/temporal'
    Roby.scheduler = Roby::Schedulers::Temporal.new

    ## You could also change the Roby search path
    # Roby.app.search_path << "separate path"
end

# Block evaluated to load the models this robot requires
Robot.requires do
end

# Block evaluated to configure the system, that is set up values in Roby's Conf
# and State
Robot.config do
end

# Block evaluated when the Roby app is fully setup, and the robot ready to
# start. This is where one usually adds permanent tasks and/or status lines
Robot.controller do
end

# Setup of the robot's main action interface
#
# Add use statements here, as e.g.
#
#   use <%= Roby.app.module_name %>::Actions::MyActionInterface
#
# or, if you're using syskit
#
#   use_profile <%= Roby.app.module_name %>::Profiles::BaseProfile
#
Robot.actions do
end

