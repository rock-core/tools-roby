require File.join(APP_DIR, 'config', 'init.rb')

# Here, we are supposed to be initialized. Setup the Roby environment itself
RobyInit()

# Load the controller
include Roby
load File.join(APP_DIR, "controllers", "#{ROBOT}.rb")

