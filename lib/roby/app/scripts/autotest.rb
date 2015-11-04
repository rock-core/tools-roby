require 'autorespawn'
require 'roby'
require 'roby/test/spec'
require 'optparse'

Robot.logger.level = Logger::WARN

app = Roby.app
app.require_app_dir
app.public_logs = false
app.single = true
app.simulation = true
app.testing = true
app.auto_load_models = false
app.manage_drb = false

modes = []
robots = []
cmdline_args = []
all_robots = false
server_pid = nil

parser = OptionParser.new do |opt|
    opt.on('--verbose', 'display INFO messages') do |val|
        cmdline_args << "--verbose"
        Roby.logger.level = Logger::INFO
    end
    opt.on('--debug', 'display DEBUG messages') do |val|
        cmdline_args << "--debug"
        Roby.logger.level = Logger::DEBUG
    end
    opt.on('-s', '--sim', 'run test in simulation (stubbing)') do |val|
        modes << '--sim'
    end
    opt.on("-l", "--live", "run tests in live mode") do |val|
	modes << '--live'
    end
    opt.on '--all-robots', 'run tests for all robots' do
        all_robots = true
    end
    opt.on('-r NAME', '--robot=NAME[,TYPE]', String, 'a robot name and type to add to the test matrix') do |name|
        robots << name
    end
    opt.on("-k", "--keep-logs", "keep all logs") do |val|
	cmdline_args << '--keep-logs'
    end
    opt.on('--server=PID', Integer, 'the minitest server PID (used to generate a drbunix path)') do |pid|
        server_pid = pid
        cmdline_args << "--server" << pid.to_s
    end
end

test_files = parser.parse(ARGV)

if !server_pid
    require 'roby/app/test_server'
    require 'roby/app/autotest_console_reporter'
    manager = Autorespawn::Manager.new(name: Hash[cmdline: "#{$0} #{ARGV.join(" ")}"])
    server_pid = Process.pid
    server = Roby::App::TestServer.start(Process.pid)
    server_console_output = Roby::App::AutotestConsoleReporter.new(server, manager)
    cmdline_args << '--server' << server_pid.to_s
else
    DRb.start_service
    manager = Autorespawn.new
end

require 'roby/app/test_reporter'
reporter = Roby::App::TestReporter.new(Process.pid, manager.name, server_pid)

Roby.display_exception do
    Roby.app.base_setup
    if all_robots
        robots = Roby.app.robots.names
    end

    process_id = Autorespawn.name || Hash.new

    if robots.size > 1
        reporter.discovery_start
        robots.each do |name|
            spawner.add_slave(
                Gem.ruby, '-S', $0,
                'autotest', "--robot=#{name}", *modes, *cmdline_args, *test_files,
                name: process_id.merge(robot: name))
        end
        reporter.discovery_finished
        manager.run
        exit 0
    end

    if robot_name = robots.first
        process_id = process_id.merge(robot: robot_name)
        cmdline_args << "--robot=#{robot_name}"
    end

    if modes.size > 1
        reporter.discovery_start
        modes.each do |m|
            manager.add_slave(
                Gem.ruby, '-S', $0, 'autotest', m, *cmdline_args, *test_files)
        end
        reporter.discovery_finished
        manager.run
        exit 0
    end

    if m = modes.first
        Roby.app.simulation = (m != '--live')
        process_id = process_id.merge(mode: m.gsub(/^--/, ''))
        cmdline_args << m
    end
    if robot_name
        Roby.app.robot robot_name
    end

    if test_files.size != 1 || !Autorespawn.slave?
        Roby.app.setup
        begin
            reporter.discovery_start
            if test_files.empty?
                test_files = Roby.app.each_model.map do |m|
                    [m, Roby.app.test_file_for(m)]
                end.compact
            else
                test_files = test_files.map { |path| [nil, path] }
            end
            test_files.each do |model, path|
                if model
                    process_id = process_id.merge(model: model.name)
                end
                
                manager.add_slave(
                    Gem.ruby, '-S', $0, 'autotest', *cmdline_args, path,
                    name: process_id.merge(path: path))
            end
            reporter.discovery_finished
            manager.run
        ensure Roby.app.cleanup
        end
        exit 0
    end

    manager.on_exception do |e|
        reporter.exception(e)
    end
    manager.run do
        Roby.app.setup
        require test_files.first
        reporter.test_start
        begin
            Roby.app.prepare

            begin
                Minitest.__run reporter, Hash.new
            rescue Interrupt
                warn "Interrupted. Exiting..."
            end
        ensure
            reporter.test_finished
            Roby.app.cleanup
        end
    end
end


