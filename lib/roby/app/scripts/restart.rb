# frozen_string_literal: true

require "roby/app/scripts"
require "roby/interface/async"

def display_notifications(interface)
    while !interface.closed?
        interface.poll
        while interface.has_notifications?
            _, (source, level, message) = interface.pop_notification
            Robot.send(level.downcase, message)
        end
        while interface.has_job_progress?
            _, (kind, job_id, job_name) = interface.pop_job_progress
            Robot.info "[#{job_id}] #{job_name}: #{kind}"
        end
        sleep 0.01
    end
end

script = Roby::App::Scripts::InterfaceScript.new
error = Roby.display_exception do
    script.run do |interface|
        Robot.info "connected"
        interface.restart
        begin
            Robot.info "waiting for remote app to terminate"
            display_notifications(interface)
        rescue Roby::Interface::ComError
            Robot.info "closed communication"
        rescue Interrupt
            Robot.info "CTRL+C detected, forcing current process to quit. Press CTRL+C once more to terminate this script"
            interface.quit
            display_notifications(interface)
        end
    end
end
if error
    exit 1
end

host, port = script.host
async = Roby::Interface::Async::Interface.new(host, port: port)
start = Time.now
while !async.connected? && (Time.now - start) < 10
    async.poll
    sleep 0.1
end

if !async.connected?
    Robot.fatal "timed out"
else
    Robot.info "new instance ready"
end
