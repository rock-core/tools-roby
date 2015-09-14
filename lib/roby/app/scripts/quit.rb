require 'roby/app/scripts'

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

Roby::App::Scripts::InterfaceScript.run do |interface|
    Robot.info "connected"
    interface.quit
    begin
        Robot.info "waiting for remote app to terminate"
        display_notifications(interface)
    rescue Roby::Interface::ComError
        Robot.info "closed communication"
    rescue Interrupt
        Robot.info "CTRL+C detected, forcing remote quit. Press CTRL+C once more to terminate this script"
        interface.quit
        display_notifications(interface)
    end
end
