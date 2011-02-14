require 'roby/log/server'

app = Roby.app

if Roby.display_exception { app.setup }
    exit(1)
end

DRb.start_service "druby://:0"

begin
    app.start_server

    Roby::Log::Server.info "ready"
    sleep
rescue Interrupt
ensure
    Roby::Log::Server.info "quitting"
    app.stop_server
end
Roby::Log::Server.info "quit"

