require 'roby'
Dir.chdir(APP_DIR)
Roby.app.setup_global_singletons
DRb.start_service "druby://localhost:0"

