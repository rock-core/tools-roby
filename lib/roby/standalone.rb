require 'roby'
Dir.chdir(APP_DIR)
Roby.app.setup_global_singletons
Roby.app.setup_drb_server

