require 'roby'
require 'roby/test/spec'
require 'optparse'
require 'test/unit'

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
    opt.on("--coverage", "generate code coverage information. This autoloads all files and task context models to get a full coverage information") do |name|
        coverage_mode = true
    end
    Roby::Application.common_optparse_setup(opt)
end

remaining_arguments = parser.parse(ARGV)

if coverage_mode
    app.auto_load_models = true
    require 'simplecov'
    SimpleCov.start
end

Roby.display_exception do
    Roby.app.setup
    Roby.app.prepare

    begin
        tests = Test::Unit::AutoRunner.new(true)
        tests.options.banner.sub!(/\[options\]/, '\& tests...')
        if remaining_arguments.empty?
            remaining_arguments = Roby.app.find_files_in_dirs('test', 'ROBOT', :path => [Roby.app.app_dir], :all => true, :order => :specific_first, :pattern => /^(?:suite_|test_).*\.rb$/)
        end

        has_tests = tests.process_args(testrb_args + remaining_arguments)
        if has_tests
            files = tests.to_run
            $0 = files.size == 1 ? File.basename(files[0]) : files.to_s
            result = tests.run
        end
    ensure
        Roby.app.cleanup
    end
end

