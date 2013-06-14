require 'roby/app/installer'

Roby.app.require_app_dir
unless robotname = ARGV.shift
    STDERR.puts "No robot name given on command line"
    STDERR.puts parser
    exit(1)
end

installer = Roby::Installer.new(Roby.app)
installer.robot(robotname)

