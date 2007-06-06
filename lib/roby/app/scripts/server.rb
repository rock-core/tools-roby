require 'roby/log/server'
require File.join(File.dirname(__FILE__), '..', 'load')
require File.join(File.dirname(__FILE__), '..', 'run')

app = Roby.app
app.droby['host'] = ":0"
app.setup
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

