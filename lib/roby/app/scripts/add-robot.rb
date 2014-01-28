require 'roby/app/installer'

begin
    Roby.app.require_app_dir
rescue Exception => e
    STDERR.puts Roby.console.color(e.message, :red)
    exit 1
end

unless robotname = ARGV.shift
    STDERR.puts "No robot name given on command line"
    STDERR.puts parser
    exit(1)
end

installer = Roby::Installer.new(Roby.app)
installer.robot(robotname)

