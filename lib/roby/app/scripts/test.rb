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

coverage_mode = false
testrb_args = []
parser = OptionParser.new do |opt|
    opt.on("--distributed", "access remote systems while setting up or running the tests") do |val|
	Roby.app.single = !val
    end
    opt.on("-l", "--live", "run tests in live mode") do |val|
	Roby.app.simulation = !val
    end
    opt.on("-k", "--keep-logs", "keep all logs") do |val|
	Roby.app.public_logs = true
    end
    opt.on("-i", "--interactive", "allow user interaction during tests") do |val|
	Roby.app.automatic_testing = false
    end
    opt.on("-n", "--name NAME", String, "run tests matching NAME") do |name|
	testrb_args << "-n" << name
    end
    opt.on('-v', '--verbose', String, "run tests in verbose mode") do |verbose|
        testrb_args << '-v'
    end
    opt.on("--coverage", "generate code coverage information. This autoloads all files and task context models to get a full coverage information") do |name|
        coverage_mode = true
    end
    opt.on('--server PORT', Integer, 'the minitest server port') do |server_port|
        testrb_args << "--server" << server_port.to_s
    end
    Roby::Application.common_optparse_setup(opt)
end

remaining_arguments = parser.parse(ARGV)
if Roby.app.public_logs?
    STDOUT.puts "Test logs are saved in #{Roby.app.log_dir}"
end

if coverage_mode
    app.auto_load_models = true
    require 'simplecov'
    SimpleCov.start
end

Roby.display_exception do
    Roby.app.setup
    begin
        Roby.app.prepare
        # tests.options.banner.sub!(/\[options\]/, '\& tests...')
        if remaining_arguments.empty?
            remaining_arguments = Roby.app.
                find_files_in_dirs('test', 'ROBOT',
                                   path: [Roby.app.app_dir],
                                   all: true,
                                   order: :specific_first,
                                   pattern: /^(?:suite_|test_).*\.rb$/)

            Roby.app.each_responding_plugin(:filter_test_files) do |plugin|
                remaining_arguments = plugin.filter_test_files(Roby.app, remaining_arguments)
            end
        end
        remaining_arguments.each do |arg|
            require arg
        end
        Minitest.run testrb_args
    ensure
        if profiling
            PerfTools::CpuProfiler.stop
        end
        Roby.app.cleanup
    end
end

