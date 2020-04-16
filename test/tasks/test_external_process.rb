# frozen_string_literal: true

require "roby/test/self"
require "roby/tasks/external_process"

module Roby
    module Tasks
        describe ExternalProcess do
            MOCKUP = File.expand_path(
                File.join("..", "mockups", "external_process"),
                File.dirname(__FILE__))

            class MockupTask < Roby::Tasks::ExternalProcess
                event :stop do |context|
                    FileUtils.touch "/tmp/external_process_mockup_stop"
                end
            end

            describe "#handle_redirection" do
                before do
                    @working_directory = make_tmpdir
                    @task = ExternalProcess.new(working_directory: @working_directory)
                end
                def mock_pipe
                    pipe_r, pipe_w = flexmock, flexmock
                    flexmock(IO).should_receive(:pipe).once.and_return([pipe_r, pipe_w])
                    [pipe_r, pipe_w]
                end
                it "returns empty sets if no redirection has been set up" do
                    opened_ios, options = @task.handle_redirection
                    assert_equal [], opened_ios
                    assert_equal({}, options)
                end

                it "closes stdout" do
                    @task.redirect_output(stdout: :close)
                    opened_ios, options = @task.handle_redirection
                    assert_equal [], opened_ios
                    assert_equal Hash[out: :close], options
                end
                it "closes stderr" do
                    @task.redirect_output(stderr: :close)
                    opened_ios, options = @task.handle_redirection
                    assert_equal [], opened_ios
                    assert_equal Hash[err: :close], options
                end
                it "closes both stdout and stderr if given a single string" do
                    @task.redirect_output(:close)
                    opened_ios, options = @task.handle_redirection
                    assert_equal [], opened_ios
                    assert_equal Hash[out: :close, err: :close], options
                end

                it "creates a pipe for stdout" do
                    pipe_r, pipe_w = mock_pipe
                    @task.redirect_output(stdout: :pipe)
                    opened_ios, options = @task.handle_redirection
                    assert_equal [[:close, pipe_w]], opened_ios
                    assert_equal Hash[out: pipe_w], options
                end
                it "creates a pipe for stderr" do
                    pipe_r, pipe_w = mock_pipe
                    @task.redirect_output(stderr: :pipe)
                    opened_ios, options = @task.handle_redirection
                    assert_equal [[:close, pipe_w]], opened_ios
                    assert_equal Hash[err: pipe_w], options
                end
                it "creates two different pipes for stdout and stderr if given a single :pipe symbol" do
                    out_pipe_r, out_pipe_w = mock_pipe
                    err_pipe_r, err_pipe_w = mock_pipe
                    @task.redirect_output(:pipe)
                    opened_ios, options = @task.handle_redirection
                    assert_equal [[:close, out_pipe_w], [:close, err_pipe_w]], opened_ios
                    assert_equal Hash[out: out_pipe_w, err: err_pipe_w], options
                end

                describe "redirection to a file without substitution" do
                    before do
                        target_dir = make_tmpdir
                        @specified_target = File.join(target_dir, "out")
                    end

                    def self.common(c, arg, spawn_arg)
                        c.it "opens the target file directly" do
                            @task.redirect_output(**Hash[arg => @specified_target])
                            _, options = @task.handle_redirection
                            assert_equal @specified_target, options[spawn_arg].path
                        end

                        c.it "truncates the target file if the filename is not preceded by +" do
                            File.open(@specified_target, "w") { |io| io.puts "TEST" }
                            @task.redirect_output(**Hash[arg => @specified_target])
                            _, options = @task.handle_redirection
                            assert_equal 0, options[spawn_arg].stat.size
                        end

                        c.it "appends instead of truncating an existing target file if the filename is preceded by +" do
                            File.open(@specified_target, "w") { |io| io.puts "TEST" }
                            @task.redirect_output(**Hash[arg => "+#{@specified_target}"])
                            _, options = @task.handle_redirection
                            assert_equal 5, options[spawn_arg].stat.size
                        end

                        c.it "requests that the IO be closed after the spawn" do
                            @task.redirect_output(**Hash[arg => @specified_target])
                            opened_ios, options = @task.handle_redirection
                            assert_equal 1, opened_ios.size
                            assert_equal [[:close, options[spawn_arg]]], opened_ios
                        end
                    end

                    describe "stdout" do
                        common(self, :stdout, :out)
                    end

                    describe "stderr" do
                        common(self, :stderr, :err)
                    end
                end

                describe "with substitution" do
                    it "creates a temporary file in the working directory for stdout to enable substitutions" do
                        @task.redirect_output(stdout: "bla-%p")
                        opened_ios, options = @task.handle_redirection
                        assert_equal 1, opened_ios.size
                        target_file, io = opened_ios[0]
                        assert_equal "bla-%p", target_file
                        assert_equal @working_directory, File.dirname(io.path)
                        assert_equal Hash[out: io], options
                    end
                    it "creates a temporary file in the working directory for stderr to enable substitutions" do
                        @task.redirect_output(stderr: "bla-%p")
                        opened_ios, options = @task.handle_redirection
                        assert_equal 1, opened_ios.size
                        target_file, io = opened_ios[0]
                        assert_equal "bla-%p", target_file
                        assert_equal @working_directory, File.dirname(io.path)
                        assert_equal Hash[err: io], options
                    end
                    it "sets up a common target file if given a single string" do
                        @task.redirect_output("bla")
                        opened_ios, options = @task.handle_redirection
                        assert_equal 1, opened_ios.size
                        target_file, io = opened_ios[0]
                        assert_equal "bla", target_file
                        assert_equal @working_directory, File.dirname(io.path)
                        assert_equal Hash[out: io, err: io], options
                    end
                    it "sets up a common target file if given the same string for stdout and stderr" do
                        @task.redirect_output(stdout: "bla", stderr: "bla")
                        opened_ios, options = @task.handle_redirection
                        assert_equal 1, opened_ios.size
                        target_file, io = opened_ios[0]
                        assert_equal "bla", target_file
                        assert_equal @working_directory, File.dirname(io.path)
                        assert_equal Hash[out: io, err: io], options
                    end
                end
            end

            it "has a default-constructible initializer" do
                Tasks::ExternalProcess.new
            end

            def run_task(task)
                expect_execution { task.start! }.to { emit task.success_event }
            end

            describe "the execution workflow" do
                it "passes on command-line arguments" do
                    plan.add(task = Tasks::ExternalProcess.new(command_line: [MOCKUP, "--no-output"]))
                    expect_execution { task.start! }.to { emit task.success_event }
                end

                it "accepts a command line with a single command argument" do
                    plan.add(task = Tasks::ExternalProcess.new(command_line: [MOCKUP]))
                    task.redirect_output :close
                    expect_execution { task.start! }.to { emit task.success_event }
                end

                it "accepts a single command as string" do
                    plan.add(task = Tasks::ExternalProcess.new(command_line: MOCKUP))
                    task.redirect_output :close
                    expect_execution { task.start! }.to { emit task.success_event }
                end

                it "fails to start if the program does not exist" do
                    plan.add(task = Tasks::ExternalProcess.new(command_line: ["does_not_exist", "--error"]))
                    expect_execution { task.start! }
                        .to { fail_to_start task, reason: CommandFailed.match.with_original_exception(Errno::ENOENT) }
                end

                it "emits failed with the program status object if the program fails" do
                    plan.add(task = Tasks::ExternalProcess.new(command_line: [MOCKUP, "--error"]))
                    expect_execution { task.start! }.to { emit task.failed_event }
                    assert_equal 1, task.event(:failed).last.context.first.exitstatus
                end

                it "emits signaled with the program status if the program is terminated by a signal" do
                    plan.add(task = Tasks::ExternalProcess.new(command_line: [MOCKUP, "--block"]))
                    expect_execution { task.start! }.to { emit task.start_event }
                    expect_execution { Process.kill("KILL", task.pid) }
                        .to { emit task.failed_event }
                    assert task.signaled?

                    ev = task.signaled_event.last
                    assert_equal 9, ev.context.first.termsig
                end
            end

            describe "redirection" do
                def do_redirection(expected)
                    plan.add(task = Tasks::ExternalProcess.new(command_line: [MOCKUP]))
                    yield(task)

                    expect_execution { task.start! }.to { emit task.success_event }

                    assert File.exist?("mockup-#{task.pid}.log")
                    File.read("mockup-#{task.pid}.log")
                ensure
                    FileUtils.rm_f "mockup-#{task.pid}.log"
                end

                it "redirects stdout to file" do
                    do_redirection `#{MOCKUP}` do |task|
                        task.redirect_output stdout: "mockup-%p.log"
                    end
                end

                pipe_task_m = ExternalProcess.new_submodel do
                    attr_reader :received_data
                    def initialize(args = {})
                        super
                        @received_data = Hash[stderr: String.new, stdout: String.new]
                    end

                    def stdout_received(data)
                        @received_data[:stdout].concat(data)
                    end

                    def stderr_received(data)
                        @received_data[:stderr].concat(data)
                    end
                    event :stop do |context|
                        kill "INT"
                    end
                end

                it "redirects stdout to the task's handler" do
                    plan.add(task = pipe_task_m.new(command_line: [MOCKUP]))
                    task.redirect_output(stdout: :pipe, stderr: :close)
                    expect_execution { task.start! }.to { emit task.success_event }
                    assert_equal Hash[stdout: "FIRST LINE\nSECOND LINE\n", stderr: ""], task.received_data
                end

                it "redirects stderr to the task's handler" do
                    plan.add(task = pipe_task_m.new(command_line: [MOCKUP, "--stderr"]))
                    task.redirect_output(stdout: :close, stderr: :pipe)
                    expect_execution { task.start! }.to { emit task.success_event }
                    assert_equal Hash[stdout: "", stderr: "FIRST LINE\nSECOND LINE\n"], task.received_data
                end

                it "redirects both to the task's handlers at the same time" do
                    plan.add(task = pipe_task_m.new(command_line: [MOCKUP, "--common"]))
                    task.redirect_output(stdout: :pipe, stderr: :pipe)
                    expect_execution { task.start! }.to { emit task.success_event }
                    assert_equal Hash[stdout: "O: FIRST LINE\nO: SECOND LINE\n", stderr: "E: FIRST LINE\nE: SECOND LINE\n"],
                                 task.received_data
                end

                it "redirects stderr to file" do
                    do_redirection `#{MOCKUP}` do |task|
                        task.command_line << "--stderr"
                        task.redirect_output stderr: "mockup-%p.log"
                    end
                end

                it "redirects both channels to the same file" do
                    output = do_redirection(nil) do |task|
                        task.command_line << "--common"
                        task.redirect_output "mockup-%p.log"
                    end
                    expected = `#{MOCKUP} --common 2>&1`
                    assert_equal expected, output
                end
            end
        end
    end
end
