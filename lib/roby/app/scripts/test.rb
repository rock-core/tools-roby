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

list_tests = false
coverage_mode = false
testrb_args = []
parser = OptionParser.new do |opt|
    opt.on('--all', 'auto-load all models and the corresponding tests') do |val|
        app.auto_load_models = true
    end

    opt.on("--distributed", "access remote systems while setting up or running the tests") do |val|
	Roby.app.single = !val
    end
    opt.on('--list', 'lists the test files that are executed, but does not execute them') do
        list_tests = true
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
    opt.on('--stackprof[=FILE]', String, 'run tests under stackprof (requires the minitest-stackprof gem)') do |path|
        testrb_args << "--stackprof"
        if path
            testrb_args << path
        end
    end
    Roby::Application.common_optparse_setup(opt)
end

test_files = parser.parse(ARGV)

if coverage_mode
    require 'simplecov'
    SimpleCov.start
end

Roby.display_exception do
    Roby.app.setup
    if Roby.app.public_logs?
        STDOUT.puts "Test logs are saved in #{Roby.app.log_dir}"
    end
    begin
        Roby.app.prepare
        # tests.options.banner.sub!(/\[options\]/, '\& tests...')
        if test_files.empty?
            test_files = app.each_test_file.map(&:first)
        end

        if list_tests
            puts "Would load #{test_files.size} test files"
            test_files.sort.each do |path|
                puts "  #{path}"
            end
        else
            test_files.each do |arg|
                require arg
            end
            Minitest.run testrb_args
        end
    ensure
        Roby.app.cleanup
    end
end

