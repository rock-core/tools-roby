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

MetaRuby.keep_definition_location = false

list_tests = false
coverage_mode = false
only_self = false
all = true
testrb_args = []
excluded_patterns = []
parser = OptionParser.new do |opt|
    opt.banner = "#{File.basename($0)} test [ROBY_OPTIONS] -- "\
                 '[MINITEST_OPTIONS] [TEST_FILES]'
    opt.on('--self', 'only run tests that are present in this bundle') do |val|
        only_self = true
    end
    opt.on('--not-all', 'run all the tests found in the bundle, regardless of whether '\
                        'they are loaded by the robot configuration') do |val|
        all = false
    end
    opt.on('--really-all', 'load all models, and run all the tests '\
                           'found in the bundle') do |val|
        app.auto_load_models = true
        all = true
    end
    opt.on('--exclude PATTERN', String, 'do not run files '\
           'matching this pattern') do |pattern|
        pattern = "**/#{pattern}" if pattern[0, 1] != '/'
        excluded_patterns << pattern
    end
    opt.on('--distributed', 'access remote systems while setting up '\
                            'or running the tests') do |val|
        Roby.app.single = !val
    end
    opt.on('--list', 'lists the test files that are executed, '\
                     'but does not execute them') do
        list_tests = true
    end
    opt.on('-l', '--live', 'run tests in live mode') do |val|
        Roby.app.simulation = !val
    end
    opt.on('-k', '--keep-logs', 'keep all logs') do
        Roby.app.public_logs = true
    end
    opt.on('--ui', 'tell plugins and/or robot configurations to load their '\
                   'UI frameworks of choice. This does not imply --interactive') do
        Conf.ui = true
    end
    opt.on('-i', '--interactive', 'allow user interaction during tests') do
        Roby.app.automatic_testing = false
    end
    opt.on('--coverage', 'generate code coverage information. This autoloads '\
                         'all files and task context models to get '\
                         'a full coverage information') do |name|
        coverage_mode = true
    end
    opt.on '--help' do
        pp opt
        Minitest.run ['--help']
        exit 0
    end
    Roby::Application.common_optparse_setup(opt)
end

test_files = parser.parse(ARGV)
test_files.delete_if do |arg|
    if arg.start_with?('-')
        testrb_args << arg
        true
    end
end

if test_files.empty?
    MetaRuby.keep_definition_location = true
end

if coverage_mode
    require 'simplecov'
    SimpleCov.start
end

exception = Roby.display_exception do
    Roby.app.setup
    if Roby.app.public_logs?
        STDOUT.puts "Test logs are saved in #{Roby.app.log_dir}"
    end
    begin
        Roby.app.prepare

        if test_files.empty?
            test_files = app.discover_test_files(
                all: all, only_self: only_self
            ).map(&:first)
            self_files, dependent_files =
                test_files.partition { |f| app.self_file?(f) }
            test_files = self_files.sort + dependent_files.sort
            if list_tests
                puts "Would load #{test_files.size} test files"
                test_files.each do |path|
                    puts "  #{path}"
                end

                all_existing_tests = app.find_dirs('test', order: :specific_first, all: !only_self).inject(Set.new) do |all, dir|
                    all.merge(Find.enum_for(:find, dir).find_all { |f| f =~ /\/test_.*\.rb$/ && File.file?(f) }.to_set)
                end
                not_run = (all_existing_tests - test_files.to_set)
                if !not_run.empty?
                    puts "\nWould NOT load #{not_run.size} tests"
                    not_run.to_a.sort.each do |not_loaded|
                        puts "  #{not_loaded}"
                    end
                end
                exit 0
            end
        end

        test_files.each do |arg|
            next if excluded_patterns.any? { |pattern| File.fnmatch?(pattern, arg) }
            require arg
        end
        passed = Minitest.run(testrb_args)
        exit(1) unless passed
    ensure
        Roby.app.shutdown
        Roby.app.cleanup
    end
end
exit(exception ? 1 : 0)
