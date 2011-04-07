require 'roby'
if defined? APP_DIR
    Dir.chdir(APP_DIR)
end
Roby.app.setup_global_singletons
DRb.start_service "druby://localhost:0"

